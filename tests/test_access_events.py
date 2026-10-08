"""Checks on access-control events (check_in, check_out, friend_visit).

Several checks look at the data AFTER the reports' cleaning rules
(dedupe on source_ref keeping the earliest copy, time = least(event_ts, ingested_at),
real members only). Those "residual" checks are blocking: if they fire, the cleaning
rules no longer explain the data and the reports cannot be trusted.
"""
import pytest

from dq import BLOCKING, WARNING, Check, as_params, run_check

# Extra copies (rows beyond the first per source_ref) landing on one UTC day.
# Baseline on the provided load: median 2 per day, worst normal day 7; the two replay
# bursts were 1,226 and 1,817. 100 is ~14x the worst normal day.
DUPLICATE_BURST_THRESHOLD = 100

# The same cleaning the report queries apply. Kept here as one definition so the
# checks and the reports cannot drift apart silently.
CLEAN_ACCESS = """
    SELECT d.event_id, d.source_ref, d.member_id, d.branch_id, d.device_id,
           lower(d.event_type) AS t, least(d.event_ts, d.ingested_at) AS ts,
           d.event_ts, d.ingested_at
    FROM (SELECT DISTINCT ON (source_ref) *
          FROM events
          WHERE lower(event_type) IN ('check_in', 'check_out', 'friend_visit')
          ORDER BY source_ref, event_ts, event_id) d
    WHERE EXISTS (SELECT 1 FROM members m WHERE m.member_id = d.member_id)
"""

