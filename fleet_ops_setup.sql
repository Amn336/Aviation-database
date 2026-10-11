-- =====================================================================
-- AIRCRAFT MAINTENANCE & FLEET OPERATIONS | Code Review Session - Phase 1
-- Dialect: MySQL 8.x (also runs on MariaDB 10.5+)
-- CLEAN SETUP for the web console: schema, data, functions, views, procedures, triggers only.
-- (No demonstration section, so the website starts from fresh data.)
-- Run the whole file top to bottom in MySQL Workbench / mysql CLI.
-- Operators are seeded from airline_financials.csv (IndiGo, Singapore Airlines).
--
-- Required components (as specified)         Section
--   sp_ScheduleMaintenance  (procedure)       5.1
--   trg_FlagAOG             (trigger)         6.1
--   fn_HoursToNextService   (function)        3.1
--   vw_FleetStatus          (view)            4.1
--   Transaction script: sp_CompleteMaintenance (5.2) + raw block (7.7)
-- =====================================================================

DROP DATABASE IF EXISTS fleet_ops_db;
CREATE DATABASE fleet_ops_db;
USE fleet_ops_db;

-- =====================================================================
-- 1. SCHEMA (Third Normal Form)
--  * Check intervals live on aircraft_types, limits and criticality live
--    on part_catalog, so neither is repeated per aircraft / per component.
--  * installed_components holds the per-aircraft life counters.
--  * aircraft.status is a controlled, derived state: SERVICEABLE,
--    GROUNDED (in maintenance) or AOG (aircraft on ground, unairworthy).
-- =====================================================================

CREATE TABLE operators (
    operator_id  INT AUTO_INCREMENT PRIMARY KEY,
    name         VARCHAR(80) NOT NULL UNIQUE,
    iata_code    VARCHAR(4)  NOT NULL UNIQUE,
    country_iso3 CHAR(3)     NOT NULL
);

CREATE TABLE airports (
    airport_code CHAR(3) PRIMARY KEY,
    name         VARCHAR(80) NOT NULL,
    city         VARCHAR(60) NOT NULL
);

CREATE TABLE aircraft_types (
    type_id              INT AUTO_INCREMENT PRIMARY KEY,
    manufacturer         VARCHAR(40) NOT NULL,
    model                VARCHAR(40) NOT NULL,
    a_check_interval_fh  INT NOT NULL,          -- flight hours between A-checks
    c_check_interval_fh  INT NOT NULL,          -- flight hours between C-checks
    UNIQUE (manufacturer, model),
    CONSTRAINT chk_intervals CHECK (a_check_interval_fh > 0 AND c_check_interval_fh >= a_check_interval_fh)
);

CREATE TABLE aircraft (
    aircraft_id           INT AUTO_INCREMENT PRIMARY KEY,
    registration          VARCHAR(10)  NOT NULL UNIQUE,
    type_id               INT          NOT NULL,
    operator_id           INT          NOT NULL,
    current_airport       CHAR(3)      NOT NULL,
    total_flight_hours    DECIMAL(10,1) NOT NULL DEFAULT 0,
    total_cycles          INT          NOT NULL DEFAULT 0,
    hours_at_last_a_check DECIMAL(10,1) NOT NULL DEFAULT 0,
    hours_at_last_c_check DECIMAL(10,1) NOT NULL DEFAULT 0,
    status                ENUM('SERVICEABLE','GROUNDED','AOG') NOT NULL DEFAULT 'SERVICEABLE',
    CONSTRAINT fk_ac_type     FOREIGN KEY (type_id)         REFERENCES aircraft_types(type_id),
    CONSTRAINT fk_ac_operator FOREIGN KEY (operator_id)     REFERENCES operators(operator_id),
    CONSTRAINT fk_ac_airport  FOREIGN KEY (current_airport) REFERENCES airports(airport_code),
    CONSTRAINT chk_ac_hours   CHECK (total_flight_hours >= 0 AND total_cycles >= 0
                                     AND hours_at_last_a_check <= total_flight_hours
                                     AND hours_at_last_c_check <= total_flight_hours)
);

