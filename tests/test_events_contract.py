"""Contract checks on the events feed: is every row well-formed and correctly referenced?"""
import pytest

from dq import (ACCESS_TYPES, BLOCKING, CRM_TYPES, EVENT_TYPES, TIERS, WARNING,
                Check, as_params, run_check, sql_list)

CHECKS = [
    Check(
        "E01_unknown_event_type",
        "event_type not in the documented set, even ignoring case",
        BLOCKING,
        f"""
        SELECT event_id, event_type, device_id, event_ts
        FROM events
        WHERE lower(event_type) NOT IN ({sql_list(EVENT_TYPES)})
        """,
    ),
    Check(
        "E02_event_type_casing",
        "event_type is a documented type in the wrong case (reports match case-insensitively)",
        WARNING,
        f"""
        SELECT device_id, event_type, count(*) AS rows_, min(event_ts) AS first_ts, max(event_ts) AS last_ts
        FROM events
        WHERE event_type NOT IN ({sql_list(EVENT_TYPES)})
          AND lower(event_type) IN ({sql_list(EVENT_TYPES)})
        GROUP BY 1, 2
        """,
    ),
    Check(
        "E03_missing_required_fields",
        "member_id or branch_id is NULL",
        BLOCKING,
        """
        SELECT event_id, event_type, member_id, branch_id
        FROM events
        WHERE member_id IS NULL OR branch_id IS NULL
        """,
    ),
    Check(
        "E04_unknown_branch",
        "event references a branch that does not exist",
        BLOCKING,
        """
        SELECT e.event_id, e.branch_id, e.event_type
        FROM events e
        WHERE e.branch_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM branches b WHERE b.branch_id = e.branch_id)
        """,
    ),
    Check(
        "E05_device_mismatch",
        "access event from an unknown device, another branch's device, or the wrong kind of device",
        BLOCKING,
        f"""
        SELECT e.event_id, e.event_type, e.device_id, d.kind, e.branch_id, d.branch_id AS device_branch_id
        FROM events e
        LEFT JOIN devices d ON d.device_id = e.device_id
        WHERE lower(e.event_type) IN ({sql_list(ACCESS_TYPES)})
          AND (d.device_id IS NULL
               OR d.branch_id IS DISTINCT FROM e.branch_id
               OR d.kind <> CASE lower(e.event_type)
                               WHEN 'check_in'  THEN 'entrance'
                               WHEN 'check_out' THEN 'exit'
                               ELSE 'front_desk' END)
        """,
    ),
    Check(
        "E06_source_ref_format",
        "source_ref is not crm:<n> for CRM events or <device_id>:<seq> for device events",
        BLOCKING,
        f"""
        SELECT event_id, event_type, source_ref, device_id
        FROM events
        WHERE CASE
                WHEN event_type IN ({sql_list(CRM_TYPES)})
                THEN NOT (device_id IS NULL AND source_ref ~ '^crm:[0-9]+$')
                ELSE NOT (device_id IS NOT NULL
                          AND split_part(source_ref, ':', 1) = device_id
                          AND split_part(source_ref, ':', 2) ~ '^[0-9]+$')
              END
        """,
    ),
    Check(
        "E07_source_ref_collision",
        "rows sharing a source_ref disagree on member, type, branch or device: dedupe would merge different events",
        BLOCKING,
        """
        SELECT source_ref, count(*) AS rows_,
               count(DISTINCT member_id) AS members, count(DISTINCT lower(event_type)) AS types,
               count(DISTINCT branch_id) AS branches, count(DISTINCT coalesce(device_id, '')) AS devices
        FROM events
        GROUP BY source_ref
        HAVING count(DISTINCT member_id) > 1 OR count(DISTINCT lower(event_type)) > 1
            OR count(DISTINCT branch_id) > 1 OR count(DISTINCT coalesce(device_id, '')) > 1
        """,
    ),
    Check(
        "E08_tier_payload",
        "membership or tier event with a missing or invalid tier in details",
        BLOCKING,
        f"""
        SELECT event_id, event_type, details
        FROM events
        WHERE (event_type IN ('membership_started', 'membership_reactivated')
               AND coalesce(details->>'tier', '') NOT IN ({sql_list(TIERS)}))
           OR (event_type = 'tier_changed'
               AND (coalesce(details->>'from', '') NOT IN ({sql_list(TIERS)})
                    OR coalesce(details->>'to', '') NOT IN ({sql_list(TIERS)})
                    OR details->>'from' = details->>'to'))
        """,
    ),
    Check(
        "E09_free_text_payload",
        "cancellation without a reason, or friend_visit without a friend_name",
        WARNING,
        """
        SELECT event_id, event_type, details
        FROM events
        WHERE (event_type = 'membership_cancelled' AND nullif(trim(details->>'reason'), '') IS NULL)
           OR (lower(event_type) = 'friend_visit' AND nullif(trim(details->>'friend_name'), '') IS NULL)
        """,
    ),
    Check(
        "E10_unknown_member",
        "events for member_ids not in members (here: turnstile test cards); reports exclude them",
        WARNING,
        """
        SELECT e.member_id, lower(e.event_type) AS event_type, count(*) AS rows_,
               min(e.event_ts) AS first_ts, max(e.event_ts) AS last_ts
        FROM events e
        WHERE e.member_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM members m WHERE m.member_id = e.member_id)
        GROUP BY 1, 2
        """,
    ),
]


@pytest.mark.parametrize("check", as_params(CHECKS))
def test_events_contract(db, check):
    run_check(db, check)
