"""Fleet Ops web console - a thin Flask layer over the fleet_ops_db stored procedures.

Run:  pip install -r requirements.txt
      set DB_PASSWORD (see README), then:  python app.py
Open: http://127.0.0.1:5000
"""
import os
from datetime import date, datetime
from decimal import Decimal

import pymysql
from flask import Flask, jsonify, request, send_from_directory
from pymysql.cursors import DictCursor

app = Flask(__name__)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def connect():
    """New connection per request. Settings come from environment variables."""
    kw = dict(
        user=os.getenv("DB_USER", "root"),
        password=os.getenv("DB_PASSWORD", ""),
        database=os.getenv("DB_NAME", "fleet_ops_db"),
        cursorclass=DictCursor,
        autocommit=True,           # the stored procedures manage their own transactions
        charset="utf8mb4",
    )
    sock = os.getenv("DB_SOCKET")
    if sock:
        kw["unix_socket"] = sock
    else:
        kw["host"] = os.getenv("DB_HOST", "127.0.0.1")
        kw["port"] = int(os.getenv("DB_PORT", "3306"))
    return pymysql.connect(**kw)


def clean(value):
    """Make DB values JSON friendly."""
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [clean(v) for v in value]
    return value


def query(sql, args=None):
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, args)
            return clean(cur.fetchall())
    finally:
        conn.close()


def sql_dt(text):
    """'2026-10-12T06:00' (datetime-local input) -> '2026-10-12 06:00:00'."""
    text = (text or "").strip().replace("T", " ")
    if len(text) == 16:
        text += ":00"
    if len(text) != 19:
        raise ValueError("Please provide a valid date and time")
    return text


def blank_to_none(value):
    return None if value in (None, "", "null") else value


@app.errorhandler(pymysql.MySQLError)
def db_error(err):
    # Business-rule errors raised with SIGNAL arrive as (1644, "message")
    message = err.args[1] if len(err.args) > 1 else str(err)
    return jsonify(error=message), 400


@app.errorhandler(ValueError)
def value_error(err):
    return jsonify(error=str(err)), 400


@app.route("/")
def home():
    return send_from_directory(BASE_DIR, "index.html")


# ------------------------------ read endpoints ------------------------------

@app.get("/api/fleet")
def fleet():
    return jsonify(query("SELECT * FROM vw_FleetStatus ORDER BY registration"))


@app.get("/api/lookups")
def lookups():
    return jsonify({
        "aircraft": query("SELECT aircraft_id, registration, status FROM aircraft ORDER BY registration"),
        "airports": query("SELECT airport_code, city FROM airports ORDER BY airport_code"),
        "parts": query("SELECT part_id, part_number, description FROM part_catalog ORDER BY part_number"),
        "components": query(
            "SELECT ic.component_id, a.registration, ic.position_code "
            "FROM installed_components ic JOIN aircraft a ON a.aircraft_id = ic.aircraft_id "
            "WHERE ic.removed_on IS NULL ORDER BY a.registration, ic.position_code"),
    })


@app.get("/api/flights")
def flights():
    return jsonify(query(
        "SELECT f.flight_id, f.flight_no, a.registration, f.origin, f.destination, "
        "f.sched_departure, f.sched_arrival, f.status "
        "FROM flights f JOIN aircraft a ON a.aircraft_id = f.aircraft_id "
        "ORDER BY f.sched_departure, f.flight_no"))


@app.get("/api/events")
def events():
    return jsonify(query(
        "SELECT e.event_id, a.registration, e.check_type, e.airport_code, e.scheduled_start, "
        "e.scheduled_end, e.status, e.remarks, "
        "(SELECT COUNT(*) FROM maintenance_tasks t WHERE t.event_id = e.event_id AND t.status = 'OPEN') AS open_tasks, "
        "(SELECT COUNT(*) FROM maintenance_tasks t WHERE t.event_id = e.event_id AND t.status = 'DONE') AS done_tasks "
        "FROM maintenance_events e JOIN aircraft a ON a.aircraft_id = e.aircraft_id "
        "ORDER BY e.event_id DESC"))