CREATE TABLE part_catalog (
    part_id      INT AUTO_INCREMENT PRIMARY KEY,
    part_number  VARCHAR(30) NOT NULL UNIQUE,
    description  VARCHAR(100) NOT NULL,
    category     ENUM('ENGINE','LANDING_GEAR','HYDRAULICS','AVIONICS','CONSUMABLE') NOT NULL,
    is_critical  BOOLEAN NOT NULL DEFAULT FALSE,
    hour_limit   DECIMAL(10,1) NULL,            -- operational inspection threshold (hours)
    cycle_limit  INT NULL,                      -- operational inspection threshold (cycles)
    CONSTRAINT chk_limits CHECK (COALESCE(hour_limit,1) > 0 AND COALESCE(cycle_limit,1) > 0)
);

CREATE TABLE part_inventory (
    part_id        INT PRIMARY KEY,
    qty_on_hand    INT NOT NULL DEFAULT 0,
    reorder_level  INT NOT NULL DEFAULT 0,
    CONSTRAINT fk_inv_part FOREIGN KEY (part_id) REFERENCES part_catalog(part_id),
    CONSTRAINT chk_qty CHECK (qty_on_hand >= 0 AND reorder_level >= 0)
);

CREATE TABLE installed_components (
    component_id          INT AUTO_INCREMENT PRIMARY KEY,
    aircraft_id           INT NOT NULL,
    part_id               INT NOT NULL,
    serial_no             VARCHAR(30) NOT NULL UNIQUE,
    position_code         VARCHAR(20) NOT NULL,       -- e.g. ENGINE-1, BRAKE-L
    hours_since_overhaul  DECIMAL(10,1) NOT NULL DEFAULT 0,
    cycles_since_overhaul INT NOT NULL DEFAULT 0,
    last_overhaul_on      DATE NULL,
    removed_on            DATE NULL,                  -- NULL = currently installed
    CONSTRAINT fk_ic_aircraft FOREIGN KEY (aircraft_id) REFERENCES aircraft(aircraft_id),
    CONSTRAINT fk_ic_part     FOREIGN KEY (part_id)     REFERENCES part_catalog(part_id),
    CONSTRAINT chk_ic_life    CHECK (hours_since_overhaul >= 0 AND cycles_since_overhaul >= 0),
    INDEX idx_ic_aircraft (aircraft_id, removed_on)
);

CREATE TABLE flights (
    flight_id        INT AUTO_INCREMENT PRIMARY KEY,
    flight_no        VARCHAR(10) NOT NULL UNIQUE,
    aircraft_id      INT NOT NULL,
    origin           CHAR(3) NOT NULL,
    destination      CHAR(3) NOT NULL,
    sched_departure  DATETIME NOT NULL,
    sched_arrival    DATETIME NOT NULL,
    status           ENUM('SCHEDULED','DEPARTED','COMPLETED','CANCELLED','REASSIGN_REQUIRED') NOT NULL DEFAULT 'SCHEDULED',
    CONSTRAINT fk_fl_aircraft FOREIGN KEY (aircraft_id) REFERENCES aircraft(aircraft_id),
    CONSTRAINT fk_fl_origin   FOREIGN KEY (origin)      REFERENCES airports(airport_code),
    CONSTRAINT fk_fl_dest     FOREIGN KEY (destination) REFERENCES airports(airport_code),
    CONSTRAINT chk_fl_times   CHECK (sched_arrival > sched_departure),
    CONSTRAINT chk_fl_route   CHECK (origin <> destination),
    INDEX idx_fl_aircraft_time (aircraft_id, sched_departure)
);

CREATE TABLE maintenance_events (
    event_id         INT AUTO_INCREMENT PRIMARY KEY,
    aircraft_id      INT NOT NULL,
    check_type       ENUM('A_CHECK','C_CHECK','AD_INSPECTION','UNSCHEDULED') NOT NULL,
    airport_code     CHAR(3) NOT NULL,
    scheduled_start  DATETIME NOT NULL,
    scheduled_end    DATETIME NOT NULL,
    status           ENUM('SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED') NOT NULL DEFAULT 'SCHEDULED',
    remarks          VARCHAR(200) NULL,
    completed_at     DATETIME NULL,
    CONSTRAINT fk_me_aircraft FOREIGN KEY (aircraft_id)  REFERENCES aircraft(aircraft_id),
    CONSTRAINT fk_me_airport  FOREIGN KEY (airport_code) REFERENCES airports(airport_code),
    CONSTRAINT chk_me_times   CHECK (scheduled_end > scheduled_start),
    INDEX idx_me_aircraft (aircraft_id, status)
);