CHECKS = [
    # --- Delivery problems the reports handle -------------------------------------------
    Check(
        "A01_retry_duplicates",
        "identical event delivered more than once (at-least-once retries); reports dedupe",
        WARNING,
        """
        SELECT source_ref, count(*) AS copies, min(ingested_at) AS first_ingested, max(ingested_at) AS last_ingested
        FROM events
        GROUP BY source_ref, member_id, lower(event_type), event_ts, branch_id, device_id, details::text
        HAVING count(*) > 1
        """,
    ),
    Check(
        "A02_replayed_with_new_timestamp",
        "same source_ref re-sent with a later event_ts (replay stamped at resend time); reports keep the earliest",
        WARNING,
        """
        SELECT device_id, (max_ts AT TIME ZONE 'UTC')::date AS replay_day_utc,
               count(*) AS refs, max(max_ts - min_ts) AS max_shift
        FROM (SELECT source_ref, device_id, min(event_ts) AS min_ts, max(event_ts) AS max_ts
              FROM events WHERE device_id IS NOT NULL
              GROUP BY source_ref, device_id
              HAVING count(DISTINCT event_ts) > 1) r
        GROUP BY 1, 2
        """,
    ),
    Check(
        "A14_duplicate_burst",
        f"more than {DUPLICATE_BURST_THRESHOLD} duplicate copies ingested on one UTC day (replay burst; normal is <10)",
        WARNING,
        f"""
        SELECT (ingested_at AT TIME ZONE 'UTC')::date AS ingested_day_utc,
               count(*) AS extra_copies,
               count(DISTINCT device_id) AS devices,
               count(*) FILTER (WHERE event_ts <> first_ts) AS re_stamped
        FROM (SELECT e.*, row_number() OVER (PARTITION BY source_ref ORDER BY event_ts, event_id) AS copy_number,
                     min(event_ts) OVER (PARTITION BY source_ref) AS first_ts
              FROM events e) x
        WHERE copy_number > 1
        GROUP BY 1
        HAVING count(*) > {DUPLICATE_BURST_THRESHOLD}
        """,
    ),
    Check(
        "A03_clock_ahead",
        "device stamped events in the future (event_ts > ingested_at + 1 min); reports use least(event_ts, ingested_at)",
        WARNING,
        """
        SELECT device_id, count(*) AS rows_, min(event_ts) AS first_ts, max(event_ts) AS last_ts,
               max(event_ts - ingested_at) AS max_ahead
        FROM events
        WHERE event_ts > ingested_at + interval '1 minute'
        GROUP BY device_id
        """,
    ),
    Check(
        "A04_sequence_gaps",
        "device sequence numbers skip: events the device recorded never arrived",
        WARNING,
        """
        SELECT device_id, seq + 1 AS first_missing, nxt - 1 AS last_missing, nxt - seq - 1 AS missing
        FROM (SELECT device_id, seq, lead(seq) OVER (PARTITION BY device_id ORDER BY seq) AS nxt
              FROM (SELECT DISTINCT device_id, split_part(source_ref, ':', 2)::bigint AS seq
                    FROM events
                    WHERE device_id IS NOT NULL AND split_part(source_ref, ':', 2) ~ '^[0-9]+$') s) g
        WHERE nxt - seq > 1
        """,
    ),
    Check(
        "A05_check_in_without_check_out",
        "member's next in/out event after a check_in is not a check_out (lost exit event or tailgating)",
        WARNING,
        f"""
        SELECT branch_id, count(*) AS check_ins_without_check_out
        FROM (SELECT branch_id, t, lead(t) OVER (PARTITION BY member_id ORDER BY ts, event_id) AS next_t
              FROM ({CLEAN_ACCESS}) c WHERE t IN ('check_in', 'check_out')) s
        WHERE t = 'check_in' AND next_t IS DISTINCT FROM 'check_out'
        GROUP BY branch_id
        """,
    ),
    Check(
        "A06_friend_visit_without_member_visit",
        "friend_visit with no check_in by that member at that branch from 5 min before to 30 min after",
        WARNING,
        f"""
        WITH c AS ({CLEAN_ACCESS})
        SELECT f.event_id, f.member_id, f.branch_id, f.ts
        FROM c f
        WHERE f.t = 'friend_visit'
          AND NOT EXISTS (SELECT 1 FROM c i
                          WHERE i.t = 'check_in' AND i.member_id = f.member_id AND i.branch_id = f.branch_id
                            AND f.ts BETWEEN i.ts - interval '5 minutes' AND i.ts + interval '30 minutes')
        """,
    ),
    Check(
        "A07_visit_without_active_membership",
        "check_in or friend_visit when the member's latest membership event is a cancellation, or there is none",
        WARNING,
        f"""
        WITH c AS ({CLEAN_ACCESS}),
        ms AS (SELECT member_id, event_type, event_ts,
                      lead(event_ts) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS until
               FROM events
               WHERE event_type IN ('membership_started', 'membership_reactivated', 'membership_cancelled'))
        SELECT c.member_id, c.t, count(*) AS rows_, min(c.ts) AS first_ts, max(c.ts) AS last_ts,
               coalesce(max(ms.event_type), '(no membership event)') AS state
        FROM c
        LEFT JOIN ms ON ms.member_id = c.member_id AND c.ts >= ms.event_ts AND (ms.until IS NULL OR c.ts < ms.until)
        WHERE c.t IN ('check_in', 'friend_visit')
          AND (ms.event_type IS NULL OR ms.event_type = 'membership_cancelled')
        GROUP BY 1, 2
        """,
    ),

    # --- Residual checks: after cleaning, these must be empty ---------------------------
    Check(
        "A10_outside_opening_hours_after_cleaning",
        "after dedupe and clock capping, access event still outside the branch's local opening hours",
        BLOCKING,
        f"""
        SELECT c.event_id, c.device_id, c.t, c.ts, (c.ts AT TIME ZONE b.timezone) AS local_ts
        FROM ({CLEAN_ACCESS}) c
        JOIN branches b ON b.branch_id = c.branch_id
        WHERE (c.ts AT TIME ZONE b.timezone)::time <  b.opens_at
           OR (c.ts AT TIME ZONE b.timezone)::time >= b.closes_at
        """,
    ),
    Check(
        "A13_outside_hours_unknown_members",
        "after dedupe and clock capping, access event by a member_id NOT in members still outside opening hours",
        WARNING,
        """
        SELECT d.event_id, d.member_id, d.device_id, lower(d.event_type) AS t,
               (least(d.event_ts, d.ingested_at) AT TIME ZONE b.timezone) AS local_ts
        FROM (SELECT DISTINCT ON (source_ref) * FROM events
              WHERE lower(event_type) IN ('check_in', 'check_out', 'friend_visit')
              ORDER BY source_ref, event_ts, event_id) d
        JOIN branches b ON b.branch_id = d.branch_id
        WHERE NOT EXISTS (SELECT 1 FROM members m WHERE m.member_id = d.member_id)
          AND ((least(d.event_ts, d.ingested_at) AT TIME ZONE b.timezone)::time <  b.opens_at
            OR (least(d.event_ts, d.ingested_at) AT TIME ZONE b.timezone)::time >= b.closes_at)
        """,
    ),
    Check(
        "A11_access_before_branch_opened",
        "access event at a branch before its opened_on date (local)",
        BLOCKING,
        f"""
        SELECT c.event_id, c.branch_id, c.t, (c.ts AT TIME ZONE b.timezone) AS local_ts, b.opened_on
        FROM ({CLEAN_ACCESS}) c
        JOIN branches b ON b.branch_id = c.branch_id
        WHERE (c.ts AT TIME ZONE b.timezone)::date < b.opened_on
        """,
    ),
    Check(
        "A12_check_out_without_check_in",
        "check_out not preceded by a check_in of the same member (exit with no entry)",
        BLOCKING,
        f"""
        SELECT event_id, member_id, branch_id, ts
        FROM (SELECT *, lag(t) OVER (PARTITION BY member_id ORDER BY ts, event_id) AS prev_t,
                        lag(branch_id) OVER (PARTITION BY member_id ORDER BY ts, event_id) AS prev_branch
              FROM ({CLEAN_ACCESS}) c WHERE t IN ('check_in', 'check_out')) s
        WHERE t = 'check_out' AND (prev_t IS DISTINCT FROM 'check_in' OR prev_branch IS DISTINCT FROM branch_id)
        """,
    ),
]


@pytest.mark.parametrize("check", as_params(CHECKS))
def test_access_events(db, check):
    run_check(db, check)
