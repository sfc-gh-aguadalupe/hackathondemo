-- =====================================================================
-- Lumora Value Loop demo — 11_facts.sql
--
-- The three planted signals live here. They are declared in PLANTED_SIGNAL
-- and then applied arithmetically, so the storyline is COMPUTED from the
-- data rather than hard-coded into any KPI:
--
--   1. Aurelia x SKINCARE x DACH breaks below plan for the trailing 8 weeks
--      while inventory kept being bought on the old plan  -> risk concentrates.
--   2. The DACH skincare promo calendar was pulled ~3 weeks EARLY (actual vs
--      planned start), pulling demand forward. Promotion TIMING is deliberately
--      absent from the baseline feature set -> it is the real missing driver
--      the CFO corrects the agent about in Act 6.
--   3. Solene and Verdant show the same break, weaker, in the same region
--      -> Act 4's group-level pattern, invisible in isolated source systems.
--
-- DETERMINISM: HASH()-derived noise only. No RANDOM().
-- ALL DATA IS SYNTHETIC AND ILLUSTRATIVE.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.CORE;

-- ---------------------------------------------------------------------
-- The planted signal, declared explicitly so it is inspectable.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE PLANTED_SIGNAL (
    brand_id      NUMBER,
    category_code VARCHAR,
    region_code   VARCHAR,
    severity      FLOAT,
    note          VARCHAR
) COMMENT = 'Declared demo signal. Severity scales the demand break and the promo pull-forward.';

INSERT INTO PLANTED_SIGNAL VALUES
    (1,'SKINCARE','DACH',1.00,'Primary risk slice - Aurelia skincare DACH'),
    (3,'SKINCARE','DACH',0.45,'Group pattern - Solene skincare DACH'),
    (5,'SKINCARE','DACH',0.35,'Group pattern - Verdant skincare DACH');

-- ---------------------------------------------------------------------
-- Date spine (549 days ending at the demo anchor date).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_DATE AS
SELECT
    DATEADD(day, SEQ4(), (SELECT history_start_date FROM DEMO_CONFIG)) AS date_key,
    SEQ4()                                                              AS day_index
FROM TABLE(GENERATOR(ROWCOUNT => 549));

-- ---------------------------------------------------------------------
-- FACT_PROMOTIONS
-- Regular promos run as planned (planned = actual) and sit outside the
-- Aug/Sep 2026 window. The three DACH skincare promos are the exception:
-- planned late August, actually run three weeks earlier.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FACT_PROMOTIONS AS
WITH k AS (SELECT SEQ4() + 1 AS promo_seq FROM TABLE(GENERATOR(ROWCOUNT => 2))),
regular AS (
    SELECT
        bc.brand_id,
        bc.category_code,
        r.region_code,
        k.promo_seq,
        DATEADD(day,
                MOD(ABS(HASH(bc.brand_id, bc.category_code, r.region_code, k.promo_seq)), 110)
                + (k.promo_seq - 1) * 210,
                DATE '2025-04-01')                                        AS planned_start,
        ROUND(1.15 + 0.30 * (ABS(HASH(bc.category_code, r.region_code, bc.brand_id, k.promo_seq)) % 1000) / 1000.0, 3) AS uplift_factor
    FROM BRAND_CATEGORY bc
    CROSS JOIN DIM_REGION r
    CROSS JOIN k
),
regular_shaped AS (
    SELECT
        brand_id, category_code, region_code,
        'Seasonal campaign ' || promo_seq                AS promo_name,
        planned_start,
        DATEADD(day, 20, planned_start)                  AS planned_end,
        planned_start                                    AS actual_start,
        DATEADD(day, 20, planned_start)                  AS actual_end,
        uplift_factor,
        FALSE                                            AS timing_changed
    FROM regular
),
-- The pull-forward: planned 2026-08-24..09-14, actually ran 2026-08-03..08-24.
pulled_forward AS (
    SELECT
        ps.brand_id,
        ps.category_code,
        ps.region_code,
        'Autumn Renewal campaign'   AS promo_name,
        DATE '2026-08-24'           AS planned_start,
        DATE '2026-09-14'           AS planned_end,
        DATE '2026-08-03'           AS actual_start,
        DATE '2026-08-24'           AS actual_end,
        ROUND(1.20 + 0.20 * ps.severity, 3) AS uplift_factor,
        TRUE                        AS timing_changed
    FROM PLANTED_SIGNAL ps
)
SELECT
    ROW_NUMBER() OVER (ORDER BY brand_id, category_code, region_code, planned_start) AS promo_id,
    *
