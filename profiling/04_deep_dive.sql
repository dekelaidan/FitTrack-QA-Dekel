-- 04_deep_dive.sql: confirm root causes behind the signals found in 01-03.
-- All timestamps printed in UTC so results are comparable across machines.
SET timezone = 'UTC';

\echo '== 1. Replay bursts: non-identical duplicate copies land in two bursts, all devices, ~07:1x UTC'
WITH r AS (
  SELECT e.*, row_number() OVER (PARTITION BY source_ref ORDER BY event_ts, event_id) AS rn,
         count(*) OVER (PARTITION BY source_ref, event_ts) AS same_ts
  FROM events e WHERE device_id IS NOT NULL)
SELECT event_ts::date AS replay_day, count(*) AS replayed_rows, count(DISTINCT device_id) AS devices,
       min(event_ts)::time AS first_at, max(event_ts)::time AS last_at,
       min(ingested_at - event_ts) AS min_lag, max(ingested_at - event_ts) AS max_lag
FROM r WHERE rn > 1 AND same_ts = 1 GROUP BY 1 ORDER BY 1;

\echo '== 2. After dedupe (earliest copy per source_ref), what is still outside opening hours?'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id)
SELECT d.device_id, count(*) AS outside_hours,
       count(*) FILTER (WHERE d.event_ts > d.ingested_at) AS stamped_after_ingest
FROM d JOIN branches b USING (branch_id)
WHERE d.device_id IS NOT NULL
  AND ((d.event_ts AT TIME ZONE b.timezone)::time <  b.opens_at
    OR (d.event_ts AT TIME ZONE b.timezone)::time >= b.closes_at)
GROUP BY 1 ORDER BY 2 DESC;

\echo '== 3. D07-IN clock: events stamped after they were ingested, window and offset'
SELECT device_id, min(event_ts) AS first_bad, max(event_ts) AS last_bad, count(*) AS rows_,
       min(event_ts - ingested_at) AS min_ahead, max(event_ts - ingested_at) AS max_ahead
FROM events WHERE event_ts > ingested_at GROUP BY 1;

\echo '== 4. Events for member_ids not in members (deduped; times in branch local time)'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id)
SELECT d.member_id, lower(d.event_type) AS t, count(*) AS rows_,
       string_agg(DISTINCT d.branch_id::text, ',') AS branches,
       min((d.event_ts AT TIME ZONE b.timezone)::time) AS earliest_local, max((d.event_ts AT TIME ZONE b.timezone)::time) AS latest_local,
       string_agg(DISTINCT to_char(d.event_ts AT TIME ZONE b.timezone, 'Dy'), ',') AS weekdays
FROM d JOIN branches b USING (branch_id)
WHERE NOT EXISTS (SELECT 1 FROM members m WHERE m.member_id = d.member_id)
GROUP BY 1,2 ORDER BY 1,2;

\echo '== 4b. Pearl District (branch 8) activity before it opened, and members with unknown home branch'
SELECT e.member_id, e.event_type, e.event_ts, m.home_branch_id, m.status
FROM events e JOIN branches b USING (branch_id) LEFT JOIN members m USING (member_id)
WHERE (e.event_ts AT TIME ZONE b.timezone)::date < b.opened_on
UNION ALL
SELECT m.member_id, '(member row)', NULL, m.home_branch_id, m.status
FROM members m WHERE m.home_branch_id NOT IN (SELECT branch_id FROM branches)
ORDER BY 1, 3 NULLS LAST;

\echo '== 5. Device sequence gaps (events the device numbered but we never received)'
WITH s AS (SELECT DISTINCT device_id, split_part(source_ref, ':', 2)::int AS seq FROM events WHERE device_id IS NOT NULL),
g AS (SELECT device_id, seq, lead(seq) OVER (PARTITION BY device_id ORDER BY seq) AS nxt FROM s)
SELECT device_id, seq + 1 AS first_missing, nxt - 1 AS last_missing, nxt - seq - 1 AS missing,
       (SELECT max(event_ts) FROM events e WHERE e.source_ref = g.device_id || ':' || lpad(g.seq::text, 7, '0')) AS last_before_gap,
       (SELECT min(event_ts) FROM events e WHERE e.source_ref = g.device_id || ':' || lpad(g.nxt::text, 7, '0')) AS first_after_gap