CREATE TABLE maintenance_tasks (
    task_id           INT AUTO_INCREMENT PRIMARY KEY,
    event_id          INT NOT NULL,
    component_id      INT NULL,
    part_id           INT NULL,                       -- part consumed by the task
    part_qty_used     INT NOT NULL DEFAULT 0,
    description       VARCHAR(150) NOT NULL,
    resets_component  BOOLEAN NOT NULL DEFAULT FALSE, -- overhaul: zero the component counters
    status            ENUM('OPEN','DONE') NOT NULL DEFAULT 'OPEN',
    completed_at      DATETIME NULL,
    CONSTRAINT fk_mt_event     FOREIGN KEY (event_id)     REFERENCES maintenance_events(event_id),
    CONSTRAINT fk_mt_component FOREIGN KEY (component_id) REFERENCES installed_components(component_id),
    CONSTRAINT fk_mt_part      FOREIGN KEY (part_id)      REFERENCES part_catalog(part_id),
    CONSTRAINT chk_mt_qty      CHECK (part_qty_used >= 0)
);

CREATE TABLE flight_disruptions (
    log_id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    flight_id        INT NOT NULL,
    event_id         INT NOT NULL,
    old_aircraft_id  INT NOT NULL,
    new_aircraft_id  INT NULL,
    action           ENUM('REASSIGNED','FLAGGED') NOT NULL,
    logged_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_fd_flight FOREIGN KEY (flight_id) REFERENCES flights(flight_id),
    CONSTRAINT fk_fd_event  FOREIGN KEY (event_id)  REFERENCES maintenance_events(event_id)
);

CREATE TABLE status_log (
    log_id       BIGINT AUTO_INCREMENT PRIMARY KEY,
    aircraft_id  INT NOT NULL,
    old_status   VARCHAR(12) NOT NULL,
    new_status   VARCHAR(12) NOT NULL,
    reason       VARCHAR(150) NOT NULL,
    changed_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_sl_aircraft FOREIGN KEY (aircraft_id) REFERENCES aircraft(aircraft_id)
);

-- =====================================================================
-- 2. SAMPLE DATA
-- =====================================================================

INSERT INTO operators (name, iata_code, country_iso3) VALUES
 ('IndiGo', 'IGO', 'IND'),
 ('Singapore Airlines', 'SIA', 'SGP');

INSERT INTO airports (airport_code, name, city) VALUES
 ('DEL', 'Indira Gandhi International',      'New Delhi'),
 ('BOM', 'Chhatrapati Shivaji Maharaj Intl', 'Mumbai'),
 ('BLR', 'Kempegowda International',         'Bengaluru'),
 ('GOI', 'Manohar International',            'Goa'),
 ('SIN', 'Changi Airport',                   'Singapore');

INSERT INTO aircraft_types (manufacturer, model, a_check_interval_fh, c_check_interval_fh) VALUES
 ('Airbus', 'A320neo',   750,  7500),
 ('Airbus', 'A350-900', 1000, 10000);

INSERT INTO aircraft (registration, type_id, operator_id, current_airport,
                      total_flight_hours, total_cycles, hours_at_last_a_check, hours_at_last_c_check) VALUES
 ('VT-IJA', 1, 1, 'DEL', 12400.0, 7800, 12000.0,  7500.0),
 ('VT-IJB', 1, 1, 'DEL',  8300.0, 5200,  7700.0,  3000.0),
 ('VT-IJC', 1, 1, 'BOM', 15100.0, 9400, 14500.0,  8000.0),
 ('VT-IJD', 1, 1, 'DEL',  5200.0, 3300,  4800.0,     0.0),
 ('9V-SMA', 2, 2, 'SIN', 20100.0, 3100, 19500.0, 12000.0);

INSERT INTO part_catalog (part_number, description, category, is_critical, hour_limit, cycle_limit) VALUES
 ('LEAP-1A',        'CFM LEAP-1A turbofan engine',          'ENGINE',       TRUE,  20000.0, 12000),
 ('TRENT-XWB',      'Rolls-Royce Trent XWB engine',         'ENGINE',       TRUE,  25000.0, 15000),
 ('MLG-BRAKE-A320', 'Main landing gear brake assembly',     'LANDING_GEAR', TRUE,   NULL,    1500),
 ('OIL-FILTER-01',  'Engine oil filter',                    'CONSUMABLE',   FALSE,  NULL,    NULL),
 ('HYD-PUMP-EDP',   'Engine-driven hydraulic pump',         'HYDRAULICS',   TRUE,   6000.0,  NULL),
 ('ENG-SEAL-KIT',   'Engine overhaul seal kit',             'CONSUMABLE',   FALSE,  NULL,    NULL);

