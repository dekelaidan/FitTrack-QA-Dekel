"""Checks on members (the CRM's current view) and its agreement with the membership events.

Reports derive membership state from events, as the business rules say, so disagreements
with members.status / membership_tier are warnings: they matter to anyone reading the
members table directly, not to the reports.
"""
import pytest

from dq import BLOCKING, TIERS, WARNING, Check, as_params, run_check, sql_list

LATEST_STATE = """
    SELECT DISTINCT ON (member_id) member_id, event_type, event_ts, ingested_at
    FROM events
    WHERE event_type IN ('membership_started', 'membership_reactivated', 'membership_cancelled')
    ORDER BY member_id, event_ts DESC, event_id DESC
"""

CHECKS = [
    Check(
        "M01_tier_status_domain",
        "membership_tier or status missing or not one of the documented values (exact case)",
        WARNING,
        f"""
        SELECT member_id, membership_tier, status, home_branch_id
        FROM members
        WHERE membership_tier IS NULL OR membership_tier NOT IN ({sql_list(TIERS)})
           OR status IS NULL OR status NOT IN ('active', 'cancelled')
        """,
    ),
    Check(
        "M02_unknown_home_branch",
        "home_branch_id missing or not a known branch",
        WARNING,
        """
        SELECT m.member_id, m.home_branch_id, m.joined_on, m.status
        FROM members m
        WHERE NOT EXISTS (SELECT 1 FROM branches b WHERE b.branch_id = m.home_branch_id)
        """,
    ),
    Check(
        "M03_duplicate_email",
        "the same email (case-insensitive) on more than one member (re-joiner created as a new member?)",
        WARNING,
        """
        SELECT lower(email) AS email, count(*) AS members, string_agg(member_id::text, ',') AS member_ids
        FROM members
        WHERE email IS NOT NULL
        GROUP BY 1
        HAVING count(*) > 1
        """,
    ),
    Check(
        "M04_implausible_dob",
        "date_of_birth missing, a 1900-01-01 placeholder or earlier, or after joined_on",
        WARNING,
        """
        SELECT member_id, date_of_birth, joined_on, home_branch_id
        FROM members
        WHERE date_of_birth IS NULL OR date_of_birth <= DATE '1900-01-01' OR date_of_birth > joined_on
        """,
    ),
    Check(
        "M05_status_disagrees_with_events",
        "members.status differs from the state derived from membership events",
        WARNING,
        f"""
        SELECT m.member_id, m.status, l.event_type AS latest_event, l.event_ts, l.ingested_at
        FROM members m
        JOIN ({LATEST_STATE}) l USING (member_id)
        WHERE lower(m.status) <> CASE l.event_type WHEN 'membership_cancelled' THEN 'cancelled' ELSE 'active' END
        """,
    ),
    Check(
        "M06_member_without_membership_events",
        "member has no membership_started event (invisible to the active-members report)",
        WARNING,
        """
        SELECT m.member_id, m.status, m.joined_on
        FROM members m
        WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.member_id = m.member_id AND e.event_type = 'membership_started')
        """,
    ),
    Check(
        "M07_invalid_membership_sequence",
        "membership events out of order: start/reactivate while active, cancel while not active, reactivate without a prior cancel",
        BLOCKING,
        """
        SELECT member_id, event_type, prev_type, event_ts
        FROM (SELECT member_id, event_type, event_ts,
                     lag(event_type) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS prev_type
              FROM (SELECT DISTINCT ON (source_ref) * FROM events
                    WHERE event_type IN ('membership_started', 'membership_reactivated', 'membership_cancelled')
                    ORDER BY source_ref, event_ts, event_id) d) s
        WHERE (event_type = 'membership_started'     AND prev_type IS NOT NULL)
           OR (event_type = 'membership_reactivated' AND prev_type IS DISTINCT FROM 'membership_cancelled')
           OR (event_type = 'membership_cancelled'   AND prev_type NOT IN ('membership_started', 'membership_reactivated'))
           OR (event_type = 'membership_cancelled'   AND prev_type IS NULL)
        """,
    ),
    Check(
        "M08_tier_changed_from_mismatch",
        "tier_changed.from is not the member's tier at that moment",
        WARNING,
        """
        SELECT member_id, event_ts, from_tier, prev_tier
        FROM (SELECT member_id, event_ts, event_type, details->>'from' AS from_tier,
                     lag(CASE WHEN event_type = 'tier_changed' THEN details->>'to' ELSE details->>'tier' END)
                       OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS prev_tier
              FROM events
              WHERE event_type IN ('membership_started', 'membership_reactivated', 'tier_changed')) s
        WHERE event_type = 'tier_changed' AND from_tier IS DISTINCT FROM prev_tier
        """,
    ),
    Check(
        "M09_late_crm_events",
        "CRM event ingested more than 1 day after it happened (month figures change after the fact)",
        WARNING,
        """
        SELECT event_type, to_char(ingested_at, 'YYYY-MM-DD') AS ingested_day, count(*) AS rows_,
               max(ingested_at - event_ts) AS max_lag
        FROM events
        WHERE device_id IS NULL AND ingested_at - event_ts > interval '1 day'
        GROUP BY 1, 2
        """,
    ),
]


@pytest.mark.parametrize("check", as_params(CHECKS))
def test_members(db, check):
    run_check(db, check)
