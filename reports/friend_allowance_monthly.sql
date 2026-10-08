-- reports/friend_allowance_monthly.sql
-- One row per month of 2024: average share of their monthly friend allowance that members used.
-- Postgres 17, read-only, self-contained.
--
-- Definition (from the spec): for every member who visited at least once in the month, take the
-- friend visits they brought that month, capped at their allowance, divide by the allowance;
-- average across those members; percentage with one decimal.
-- Allowance per month by tier: basic 2, standard 3, premium 8.
--
-- Decisions (evidence in DATA_QUALITY.md):
-- 1. Visits and friend visits use the same cleaning as the other reports: dedupe on source_ref
--    keeping the earliest copy, case-insensitive types, real members only,
--    time = least(event_ts, ingested_at), month = calendar month in the branch's time zone.
-- 2. "Visited at least once" = at least one check_in in that local month, at any branch.
-- 3. Friend visits count even without a matching check-in (the member is in the denominator
--    only if they also checked in some time that month).
-- 4. "Tier in that month" = the tier in force at the END of the month: the latest of
--    membership_started.tier / membership_reactivated.tier / tier_changed.to up to month end
--    (branch-local). A cancellation keeps the last tier. If a member has no tier events at all,
--    members.membership_tier is used as a fallback (2 members in this database).
-- 5. Months with no visiting members return NULL rather than being dropped.

WITH months AS (
    SELECT gs::date AS month_start, (gs + interval '1 month')::date AS next_month_start
    FROM generate_series(DATE '2024-01-01', DATE '2024-12-01', interval '1 month') AS gs
),
access_events AS (
    SELECT DISTINCT ON (e.source_ref)
           lower(e.event_type) AS t, e.member_id, e.branch_id,
           least(e.event_ts, e.ingested_at) AS ts
    FROM events e
    WHERE lower(e.event_type) IN ('check_in', 'friend_visit')
    ORDER BY e.source_ref, e.event_ts, e.event_id
),
access_by_month AS (
    SELECT a.member_id,
           date_trunc('month', a.ts AT TIME ZONE b.timezone)::date AS month_start,
           count(*) FILTER (WHERE a.t = 'check_in')     AS visits,
           count(*) FILTER (WHERE a.t = 'friend_visit') AS friend_visits
    FROM access_events a
    JOIN branches b ON b.branch_id = a.branch_id
    WHERE EXISTS (SELECT 1 FROM members m WHERE m.member_id = a.member_id)
    GROUP BY 1, 2
),
tier_events AS (
    SELECT DISTINCT ON (e.source_ref)
           e.member_id, e.event_id,
           e.event_ts AT TIME ZONE b.timezone AS local_ts,
           CASE WHEN e.event_type = 'tier_changed' THEN e.details->>'to' ELSE e.details->>'tier' END AS tier
    FROM events e
    JOIN branches b ON b.branch_id = e.branch_id
    WHERE e.event_type IN ('membership_started', 'membership_reactivated', 'tier_changed')
    ORDER BY e.source_ref, e.event_ts, e.event_id
),
tier_at_month_end AS (
    SELECT DISTINCT ON (mo.month_start, te.member_id)
           mo.month_start, te.member_id, te.tier
    FROM months mo
    JOIN tier_events te ON te.local_ts < mo.next_month_start
    ORDER BY mo.month_start, te.member_id, te.local_ts DESC, te.event_id DESC
),
visitors AS (
    SELECT a.month_start, a.member_id, a.friend_visits,
           coalesce(t.tier, m.membership_tier) AS tier
    FROM access_by_month a
    JOIN months mo ON mo.month_start = a.month_start
    JOIN members m ON m.member_id = a.member_id
    LEFT JOIN tier_at_month_end t ON t.month_start = a.month_start AND t.member_id = a.member_id
    WHERE a.visits > 0
),
utilization AS (
    SELECT month_start,
           least(friend_visits, allowance)::numeric / allowance AS used_share
    FROM (SELECT v.*, CASE lower(v.tier) WHEN 'basic' THEN 2 WHEN 'standard' THEN 3 WHEN 'premium' THEN 8 END AS allowance
          FROM visitors v) x
    WHERE allowance IS NOT NULL
)
SELECT to_char(mo.month_start, 'YYYY-MM') AS month,
       round(100 * avg(u.used_share), 1) AS avg_utilization_pct
FROM months mo
LEFT JOIN utilization u ON u.month_start = mo.month_start
GROUP BY mo.month_start
ORDER BY mo.month_start;