@app.get("/api/events/<int:event_id>/tasks")
def event_tasks(event_id):
    return jsonify(query(
        "SELECT t.task_id, t.description, p.part_number, t.part_qty_used, ic.position_code, "
        "t.resets_component, t.status "
        "FROM maintenance_tasks t "
        "LEFT JOIN part_catalog p ON p.part_id = t.part_id "
        "LEFT JOIN installed_components ic ON ic.component_id = t.component_id "
        "WHERE t.event_id = %s ORDER BY t.task_id", (event_id,)))


@app.get("/api/stock")
def stock():
    return jsonify(query(
        "SELECT p.part_number, p.description, i.qty_on_hand, i.reorder_level "
        "FROM part_inventory i JOIN part_catalog p ON p.part_id = i.part_id ORDER BY p.part_number"))


@app.get("/api/logs")
def logs():
    return jsonify({
        "status": query(
            "SELECT l.log_id, a.registration, l.old_status, l.new_status, l.reason, l.changed_at "
            "FROM status_log l JOIN aircraft a ON a.aircraft_id = l.aircraft_id "
            "ORDER BY l.log_id DESC LIMIT 30"),
        "disruptions": query(
            "SELECT d.log_id, f.flight_no, d.event_id, oa.registration AS old_aircraft, "
            "na.registration AS new_aircraft, d.action, d.logged_at "
            "FROM flight_disruptions d "
            "JOIN flights f ON f.flight_id = d.flight_id "
            "JOIN aircraft oa ON oa.aircraft_id = d.old_aircraft_id "
            "LEFT JOIN aircraft na ON na.aircraft_id = d.new_aircraft_id "
            "ORDER BY d.log_id DESC LIMIT 30"),
    })


# ----------------------------- action endpoints -----------------------------

@app.post("/api/maintenance/schedule")
def schedule():
    b = request.get_json(force=True)
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "CALL sp_ScheduleMaintenance(%s, %s, %s, %s, %s, %s, @evt, @reassigned, @flagged)",
                (int(b["aircraft_id"]), b["check_type"], sql_dt(b["start"]), sql_dt(b["end"]),
                 b["airport"], blank_to_none(b.get("remarks"))))
            cur.execute("SELECT @evt AS event_id, @reassigned AS reassigned, @flagged AS flagged")
            return jsonify(clean(cur.fetchone()))
    finally:
        conn.close()


@app.post("/api/maintenance/<int:event_id>/tasks")
def add_task(event_id):
    b = request.get_json(force=True)
    description = (b.get("description") or "").strip()
    if not description:
        raise ValueError("Task description is required")
    part_id = blank_to_none(b.get("part_id"))
    qty = int(b.get("qty") or 0)
    if qty < 0 or (qty > 0 and part_id is None):
        raise ValueError("Choose a part when quantity is above zero")
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO maintenance_tasks (event_id, component_id, part_id, part_qty_used, description, resets_component) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (event_id, blank_to_none(b.get("component_id")), part_id, qty, description,
                 bool(b.get("resets"))))
        return jsonify(ok=True)
    finally:
        conn.close()


@app.post("/api/maintenance/<int:event_id>/complete")
def complete(event_id):
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute("CALL sp_CompleteMaintenance(%s)", (event_id,))
        return jsonify(ok=True)
    finally:
        conn.close()


@app.post("/api/flights")
def add_flight():
    b = request.get_json(force=True)
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO flights (flight_no, aircraft_id, origin, destination, sched_departure, sched_arrival) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                ((b.get("flight_no") or "").strip().upper(), int(b["aircraft_id"]), b["origin"],
                 b["destination"], sql_dt(b["departure"]), sql_dt(b["arrival"])))
        return jsonify(ok=True)
    finally:
        conn.close()


@app.post("/api/flights/<int:flight_id>/complete")
def complete_flight(flight_id):
    """Marking a flight COMPLETED fires trg_flight_completed -> trg_FlagAOG."""
    conn = connect()
    try:
        with conn.cursor() as cur:
            n = cur.execute(
                "UPDATE flights SET status = 'COMPLETED' WHERE flight_id = %s AND status IN ('SCHEDULED','DEPARTED')",
                (flight_id,))
            if n == 0:
                raise ValueError("This flight cannot be completed (already completed, cancelled or flagged)")
        return jsonify(ok=True)
    finally:
        conn.close()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", "5000")), debug=False)
