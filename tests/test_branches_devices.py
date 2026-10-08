"""Reference data the local-time rules depend on."""
import pytest

from dq import BLOCKING, Check, as_params, run_check

CHECKS = [
    Check(
        "B01_invalid_timezone",
        "branches.timezone is not a valid IANA zone name (local-time bucketing would fail)",
        BLOCKING,
        """
        SELECT branch_id, name, timezone
        FROM branches
        WHERE timezone IS NULL OR timezone NOT IN (SELECT name FROM pg_timezone_names)
        """,
    ),
    Check(
        "B02_bad_opening_hours",
        "opening hours missing or closes_at not after opens_at",
        BLOCKING,
        """
        SELECT branch_id, name, opens_at, closes_at
        FROM branches
        WHERE opens_at IS NULL OR closes_at IS NULL OR closes_at <= opens_at
        """,
    ),
    # Assumes the current layout: one turnstile in, one out and one tablet per branch. A branch that
    # opens with more than one entrance will fail this check on purpose; widen it then, deliberately.
    Check(
        "B03_branch_device_set",
        "branch without exactly one entrance, one exit and one front_desk device",
        BLOCKING,
        """
        SELECT b.branch_id, b.name,
               count(*) FILTER (WHERE d.kind = 'entrance')   AS entrances,
               count(*) FILTER (WHERE d.kind = 'exit')       AS exits,
               count(*) FILTER (WHERE d.kind = 'front_desk') AS desks
        FROM branches b LEFT JOIN devices d ON d.branch_id = b.branch_id
        GROUP BY 1, 2
        HAVING count(*) FILTER (WHERE d.kind = 'entrance') <> 1
            OR count(*) FILTER (WHERE d.kind = 'exit') <> 1
            OR count(*) FILTER (WHERE d.kind = 'front_desk') <> 1
        """,
    ),
    Check(
        "B05_device_kind_domain",
        "device kind missing or not entrance / exit / front_desk",
        BLOCKING,
        """
        SELECT device_id, branch_id, kind
        FROM devices
        WHERE kind IS NULL OR kind NOT IN ('entrance', 'exit', 'front_desk')
        """,
    ),
]


@pytest.mark.parametrize("check", as_params(CHECKS))
def test_branches_devices(db, check):
    run_check(db, check)
