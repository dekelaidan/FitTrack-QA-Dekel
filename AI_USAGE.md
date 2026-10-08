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

## My decisions vs. AI's
- (fill in as we go)

## How I verified AI-written SQL and code
- (fill in as we go)