FROM g WHERE nxt - seq > 1;

\echo '== 6. Visit pairing (deduped, real members, ts capped at ingested_at): what follows each check_in / check_out'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id),
a AS (SELECT member_id, branch_id, lower(event_type) AS t, least(event_ts, ingested_at) AS ts, event_id
      FROM d WHERE lower(event_type) IN ('check_in', 'check_out')
        AND member_id IN (SELECT member_id FROM members)),
s AS (SELECT *, lead(t) OVER w AS next_t, lead(branch_id) OVER w AS next_branch, lag(t) OVER w AS prev_t
      FROM a WINDOW w AS (PARTITION BY member_id ORDER BY ts, event_id))
SELECT t, coalesce(next_t, '(end)') AS next_t, next_branch = branch_id AS same_branch, count(*)
FROM s GROUP BY 1,2,3 ORDER BY 1,2,3;

\echo '== 7. Check-ins with no check-out, by branch (top local days)'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id),
a AS (SELECT member_id, branch_id, lower(event_type) AS t, least(event_ts, ingested_at) AS ts, event_id
      FROM d WHERE lower(event_type) IN ('check_in', 'check_out') AND member_id IN (SELECT member_id FROM members)),
s AS (SELECT *, lead(t) OVER (PARTITION BY member_id ORDER BY ts, event_id) AS next_t FROM a)
SELECT s.branch_id, (s.ts AT TIME ZONE b.timezone)::date AS local_day, count(*) AS no_checkout
FROM s JOIN branches b USING (branch_id)
WHERE t = 'check_in' AND coalesce(next_t, '') <> 'check_out'
GROUP BY 1,2 HAVING count(*) >= 5 ORDER BY 3 DESC;

\echo '== 8. Friend visits with no member check-in at that branch in [-5 min, +30 min]'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id),
ci AS (SELECT member_id, branch_id, least(event_ts, ingested_at) AS ts FROM d WHERE lower(event_type) = 'check_in')
SELECT f.device_id, count(*) AS orphan_friend_visits
FROM d f
WHERE f.event_type = 'friend_visit'
  AND NOT EXISTS (SELECT 1 FROM ci WHERE ci.member_id = f.member_id AND ci.branch_id = f.branch_id
                  AND least(f.event_ts, f.ingested_at) BETWEEN ci.ts - interval '5 minutes' AND ci.ts + interval '30 minutes')
GROUP BY ROLLUP (1) ORDER BY 1 NULLS LAST;

\echo '== 9. Access activity vs membership state at the time (events = source of truth)'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id),
ms AS (SELECT member_id, event_type, event_ts, ingested_at,
              lead(event_ts) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS until
       FROM d WHERE event_type IN ('membership_started', 'membership_reactivated', 'membership_cancelled')),
a AS (SELECT d.event_id, lower(d.event_type) AS t, least(d.event_ts, d.ingested_at) AS ts, d.member_id
      FROM d WHERE lower(d.event_type) IN ('check_in', 'friend_visit') AND d.member_id IN (SELECT member_id FROM members))
SELECT a.t, coalesce(ms.event_type, '(no membership event yet)') AS state, count(*) AS rows_,
       count(DISTINCT a.member_id) AS members_,
       count(*) FILTER (WHERE ms.event_type = 'membership_cancelled' AND a.ts < ms.ingested_at) AS before_cancel_ingested
FROM a LEFT JOIN ms ON ms.member_id = a.member_id AND a.ts >= ms.event_ts AND (ms.until IS NULL OR a.ts < ms.until)
GROUP BY 1,2 ORDER BY 1,2;

\echo '== 10. CRM: ingestion lag by event type (cancellations arrive in monthly batches)'
SELECT event_type, count(*) AS rows_,
       count(*) FILTER (WHERE ingested_at - event_ts > interval '1 day') AS lag_over_1d,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY ingested_at - event_ts) AS median_lag,
       max(ingested_at - event_ts) AS max_lag
FROM events WHERE device_id IS NULL GROUP BY 1 ORDER BY 1;
SELECT extract(day FROM ingested_at) AS ingest_day_of_month, count(*)
FROM events WHERE event_type = 'membership_cancelled' GROUP BY 1 ORDER BY 1;

