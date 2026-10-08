-- 02_anomalies.sql: drill into the signals from 01

\echo '== A. CHECK_IN uppercase: which devices, which days'
SELECT device_id, (event_ts AT TIME ZONE b.timezone)::date AS local_day, count(*)
FROM events e JOIN branches b USING (branch_id)
WHERE event_type = 'CHECK_IN' GROUP BY 1,2 ORDER BY 1,2;

\echo '== A2. Are CHECK_IN rows also present as check_in (same source_ref)?'
SELECT count(*) AS upper_with_lower_twin
FROM events u JOIN events l ON l.source_ref = u.source_ref AND l.event_type = 'check_in'
WHERE u.event_type = 'CHECK_IN';

\echo '== B. Duplicate source_refs: identical payload (retry) vs different payload (ref reuse)'
WITH d AS (
  SELECT source_ref,
         CASE WHEN source_ref LIKE 'crm:%' THEN 'crm' ELSE split_part(source_ref, ':', 1) END AS sender,
         count(*) AS n,
         count(DISTINCT (member_id, lower(event_type), event_ts, device_id, details::text)) AS distinct_payloads,
         max(event_ts) - min(event_ts) AS ts_spread,
         max(ingested_at) - min(ingested_at) AS ingest_spread
  FROM events GROUP BY 1 HAVING count(*) > 1)
SELECT sender, n, distinct_payloads = 1 AS identical,
       count(*) AS refs, max(ts_spread) AS max_ts_spread, max(ingest_spread) AS max_ingest_spread
FROM d GROUP BY 1,2,3 ORDER BY 1,2,3;

\echo '== C. Events ingested before they happened: by sender and gap size'
SELECT coalesce(device_id, 'crm') AS sender,
       date_trunc('minute', event_ts - ingested_at) AS ahead_by,
       count(*), min(event_ts), max(event_ts)
FROM events WHERE ingested_at < event_ts
GROUP BY 1,2 ORDER BY 3 DESC LIMIT 25;

\echo '== D. Late arrivals (> 1 day lag): by sender and month'
SELECT coalesce(device_id, 'crm') AS sender, to_char(event_ts, 'YYYY-MM') AS month,
       count(*), max(ingested_at - event_ts) AS max_lag
FROM events WHERE ingested_at - event_ts > interval '1 day'
GROUP BY 1,2 ORDER BY 3 DESC LIMIT 25;

\echo '== E. Check-ins vs check-outs per branch per local month'
SELECT e.branch_id, to_char(event_ts AT TIME ZONE b.timezone, 'YYYY-MM') AS month,
       count(*) FILTER (WHERE lower(event_type) = 'check_in')  AS ins,
       count(*) FILTER (WHERE event_type = 'check_out') AS outs
FROM events e JOIN branches b USING (branch_id)
WHERE lower(event_type) IN ('check_in','check_out')
GROUP BY 1,2
HAVING abs(count(*) FILTER (WHERE lower(event_type)='check_in')
         - count(*) FILTER (WHERE event_type='check_out')) > 20
ORDER BY 1,2;

\echo '== F. Access events outside local opening hours, by branch/device'
SELECT e.device_id, count(*)
FROM events e JOIN branches b USING (branch_id)
WHERE e.device_id IS NOT NULL
  AND ((event_ts AT TIME ZONE b.timezone)::time < b.opens_at
    OR (event_ts AT TIME ZONE b.timezone)::time > b.closes_at)
GROUP BY 1 ORDER BY 2 DESC;

\echo '== G. Access events before branch opened'
SELECT e.branch_id, b.opened_on, count(*), min(event_ts)
FROM events e JOIN branches b USING (branch_id)
WHERE (event_ts AT TIME ZONE b.timezone)::date < b.opened_on GROUP BY 1,2;

\echo '== H. Fractional-second timestamps, by sender and type'
SELECT coalesce(device_id,'crm') AS sender, event_type, count(*)
FROM events WHERE event_ts <> date_trunc('second', event_ts)
GROUP BY 1,2 ORDER BY 3 DESC;

\echo '== I. Event member integrity'
SELECT count(*) FILTER (WHERE e.member_id IS NULL) AS null_member,
       count(*) FILTER (WHERE e.member_id IS NOT NULL AND m.member_id IS NULL) AS unknown_member
FROM events e LEFT JOIN members m USING (member_id);

\echo '== J. Members: profile sanity'
SELECT count(*) AS members,
       count(*) - count(DISTINCT lower(email)) AS dup_emails,
       count(*) FILTER (WHERE email IS NULL) AS null_email,
       count(*) FILTER (WHERE date_of_birth > joined_on OR date_of_birth < '1920-01-01') AS bad_dob,
       count(*) FILTER (WHERE joined_on IS NULL) AS null_joined,
       count(*) FILTER (WHERE home_branch_id NOT IN (SELECT branch_id FROM branches)) AS bad_home_branch
FROM members;
SELECT membership_tier, status, count(*) FROM members GROUP BY 1,2 ORDER BY 1,2;

\echo '== K. members.status vs latest membership event'
WITH last_ev AS (
  SELECT DISTINCT ON (member_id) member_id, event_type
  FROM events
  WHERE event_type IN ('membership_started','membership_reactivated','membership_cancelled')
  ORDER BY member_id, event_ts DESC, event_id DESC)
SELECT m.status, coalesce(l.event_type, '(none)') AS latest_event, count(*)
FROM members m LEFT JOIN last_ev l USING (member_id)
GROUP BY 1,2 ORDER BY 1,2;
