-- 06_report_impact.sql: how much each data issue would move each report if left uncleaned.
SET timezone = 'UTC';

\echo '== 1. daily_visits: naive (exact type, no dedupe, all member_ids, UTC day) vs clean, worst days'
WITH naive AS (
    SELECT (event_ts AT TIME ZONE 'UTC')::date AS d, count(*) FILTER (WHERE event_type = 'check_in') AS mv,
           count(*) FILTER (WHERE event_type = 'friend_visit') AS fv
    FROM events WHERE event_type IN ('check_in', 'friend_visit')
      AND event_ts >= '2024-01-01' AND event_ts < '2025-01-01' GROUP BY 1),
clean AS (
    SELECT (a.ts AT TIME ZONE b.timezone)::date AS d, count(*) FILTER (WHERE a.t = 'check_in') AS mv,
           count(*) FILTER (WHERE a.t = 'friend_visit') AS fv
    FROM (SELECT DISTINCT ON (source_ref) lower(event_type) AS t, member_id, branch_id, least(event_ts, ingested_at) AS ts
          FROM events WHERE lower(event_type) IN ('check_in', 'friend_visit') ORDER BY source_ref, event_ts, event_id) a
    JOIN branches b USING (branch_id)
    WHERE a.member_id IN (SELECT member_id FROM members) GROUP BY 1)
SELECT coalesce(n.d, c.d) AS day, n.mv AS naive_member, c.mv AS clean_member, n.mv - c.mv AS diff_member,
       n.fv AS naive_friend, c.fv AS clean_friend
FROM naive n FULL JOIN clean c ON c.d = n.d
WHERE coalesce(n.d, c.d) BETWEEN '2024-01-01' AND '2024-12-31'
ORDER BY abs(coalesce(n.mv, 0) - coalesce(c.mv, 0)) DESC LIMIT 8;

\echo '== 2. daily_visits: effect of each issue on its own (rows moved or added across 2024)'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id)
SELECT 'replay copies (re-stamped)' AS issue, count(*) AS rows_
  FROM events e WHERE lower(event_type) IN ('check_in', 'friend_visit')
   AND EXISTS (SELECT 1 FROM events o WHERE o.source_ref = e.source_ref AND o.event_ts < e.event_ts)
UNION ALL SELECT 'exact retry copies', count(*) - count(DISTINCT source_ref)
  FROM events e WHERE lower(event_type) IN ('check_in', 'friend_visit')
   AND NOT EXISTS (SELECT 1 FROM events o WHERE o.source_ref = e.source_ref AND o.event_ts < e.event_ts)
UNION ALL SELECT 'CHECK_IN casing (lost by exact match)', count(*) FROM events WHERE event_type = 'CHECK_IN'
UNION ALL SELECT 'test-card check-ins', count(*) FROM d WHERE lower(event_type) = 'check_in' AND member_id NOT IN (SELECT member_id FROM members)
UNION ALL SELECT 'D07 clock: visits landing on the wrong local day', count(*)
  FROM d JOIN branches b USING (branch_id)
  WHERE lower(event_type) IN ('check_in', 'friend_visit') AND event_ts > ingested_at
    AND (event_ts AT TIME ZONE b.timezone)::date <> (ingested_at AT TIME ZONE b.timezone)::date
UNION ALL SELECT 'UTC instead of local day (check-ins)', count(*)
  FROM d JOIN branches b USING (branch_id)
  WHERE lower(event_type) = 'check_in'
    AND (least(event_ts, ingested_at) AT TIME ZONE 'UTC')::date <> (least(event_ts, ingested_at) AT TIME ZONE b.timezone)::date;

\echo '== 3. active_members_monthly: events-based (report) vs members.status vs "as known on the last day of the month"'
WITH months AS (SELECT gs::date AS ms, (gs + interval '1 month')::date AS nx
                FROM generate_series(DATE '2024-01-01', DATE '2024-12-01', interval '1 month') gs),
me AS (SELECT e.member_id, e.event_type, e.event_id, e.ingested_at, e.event_ts AT TIME ZONE b.timezone AS lt
       FROM events e JOIN branches b USING (branch_id)
       WHERE e.event_type IN ('membership_started', 'membership_reactivated', 'membership_cancelled')),
final AS (SELECT DISTINCT ON (mo.ms, me.member_id) mo.ms, me.event_type
          FROM months mo JOIN me ON me.lt < mo.nx ORDER BY mo.ms, me.member_id, me.lt DESC, me.event_id DESC),
as_known AS (SELECT DISTINCT ON (mo.ms, me.member_id) mo.ms, me.event_type
             FROM months mo JOIN me ON me.lt < mo.nx AND me.ingested_at < (mo.nx::timestamp AT TIME ZONE 'America/Los_Angeles')
             ORDER BY mo.ms, me.member_id, me.lt DESC, me.event_id DESC)
SELECT to_char(mo.ms, 'YYYY-MM') AS month,
       (SELECT count(*) FROM final f WHERE f.ms = mo.ms AND f.event_type <> 'membership_cancelled') AS final_figure,
       (SELECT count(*) FROM as_known k WHERE k.ms = mo.ms AND k.event_type <> 'membership_cancelled') AS if_run_at_month_end,
       (SELECT count(*) FROM members WHERE lower(status) = 'active') AS members_status_active_today
FROM months mo ORDER BY 1;

\echo '== 4. friend_allowance_monthly: tier from events vs members.membership_tier, and naive friend counts'
WITH a AS (SELECT DISTINCT ON (source_ref) lower(event_type) t, member_id, branch_id, least(event_ts, ingested_at) ts
           FROM events WHERE lower(event_type) IN ('check_in', 'friend_visit') ORDER BY source_ref, event_ts, event_id),
raw AS (SELECT lower(event_type) t, member_id, branch_id, event_ts ts FROM events WHERE lower(event_type) IN ('check_in', 'friend_visit'))
SELECT 'friend_visit rows, raw' AS what, count(*) FROM raw WHERE t = 'friend_visit'
UNION ALL SELECT 'friend_visit rows, deduped', count(*) FROM a WHERE t = 'friend_visit'
UNION ALL SELECT 'members whose members.membership_tier disagrees with events', count(*)
  FROM members m JOIN (SELECT DISTINCT ON (member_id) member_id,
                         CASE WHEN event_type = 'tier_changed' THEN details->>'to' ELSE details->>'tier' END AS tier
                       FROM events WHERE event_type IN ('membership_started', 'membership_reactivated', 'tier_changed')
                       ORDER BY member_id, event_ts DESC, event_id DESC) t USING (member_id)
  WHERE m.membership_tier <> t.tier;
