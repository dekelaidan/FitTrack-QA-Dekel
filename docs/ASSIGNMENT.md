# FitTrack — Senior QA Engineer (Data Quality) home assignment

FitTrack runs eight gyms across four US time zones. Two systems write into one
Postgres database:

- the **CRM** records memberships: sign-ups, tier changes, cancellations and
  reactivations;
- the **access-control system**, made up of entrance and exit turnstiles plus a
  front-desk tablet at every branch, records each check-in, each check-out and
  each friend a member brings along.

Management reports on this data and needs to know it can be trusted every day. You
are the senior QA engineer who owns that question.

## Getting the data

You need Docker.

```bash
docker compose up -d --wait        # the first start loads the data (a few seconds)
```

| Setting  | Value       |
| -------- | ----------- |
| host     | `localhost` |
| port     | `5432` — set `FITTRACK_DB_PORT=5433` before `docker compose up` if 5432 is taken |
| database | `fittrack`  |
| user     | `fittrack`  |
| password | `fittrack`  |

`docker compose down -v` deletes the data, and the next `up` reloads it from scratch. Treat
the four source tables as read-only; create views, schemas or tables of your own
freely.

## The data

**`branches`** — one row per gym. `timezone` is an IANA zone name. `opens_at` and `closes_at`
are local opening hours and apply every day.

**`devices`** — the access-control devices: `kind` is `entrance` (turnstile in),
`exit` (turnstile out) or `front_desk` (tablet).

**`members`** — one row per member: profile data (`first_name`, `last_name`,
`email`, `date_of_birth`, `home_branch_id`, `joined_on`), plus the CRM's current
view of the member's `membership_tier` (`basic` / `standard` / `premium`) and
`status` (`active` / `cancelled`).

**`events`** — everything that happened, from both systems.

| column        | meaning |
| ------------- | ------- |
| `event_id`    | Primary key of the row in this database. |
| `source_ref`  | Identifier assigned by the sending system: `crm:<n>` for CRM events, `<device_id>:<sequence>` for device events. |
| `member_id`   | The member the event is about. |
| `event_type`  | See below. |
| `event_ts`    | When the event happened, as reported by the sending system. |
| `branch_id`   | Branch where it happened. |
| `device_id`   | Device that recorded it (empty for CRM events). |
| `ingested_at` | When the row landed in this database. |
| `details`     | JSON payload, per event type. |

| `event_type`             | sent by | `details` |
| ------------------------ | ------- | --------- |
| `membership_started`     | CRM | `{"tier": ...}` |
| `membership_reactivated` | CRM | `{"tier": ...}` — a former member re-joins |
| `membership_cancelled`   | CRM | `{"reason": ...}` |
| `tier_changed`           | CRM | `{"from": ..., "to": ...}` |
| `check_in`               | entrance turnstile | — |
| `check_out`              | exit turnstile | — |
| `friend_visit`           | front-desk tablet | `{"friend_name": ...}` — a friend entering with the member |

Membership history goes back to 2021; access events cover 2024.

## Business rules

1. **Membership state comes from `events`.** A membership is active from
   `membership_started` (or `membership_reactivated`) until `membership_cancelled`.
2. **Active in a month.** A member counts as active in a month when their latest
   membership event up to the end of that month is `membership_started` or
   `membership_reactivated`.
3. **A visit** starts with a `check_in` at a branch's entrance and ends with a
   `check_out` at the same branch's exit.
4. **Bring a friend.** A member may bring a friend along on a visit; the front desk
   records it as a `friend_visit`. A friend can only come in together with the
   member. Each calendar month a member may bring friends this many times,
   depending on their tier in that month:

   | tier     | friend visits per month |
   | -------- | ----------------------- |
   | basic    | 2 |
   | standard | 3 |
   | premium  | 8 |

5. **Local time.** Days and months are calendar days and months in the time zone of
   the branch where the event happened.

## What to deliver

Push everything to a **GitHub repository** and send us the link. Make it public, or
private with access granted to the reviewer named in your invitation email. We read
the **commit history**, so commit as you go, and please don't squash.

### 1. A data-quality test suite

Use any language and tools you like. It must run with **one command**, exit non-zero
when it finds a problem that should stop reports going out, and be something we could
run in CI against every new load of this database.

### 2. `DATA_QUALITY.md`

Your report on the data. For each issue, give:
- what it is;
- your evidence (the query and the count);
- its severity;
- which reports it affects (the required one and any bonus ones you wrote), and by
  roughly how much;
- the most likely cause.

When one root cause (a single bug, a misconfiguration, or one missing piece of logic)
explains several of the symptoms you saw, group them under it and say so. Finish with
the questions you'd put to the teams that own the CRM and the access-control system,
and what you'd monitor from now on.

### 3. One report query

A report is an **SQL query** that returns the report's data. Write this one to
`reports/visits_per_branch.sql`:

| columns | one row per |
| ------- | ----------- |
| `branch_id`, `branch_name`, `member_visits` | branch, with its members' visits in 2024 |

The file holds **one query** for Postgres 17; CTEs are fine. We run it exactly as it is,
with `psql -f` in a read-only session, against two databases: a fresh copy of this one,
and a different database with the same schema. So it must stand on its own and can't
depend on tables, views or functions you created. The same applies to the bonus
queries below.

Treat the data as you would a production feed: decide what counts, and write down
the decisions you made. Comments in the SQL are a good place for them.

### 4. `AI_USAGE.md`

We expect you to use AI tools, and we want to understand how you work with them.
Describe:
- the tools you used;
- which ideas, checks and decisions were yours and which were the AI's;
- concrete cases where you rejected or corrected AI output, and why;
- how you verified the SQL and code the AI wrote.

### 5. `README.md`

Explain how to run the test suite. It must read its database connection from the
standard Postgres environment variables (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`,
`PGPASSWORD`), because **we will run it against a different database with the same
schema**. Note how long you spent.

### Bonus: three more report queries

Optional, and worth extra credit. Same rules as the required query, in the same
`reports/` folder, covering 2024:

| file | columns | one row per |
| ---- | ------- | ----------- |
| `reports/active_members_monthly.sql` | `month` (`YYYY-MM`), `active_members` | month, 2024-01 … 2024-12 |
| `reports/daily_visits.sql` | `date` (`YYYY-MM-DD`), `member_visits`, `friend_visits` | day of 2024, all branches combined (a day with no visits may be left out) |
| `reports/friend_allowance_monthly.sql` | `month`, `avg_utilization_pct` | month, 2024-01 … 2024-12 |

`avg_utilization_pct` is the average share of their friend allowance that members
used. For every member who visited at least once in the month, take the friend visits
they brought that month (counting at most their allowance) and divide by their
allowance. Average across those members and express it as a percentage with one
decimal.

## Time

Most people spend 3–5 hours. Please don't spend more than a day; we'd rather see a
well-reasoned subset than an exhaustive one.

## How we evaluate

- **Report queries:** correctness, on this database and on a different one with the
  same schema. Bonus queries earn extra credit; leaving them out costs nothing.
- **The test suite:** range, rigour, and how easy it is to run and extend.
- **`DATA_QUALITY.md`:** what you found, how you proved it, how you prioritised it,
  and how well you explained causes.
- **`AI_USAGE.md`:** honesty and judgment.
- **Commit history:** how the work progressed.

Questions? Reply to the invitation email — we would rather clarify than have you guess.