FROM (SELECT * FROM regular_shaped UNION ALL SELECT * FROM pulled_forward);

-- ---------------------------------------------------------------------
-- Demand model, shared by sales / inventory / signals so all three agree.
--   planned_daily  = what the plan expected (no break, no promo timing)
--   actual_daily   = what really happened (break + actual promo window)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_DEMAND_MODEL AS
WITH grid AS (
    SELECT
        bc.brand_id, bc.category_code, r.region_code, d.date_key, d.day_index,
        b.brand_scale, r.region_scale,
        c.base_units_day, c.season_phase, c.season_amp
    FROM BRAND_CATEGORY bc
    JOIN DIM_BRAND    b ON b.brand_id = bc.brand_id
    JOIN DIM_CATEGORY c ON c.category_code = bc.category_code
    CROSS JOIN DIM_REGION r
    CROSS JOIN DIM_DATE   d
),
shaped AS (
    SELECT
        g.*,
        cfg.break_start_date,
        -- annual seasonality
        1 + g.season_amp * SIN(2 * 3.14159265 * DAYOFYEAR(g.date_key) / 365.0 + g.season_phase) AS season_f,
        -- mild growth trend
        1 + 0.00025 * g.day_index                                                               AS trend_f,
        COALESCE(ps.severity, 0)                                                                AS severity
    FROM grid g
    CROSS JOIN DEMO_CONFIG cfg
    LEFT JOIN PLANTED_SIGNAL ps
           ON ps.brand_id = g.brand_id
          AND ps.category_code = g.category_code
          AND ps.region_code = g.region_code
)
SELECT
    s.brand_id, s.category_code, s.region_code, s.date_key, s.day_index, s.severity,
    s.base_units_day * s.brand_scale * s.region_scale AS base_units,
    s.season_f,
    s.trend_f,
    -- demand break: ramps to -50% x severity over 6 weeks from break_start.
    -- Sized so the planted slices separate clearly from ordinary seasonal
    -- softness in the same category (~-10%) rather than blending into it.
    CASE WHEN s.date_key >= s.break_start_date
         THEN 1 - s.severity * 0.50 * LEAST(1, DATEDIFF(day, s.break_start_date, s.date_key) / 42.0)
         ELSE 1 END                                   AS break_f,
    -- uplift from the promo window that ACTUALLY ran
    COALESCE((SELECT MAX(p.uplift_factor) FROM FACT_PROMOTIONS p
              WHERE p.brand_id = s.brand_id AND p.category_code = s.category_code
                AND p.region_code = s.region_code
                AND s.date_key BETWEEN p.actual_start AND p.actual_end), 1) AS promo_actual_f,
    -- uplift the plan assumed, i.e. the PLANNED window
    COALESCE((SELECT MAX(p.uplift_factor) FROM FACT_PROMOTIONS p
              WHERE p.brand_id = s.brand_id AND p.category_code = s.category_code
                AND p.region_code = s.region_code
                AND s.date_key BETWEEN p.planned_start AND p.planned_end), 1) AS promo_planned_f
FROM shaped s;

-- ---------------------------------------------------------------------
-- FACT_SALES — daily x brand x region x category x channel
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FACT_SALES AS
WITH ch AS (
    SELECT 'ONLINE' AS channel, 0.45 AS channel_share
    UNION ALL SELECT 'STORE', 0.55
),
prices AS (
    -- ROUND is required for determinism, not cosmetics: floating-point AVG()
    -- sums in a parallelism-dependent order, so an unrounded average can
    -- differ in its last bits between rebuilds and shift a demo figure.
    SELECT brand_id, category_code,
           ROUND(AVG(unit_price), 4) AS avg_price,
           ROUND(AVG(unit_cost), 4)  AS avg_cost
    FROM DIM_PRODUCT GROUP BY 1,2
)
SELECT
    m.date_key                                   AS sales_date,
    m.brand_id,
    b.brand_name,
    b.source_system,
    m.region_code,
    rg.data_residency_zone,
    m.category_code,
    ch.channel,
    GREATEST(1, ROUND(
        m.base_units * ch.channel_share * m.season_f * m.trend_f * m.break_f * m.promo_actual_f
        -- weekday shape: stores peak at the weekend, online dips slightly
        * CASE WHEN DAYOFWEEK(m.date_key) IN (0,6)
               THEN CASE WHEN ch.channel = 'STORE' THEN 1.18 ELSE 0.92 END
               ELSE 1 END
        -- deterministic noise, +/-8%
        * (0.92 + 0.16 * (ABS(HASH(m.brand_id, m.category_code, m.region_code, ch.channel, m.date_key)) % 1000) / 1000.0)
    ))                                           AS units_sold,
    p.avg_price,
    p.avg_cost
