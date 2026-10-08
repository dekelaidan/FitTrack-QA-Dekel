"""Data-quality check model and runner.

A check is an SQL query that returns the rows that violate a rule.
Zero rows = pass. The severity decides what a violation does:

  blocking  the reports cannot be trusted even after their cleaning rules -> test fails (exit 1)
  warning   a known problem the reports already handle -> test passes, listed in the summary

To add a check, append a Check(...) to a CHECKS list in any tests/test_*.py file.
"""
from dataclasses import dataclass

import pytest

BLOCKING = "blocking"
WARNING = "warning"

# Non-blocking findings, printed in the terminal summary by conftest.py
WARNINGS: list[str] = []

# Event types documented in the assignment (exact, lowercase).
EVENT_TYPES = (
    "membership_started", "membership_reactivated", "membership_cancelled", "tier_changed",
    "check_in", "check_out", "friend_visit",
)
CRM_TYPES = EVENT_TYPES[:4]
ACCESS_TYPES = EVENT_TYPES[4:]
TIERS = ("basic", "standard", "premium")


def sql_list(values) -> str:
    return ", ".join(f"'{v}'" for v in values)


@dataclass(frozen=True)
class Check:
    id: str
    description: str
    severity: str
    sql: str  # a single SELECT returning violating rows, no trailing semicolon

    def __post_init__(self):
        if self.severity not in (BLOCKING, WARNING):
            raise ValueError(f"{self.id}: unknown severity {self.severity!r}")


def as_params(checks):
    """Parametrize helper: test id = check id, marker = severity (so `pytest -m blocking` works)."""
    return [pytest.param(c, id=c.id, marks=getattr(pytest.mark, c.severity)) for c in checks]


def run_check(db, check: Check, sample_size: int = 5) -> None:
    count = db.execute(f"SELECT count(*) FROM ({check.sql}) AS v").fetchone()[0]
    if count == 0:
        return

    cur = db.execute(f"SELECT * FROM ({check.sql}) AS v LIMIT {sample_size}")
    cols = [c.name for c in cur.description]
    sample = [dict(zip(cols, row)) for row in cur.fetchall()]
    msg = f"[{check.id}] {check.description}: {count} rows. Sample: {sample}"

    if check.severity == BLOCKING:
        pytest.fail(msg, pytrace=False)
    WARNINGS.append(msg)