INSERT INTO part_inventory (part_id, qty_on_hand, reorder_level) VALUES
 (1, 1, 1), (2, 1, 1), (3, 4, 2), (4, 40, 10), (5, 3, 2), (6, 6, 5);

INSERT INTO installed_components
 (aircraft_id, part_id, serial_no, position_code, hours_since_overhaul, cycles_since_overhaul, last_overhaul_on) VALUES
 (1, 1, 'ENG-LA-1001', 'ENGINE-1',  9800.0,  6100, '2022-03-10'),
 (1, 1, 'ENG-LA-1002', 'ENGINE-2',  9800.0,  6100, '2022-03-10'),
 (2, 1, 'ENG-LA-2001', 'ENGINE-1',  8300.0,  5200, NULL),
 (2, 1, 'ENG-LA-2002', 'ENGINE-2',  8300.0,  5200, NULL),
 (2, 3, 'BRK-2001',    'BRAKE-L',   3000.0,  1490, '2025-01-15'),
 (3, 1, 'ENG-LA-3001', 'ENGINE-1', 19998.5, 11990, '2019-06-01'),   -- 1.5 h from its limit
 (3, 1, 'ENG-LA-3002', 'ENGINE-2', 15200.0,  9500, '2021-02-11'),
 (4, 1, 'ENG-LA-4001', 'ENGINE-1',  4000.0,  2600, NULL),
 (4, 1, 'ENG-LA-4002', 'ENGINE-2',  4000.0,  2600, NULL),
 (5, 2, 'ENG-TX-5001', 'ENGINE-1', 11000.0,  2900, NULL),
 (5, 2, 'ENG-TX-5002', 'ENGINE-2', 11000.0,  2900, NULL);

INSERT INTO flights (flight_no, aircraft_id, origin, destination, sched_departure, sched_arrival) VALUES
 ('6E-201', 1, 'DEL', 'BOM', TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '06:00:00'), TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '08:15:00')),
 ('6E-202', 1, 'BOM', 'DEL', TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '09:15:00'), TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '11:30:00')),
 ('6E-410', 2, 'DEL', 'GOI', TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '07:00:00'), TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '09:30:00')),
 ('6E-305', 3, 'BOM', 'BLR', TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '09:00:00'), TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '10:45:00')),
 ('SQ-421',  5, 'SIN', 'DEL', TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '08:00:00'), TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '11:10:00'));

-- =====================================================================
-- 3. FUNCTIONS
-- =====================================================================
DELIMITER //

-- 3.1 Flight hours remaining before the next mandatory service.
--     p_check: 'A'      -> hours to next A-check (airframe)
--              'C'      -> hours to next C-check (airframe)
--              'ENGINE' -> lowest hours remaining to any installed engine's limit
--     A negative result means the service is overdue.
CREATE FUNCTION fn_HoursToNextService(p_aircraft_id INT, p_check VARCHAR(10))
RETURNS DECIMAL(10,1)
READS SQL DATA
BEGIN
    DECLARE v_remaining DECIMAL(10,1);

    IF UPPER(p_check) = 'A' THEN
        SELECT t.a_check_interval_fh - (a.total_flight_hours - a.hours_at_last_a_check)
          INTO v_remaining
          FROM aircraft a JOIN aircraft_types t ON t.type_id = a.type_id
         WHERE a.aircraft_id = p_aircraft_id;
    ELSEIF UPPER(p_check) = 'C' THEN
        SELECT t.c_check_interval_fh - (a.total_flight_hours - a.hours_at_last_c_check)
          INTO v_remaining
          FROM aircraft a JOIN aircraft_types t ON t.type_id = a.type_id
         WHERE a.aircraft_id = p_aircraft_id;
    ELSEIF UPPER(p_check) = 'ENGINE' THEN
        SELECT MIN(p.hour_limit - ic.hours_since_overhaul)
          INTO v_remaining
          FROM installed_components ic
          JOIN part_catalog p ON p.part_id = ic.part_id
         WHERE ic.aircraft_id = p_aircraft_id
           AND ic.removed_on IS NULL
           AND p.category = 'ENGINE'
           AND p.hour_limit IS NOT NULL;
    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Check type must be A, C or ENGINE';
    END IF;

    RETURN v_remaining;
END//

DELIMITER ;

-- =====================================================================
-- 4. VIEWS
-- =====================================================================

