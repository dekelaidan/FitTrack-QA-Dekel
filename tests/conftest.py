import os

import psycopg
import pytest

from dq import WARNINGS


@pytest.fixture(scope="session")
def db():
    # libpq reads PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD from the environment.
    missing = [v for v in ("PGHOST", "PGDATABASE", "PGUSER") if not os.environ.get(v)]
    if missing:
        pytest.exit(f"Missing env vars: {', '.join(missing)} (run `source .env`)", returncode=2)

    with psycopg.connect(autocommit=True) as conn:
        # Guarantee the suite never writes to the database it is checking.
        conn.execute("SET default_transaction_read_only = on")
        conn.execute("SET timezone = 'UTC'")
        yield conn


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    if WARNINGS:
        terminalreporter.section(f"data-quality warnings (non-blocking): {len(WARNINGS)}")
        for line in WARNINGS:
            terminalreporter.write_line(line)
