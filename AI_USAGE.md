# AI usage

> Working log. Kept as I go, cleaned up at the end.

## Tools
- Claude (claude.ai chat): planning, SQL drafts, test-suite scaffolding, review of my reasoning.

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

## My decisions vs. AI's
- Visit = deduped check-in (earliest copy per source_ref), case-insensitive type; a missing check-out does not cancel a visit.
- Only member_ids present in members count (drops turnstile test cards without hard-coding their IDs).
- Event time = least(event_ts, ingested_at), so fast device clocks are corrected without naming a device.
- Years, months and days are bucketed in the branch's IANA time zone, as half-open ranges.
- Visits by members whose membership was cancelled at the time are counted (the report counts visits that happened); flagged for the CRM team.
- Severity rule: blocking = the reports cannot be trusted even after their cleaning rules; warning = known and handled.

## How I verified AI-written SQL and code
- Every profiling count was re-run and compared with the earlier query outputs saved in profiling/.
- profiling/05_verify_rules.sql: out-of-hours access events drop 3,209 -> 172 -> 172 -> 0 as each rule is applied; deduped check-ins equal each entrance's highest sequence number.
- tests/test_reports.py recomputes visits_per_branch a second, independent way (anti-join instead of DISTINCT ON) and asserts both agree.
- Mutation test: on a scratch copy of the DB, injected one problem per blocking check (unknown type, wrong-branch device, ref collision, 3:30am check-in, check-out without check-in, invalid time zone). Every one failed the suite with exit code 1.