-- 4.1 Fleet airworthiness dashboard
CREATE OR REPLACE VIEW vw_FleetStatus AS
SELECT a.registration,
       o.name                                  AS operator,
       CONCAT(t.manufacturer, ' ', t.model)    AS aircraft_type,
       a.status,
       CASE a.status
            WHEN 'SERVICEABLE' THEN 'AIRWORTHY'
            WHEN 'GROUNDED'    THEN 'IN MAINTENANCE'
            ELSE                    'NOT AIRWORTHY (AOG)'
       END                                     AS airworthiness,
       a.current_airport                       AS location,
       ap.city                                 AS location_city,
       a.total_flight_hours,
       a.total_cycles,
       fn_HoursToNextService(a.aircraft_id, 'A')      AS hours_to_a_check,
       fn_HoursToNextService(a.aircraft_id, 'C')      AS hours_to_c_check,
       fn_HoursToNextService(a.aircraft_id, 'ENGINE') AS engine_hours_remaining,
       (SELECT MIN(m.scheduled_start)
          FROM maintenance_events m
         WHERE m.aircraft_id = a.aircraft_id
           AND m.status IN ('SCHEDULED','IN_PROGRESS')) AS next_maintenance
FROM aircraft a
JOIN aircraft_types t ON t.type_id     = a.type_id
JOIN operators      o ON o.operator_id = a.operator_id
JOIN airports      ap ON ap.airport_code = a.current_airport;

-- 4.2 Completed maintenance history with parts used
CREATE OR REPLACE VIEW vw_MaintenanceHistory AS
SELECT a.registration, e.event_id, e.check_type, e.completed_at,
       COUNT(k.task_id)                  AS tasks_done,
       COALESCE(SUM(k.part_qty_used), 0) AS parts_consumed
FROM maintenance_events e
JOIN aircraft a ON a.aircraft_id = e.aircraft_id
LEFT JOIN maintenance_tasks k ON k.event_id = e.event_id AND k.status = 'DONE'
WHERE e.status = 'COMPLETED'
GROUP BY a.registration, e.event_id, e.check_type, e.completed_at;

-- 4.3 Parts at or below their reorder level
CREATE OR REPLACE VIEW vw_LowStockParts AS
SELECT p.part_number, p.description, i.qty_on_hand, i.reorder_level
FROM part_inventory i
JOIN part_catalog p ON p.part_id = i.part_id
WHERE i.qty_on_hand <= i.reorder_level;

-- =====================================================================
-- 5. STORED PROCEDURES
-- =====================================================================
DELIMITER //

-- 5.1 Schedule maintenance: log the event, ground the aircraft, then for
--     every scheduled flight inside the window either REASSIGN it to a free
--     serviceable aircraft (same type + operator, located at the origin) or
--     FLAG it REASSIGN_REQUIRED. One atomic transaction.
CREATE PROCEDURE sp_ScheduleMaintenance(
    IN  p_aircraft_id INT,
    IN  p_check_type  VARCHAR(15),
    IN  p_start       DATETIME,
    IN  p_end         DATETIME,
    IN  p_airport     CHAR(3),
    IN  p_remarks     VARCHAR(200),
    OUT p_event_id    INT,
    OUT p_reassigned  INT,
    OUT p_flagged     INT)