FROM V_DEMAND_MODEL m
JOIN DIM_BRAND  b  ON b.brand_id = m.brand_id
JOIN DIM_REGION rg ON rg.region_code = m.region_code
JOIN prices     p  ON p.brand_id = m.brand_id AND p.category_code = m.category_code
CROSS JOIN ch;

-- add the money columns (kept as stored columns so the app reads them directly)
CREATE OR REPLACE TABLE FACT_SALES AS
SELECT
    s.*,
    ROUND(s.units_sold * s.avg_price, 2)                    AS revenue_amount,
    ROUND(s.units_sold * (s.avg_price - s.avg_cost), 2)     AS gross_margin_amount
FROM FACT_SALES s;

-- ---------------------------------------------------------------------
-- FACT_INVENTORY — weekly snapshots.
-- On-hand is bought against the PLAN (no knowledge of the break), which is
-- precisely why the planted slices end up over-stocked once demand falls.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FACT_INVENTORY AS
WITH weeks AS (
    SELECT date_key AS snapshot_date, day_index
    FROM DIM_DATE
    WHERE DAYOFWEEK(date_key) = 1          -- Mondays
),
planned AS (
    SELECT
        m.brand_id, m.category_code, m.region_code, m.date_key,
        m.base_units * m.season_f * m.trend_f AS planned_daily_units,
        m.severity
    FROM V_DEMAND_MODEL m
),
prices AS (
    -- rounded for determinism, as above
    SELECT brand_id, category_code,
           ROUND(AVG(unit_cost), 4)  AS avg_cost,
           ROUND(AVG(unit_price), 4) AS avg_price
    FROM DIM_PRODUCT GROUP BY 1,2
),
-- Buying position per slice, in days of PLANNED cover.
-- Ordinary slices scatter around the 45-day policy, so roughly half run
-- short (real stockout risk) and half run long. The planted slices sit
-- well above policy: they kept buying into a demand break.
cover AS (
    SELECT
        pl.brand_id, pl.category_code, pl.region_code,
        CASE WHEN pl.severity > 0 THEN 52
             ELSE 24 + MOD(ABS(HASH(pl.brand_id, pl.category_code, pl.region_code)), 26)
        END AS on_hand_cover_days,
        CASE WHEN pl.severity > 0 THEN 14
             ELSE 6 + MOD(ABS(HASH(pl.category_code, pl.region_code, pl.brand_id, 'oo')), 7)
        END AS on_order_cover_days
    FROM (SELECT DISTINCT brand_id, category_code, region_code, severity FROM V_DEMAND_MODEL) pl
)
SELECT
    w.snapshot_date,
    pl.brand_id,
    b.brand_name,
    pl.region_code,
    pl.category_code,
    -- on-hand and on-order, each in that slice's own days of planned cover
    ROUND(pl.planned_daily_units * cv.on_hand_cover_days
          * (0.94 + 0.12 * (ABS(HASH(pl.brand_id, pl.category_code, pl.region_code, w.snapshot_date)) % 1000) / 1000.0)) AS on_hand_units,
    ROUND(pl.planned_daily_units * cv.on_order_cover_days
          * (0.90 + 0.20 * (ABS(HASH(pl.category_code, pl.region_code, pl.brand_id, w.snapshot_date)) % 1000) / 1000.0)) AS on_order_units,
    pr.avg_cost,
    pr.avg_price,
    45 AS target_cover_days
