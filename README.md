# FitTrack data quality

Data-quality test suite, report queries and findings for the FitTrack home assignment
(the original brief is in [`docs/ASSIGNMENT.md`](docs/ASSIGNMENT.md)).

| What | Where |
|---|---|
| Test suite (one command, CI-ready) | [`tests/`](tests/) |
| Findings: root causes, evidence, impact, questions, monitoring | [`DATA_QUALITY.md`](DATA_QUALITY.md) |
| Required report | [`reports/visits_per_branch.sql`](reports/visits_per_branch.sql) |
| Bonus reports | [`reports/active_members_monthly.sql`](reports/active_members_monthly.sql), [`reports/daily_visits.sql`](reports/daily_visits.sql), [`reports/friend_allowance_monthly.sql`](reports/friend_allowance_monthly.sql) |
| How AI was used, corrected and verified | [`AI_USAGE.md`](AI_USAGE.md) |
| Exploration and proof queries, with saved outputs | [`profiling/`](profiling/) |
| Mock CRM & access-control portal: trigger the issues live and watch the anomaly counts | [`tools/mock_portal/`](tools/mock_portal/) |

## Run the test suite

Requirements: Python 3.10+ and a reachable Postgres. The suite reads its connection **only** from the standard
`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and `PGPASSWORD` environment variables, so it runs unchanged against
any database with this schema. It connects read-only and never writes.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=fittrack PGUSER=fittrack PGPASSWORD=fittrack
pytest
```

`pytest` is the one command. Its exit code is the verdict:

| Exit code | Meaning |
|---|---|
| `0` | No blocking problem. Reports can go out. Known, handled issues are listed under **data-quality warnings** at the end of the output. |
| `1` | At least one blocking check failed. Each failure prints the rule, the number of offending rows and a sample of them. |
| `2` | A connection setting is missing (for example `PGHOST` not exported). |

Against the provided database: **51 passed, 18 warnings, exit code 0**, in about 8 seconds.

### Running the database locally

```bash
docker compose up -d --wait                              # first start loads db/init (a few seconds)
cp .env.example .env && source .env                      # the same PG* variables as above
```

If port 5432 is already taken by a local Postgres (it was on my machine), start it with
`FITTRACK_DB_PORT=5433 docker compose up -d --wait` and set `PGPORT=5433`. Use `127.0.0.1` rather than
`localhost`, so `psql` cannot reach a different server on IPv6 `::1`.

### Useful variations

```bash
pytest -m blocking                      # only the checks that gate the reports
pytest -m warning                       # only the known-issue trackers
pytest -k A03                           # one check, by id
pytest tests/test_reports.py            # only the report-query tests
pytest --junitxml=dq-results.xml        # machine-readable results for CI
```

### In CI

[`.github/workflows/data-quality.yml`](.github/workflows/data-quality.yml) does what a CI job against every
new load would do: it starts the database, runs `pytest` (the job fails on any blocking check), runs every
report with `psql -f` in a read-only session the way the reviewers will, and keeps the JUnit results. To
point it at another database, set the `PG*` variables as repository secrets instead of starting Docker.

## What the suite checks

Each check is one SQL query that returns the rows breaking a rule. Zero rows is a pass. Each check has a
severity:

- **blocking**: the reports cannot be trusted even after their cleaning rules (for example an unknown
  `event_type`, a `source_ref` shared by two different events, an access event still outside opening hours
  after cleaning, or an invalid branch time zone). The test fails.
- **warning**: a known issue the reports already correct for (duplicates, replays, clock skew, test cards,
  late CRM data). The test passes and the issue is listed in the run summary, so trends stay visible without
  blocking every run on historical data the reports already handle.

| File | Covers |
|---|---|
| `tests/test_events_contract.py` | Event types and casing (and documented types that go missing), required fields, branch and device references, `source_ref` format, collisions across members, payloads, CRM refs and replay distance, JSON payloads, unknown members |
| `tests/test_access_events.py` | Retries, re-stamped replays, duplicate bursts above a daily threshold, device clocks ahead, sequence gaps, missing check-outs, friend visits without a member, visits without an active membership, plus residual checks after cleaning |
| `tests/test_branches_devices.py` | Valid IANA time zones, opening hours, one entrance/exit/desk per branch, valid device kinds |
| `tests/test_members.py` | Status and tier values, home branch, duplicate people, placeholder birth dates, `members` vs events, membership event order, tier changes outside a membership, late CRM data |
| `tests/test_reports.py` | Every report runs read-only and has the agreed columns and rows; `visits_per_branch` matches an independent recount; daily and per-branch totals agree |

