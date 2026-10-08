"""Incremental ("per load") checks: look only at rows ingested after a watermark.

The rest of the suite re-checks the whole history on every run, so known, already-handled
problems (the 2024 replays, the D07 clock) repeat as warnings forever. These checks answer a
different question: did THIS load bring a NEW problem? Each one is blocking.

Watermark, from the environment (nothing is stored in the database; the suite stays read-only):
    DQ_SINCE=<ISO timestamp>   e.g. 2025-01-01T00:00:00+00:00  (CI: time of the last good run)
    DQ_SINCE=auto              the last DQ_WINDOW_HOURS (default 24) before max(ingested_at)
    unset                      these tests are skipped; the full-history suite runs as usual
"""
import os
from dataclasses import replace
from datetime import datetime, timezone

import pytest

from dq import BLOCKING, EVENT_TYPES, CRM_TYPES, Check, as_params, run_check, sql_list

DUPLICATE_BURST_THRESHOLD = 100       # same baseline as A14: normal days have < 10 extra copies
CANCELLATION_BATCH_MAX_LAG_DAYS = 35  # cancellations arrive monthly on the 2nd; > 35 days is beyond one batch


@pytest.fixture(scope="module")
def since(db):
    raw = os.environ.get("DQ_SINCE", "").strip()
    if not raw:
        pytest.skip("DQ_SINCE not set: incremental (per-load) checks skipped")
    if raw.lower() == "auto":
        hours = int(os.environ.get("DQ_WINDOW_HOURS", "24"))
        ts = db.execute(
            "SELECT max(ingested_at) - make_interval(hours => %s) FROM events", (hours,)
        ).fetchone()[0]
        if ts is None:
            pytest.fail("events is empty: nothing has been loaded", pytrace=False)
    else:
        try:
            ts = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            pytest.exit(f"DQ_SINCE={raw!r} is not an ISO timestamp or 'auto'", returncode=2)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
    return ts


# {since} is replaced with a validated timestamptz literal at run time.
CHECKS = [
    Check(
        "I01_load_is_empty",
        "no events were ingested after the watermark: the feed may have stopped",
        BLOCKING,
        """
        SELECT {since} AS watermark, (SELECT max(ingested_at) FROM events) AS latest_ingested
        WHERE NOT EXISTS (SELECT 1 FROM events WHERE ingested_at > {since})
        """,
    ),
    Check(
        "I02_new_unknown_event_type_or_casing",
        "this load contains an event_type that is not exactly one of the documented types (new type or casing drift)",
        BLOCKING,
        f"""
        SELECT coalesce(device_id, 'crm') AS sender, event_type, count(*) AS rows_
        FROM events
        WHERE ingested_at > {{since}} AND event_type NOT IN ({sql_list(EVENT_TYPES)})
        GROUP BY 1, 2
        """,
    ),
    Check(
        "I03_new_clock_ahead",
        "this load contains events stamped after they were ingested (+1 min): a sender's clock or time zone is wrong",
        BLOCKING,
        """
        SELECT coalesce(device_id, 'crm') AS sender, count(*) AS rows_, max(event_ts - ingested_at) AS max_ahead
        FROM events
        WHERE ingested_at > {since} AND event_ts > ingested_at + interval '1 minute'
        GROUP BY 1
        """,
    ),
    Check(
        "I04_new_duplicate_burst",
        f"this load contains more than {DUPLICATE_BURST_THRESHOLD} duplicate copies on one UTC day (replay burst)",
        BLOCKING,
        f"""
        SELECT (ingested_at AT TIME ZONE 'UTC')::date AS ingested_day_utc, count(*) AS extra_copies,
               count(DISTINCT device_id) AS devices
        FROM (SELECT e.*, row_number() OVER (PARTITION BY source_ref ORDER BY event_ts, event_id) AS copy_number
              FROM events e) x
        WHERE copy_number > 1 AND ingested_at > {{since}}
        GROUP BY 1
        HAVING count(*) > {DUPLICATE_BURST_THRESHOLD}
        """,
    ),
    Check(
        "I05_new_sequence_gap",
        "a device sequence gap closed by a row in this load: events numbered by the device never arrived",
        BLOCKING,
        """
        SELECT device_id, seq + 1 AS first_missing, nxt - 1 AS last_missing, nxt - seq - 1 AS missing
        FROM (SELECT device_id, seq, ingested_at,
                     lead(seq) OVER (PARTITION BY device_id ORDER BY seq) AS nxt,
                     lead(ingested_at) OVER (PARTITION BY device_id ORDER BY seq) AS nxt_ingested
              FROM (SELECT device_id, split_part(source_ref, ':', 2)::bigint AS seq, min(ingested_at) AS ingested_at
                    FROM events
                    WHERE device_id IS NOT NULL AND split_part(source_ref, ':', 2) ~ '^[0-9]+$'
                    GROUP BY 1, 2) s) g
        WHERE nxt - seq > 1 AND nxt_ingested > {since}
        """,
    ),
    Check(
        "I06_new_unknown_member_id",
        "this load contains a member_id that is not in members and was never seen before the watermark",
        BLOCKING,
        """
        SELECT e.member_id, count(*) AS rows_, min(e.ingested_at) AS first_ingested
        FROM events e
        WHERE e.ingested_at > {since}
          AND NOT EXISTS (SELECT 1 FROM members m WHERE m.member_id = e.member_id)
          AND NOT EXISTS (SELECT 1 FROM events o WHERE o.member_id = e.member_id AND o.ingested_at <= {since})
        GROUP BY e.member_id
        """,
    ),
    Check(
        "I07_new_late_crm_event",
        f"this load contains a CRM event later than expected: non-cancellations > 1 day, cancellations > {CANCELLATION_BATCH_MAX_LAG_DAYS} days",
        BLOCKING,
        f"""
        SELECT event_type, count(*) AS rows_, max(ingested_at - event_ts) AS max_lag
        FROM events
        WHERE ingested_at > {{since}} AND event_type IN ({sql_list(CRM_TYPES)})
          AND ingested_at - event_ts > CASE WHEN event_type = 'membership_cancelled'
                                            THEN interval '{CANCELLATION_BATCH_MAX_LAG_DAYS} days'
                                            ELSE interval '1 day' END
        GROUP BY 1
        """,
    ),
]


@pytest.mark.parametrize("check", as_params(CHECKS))
def test_incremental(db, since, check):
    literal = f"TIMESTAMPTZ '{since.isoformat()}'"  # since is a parsed datetime, never raw user text
    run_check(db, replace(check, sql=check.sql.replace("{since}", literal)))
