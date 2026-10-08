-- reports/daily_visits.sql
-- One row per day of 2024 with any visit, all branches combined: member visits and friend visits.
-- Postgres 17, read-only, self-contained.
--
-- Decisions (same cleaning as visits_per_branch.sql; evidence in DATA_QUALITY.md):
-- 1. member_visits = check_in events; friend_visits = friend_visit events.
--    event_type matched case-insensitively.
-- 2. Rows sharing a source_ref are one event (retries, and replays re-stamped at resend
--    time); keep the earliest copy.
-- 3. Only member_ids present in members (excludes turnstile test cards).
-- 4. Event time = least(event_ts, ingested_at): corrects device clocks that run ahead
--    (one entrance was ~3h ahead for two months, which moved late-evening visits to the
--    next day).
-- 5. The day is the calendar day in the time zone of the branch where the event happened,
--    so one "date" combines each branch's own local day.
-- 6. Friend visits are counted even when no matching member check-in is found (55 in 2024):
--    the friend did come in; the missing check-in is flagged as a data issue, not a reason
--    to drop the friend. Visits by members whose membership was cancelled are counted too.
-- 7. Days with no visits at all are left out (allowed by the spec).

WITH access_events AS (
    SELECT DISTINCT ON (e.source_ref)
           lower(e.event_type) AS t, e.member_id, e.branch_id,
           least(e.event_ts, e.ingested_at) AS ts
    FROM events e
    WHERE lower(e.event_type) IN ('check_in', 'friend_visit')
    ORDER BY e.source_ref, e.event_ts, e.event_id
),
local_days AS (
    SELECT a.t, (a.ts AT TIME ZONE b.timezone)::date AS local_day
    FROM access_events a
    JOIN branches b ON b.branch_id = a.branch_id
    WHERE EXISTS (SELECT 1 FROM members m WHERE m.member_id = a.member_id)
)
SELECT to_char(local_day, 'YYYY-MM-DD') AS date,
       count(*) FILTER (WHERE t = 'check_in')     AS member_visits,
       count(*) FILTER (WHERE t = 'friend_visit') AS friend_visits
FROM local_days
WHERE local_day >= DATE '2024-01-01' AND local_day < DATE '2025-01-01'
GROUP BY local_day
ORDER BY local_day;
