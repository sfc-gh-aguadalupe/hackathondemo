-- =====================================================================
-- Lumora Value Loop demo — 21_kpi_views.sql
--
-- ONE DEFINITION PER KPI. The Streamlit app, the agent's tools and the
-- semantic view all read these same views, so a number quoted in the chat
-- panel cannot drift from the number on the KPI card.
--
-- Every currency figure is derived from synthetic unit cost/price and is
-- ILLUSTRATIVE. The markdown rate is an explicit stated assumption, not an
-- observed fact — see MARKDOWN_RATE_ASSUMPTION below.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.APP;

-- Stated assumptions, surfaced in the UI rather than buried in SQL.
CREATE OR REPLACE VIEW LUMORA_DEMO.APP.V_ASSUMPTIONS AS
SELECT 0.40 AS markdown_rate,
       45   AS target_cover_days,
       'Markdown rate of 40% of cost is an assumption, not an observed Lumora figure' AS markdown_note,
       'All financial values are illustrative and derived from synthetic unit economics' AS value_disclaimer;

-- ---------------------------------------------------------------------
-- V_SLICE_RISK — the analytical core, one row per brand x region x category.
-- Everything else on the cockpit aggregates this.
--
-- Inventory was purchased against the PLAN. Forward demand comes from the
-- CURRENT forecast. Where the plan-driven stock exceeds what the current
-- forecast will consume, that difference is exposure — which is why the
-- risk concentrates on the slices whose demand broke, without any slice
-- being singled out in code.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.APP.V_SLICE_RISK AS
WITH latest_snap AS (
    SELECT MAX(snapshot_date) AS snapshot_date
    FROM LUMORA_DEMO.CORE.FACT_INVENTORY
    WHERE snapshot_date <= (SELECT demo_asof_date FROM LUMORA_DEMO.CORE.DEMO_CONFIG)
),
inv AS (
    SELECT i.brand_id, i.region_code, i.category_code,
           i.snapshot_date,
           i.on_hand_units, i.on_order_units,
           i.on_hand_value, i.on_order_value,
           i.avg_cost, i.avg_price, i.target_cover_days
    FROM LUMORA_DEMO.CORE.FACT_INVENTORY i
    JOIN latest_snap s ON s.snapshot_date = i.snapshot_date
),
-- forward 45 days of demand from the live forecast
fwd AS (
    SELECT brand_id, region_code, category_code,
           SUM(forecast_units) AS fwd_demand_units,
           AVG(forecast_units) AS fwd_daily_units,
           SUM(forecast_lower) AS fwd_demand_lower,
           SUM(forecast_upper) AS fwd_demand_upper,
           MAX(model_version)  AS model_version,
           MAX(generated_at)   AS forecast_generated_at
    FROM LUMORA_DEMO.ML.FACT_FORECAST
    WHERE forecast_vintage = 'CURRENT'
      AND forecast_date <= DATEADD(day, 45, DATE '2026-09-15')
    GROUP BY 1,2,3
),
ev AS (
    SELECT brand_id, region_code, category_code,
           wape_pct, bias_pct, actual_units AS eval_actual_units,
           forecast_units AS eval_forecast_units, evaluated_at
    FROM LUMORA_DEMO.ML.FACT_FORECAST_EVALUATION
)
SELECT
    inv.brand_id,
    b.brand_name,
    b.source_system,
    inv.region_code,
    r.data_residency_zone,
    r.is_eu,
    inv.category_code,
    inv.snapshot_date,
    inv.on_hand_units,
    inv.on_order_units,
    inv.on_hand_value,
    inv.on_order_value,
    inv.avg_cost,
    inv.avg_price,
    inv.target_cover_days,
    ROUND(fwd.fwd_demand_units, 1)                                     AS fwd_demand_units_45d,
    ROUND(fwd.fwd_daily_units, 2)                                      AS fwd_daily_units,
    ROUND(fwd.fwd_demand_lower, 1)                                     AS fwd_demand_lower_45d,
    ROUND(fwd.fwd_demand_upper, 1)                                     AS fwd_demand_upper_45d,
    fwd.model_version,
    fwd.forecast_generated_at,
    ev.wape_pct,
    ev.bias_pct,
    ev.eval_actual_units,
    ev.eval_forecast_units,
    ev.evaluated_at,
    -- position vs forward demand
    (inv.on_hand_units + inv.on_order_units)                           AS available_units,
    ROUND((inv.on_hand_units + inv.on_order_units)
          / NULLIF(fwd.fwd_daily_units, 0), 1)                         AS cover_days,
    -- EXPOSURE: stock beyond what the current forecast will consume
    GREATEST(0, ROUND(inv.on_hand_units + inv.on_order_units - fwd.fwd_demand_units)) AS excess_units,
    ROUND(GREATEST(0, inv.on_hand_units + inv.on_order_units - fwd.fwd_demand_units)
          * inv.avg_cost, 2)                                           AS inventory_value_at_risk,
    -- markdown exposure at the stated assumed rate
    ROUND(GREATEST(0, inv.on_hand_units + inv.on_order_units - fwd.fwd_demand_units)
          * inv.avg_cost * (SELECT markdown_rate FROM LUMORA_DEMO.APP.V_ASSUMPTIONS), 2) AS markdown_exposure,
    -- the opposite risk: not enough stock for forecast demand
    GREATEST(0, ROUND(fwd.fwd_demand_units - inv.on_hand_units - inv.on_order_units))  AS stockout_gap_units,
    ROUND(GREATEST(0, fwd.fwd_demand_units - inv.on_hand_units - inv.on_order_units)
          * (inv.avg_price - inv.avg_cost), 2)                          AS stockout_margin_at_risk
