-- 01_shape.sql: first look at the data
SELECT * FROM branches;
SELECT d.*, b.name FROM devices d LEFT JOIN branches b USING (branch_id) ORDER BY branch_id, kind;
\d events
\d members

SELECT event_type, count(*), min(event_ts), max(event_ts),
       count(*) FILTER (WHERE device_id IS NULL) AS no_device,
       count(*) FILTER (WHERE branch_id IS NULL) AS no_branch
FROM events GROUP BY 1 ORDER BY 1;

-- duplicates from the sending side
SELECT count(*) AS dup_source_refs FROM (
  SELECT source_ref FROM events GROUP BY 1 HAVING count(*) > 1) x;

-- event branch vs device branch, event type vs device kind
SELECT e.event_type, d.kind, (e.branch_id = d.branch_id) AS branch_match, count(*)
FROM events e JOIN devices d USING (device_id)
GROUP BY 1,2,3 ORDER BY 1,2,3;

-- ingestion lag
SELECT count(*) FILTER (WHERE ingested_at < event_ts) AS ingested_before_event,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY ingested_at - event_ts) AS median_lag,
       max(ingested_at - event_ts) AS max_lag
FROM events;
