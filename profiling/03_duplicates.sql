-- 03_duplicates.sql: what differs between rows sharing a source_ref?

\echo '== Which fields differ within a duplicated source_ref'
WITH g AS (
  SELECT source_ref,
         count(*) AS n,
         count(DISTINCT member_id)         AS members,
         count(DISTINCT lower(event_type)) AS types,
         count(DISTINCT event_ts)          AS tss,
         count(DISTINCT details::text)     AS details
  FROM events GROUP BY 1 HAVING count(*) > 1)
SELECT members > 1 AS diff_member, types > 1 AS diff_type,
       tss > 1 AS diff_ts, details > 1 AS diff_details, count(*) AS refs
FROM g GROUP BY 1,2,3,4 ORDER BY refs DESC;

\echo '== Sample of non-identical duplicates'
WITH d AS (
  SELECT source_ref FROM events GROUP BY 1
  HAVING count(DISTINCT (member_id, lower(event_type), event_ts, details::text)) > 1)
SELECT e.source_ref, e.event_id, e.member_id, e.event_type,
       e.event_ts, e.ingested_at, e.ingested_at - e.event_ts AS lag, e.details
FROM events e JOIN d USING (source_ref)
ORDER BY e.source_ref, e.event_id
LIMIT 30;

\echo '== Does the later copy look like it was stamped at resend time?'
WITH r AS (
  SELECT source_ref, event_ts, ingested_at,
         row_number() OVER (PARTITION BY source_ref ORDER BY event_ts) AS rn,
         count(*)     OVER (PARTITION BY source_ref) AS n
  FROM events)
SELECT rn,
       count(*) AS rows_,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY ingested_at - event_ts) AS median_lag,
       count(*) FILTER (WHERE event_ts <> date_trunc('second', event_ts)) AS fractional_secs
FROM r WHERE n > 1 GROUP BY rn ORDER BY rn;

\echo '== Do device sequence numbers look monotonic in time? (sample device)'
SELECT split_part(source_ref, ':', 2)::bigint AS seq, event_ts, event_type, member_id
FROM events WHERE device_id = 'D01-IN'
ORDER BY seq LIMIT 40;