FROM inv
JOIN LUMORA_DEMO.CORE.DIM_BRAND  b ON b.brand_id = inv.brand_id
JOIN LUMORA_DEMO.CORE.DIM_REGION r ON r.region_code = inv.region_code
LEFT JOIN fwd ON fwd.brand_id = inv.brand_id AND fwd.region_code = inv.region_code
              AND fwd.category_code = inv.category_code
LEFT JOIN ev  ON ev.brand_id  = inv.brand_id AND ev.region_code  = inv.region_code
              AND ev.category_code  = inv.category_code;

-- ---------------------------------------------------------------------
-- V_KPI_EXEC — the cockpit's headline cards, one row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.APP.V_KPI_EXEC AS
WITH risk AS (
    SELECT
        SUM(inventory_value_at_risk)  AS inventory_value_at_risk,
        SUM(markdown_exposure)        AS markdown_exposure,
        SUM(stockout_margin_at_risk)  AS stockout_margin_at_risk,
        COUNT(*)                      AS slice_count,
        COUNT(CASE WHEN cover_days > target_cover_days * 1.5 THEN 1 END) AS overstocked_slices,
        COUNT(CASE WHEN stockout_gap_units > 0 THEN 1 END)              AS stockout_slices
    FROM LUMORA_DEMO.APP.V_SLICE_RISK
),
acc AS (
    -- group-level accuracy, weighted by volume (not an average of averages)
    SELECT
        ROUND(100.0 * SUM(ABS(eval_forecast_units - eval_actual_units))
              / NULLIF(SUM(eval_actual_units), 0), 2) AS wape_pct,
        ROUND(100.0 * SUM(eval_forecast_units - eval_actual_units)
              / NULLIF(SUM(eval_actual_units), 0), 2) AS bias_pct,
        MAX(evaluated_at) AS evaluated_at
    FROM LUMORA_DEMO.APP.V_SLICE_RISK
),
cust AS (
    SELECT
        COUNT(DISTINCT customer_group_id) AS total_customers,
        COUNT(DISTINCT CASE WHEN brand_count > 1 THEN customer_group_id END) AS multi_brand_customers
    FROM (
        SELECT customer_group_id, COUNT(DISTINCT brand_id) AS brand_count
        FROM LUMORA_DEMO.CORE.DIM_CUSTOMER_IDENTITY
        GROUP BY 1
    )
),
model AS (
    SELECT MAX(model_version) AS model_version,
           MAX(generated_at)  AS forecast_generated_at,
           MAX(trained_through_date) AS trained_through_date
    FROM LUMORA_DEMO.ML.FACT_FORECAST
    WHERE forecast_vintage = 'CURRENT'
)
SELECT
    risk.inventory_value_at_risk,
    risk.markdown_exposure,
    risk.stockout_margin_at_risk,
    risk.overstocked_slices,
    risk.stockout_slices,
    risk.slice_count,
    acc.wape_pct                                                                AS forecast_wape_pct,
    acc.bias_pct                                                                AS forecast_bias_pct,
    acc.evaluated_at,
    cust.total_customers,
    cust.multi_brand_customers,
    ROUND(100.0 * cust.multi_brand_customers / NULLIF(cust.total_customers,0), 1) AS cross_brand_coverage_pct,
    model.model_version,
    model.trained_through_date,
    model.forecast_generated_at,
    (SELECT value_disclaimer FROM LUMORA_DEMO.APP.V_ASSUMPTIONS)                AS value_disclaimer
FROM risk CROSS JOIN acc CROSS JOIN cust CROSS JOIN model;

-- ---------------------------------------------------------------------
-- V_BRAND_RISK_HEATMAP — brand x region exposure for the cockpit heatmap.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.APP.V_BRAND_RISK_HEATMAP AS
SELECT
    brand_name,
    region_code,
    data_residency_zone,
    ROUND(SUM(inventory_value_at_risk), 2) AS inventory_value_at_risk,
    ROUND(SUM(markdown_exposure), 2)       AS markdown_exposure,
    ROUND(100.0 * SUM(eval_forecast_units - eval_actual_units)
          / NULLIF(SUM(eval_actual_units), 0), 1) AS bias_pct,
    COUNT(*) AS category_count