BEGIN
    DECLARE v_status VARCHAR(12);
    DECLARE v_type   INT;
    DECLARE v_op     INT;
    DECLARE v_done   INT DEFAULT 0;
    DECLARE v_flight INT;
    DECLARE v_origin CHAR(3);
    DECLARE v_dep    DATETIME;
    DECLARE v_arr    DATETIME;
    DECLARE v_sub    INT;

    DECLARE cur CURSOR FOR
        SELECT flight_id, origin, sched_departure, sched_arrival
          FROM flights
         WHERE aircraft_id = p_aircraft_id
           AND status = 'SCHEDULED'
           AND sched_departure < p_end
           AND sched_arrival   > p_start
         ORDER BY sched_departure;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_reassigned = 0;
    SET p_flagged    = 0;

    IF p_check_type NOT IN ('A_CHECK','C_CHECK','AD_INSPECTION','UNSCHEDULED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid check type';
    END IF;
    IF p_end <= p_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance end must be after start';
    END IF;

    START TRANSACTION;
        SELECT status, type_id, operator_id INTO v_status, v_type, v_op
          FROM aircraft WHERE aircraft_id = p_aircraft_id FOR UPDATE;

        IF v_status IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aircraft not found';
        END IF;

        IF EXISTS (SELECT 1 FROM maintenance_events
                    WHERE aircraft_id = p_aircraft_id
                      AND status IN ('SCHEDULED','IN_PROGRESS')
                      AND scheduled_start < p_end AND scheduled_end > p_start) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aircraft already has maintenance in this window';
        END IF;

        INSERT INTO maintenance_events
               (aircraft_id, check_type, airport_code, scheduled_start, scheduled_end, remarks)
        VALUES (p_aircraft_id, p_check_type, p_airport, p_start, p_end, p_remarks);
        SET p_event_id = LAST_INSERT_ID();

        -- ground the aircraft (an AOG aircraft stays AOG until released)
        IF v_status = 'SERVICEABLE' THEN
            UPDATE aircraft SET status = 'GROUNDED' WHERE aircraft_id = p_aircraft_id;
            INSERT INTO status_log (aircraft_id, old_status, new_status, reason)
            VALUES (p_aircraft_id, 'SERVICEABLE', 'GROUNDED',
                    CONCAT('Maintenance event ', p_event_id, ' (', p_check_type, ')'));
        END IF;

        -- resolve conflicting flights
        OPEN cur;
        flight_loop: LOOP
            FETCH cur INTO v_flight, v_origin, v_dep, v_arr;
            IF v_done = 1 THEN LEAVE flight_loop; END IF;

            -- MIN() always returns one row (NULL if none), so it never trips the NOT FOUND handler
            SELECT MIN(a.aircraft_id) INTO v_sub
              FROM aircraft a
             WHERE a.aircraft_id <> p_aircraft_id
               AND a.type_id = v_type
               AND a.operator_id = v_op
               AND a.status = 'SERVICEABLE'
               AND a.current_airport = v_origin
               AND NOT EXISTS (SELECT 1 FROM flights f
                                WHERE f.aircraft_id = a.aircraft_id
                                  AND f.status IN ('SCHEDULED','DEPARTED')
                                  AND f.sched_departure < v_arr AND f.sched_arrival > v_dep)
               AND NOT EXISTS (SELECT 1 FROM maintenance_events m
                                WHERE m.aircraft_id = a.aircraft_id
                                  AND m.status IN ('SCHEDULED','IN_PROGRESS')
                                  AND m.scheduled_start < v_arr AND m.scheduled_end > v_dep);

            IF v_sub IS NOT NULL THEN
                UPDATE flights SET aircraft_id = v_sub WHERE flight_id = v_flight;
                INSERT INTO flight_disruptions (flight_id, event_id, old_aircraft_id, new_aircraft_id, action)
                VALUES (v_flight, p_event_id, p_aircraft_id, v_sub, 'REASSIGNED');
                SET p_reassigned = p_reassigned + 1;
            ELSE
                UPDATE flights SET status = 'REASSIGN_REQUIRED' WHERE flight_id = v_flight;
                INSERT INTO flight_disruptions (flight_id, event_id, old_aircraft_id, new_aircraft_id, action)
                VALUES (v_flight, p_event_id, p_aircraft_id, NULL, 'FLAGGED');
                SET p_flagged = p_flagged + 1;
            END IF;
        END LOOP;
        CLOSE cur;
    COMMIT;
END//

-- 5.2 TRANSACTION SCRIPT: complete a maintenance event.
--     In ONE transaction: finish every open task, consume parts from
--     inventory, reset overhauled components, update A/C-check baselines,
--     close the event and restore airworthiness. Any failure (e.g. not
--     enough stock, component still over its limit) rolls everything back.
CREATE PROCEDURE sp_CompleteMaintenance(IN p_event_id INT)
BEGIN
    DECLARE v_aircraft INT;
    DECLARE v_status   VARCHAR(12);
    DECLARE v_type     VARCHAR(15);
    DECLARE v_ac_old   VARCHAR(12);
    DECLARE v_done     INT DEFAULT 0;
    DECLARE v_task     INT;
    DECLARE v_part     INT;
    DECLARE v_qty      INT;
    DECLARE v_comp     INT;
    DECLARE v_reset    BOOLEAN;
    DECLARE v_stock    INT;
    DECLARE v_bad      INT;
    DECLARE v_new_status VARCHAR(12);

    DECLARE cur CURSOR FOR
        SELECT task_id, part_id, part_qty_used, component_id, resets_component
          FROM maintenance_tasks
         WHERE event_id = p_event_id AND status = 'OPEN'
         ORDER BY task_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
        SELECT aircraft_id, status, check_type INTO v_aircraft, v_status, v_type
          FROM maintenance_events WHERE event_id = p_event_id FOR UPDATE;

        IF v_aircraft IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance event not found';
        ELSEIF v_status NOT IN ('SCHEDULED','IN_PROGRESS') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Event is already closed';
        END IF;

        SELECT status INTO v_ac_old FROM aircraft WHERE aircraft_id = v_aircraft FOR UPDATE;

        OPEN cur;
        task_loop: LOOP
            FETCH cur INTO v_task, v_part, v_qty, v_comp, v_reset;
            IF v_done = 1 THEN LEAVE task_loop; END IF;

            IF v_part IS NOT NULL AND v_qty > 0 THEN
                SELECT COALESCE(MIN(qty_on_hand), -1) INTO v_stock
                  FROM part_inventory WHERE part_id = v_part FOR UPDATE;
                IF v_stock < v_qty THEN
                    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient part stock - maintenance not completed';
                END IF;
                UPDATE part_inventory SET qty_on_hand = qty_on_hand - v_qty WHERE part_id = v_part;
            END IF;

            IF v_reset = TRUE AND v_comp IS NOT NULL THEN
                UPDATE installed_components
                   SET hours_since_overhaul = 0, cycles_since_overhaul = 0,
                       last_overhaul_on = CURRENT_DATE
                 WHERE component_id = v_comp;
            END IF;

            UPDATE maintenance_tasks
               SET status = 'DONE', completed_at = CURRENT_TIMESTAMP
             WHERE task_id = v_task;
        END LOOP;
        CLOSE cur;

        -- reset the inspection baselines for scheduled checks
        IF v_type = 'A_CHECK' THEN
            UPDATE aircraft SET hours_at_last_a_check = total_flight_hours WHERE aircraft_id = v_aircraft;
        ELSEIF v_type = 'C_CHECK' THEN
            UPDATE aircraft
               SET hours_at_last_a_check = total_flight_hours,
                   hours_at_last_c_check = total_flight_hours
             WHERE aircraft_id = v_aircraft;
        END IF;

        UPDATE maintenance_events
           SET status = 'COMPLETED', completed_at = CURRENT_TIMESTAMP
         WHERE event_id = p_event_id;

        -- airworthiness gate: no critical component may still be beyond its limit
        SELECT COUNT(*) INTO v_bad
          FROM installed_components ic
          JOIN part_catalog p ON p.part_id = ic.part_id
         WHERE ic.aircraft_id = v_aircraft AND ic.removed_on IS NULL AND p.is_critical
           AND ((p.hour_limit  IS NOT NULL AND ic.hours_since_overhaul  >= p.hour_limit)
             OR (p.cycle_limit IS NOT NULL AND ic.cycles_since_overhaul >= p.cycle_limit));
        IF v_bad > 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot release aircraft: a critical component is still beyond its limit';
        END IF;

        -- stay GROUNDED if another maintenance event is still open
        IF EXISTS (SELECT 1 FROM maintenance_events
                    WHERE aircraft_id = v_aircraft AND status IN ('SCHEDULED','IN_PROGRESS')) THEN
            SET v_new_status = 'GROUNDED';
        ELSE
            SET v_new_status = 'SERVICEABLE';
        END IF;

        IF v_new_status <> v_ac_old THEN
            UPDATE aircraft SET status = v_new_status WHERE aircraft_id = v_aircraft;
            INSERT INTO status_log (aircraft_id, old_status, new_status, reason)
            VALUES (v_aircraft, v_ac_old, v_new_status,
                    CONCAT('Maintenance event ', p_event_id, ' completed'));
        END IF;
    COMMIT;
END//

DELIMITER ;

-- =====================================================================
-- 6. TRIGGERS
-- =====================================================================
DELIMITER //

-- 6.1 trg_FlagAOG: when a CRITICAL installed component reaches or passes its
--     hour or cycle threshold, mark the aircraft AOG and log the reason.
CREATE TRIGGER trg_FlagAOG
AFTER UPDATE ON installed_components
FOR EACH ROW
BEGIN
    DECLARE v_critical BOOLEAN;
    DECLARE v_hour_lim DECIMAL(10,1);
    DECLARE v_cyc_lim  INT;
    DECLARE v_status   VARCHAR(12);
    DECLARE v_part_no  VARCHAR(30);

    IF NEW.removed_on IS NULL THEN
        SELECT is_critical, hour_limit, cycle_limit, part_number
          INTO v_critical, v_hour_lim, v_cyc_lim, v_part_no
          FROM part_catalog WHERE part_id = NEW.part_id;

        IF v_critical
           AND ((v_hour_lim IS NOT NULL AND NEW.hours_since_overhaul  >= v_hour_lim)
             OR (v_cyc_lim  IS NOT NULL AND NEW.cycles_since_overhaul >= v_cyc_lim)) THEN

            SELECT status INTO v_status FROM aircraft WHERE aircraft_id = NEW.aircraft_id;
            IF v_status <> 'AOG' THEN
                UPDATE aircraft SET status = 'AOG' WHERE aircraft_id = NEW.aircraft_id;
                INSERT INTO status_log (aircraft_id, old_status, new_status, reason)
                VALUES (NEW.aircraft_id, v_status, 'AOG',
                        CONCAT('Critical component ', v_part_no, ' (', NEW.serial_no, ') passed its limit'));
            END IF;
        END IF;
    END IF;
END//

-- 6.2 Completing a flight accrues hours and cycles on the airframe and on
--     every installed component (this is what makes trg_FlagAOG fire naturally)
CREATE TRIGGER trg_flight_completed
AFTER UPDATE ON flights
FOR EACH ROW
BEGIN
    DECLARE v_hours DECIMAL(10,1);
    IF OLD.status <> 'COMPLETED' AND NEW.status = 'COMPLETED' THEN
        SET v_hours = ROUND(TIMESTAMPDIFF(MINUTE, NEW.sched_departure, NEW.sched_arrival) / 60, 1);

        UPDATE aircraft
           SET total_flight_hours = total_flight_hours + v_hours,
               total_cycles       = total_cycles + 1,
               current_airport    = NEW.destination
         WHERE aircraft_id = NEW.aircraft_id;

        UPDATE installed_components
           SET hours_since_overhaul  = hours_since_overhaul + v_hours,
               cycles_since_overhaul = cycles_since_overhaul + 1
         WHERE aircraft_id = NEW.aircraft_id AND removed_on IS NULL;
    END IF;
END//

-- 6.3 Only SERVICEABLE aircraft may be assigned to a new flight
CREATE TRIGGER trg_flights_before_insert
BEFORE INSERT ON flights
FOR EACH ROW
BEGIN
    DECLARE v_status VARCHAR(12);
    SELECT status INTO v_status FROM aircraft WHERE aircraft_id = NEW.aircraft_id;
    IF v_status <> 'SERVICEABLE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aircraft is not serviceable and cannot be assigned to a flight';
    END IF;
END//

-- 6.4 A completed flight is a historical record
CREATE TRIGGER trg_flights_before_update
BEFORE UPDATE ON flights
FOR EACH ROW
BEGIN
    IF OLD.status = 'COMPLETED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Completed flights cannot be modified';
    END IF;
END//

-- 6.5 Airframe counters never go backwards, and an aircraft cannot be
--     released to SERVICEABLE while a critical component is over its limit
CREATE TRIGGER trg_aircraft_before_update
BEFORE UPDATE ON aircraft
FOR EACH ROW
BEGIN
    IF NEW.total_flight_hours < OLD.total_flight_hours OR NEW.total_cycles < OLD.total_cycles THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Flight hours and cycles cannot decrease';
    END IF;

    IF NEW.status = 'SERVICEABLE' AND OLD.status <> 'SERVICEABLE' THEN
        IF EXISTS (SELECT 1
                     FROM installed_components ic
                     JOIN part_catalog p ON p.part_id = ic.part_id
                    WHERE ic.aircraft_id = OLD.aircraft_id AND ic.removed_on IS NULL AND p.is_critical
                      AND ((p.hour_limit  IS NOT NULL AND ic.hours_since_overhaul  >= p.hour_limit)
                        OR (p.cycle_limit IS NOT NULL AND ic.cycles_since_overhaul >= p.cycle_limit))) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aircraft cannot be released: a critical component is beyond its limit';
        END IF;
    END IF;
END//

-- 6.6 Status log is append-only
CREATE TRIGGER trg_statuslog_no_update
BEFORE UPDATE ON status_log
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Status log is immutable';
END//

CREATE TRIGGER trg_statuslog_no_delete
BEFORE DELETE ON status_log
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Status log cannot be deleted';
END//

DELIMITER ;
