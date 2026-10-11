# Fleet Ops Console

A small website over the `fleet_ops_db` stored procedures, triggers and views.
Browser page (`index.html`) -> Flask API (`app.py`) -> MySQL.

## 1. Set up the database (once)
Open `fleet_ops_setup.sql` in MySQL Workbench and run the whole file.
Re-run it any time to reset the demo data.

## 2. Install and run
Windows PowerShell:

    pip install -r requirements.txt
    $env:DB_PASSWORD = "your MySQL root password"
    python app.py

macOS / Linux:

    pip install -r requirements.txt
    export DB_PASSWORD="your MySQL root password"
    python3 app.py

Open http://127.0.0.1:5000

Optional environment variables: DB_USER (default root), DB_HOST (127.0.0.1),
DB_PORT (3306), DB_NAME (fleet_ops_db), PORT (5000).

## 3. Demo walkthrough
1. Maintenance tab: schedule an A-check for VT-IJA tomorrow. One flight is
   reassigned to VT-IJD, one is flagged (sp_ScheduleMaintenance).
2. Add a task (oil filters, qty 4), then press Complete (sp_CompleteMaintenance).
   VT-IJA returns to SERVICEABLE and stock drops by 4.
3. Flights tab: press Complete flight on 6E-305. VT-IJC's engine passes its
   limit and the aircraft turns AOG by itself (trg_FlagAOG).
4. Try adding a flight on VT-IJC: the database refuses it.
5. Schedule an Unscheduled event for VT-IJC and press Complete straight away:
   refused, the engine is still over its limit. Add a task with the engine
   component, "Overhaul" ticked, a seal kit part and quantity 2, then
   Complete again. The aircraft is released and seal-kit stock goes below its
   reorder level (Parts & Logs tab).