FROM weeks w
JOIN planned pl ON pl.date_key = w.snapshot_date
JOIN cover   cv ON cv.brand_id = pl.brand_id AND cv.category_code = pl.category_code
                AND cv.region_code = pl.region_code
JOIN DIM_BRAND b ON b.brand_id = pl.brand_id
JOIN prices   pr ON pr.brand_id = pl.brand_id AND pr.category_code = pl.category_code;

CREATE OR REPLACE TABLE FACT_INVENTORY AS
SELECT
    i.*,
    ROUND(i.on_hand_units  * i.avg_cost, 2) AS on_hand_value,
    ROUND(i.on_order_units * i.avg_cost, 2) AS on_order_value
FROM FACT_INVENTORY i;

-- ---------------------------------------------------------------------
-- FACT_DEMAND_SIGNALS — leading indicators.
-- Search interest for the planted slices starts falling TWO WEEKS BEFORE
-- the sales break, so the explanation tool has a genuine early warning
-- to point at rather than a coincident metric.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FACT_DEMAND_SIGNALS AS
SELECT
    m.date_key AS signal_date,
    m.brand_id,
    m.region_code,
    m.category_code,
    ROUND(m.base_units * 7.5 * m.season_f
          * (0.90 + 0.20 * (ABS(HASH('web', m.brand_id, m.category_code, m.region_code, m.date_key)) % 1000) / 1000.0)) AS web_sessions,
    ROUND(100
          * CASE WHEN m.date_key >= DATEADD(day, -14, cfg.break_start_date)
                 THEN 1 - m.severity * 0.28
                       * LEAST(1, DATEDIFF(day, DATEADD(day, -14, cfg.break_start_date), m.date_key) / 42.0)
                 ELSE 1 END
          * (0.96 + 0.08 * (ABS(HASH('srch', m.brand_id, m.category_code, m.region_code, m.date_key)) % 1000) / 1000.0)
    , 1)                                                                     AS search_interest_index,
    ROUND(m.base_units * 1.4 * m.season_f * m.break_f
          * (0.90 + 0.20 * (ABS(HASH('bskt', m.brand_id, m.category_code, m.region_code, m.date_key)) % 1000) / 1000.0)) AS basket_adds
FROM V_DEMAND_MODEL m
CROSS JOIN DEMO_CONFIG cfg;

-- ---------------------------------------------------------------------
-- FACT_CUSTOMER_ACTIVITY — monthly, for the cross-brand drill-down.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FACT_CUSTOMER_ACTIVITY AS
WITH months AS (
    SELECT DISTINCT DATE_TRUNC('month', date_key) AS activity_month FROM DIM_DATE
)
SELECT
    ci.identity_id,
    ci.customer_group_id,
    ci.brand_id,
    ci.region_code,
    m.activity_month,
    1 + MOD(ABS(HASH(ci.identity_id, m.activity_month)), 4)                         AS orders,
    ROUND((25 + MOD(ABS(HASH(m.activity_month, ci.identity_id)), 180))
          * (1 + MOD(ABS(HASH(ci.identity_id, m.activity_month)), 4)) / 1.0, 2)     AS revenue_amount
FROM DIM_CUSTOMER_IDENTITY ci
CROSS JOIN months m
-- not every customer buys every month; ~55% active, deterministically
WHERE MOD(ABS(HASH(ci.identity_id, m.activity_month, 'act')), 100) < 55;

-- ---------------------------------------------------------------------
-- Sanity output
-- ---------------------------------------------------------------------
SELECT 'FACT_PROMOTIONS' AS table_name, COUNT(*) AS row_count FROM FACT_PROMOTIONS
UNION ALL SELECT 'FACT_SALES',             COUNT(*) FROM FACT_SALES
UNION ALL SELECT 'FACT_INVENTORY',         COUNT(*) FROM FACT_INVENTORY
UNION ALL SELECT 'FACT_DEMAND_SIGNALS',    COUNT(*) FROM FACT_DEMAND_SIGNALS
UNION ALL SELECT 'FACT_CUSTOMER_ACTIVITY', COUNT(*) FROM FACT_CUSTOMER_ACTIVITY
UNION ALL SELECT 'promos with timing change', COUNT(*) FROM FACT_PROMOTIONS WHERE timing_changed;