FROM LUMORA_DEMO.APP.V_SLICE_RISK
GROUP BY 1,2,3;

-- ---------------------------------------------------------------------
-- V_ACTUAL_VS_FORECAST — the time-series chart. Actuals, the live forecast
-- with its interval, and last month's plan on the same axis.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.APP.V_ACTUAL_VS_FORECAST AS
WITH actuals AS (
    SELECT brand_id, region_code, category_code, sales_date AS date_key,
           SUM(units_sold) AS actual_units, SUM(revenue_amount) AS actual_revenue
    FROM LUMORA_DEMO.CORE.FACT_SALES
    GROUP BY 1,2,3,4
),
fc AS (
    SELECT brand_id, region_code, category_code, forecast_date AS date_key,
           MAX(CASE WHEN forecast_vintage='CURRENT'    THEN forecast_units END) AS forecast_units,
           MAX(CASE WHEN forecast_vintage='CURRENT'    THEN forecast_lower END) AS forecast_lower,
           MAX(CASE WHEN forecast_vintage='CURRENT'    THEN forecast_upper END) AS forecast_upper,
           MAX(CASE WHEN forecast_vintage='PRIOR_PLAN' THEN forecast_units END) AS prior_plan_units
    FROM LUMORA_DEMO.ML.FACT_FORECAST
    GROUP BY 1,2,3,4
)
SELECT
    COALESCE(a.brand_id, f.brand_id)           AS brand_id,
    b.brand_name,
    COALESCE(a.region_code, f.region_code)     AS region_code,
    COALESCE(a.category_code, f.category_code) AS category_code,
    COALESCE(a.date_key, f.date_key)           AS date_key,
    a.actual_units,
    a.actual_revenue,
    f.forecast_units,
    f.forecast_lower,
    f.forecast_upper,
    f.prior_plan_units
FROM actuals a
FULL OUTER JOIN fc f
  ON  f.brand_id = a.brand_id AND f.region_code = a.region_code
  AND f.category_code = a.category_code AND f.date_key = a.date_key
JOIN LUMORA_DEMO.CORE.DIM_BRAND b
  ON b.brand_id = COALESCE(a.brand_id, f.brand_id);

-- ---------------------------------------------------------------------
-- V_WHAT_CHANGED — current forecast vs last month's plan over the window
-- both vintages cover (2026-09-16..2026-10-14). This is the "what changed?"
-- callout, and it is a comparison of two models, not a narrative.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.APP.V_WHAT_CHANGED AS
WITH overlap AS (
    SELECT brand_id, region_code, category_code,
           SUM(CASE WHEN forecast_vintage='CURRENT'    THEN forecast_units END) AS current_units,
           SUM(CASE WHEN forecast_vintage='PRIOR_PLAN' THEN forecast_units END) AS prior_plan_units
    FROM LUMORA_DEMO.ML.FACT_FORECAST
    WHERE forecast_date BETWEEN DATE '2026-09-16' AND DATE '2026-10-14'
    GROUP BY 1,2,3
)
SELECT
    o.brand_id, b.brand_name, o.region_code, o.category_code,
    ROUND(o.current_units, 1)    AS current_units,
    ROUND(o.prior_plan_units, 1) AS prior_plan_units,
    ROUND(o.current_units - o.prior_plan_units, 1) AS delta_units,
    ROUND(100.0 * (o.current_units - o.prior_plan_units)
          / NULLIF(o.prior_plan_units, 0), 1)      AS delta_pct
FROM overlap o
JOIN LUMORA_DEMO.CORE.DIM_BRAND b ON b.brand_id = o.brand_id
WHERE o.prior_plan_units IS NOT NULL AND o.current_units IS NOT NULL;

-- ---------------------------------------------------------------------
-- V_CROSS_BRAND_CUSTOMERS — the marketing KPI and the Act 4 evidence.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.APP.V_CROSS_BRAND_CUSTOMERS AS
WITH spans AS (
    SELECT customer_group_id,
           COUNT(DISTINCT brand_id)   AS brand_count,
           COUNT(DISTINCT region_code) AS region_count,
           MAX(sensitivity_class)      AS sensitivity_class
    FROM LUMORA_DEMO.CORE.DIM_CUSTOMER_IDENTITY
    GROUP BY 1
)
SELECT brand_count,
       COUNT(*) AS customer_groups,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_base
FROM spans
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- Sanity output — the headline KPIs the cockpit will show.
-- ---------------------------------------------------------------------
SELECT * FROM LUMORA_DEMO.APP.V_KPI_EXEC;
