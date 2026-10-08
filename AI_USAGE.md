# AI usage

> Working log. Kept as I go, cleaned up at the end.

## Tools
- Claude (claude.ai chat): planning, SQL drafts, test-suite scaffolding, review of my reasoning.
- Claude (agent with access to this repo folder): built `tools/mock_portal/` from my spec and added it to the repo, README and this log.

## Log

| # | Step | What the AI suggested | What I did (accepted / changed / rejected) | Why / how I verified |
|---|------|----------------------|--------------------------------------------|----------------------|
| 1 | Setup | Connect with `PGHOST=localhost PGPORT=5432` | Changed: ran the DB on 5433 with `PGHOST=127.0.0.1` | `psql` hit my local Homebrew Postgres on `::1` ("role fittrack does not exist"). Confirmed with `lsof` that two servers were on 5432. |
| 2 | Setup | Verify connection by expecting `inet_server_port()` = 5433 | Corrected: it returns 5432 | The function reports the port inside the container; Docker maps host 5433 to it. `current_database()` is the real proof. |
| 3 | Setup | Pasted shell commands with trailing `# comments` | Corrected | zsh does not treat `#` as a comment interactively; an apostrophe in a comment left the shell at `quote>`. Enabled `setopt interactivecomments`. |
| 4 | Profiling | Query 02-G flagged 5 Pearl District events "before the branch opened" as suspect | Re-classified | They are CRM pre-sale sign-ups, not access events. The real anomaly is those 5 members having home_branch_id 9 and status 'Active' (see 04, section 4b). |
| 5 | Profiling | First guess: fractional seconds are a fingerprint of a different code path | Partly rejected | Exit turnstiles always send milliseconds (~97% of check_outs), so fractions are normal there. They only mark the replayed copies on entrance and desk devices. |
| 6 | Test suite | Make "device clock ahead" (event_ts > ingested_at) a blocking check | Changed to warning | The visits report already corrects it with least(event_ts, ingested_at). A blocking check on historic, already-handled data would fail every CI run forever. Blocking is reserved for problems the reports cannot absorb; a residual check (anything still outside opening hours AFTER cleaning) is blocking instead. |
| 7 | Verification | A sanity query "deduped check-ins = distinct sequence numbers" | Rejected as a tautology | Both sides count the same distinct source_refs. Replaced with "deduped check-ins = highest sequence number issued", which is independent evidence (gap-free counters). |
| 8 | DATA_QUALITY.md | First draft said test cards add +53 visits to every branch, and that all 5 duplicate-email pairs were re-joiners | Corrected before publishing | Re-ran the counts: Pearl District gets +35 (it opened in May), and only 2 pairs are re-joiners; 2 were created twice on consecutive days, 1 was cancelled and re-created. Every number in the doc was then traced to a query in profiling/. |
| 9 | Bonus report | friend_allowance_monthly first version used a correlated subquery for the tier at month end | Rewritten | It took 30 s and slowed the suite to 89 s. Rewritten as a DISTINCT ON join (0.3 s); confirmed all 12 monthly values identical before and after. |
| 10 | Mock portal | First draft, written before the AI had seen the repo, guessed the schema: a `source_system` column, `payload` instead of `details`, psycopg2, tiers basic/plus/premium with friend limits 0/1/3, and writes into `public.events` | Changed by the AI when it was given the repo | Checked against `db/init/01_schema.sql` and `docs/ASSIGNMENT.md`: real columns are `details`/`device_id`, `event_id` has no default, tiers are basic/standard/premium with 2/3/8 friend visits. Writing to `public.events` would break the read-only rule and add fake rows to every count the test suite and `DATA_QUALITY.md` report, so the portal writes to a sandbox `mock_portal.events` (`LIKE public.events`) and marks injected rows with `event_id >= 9e9`. |
| 11 | Mock portal | The friend-breach burst spaced its events +1 s apart, moving forward in time | Corrected | The time-skew card showed 5 instead of 1: honest rows landed a few seconds after `ingested_at`. Now the burst is spaced backwards. |
| 12 | Test suite | I asked for checks on unknown event types, shared source_refs, invalid branches/devices and out-of-hours access after cleaning. The AI's first move was to point out all four already existed (E01, E07, E04/E05, A10) rather than duplicate them | Accepted, and widened | I agreed duplicates would add nothing, so we added checks for the gaps in each area instead: E11 documented type missing, E12 same ref with a different payload, E13 CRM ref reused, E14 replay copies more than 7 days apart, B05 device kind domain, A13 out-of-hours by non-members. All return 0 rows on this load. |
| 13 | Test suite | Also proposed B04 "device belongs to an unknown branch" | Rejected | On injection, Postgres refused the bad row: the schema has `devices.branch_id REFERENCES branches`. The other database shares the schema, so the check could never fire. A check that can't fail is dead weight; dropped it and documented the FK in DATA_QUALITY.md instead. |
| 14 | Test suite | Threshold for E14 (copies of one source_ref too far apart) | Set to 7 days from the data | The longest real replay gap is 3 d 22 h (profiling/02 B), so 7 days leaves headroom for a normal replay while still catching a counter reset. |

