-- reports/visits_per_branch.sql
-- One row per branch: the number of member visits that started in 2024.
-- Postgres 17, read-only, self-contained (uses only branches, members, events).
--
-- Counting decisions (evidence and counts are in DATA_QUALITY.md):
--
-- 1. A visit = one check_in at the branch's entrance.
--    - A missing check_out does not cancel the visit. Exit turnstiles lose events
--      (e.g. a 27-event sequence gap on one exit device), and the member still came in.
--    - event_type is matched case-insensitively: one entrance sent 'CHECK_IN' for a week,
--      and those rows are real visits with no lowercase twin.
--    - Rows sharing a source_ref are the same physical event (device sequence numbers
--      are gap-free and time-ordered). They come from at-least-once retries (identical
--      copies) and from device replays that re-stamp the copy with the resend time.
--      We keep the EARLIEST copy, because the later copy's event_ts is not when it happened.
--
-- 2. Only members count. Events whose member_id is not in members are excluded:
--    in this database they are turnstile test cards (Mondays at opening, ~1 min visits).
--    Visits by members whose membership was cancelled at the time ARE counted: the
--    report counts visits that happened, not visits the member was entitled to.
--    (Flagged in DATA_QUALITY.md as a question for the CRM team.)
--
-- 3. Event time = least(event_ts, ingested_at). An event cannot happen after it
--    reached the database; when a device clock runs ahead (one entrance was ~3h ahead
--    for two months), ingestion time is the best estimate (normal lag is ~13 s).
--    A clock that runs slow cannot be told apart from late delivery, so it is not corrected.
--
-- 4. "2024" is the calendar year in the branch's own time zone (IANA name from
--    branches.timezone, so DST and Arizona's lack of it are handled), as a half-open range.
--
-- Branches with no visits are still listed, with 0.

WITH access_events AS (
    -- Rule 1: one row per source_ref, keeping the original (earliest) copy.
    SELECT DISTINCT ON (e.source_ref)
           e.source_ref, e.event_type, e.member_id, e.branch_id, e.event_ts, e.ingested_at
    FROM events e
    WHERE lower(e.event_type) = 'check_in'
    ORDER BY e.source_ref, e.event_ts, e.event_id
),
visits AS (
    SELECT a.branch_id
    FROM access_events a
    JOIN branches b ON b.branch_id = a.branch_id
    WHERE EXISTS (SELECT 1 FROM members m WHERE m.member_id = a.member_id)          -- Rule 2
      AND (least(a.event_ts, a.ingested_at) AT TIME ZONE b.timezone)                 -- Rules 3 + 4
            >= TIMESTAMP '2024-01-01 00:00:00'
      AND (least(a.event_ts, a.ingested_at) AT TIME ZONE b.timezone)
            <  TIMESTAMP '2025-01-01 00:00:00'
)
SELECT b.branch_id,
       b.name AS branch_name,
       count(v.branch_id) AS member_visits
FROM branches b
LEFT JOIN visits v ON v.branch_id = b.branch_id
GROUP BY b.branch_id, b.name
ORDER BY b.branch_id;
