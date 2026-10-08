"""Every report query must run as-is in a read-only session and return the agreed shape."""
from pathlib import Path

import pytest

REPORTS = Path(__file__).resolve().parent.parent / "reports"

# file -> expected columns, in order
EXPECTED_COLUMNS = {
    "visits_per_branch.sql": ["branch_id", "branch_name", "member_visits"],
}


def run_report(db, name):
    sql = (REPORTS / name).read_text()
    with db.transaction():
        db.execute("SET TRANSACTION READ ONLY")
        cur = db.execute(sql)
        cols = [c.name for c in cur.description]
        rows = cur.fetchall()
    return cols, rows


@pytest.mark.blocking
@pytest.mark.parametrize("name", sorted(EXPECTED_COLUMNS))
def test_report_runs_and_has_expected_columns(db, name):
    cols, _ = run_report(db, name)
    assert cols == EXPECTED_COLUMNS[name]


@pytest.mark.blocking
def test_visits_per_branch_one_row_per_branch(db):
    _, rows = run_report(db, "visits_per_branch.sql")
    branch_ids = [r[0] for r in db.execute("SELECT branch_id FROM branches ORDER BY 1").fetchall()]
    assert [r[0] for r in rows] == branch_ids
    assert all(r[2] is not None and r[2] >= 0 for r in rows)


@pytest.mark.blocking
def test_visits_per_branch_matches_independent_count(db):
    """Cross-check: count the same visits a different way (anti-join instead of DISTINCT ON).

    A visit is the earliest row of each check_in source_ref; ties are broken by event_id.
    """
    _, rows = run_report(db, "visits_per_branch.sql")
    expected = dict(db.execute("""
        SELECT b.branch_id, count(e.event_id)
        FROM branches b
        LEFT JOIN events e
          ON e.branch_id = b.branch_id
         AND lower(e.event_type) = 'check_in'
         AND e.member_id IN (SELECT member_id FROM members)
         AND NOT EXISTS (SELECT 1 FROM events o
                         WHERE o.source_ref = e.source_ref
                           AND (o.event_ts, o.event_id) < (e.event_ts, e.event_id))
         AND least(e.event_ts, e.ingested_at) >= (TIMESTAMP '2024-01-01' AT TIME ZONE b.timezone)
         AND least(e.event_ts, e.ingested_at) <  (TIMESTAMP '2025-01-01' AT TIME ZONE b.timezone)
        GROUP BY b.branch_id
    """).fetchall())
    assert {r[0]: r[2] for r in rows} == expected
