-- reports/active_members_monthly.sql
-- One row per month of 2024 (2024-01 ... 2024-12): members whose membership is active in that month.
-- Postgres 17, read-only, self-contained.
--
-- Decisions (evidence in DATA_QUALITY.md):
-- 1. Business rule as written: a member is active in a month when their latest membership
--    event (membership_started / membership_reactivated / membership_cancelled) up to the
--    END of that month is membership_started or membership_reactivated. tier_changed does
--    not change state.
-- 2. "End of month" is the end of the calendar month in the time zone of the branch where
--    each membership event happened (business rule 5), via branches.timezone.
-- 3. The events are the source of truth, not members.status (they disagree for 49 members,
--    mostly because cancellations arrive in a monthly batch and members.status is not updated).
-- 4. CRM rows are deduplicated on source_ref (none are duplicated today; this guards against
--    retries like the ones the devices produce). Ties at the same timestamp are broken by event_id.
-- 5. Only member_ids present in members are counted.
-- 6. Known limitation: cancellations reach the database in a batch on the 2nd of the following
--    month, so the latest month's figure is provisional until then and will go DOWN when the
--    batch lands. Members with no membership events at all are not counted (2 such members).

WITH months AS (
    SELECT gs::date AS month_start, (gs + interval '1 month')::date AS next_month_start
    FROM generate_series(DATE '2024-01-01', DATE '2024-12-01', interval '1 month') AS gs
),
membership_events AS (
    SELECT DISTINCT ON (e.source_ref)
           e.member_id, e.event_type, e.event_id,
           e.event_ts AT TIME ZONE b.timezone AS local_ts
    FROM events e
    JOIN branches b ON b.branch_id = e.branch_id
    WHERE e.event_type IN ('membership_started', 'membership_reactivated', 'membership_cancelled')
      AND EXISTS (SELECT 1 FROM members m WHERE m.member_id = e.member_id)
    ORDER BY e.source_ref, e.event_ts, e.event_id
),
state_at_month_end AS (
    SELECT DISTINCT ON (mo.month_start, me.member_id)
           mo.month_start, me.member_id, me.event_type
    FROM months mo
    JOIN membership_events me ON me.local_ts < mo.next_month_start
    ORDER BY mo.month_start, me.member_id, me.local_ts DESC, me.event_id DESC
)
SELECT to_char(mo.month_start, 'YYYY-MM') AS month,
       count(s.member_id) AS active_members
FROM months mo
LEFT JOIN state_at_month_end s
       ON s.month_start = mo.month_start
      AND s.event_type IN ('membership_started', 'membership_reactivated')
GROUP BY mo.month_start
ORDER BY mo.month_start;