**Proving the checks can fail.** On a scratch copy of the database I injected one problem per blocking check
(an unknown type, a wrong-branch device, a `source_ref` collision, a 3:30am check-in, a check-out without a
check-in, an invalid time zone). Every one failed the suite with exit code 1. The same was done for the second
round of contract guards (`E11`–`E14`, `B05`, `A13`): every blocking check failed, and every warning
recorded its injected row. See `AI_USAGE.md`.

### Adding a check

Append a `Check` to the `CHECKS` list of the relevant `tests/test_*.py` file (or a new `tests/test_*.py`
with the same three-line test at the bottom):

```python
Check(
    "A13_visit_longer_than_6h",                          # id: shown in output, usable with -k
    "check_in followed by its check_out more than 6 h later",
    WARNING,                                             # or BLOCKING
    """
    SELECT ...  -- return the violating rows; no trailing semicolon
    """,
),
```

No other wiring is needed. The id, severity marker and summary output come from `tests/dq.py`.

## Reports

Each report is one self-contained Postgres query: it uses only the four source tables, needs no views or
functions, and runs with `psql -f` in a read-only session. The counting decisions are explained in comments
at the top of each file. In short, all of them:

1. treat rows sharing a `source_ref` as one event and keep the earliest copy (retries, and device replays
   re-stamped at the resend time);
2. match `event_type` case-insensitively;
3. count only `member_id`s present in `members` (this excludes turnstile test cards);
4. use `least(event_ts, ingested_at)` as the event time (a device clock running ahead is capped at the
   moment the row arrived);
5. bucket days, months and years in the local time zone of the branch where the event happened.

`DATA_QUALITY.md` explains why each rule exists and how much each report would be off without it.
`profiling/05_verify_rules.sql` proves the rules work: out-of-hours access events go 3,209 → 172 → 172 → 0
as they are applied.

## Mock portal: reproduce the issues live

A small local web app that plays the two source systems. You send CRM events
(`membership_started`, `membership_cancelled`, `tier_changed`) and access events (`check_in`, `check_out`,
`friend_visit`), with toggles that reproduce the defects found in `DATA_QUALITY.md`, and watch them appear in a
live table and on five anomaly cards.

| Toggle | Reproduces | Card that moves |
|---|---|---|
| Casing bug | `CHECK_IN` instead of `check_in` | Uppercase `CHECK_IN` |
| Duplicate `source_ref` | the same event sent twice (retry) | Duplicate `source_ref` |
| Invalid tier name | `Platinum++` in `details` | (visible in the table) |
| Unclosed visit | a `check_in` 12 h ago with no `check_out` | Unmatched / orphaned visits |
| `check_out` with no `check_in` | a lost entrance event | Unmatched / orphaned visits |
| Friend allowance breach | the member's real tier limit + 1 friend visits in one month | Friend allowance breaches |
| Clock skew | `event_ts` 2 h ahead of `ingested_at` | Time skew |

```bash
docker compose up -d --wait && source .env          # the database from "Running the database locally"
pip install -r tools/mock_portal/requirements.txt
python tools/mock_portal/app.py                      # http://127.0.0.1:5050
```

**It never writes to the source tables.** The assignment treats them as read-only, and the test suite must keep
reading the real load. On start the portal creates its own sandbox, `mock_portal.events`
(`LIKE public.events INCLUDING ALL`, so same columns, types and constraints), and writes only there. Injected
rows get `event_id >= 9,000,000,000`, and the **Delete all injected events** button removes only those. `pytest`
results are unaffected. It reads `public.members` to look up each member's real tier. To drop the sandbox
entirely: `psql -c "DROP SCHEMA mock_portal CASCADE"`.

Flask plus psycopg 3, one HTML page with Tailwind from its CDN (the page needs internet for styling). Under 150
lines in total.

## Repository layout

```
reports/      the four report queries
tests/        the data-quality suite (dq.py = check model and runner)
profiling/    exploration and proof queries, numbered in the order I ran them, with outputs
db/init/      provided schema and data (loaded by docker compose)
docs/         the original assignment brief
tools/        mock_portal: local web app to reproduce the data-quality issues live
```

## Time spent

About **3.5 hours** in total, over two sessions (Wednesday evening and Thursday morning): understanding the
brief and setting up, profiling the data, running and checking the SQL, designing the counting rules and the
extra validation checks, and writing the documents.

Most of the SQL, Python and first drafts of the documents were written with AI and then checked by me:
re-running counts, cross-checking the reports against each other, and injecting known problems to prove the
checks fail. `AI_USAGE.md` describes how.
