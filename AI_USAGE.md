# AI usage

> Working log. Kept as I go, cleaned up at the end.

## Tools
- Claude (claude.ai chat): planning, SQL drafts, test-suite scaffolding, review of my reasoning.

## Log

| # | Step | What the AI suggested | What I did (accepted / changed / rejected) | Why / how I verified |
|---|------|----------------------|--------------------------------------------|----------------------|
| 1 | Setup | Connect with `PGHOST=localhost PGPORT=5432` | Changed: ran the DB on 5433 with `PGHOST=127.0.0.1` | `psql` hit my local Homebrew Postgres on `::1` ("role fittrack does not exist"). Confirmed with `lsof` that two servers were on 5432. |

## My decisions vs. AI's
- (fill in as we go)

## How I verified AI-written SQL and code
- (fill in as we go)
