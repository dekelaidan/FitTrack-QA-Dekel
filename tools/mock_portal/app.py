"""FitTrack Mock Portal: inject CRM/access events into mock_portal.events (a sandbox copy of public.events; the source tables
stay read-only per the assignment, so the DQ suite keeps reading clean data) and watch the anomalies they cause."""
import json, os, time
from datetime import datetime, timedelta, timezone
import psycopg
from psycopg.rows import dict_row  # psycopg 3, already in requirements.txt
from flask import Flask, jsonify, render_template, request

app, T = Flask(__name__), os.getenv("EVENTS_TABLE", "mock_portal.events")
app.json.sort_keys = False  # keep anomaly cards in the order defined below
FRIEND_LIMIT = {"basic": 2, "standard": 3, "premium": 8}  # friend visits per calendar month (assignment, rule 4)
seq = lambda i=0: f"{(time.time_ns() // 1000 + i) % 10**7:07d}"  # 7-digit seq, as in crm:<n> and <device_id>:<n>
MOCK_ID = 9_000_000_000  # injected rows get event_id >= this, so cleanup never touches loaded data
CARDS = {
    "Uppercase CHECK_IN": f"SELECT count(*) FROM {T} WHERE event_type = 'CHECK_IN'",
    "Duplicate source_ref": f"SELECT coalesce(sum(c - 1), 0) FROM (SELECT count(*) c FROM {T} GROUP BY source_ref HAVING count(*) > 1) d",
    # check_in older than 4h with no later check_out + check_out with no earlier check_in (same member & branch)
    "Unmatched / orphaned visits": f"""SELECT (SELECT count(*) FROM {T} i WHERE lower(i.event_type) = 'check_in'
        AND i.event_ts < now() - interval '4 hours' AND NOT EXISTS (SELECT 1 FROM {T} o WHERE lower(o.event_type) = 'check_out'
        AND o.member_id = i.member_id AND o.branch_id = i.branch_id AND o.event_ts > i.event_ts))
      + (SELECT count(*) FROM {T} o WHERE lower(o.event_type) = 'check_out' AND NOT EXISTS (SELECT 1 FROM {T} i
        WHERE lower(i.event_type) = 'check_in' AND i.member_id = o.member_id AND i.branch_id = o.branch_id AND i.event_ts < o.event_ts))""",
    "Time skew (ingested_at < event_ts)": f"SELECT count(*) FROM {T} WHERE ingested_at < event_ts",
    "Friend allowance breaches (member-months)": f"""SELECT count(*) FROM (SELECT f.member_id FROM {T} f
        LEFT JOIN public.members m USING (member_id) WHERE lower(f.event_type) = 'friend_visit'
        GROUP BY f.member_id, date_trunc('month', f.event_ts), m.membership_tier
        HAVING count(*) > CASE lower(m.membership_tier) WHEN 'standard' THEN 3 WHEN 'premium' THEN 8 ELSE 2 END) b""",
}
INSERT = f"""INSERT INTO {T} (event_id, source_ref, member_id, event_type, event_ts, branch_id, device_id, ingested_at, details)
    SELECT greatest(coalesce(max(event_id), 0) + 1, {MOCK_ID}), %s, %s::int, %s, %s::timestamptz, %s::int, %s, %s::timestamptz,
    %s::jsonb FROM {T}"""

def run(sql, args=None):
    with psycopg.connect(row_factory=dict_row) as conn:  # libpq reads PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD
        cur = conn.execute(sql, args)
        return cur.fetchall() if cur.description else cur.rowcount

def insert(rows):
    now = datetime.now(timezone.utc)
    with psycopg.connect() as conn:  # one transaction: all rows of a burst land together, or none do
        conn.cursor().executemany(INSERT, [(r["ref"], r["member_id"], r["type"], r.get("ts", now), r["branch_id"],
                                            r.get("device"), now, json.dumps(r["details"]) if r.get("details") else None) for r in rows])
    return jsonify(ok=True, inserted=len(rows))

@app.post("/api/crm")
def crm():
    b = request.get_json()
    et, tier = b["event_type"], "Platinum++" if b.get("bad_tier") else b["tier"]
    details = {"membership_cancelled": {"reason": "moved_away"}, "tier_changed": {"from": "basic", "to": tier}}.get(et, {"tier": tier})
    ev = {"ref": f"crm:{seq()}", "type": et, "member_id": b["member_id"], "branch_id": b["branch_id"],
          "details": {**details, **json.loads(b.get("details") or "{}")}}
    return insert([ev, ev] if b.get("dup_ref") else [ev])

@app.post("/api/access")
def access():
    b = request.get_json()
    et, now = b["event_type"], datetime.now(timezone.utc)
    device = f"D{int(b['branch_id']):02d}-" + {"check_in": "IN", "check_out": "OUT"}.get(et, "DESK")
    ts = now + timedelta(hours=2) if b.get("skew") else now - timedelta(hours=12) if b.get("unclosed") and et == "check_in" else now
    tier = (run("SELECT lower(membership_tier) AS t FROM public.members WHERE member_id = %s", (b["member_id"],)) or [{"t": "basic"}])[0]["t"]
    n = FRIEND_LIMIT.get(tier, 2) + 1 if b.get("breach") and et == "friend_visit" else 1  # one over the member's real allowance
    return insert([{"ref": f"{device}:{seq(i)}", "type": et.upper() if b.get("upper") else et, "member_id": b["member_id"],
                    "branch_id": b["branch_id"], "device": device, "ts": ts - timedelta(seconds=n - i),
                    "details": {"friend_name": f"Mock Guest {i + 1}"} if et == "friend_visit" else None} for i in range(n)])

@app.get("/api/dashboard")
def dashboard():
    cards = {name: int(list(run(sql)[0].values())[0]) for name, sql in CARDS.items()}
    events = run(f"""SELECT event_id, ingested_at::text, event_ts::text, source_ref, event_type, member_id, branch_id, device_id,
        details, event_type = 'CHECK_IN' AS f_case, ingested_at < event_ts AS f_skew,
        count(*) OVER (PARTITION BY source_ref) > 1 AS f_dup FROM {T} ORDER BY ingested_at DESC, event_id DESC LIMIT 40""")
    return jsonify(table=T, cards=cards, events=events)

@app.post("/api/cleanup")
def cleanup():
    return jsonify(ok=True, deleted=run(f"DELETE FROM {T} WHERE event_id >= %s", (MOCK_ID,)))

for exc in (psycopg.Error, ValueError, KeyError, TypeError):  # surface DB/input errors in the UI instead of a 500 page
    app.register_error_handler(exc, lambda e: (jsonify(ok=False, error=str(e).strip() or repr(e)), 400))
app.add_url_rule("/", view_func=lambda: render_template("index.html"))

if __name__ == "__main__":
    if T == "mock_portal.events":  # sandbox: same columns, types and constraints as public.events, starts empty
        run("CREATE SCHEMA IF NOT EXISTS mock_portal; CREATE TABLE IF NOT EXISTS mock_portal.events (LIKE public.events INCLUDING ALL)")
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", 5050)), debug=True)