## My decisions vs. AI's
- Visit = deduped check-in (earliest copy per source_ref), case-insensitive type; a missing check-out does not cancel a visit.
- Only member_ids present in members count (drops turnstile test cards without hard-coding their IDs).
- Event time = least(event_ts, ingested_at), so fast device clocks are corrected without naming a device.
- Years, months and days are bucketed in the branch's IANA time zone, as half-open ranges.
- Visits by members whose membership was cancelled at the time are counted (the report counts visits that happened); flagged for the CRM team.
- Tier "in that month" for the friend allowance = tier in force at the end of the month (latest started/reactivated tier or tier_changed.to); members.membership_tier only as a fallback for members with no tier events.
- Friend visits are counted even without a matching member check-in (the friend came in; the missing check-in is the defect).
- Months and days are bucketed by the local time of the branch where each event happened, including CRM events.
- Severity rule: blocking = the reports cannot be trusted even after their cleaning rules; warning = known and handled.

## How I verified AI-written SQL and code
- Every profiling count was re-run and compared with the earlier query outputs saved in profiling/.
- profiling/05_verify_rules.sql: out-of-hours access events drop 3,209 -> 172 -> 172 -> 0 as each rule is applied; deduped check-ins equal each entrance's highest sequence number.
- Bonus reports cross-checked: the daily_visits total (71,899) equals the visits_per_branch total; monthly reports return exactly 2024-01 to 2024-12.
- profiling/06_report_impact.sql measures what each issue would do to each report if left uncleaned; those numbers are the "by how much" in DATA_QUALITY.md.
- tests/test_reports.py recomputes visits_per_branch a second, independent way (anti-join instead of DISTINCT ON) and asserts both agree.
- Second round of guards (E11-E14, B05, A13): injected one problem per check into a scratch copy; the 4 new blocking checks (E12, E13, E14, B05) and the existing ones in those areas (E01, E04, E05, E07, A10) all failed with exit code 1 and both warnings recorded their single injected row. Re-ran the full suite on the real DB afterwards: 49 passed, the same 17 warnings, exit 0, so nothing earlier broke.
- Mutation test: on a scratch copy of the DB, injected one problem per blocking check (unknown type, wrong-branch device, ref collision, 3:30am check-in, check-out without check-in, invalid time zone). Every one failed the suite with exit code 1.
- Mock portal: on a scratch Postgres loaded with `db/init/01_schema.sql`, each toggle was fired once and moved exactly its own card (1 / 1 / 2 / 1 / 1; a premium member's burst was 9 friend visits = limit 8 + 1). The `public.events` row count was unchanged, and cleanup deleted only the 19 injected rows.
