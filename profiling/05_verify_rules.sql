-- 05_verify_rules.sql: prove each cleaning rule in reports/visits_per_branch.sql does what it claims.
SET timezone = 'UTC';

\echo '== A. Access events outside local opening hours, as each rule is applied (last line must be 0)'
WITH raw AS (
    SELECT e.*, b.timezone, b.opens_at, b.closes_at
    FROM events e JOIN branches b USING (branch_id)
    WHERE lower(e.event_type) IN ('check_in', 'check_out', 'friend_visit')
),
deduped AS (                                                   -- Rule 1
    SELECT DISTINCT ON (source_ref) * FROM raw ORDER BY source_ref, event_ts, event_id
),
members_only AS (                                              -- Rule 2
    SELECT d.* FROM deduped d WHERE EXISTS (SELECT 1 FROM members m WHERE m.member_id = d.member_id)
),
steps AS (
    SELECT 1 AS step, 'raw event_ts'                          AS rule_applied, event_ts AS ts, timezone, opens_at, closes_at FROM raw
    UNION ALL SELECT 2, '+ rule 1: dedupe on source_ref',               event_ts, timezone, opens_at, closes_at FROM deduped
    UNION ALL SELECT 3, '+ rule 2: real members only',                  event_ts, timezone, opens_at, closes_at FROM members_only
    UNION ALL SELECT 4, '+ rule 3: least(event_ts, ingested_at)',       least(event_ts, ingested_at), timezone, opens_at, closes_at FROM members_only
)
SELECT step, rule_applied,
       count(*) FILTER (WHERE (ts AT TIME ZONE timezone)::time <  opens_at          -- Rule 4: local time
                           OR (ts AT TIME ZONE timezone)::time >= closes_at) AS outside_opening_hours
FROM steps GROUP BY 1, 2 ORDER BY 1;

\echo '== B. Rule 1 cross-check: deduped check-ins per entrance = highest sequence number it issued (diff must be 0)'
SELECT device_id,
       count(*) AS deduped_check_ins,
       max(split_part(source_ref, ':', 2)::int) AS max_sequence,
       max(split_part(source_ref, ':', 2)::int) - count(*) AS diff
FROM (SELECT DISTINCT ON (source_ref) * FROM events
      WHERE lower(event_type) = 'check_in' ORDER BY source_ref, event_ts, event_id) d
GROUP BY 1 ORDER BY 1;