\echo '== 11. members.status vs status derived from events, by when the latest event was ingested'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id),
last_ev AS (SELECT DISTINCT ON (member_id) member_id, event_type, event_ts, ingested_at
            FROM d WHERE event_type IN ('membership_started', 'membership_reactivated', 'membership_cancelled')
            ORDER BY member_id, event_ts DESC, event_id DESC)
SELECT m.status AS crm_status,
       coalesce(CASE l.event_type WHEN 'membership_cancelled' THEN 'cancelled' ELSE 'active' END, '(no events)') AS derived,
       to_char(l.ingested_at, 'YYYY-MM') AS last_event_ingested, count(*)
FROM members m LEFT JOIN last_ev l USING (member_id)
WHERE l.member_id IS NULL OR m.status IS DISTINCT FROM CASE l.event_type WHEN 'membership_cancelled' THEN 'cancelled' ELSE 'active' END
GROUP BY 1,2,3 ORDER BY 1,2,3;

\echo '== 12. members.membership_tier vs latest tier from events; tier_changed.from vs previous tier'
WITH d AS (SELECT DISTINCT ON (source_ref) * FROM events ORDER BY source_ref, event_ts, event_id),
t AS (SELECT member_id, event_type, event_ts, event_id, details->>'from' AS from_tier,
             CASE WHEN event_type = 'tier_changed' THEN details->>'to' ELSE details->>'tier' END AS tier
      FROM d WHERE event_type IN ('membership_started', 'membership_reactivated', 'tier_changed')),
s AS (SELECT *, lag(tier) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS prev_tier,
             row_number() OVER (PARTITION BY member_id ORDER BY event_ts DESC, event_id DESC) AS rn FROM t)
SELECT 'members.tier <> latest event tier' AS check_, count(*) FROM s JOIN members m USING (member_id) WHERE rn = 1 AND m.membership_tier <> s.tier
UNION ALL
SELECT 'tier_changed.from <> previous tier', count(*) FROM s WHERE event_type = 'tier_changed' AND from_tier IS DISTINCT FROM prev_tier;

\echo '== 13. members profile problems'
SELECT 'status not lowercase/known' AS issue, count(*) FROM members WHERE status NOT IN ('active', 'cancelled')
UNION ALL SELECT 'home_branch_id unknown', count(*) FROM members WHERE home_branch_id NOT IN (SELECT branch_id FROM branches)
UNION ALL SELECT 'date_of_birth = 1900-01-01 placeholder', count(*) FROM members WHERE date_of_birth = DATE '1900-01-01'
UNION ALL SELECT 'email shared by >1 member', count(*) FROM members WHERE lower(email) IN (SELECT lower(email) FROM members GROUP BY 1 HAVING count(*) > 1)
UNION ALL SELECT 'no CRM events at all', count(*) FROM members m WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.member_id = m.member_id AND e.device_id IS NULL);

\echo '== 14. Impact on the required report: 2024 check-ins per branch under each cleaning rule'
WITH raw AS (SELECT e.*, b.timezone FROM events e JOIN branches b USING (branch_id)),
d AS (SELECT DISTINCT ON (source_ref) * FROM raw ORDER BY source_ref, event_ts, event_id)
SELECT b.branch_id, b.name,
  (SELECT count(*) FROM raw WHERE branch_id = b.branch_id AND event_type = 'check_in'
     AND event_ts >= '2024-01-01' AND event_ts < '2025-01-01') AS naive_exact_utc,
  (SELECT count(*) FROM raw WHERE branch_id = b.branch_id AND lower(event_type) = 'check_in'
     AND extract(year FROM event_ts AT TIME ZONE timezone) = 2024) AS case_fixed_local,
  (SELECT count(*) FROM d WHERE branch_id = b.branch_id AND lower(event_type) = 'check_in'
     AND extract(year FROM event_ts AT TIME ZONE timezone) = 2024) AS plus_dedup,
  (SELECT count(*) FROM d WHERE branch_id = b.branch_id AND lower(event_type) = 'check_in'
     AND extract(year FROM least(event_ts, ingested_at) AT TIME ZONE timezone) = 2024
     AND member_id IN (SELECT member_id FROM members)) AS plus_real_members
FROM branches b ORDER BY 1;
