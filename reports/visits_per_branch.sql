/*
================================================================================
 Report   : Member visits per branch, 2024
 File     : reports/visits_per_branch.sql
 Target   : PostgreSQL 17. One self-contained query; reads only the source
            tables branches, members and events. Safe in a read-only session.
 Run      : psql -f reports/visits_per_branch.sql
--------------------------------------------------------------------------------
 OUTPUT   : one row per branch, ordered by branch_id
   branch_id      integer  the branch
   branch_name    text     branches.name
   member_visits  bigint   visits by members that started in calendar 2024,
                           in the branch's local time; 0 if none
--------------------------------------------------------------------------------
 COUNTING RULES (the evidence and counts behind each one are in DATA_QUALITY.md)

 R1  A visit is one check-in.
     A visit starts with a check_in at the branch entrance, so it is counted
     there. A missing check_out does not cancel it: exit events are sometimes
     lost (for example a 27-event sequence gap on one exit device), but the
     member did come in.

 R2  Event types are matched case-insensitively.
     One entrance sent 'CHECK_IN' for a week. Those rows have no lowercase twin;
     they are real visits that an exact match would silently drop.

 R3  One row per source_ref, keeping the earliest copy.
     source_ref is assigned by the sending device, so rows that share it are the
     same physical event. Copies come from delivery retries (identical) and from
     device replays that re-stamp the copy with the moment it was re-sent. The
     earliest event_ts is the real one. Ties are broken by event_id.

 R4  Only real members count.
     Events whose member_id is not in members are excluded. In this database
     they are turnstile test cards (Mondays at opening, about one minute long).
     The rule is generic, so no IDs are hard-coded.
     Visits by members whose membership was cancelled at the time ARE counted:
     this report counts visits that happened, not visits that were entitled.

 R5  Event time is the earlier of event_ts and ingested_at.
     An event cannot happen after the database received it. When a device clock
     runs ahead (one entrance was 3 h ahead for two months), the ingestion time
     is the best estimate; normal lag is about 13 s.
     Limitation: a clock running slow looks like late delivery and is kept as is.

 R6  "2024" is the calendar year in the branch's own time zone.
     Business rule: days, months and years are local to the branch where the
     event happened. branches.timezone is an IANA name, so daylight saving time
     (and Arizona's lack of it) is handled. The year is a half-open range:
     local time >= 2024-01-01 00:00 and < 2025-01-01 00:00.

 Branches with no visits are still listed, with member_visits = 0.
--------------------------------------------------------------------------------
 RESULT ON THE PROVIDED DATABASE (cross-checked in tests/test_reports.py)
   1 Back Bay 9,838 | 2 Harbor Point 10,006 | 3 Lakeshore 11,354
   4 Riverwalk 9,264 | 5 Union Station 9,339 | 6 Camelback 8,679
   7 Mission Bay 9,744 | 8 Pearl District 3,675          total 71,899
================================================================================
*/

WITH
-- R1 + R2: every check-in row, whatever the casing of event_type.
check_in_rows AS (
    SELECT
        e.event_id,
        e.source_ref,
        e.member_id,
        e.branch_id,
        e.event_ts,
        e.ingested_at,
        ROW_NUMBER() OVER (
            PARTITION BY e.source_ref
            ORDER BY e.event_ts, e.event_id
        ) AS copy_number
    FROM events AS e
    WHERE LOWER(e.event_type) = 'check_in'
),

-- R3 + R4 + R5: one row per real event, by a real member, at its corrected time.
member_check_ins AS (
    SELECT
        c.branch_id,
        CASE
            WHEN c.event_ts > c.ingested_at THEN c.ingested_at
            ELSE c.event_ts
        END AS visit_ts
    FROM check_in_rows AS c
    WHERE c.copy_number = 1
      AND EXISTS (
            SELECT 1
            FROM members AS m
            WHERE m.member_id = c.member_id
      )
),

-- R6: keep the visits that started in 2024, in the branch's local time.
visits_2024 AS (
    SELECT
        v.branch_id
    FROM member_check_ins AS v
    JOIN branches AS b
      ON b.branch_id = v.branch_id
    WHERE (v.visit_ts AT TIME ZONE b.timezone) >= TIMESTAMP '2024-01-01 00:00:00'
      AND (v.visit_ts AT TIME ZONE b.timezone) <  TIMESTAMP '2025-01-01 00:00:00'
)

SELECT
    b.branch_id,
    b.name               AS branch_name,
    COUNT(v.branch_id)   AS member_visits
FROM branches AS b
LEFT JOIN visits_2024 AS v
  ON v.branch_id = b.branch_id
GROUP BY
    b.branch_id,
    b.name
ORDER BY
    b.branch_id;
