-- =====================================================================
-- Lumora Value Loop demo — 20_forecast.sql
--
-- TWO FORECAST VINTAGES, on purpose.
--
--   PRIOR_PLAN : trained through 2026-08-15 (one month before the anchor).
--                It has only partial sight of the demand break, and it
--                assumes the promo runs in its PLANNED late-August window.
--                This is "last month's plan".
--   CURRENT    : trained through 2026-09-15, the live forecast.
--
-- Two vintages are what make two things answerable with real numbers rather
-- than narration:
--   * "What changed versus last month's forecast?"  -> CURRENT vs PRIOR_PLAN
--   * forecast error / bias                         -> actuals vs PRIOR_PLAN
--     over 2026-08-16..2026-09-15, a genuine out-of-sample window.
--
-- method='fast' (GBM) is chosen deliberately over the 'best' ensemble:
-- 68 series x 549 daily points must train in demo-build time.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.ML;

-- ---------------------------------------------------------------------
-- Training views. Series key is an array -> VARIANT, per the multi-series
-- contract. Grain: brand x region x category, daily.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_TRAIN_PRIOR_PLAN AS
SELECT
    [brand_id, region_code, category_code]      AS series_key,
    TO_TIMESTAMP_NTZ(sales_date)                AS ts,
    SUM(units_sold)::FLOAT                      AS units
FROM LUMORA_DEMO.CORE.FACT_SALES
WHERE sales_date <= DATE '2026-08-15'
GROUP BY 1, 2;

CREATE OR REPLACE VIEW V_TRAIN_CURRENT AS
SELECT
    [brand_id, region_code, category_code]      AS series_key,
    TO_TIMESTAMP_NTZ(sales_date)                AS ts,
    SUM(units_sold)::FLOAT                      AS units
FROM LUMORA_DEMO.CORE.FACT_SALES
WHERE sales_date <= DATE '2026-09-15'
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- Train. evaluate=FALSE: the honest accuracy measure for this demo is the
-- PRIOR_PLAN vintage scored against actuals that have since landed, which
-- is computed below — not built-in cross-validation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST LUMORA_DEMO.ML.FCST_PRIOR_PLAN(
    INPUT_DATA        => TABLE(LUMORA_DEMO.ML.V_TRAIN_PRIOR_PLAN),
    SERIES_COLNAME    => 'series_key',
    TIMESTAMP_COLNAME => 'ts',
    TARGET_COLNAME    => 'units',
    CONFIG_OBJECT     => {'on_error': 'skip', 'method': 'fast', 'evaluate': FALSE}
);

CREATE OR REPLACE SNOWFLAKE.ML.FORECAST LUMORA_DEMO.ML.FCST_CURRENT(
    INPUT_DATA        => TABLE(LUMORA_DEMO.ML.V_TRAIN_CURRENT),
    SERIES_COLNAME    => 'series_key',
    TIMESTAMP_COLNAME => 'ts',
    TARGET_COLNAME    => 'units',
    CONFIG_OBJECT     => {'on_error': 'skip', 'method': 'fast', 'evaluate': FALSE}
);

-- ---------------------------------------------------------------------
-- FACT_FORECAST — both vintages, with the model version and refresh
-- timestamp the UI is required to display.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE LUMORA_DEMO.ML.FACT_FORECAST AS
WITH prior AS (
    SELECT * FROM TABLE(LUMORA_DEMO.ML.FCST_PRIOR_PLAN!FORECAST(
        FORECASTING_PERIODS => 60,
        CONFIG_OBJECT => {'prediction_interval': 0.90}))
),
curr AS (
    SELECT * FROM TABLE(LUMORA_DEMO.ML.FCST_CURRENT!FORECAST(
        FORECASTING_PERIODS => 60,
        CONFIG_OBJECT => {'prediction_interval': 0.90}))
),
unioned AS (
    SELECT 'PRIOR_PLAN' AS forecast_vintage,
           'fcst-v1.0-trained-2026-08-15' AS model_version,
           DATE '2026-08-15' AS trained_through_date,
           series, ts, forecast, lower_bound, upper_bound FROM prior
    UNION ALL
    SELECT 'CURRENT',
           'fcst-v1.1-trained-2026-09-15',
           DATE '2026-09-15',
           series, ts, forecast, lower_bound, upper_bound FROM curr
)
SELECT
    forecast_vintage,
    model_version,
    trained_through_date,
    series[0]::NUMBER      AS brand_id,
    series[1]::VARCHAR     AS region_code,
    series[2]::VARCHAR     AS category_code,
    ts::DATE               AS forecast_date,
    GREATEST(0, ROUND(forecast, 1))    AS forecast_units,
    GREATEST(0, ROUND(lower_bound, 1)) AS forecast_lower,
    GREATEST(0, ROUND(upper_bound, 1)) AS forecast_upper,
    CURRENT_TIMESTAMP()    AS generated_at
FROM unioned;

-- ---------------------------------------------------------------------
-- FACT_FORECAST_EVALUATION — PRIOR_PLAN scored on the month that has since
-- happened (2026-08-16..2026-09-15). This is where the planted break shows
-- up as systematic over-forecasting, which is the Act 1 / Act 2 evidence.
--   wape_pct  : weighted absolute percentage error
--   bias_pct  : positive = the plan over-forecast demand
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE LUMORA_DEMO.ML.FACT_FORECAST_EVALUATION AS
WITH actuals AS (
    SELECT brand_id, region_code, category_code, sales_date,
           SUM(units_sold) AS actual_units
    FROM LUMORA_DEMO.CORE.FACT_SALES
    WHERE sales_date BETWEEN DATE '2026-08-16' AND DATE '2026-09-15'
    GROUP BY 1,2,3,4
),
joined AS (
    SELECT
        a.brand_id, a.region_code, a.category_code,
        a.sales_date, a.actual_units,
        f.forecast_units, f.model_version
    FROM actuals a
    JOIN LUMORA_DEMO.ML.FACT_FORECAST f
      ON  f.forecast_vintage = 'PRIOR_PLAN'
      AND f.brand_id      = a.brand_id
      AND f.region_code   = a.region_code
      AND f.category_code = a.category_code
      AND f.forecast_date = a.sales_date
)
SELECT
    brand_id, region_code, category_code,
    MAX(model_version)                                                  AS model_version,
    DATE '2026-08-16'                                                   AS eval_start_date,
    DATE '2026-09-15'                                                   AS eval_end_date,
    SUM(actual_units)                                                   AS actual_units,
    ROUND(SUM(forecast_units), 1)                                       AS forecast_units,
    ROUND(100.0 * SUM(ABS(forecast_units - actual_units)) / NULLIF(SUM(actual_units),0), 2) AS wape_pct,
    ROUND(100.0 * SUM(forecast_units - actual_units)     / NULLIF(SUM(actual_units),0), 2)  AS bias_pct,
    CURRENT_TIMESTAMP()                                                 AS evaluated_at
FROM joined
GROUP BY 1,2,3;

-- ---------------------------------------------------------------------
-- Sanity output
-- ---------------------------------------------------------------------
SELECT forecast_vintage, COUNT(*) AS row_count,
       MIN(forecast_date) AS from_date, MAX(forecast_date) AS to_date,
       COUNT(DISTINCT brand_id || region_code || category_code) AS series_count
FROM LUMORA_DEMO.ML.FACT_FORECAST
GROUP BY 1;
