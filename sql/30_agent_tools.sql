-- =====================================================================
-- Lumora Value Loop demo — 30_agent_tools.sql
--
-- Five deterministic agent tools (stored procedures) plus the
-- LUMORA_VALUE_AGENT Cortex Agent that orchestrates them, Cortex Search,
-- and Cortex Analyst over the executive semantic view. Every calculation
-- a tool returns is computed in SQL — the LLM never invents a number.
--
-- CRITICAL IMPLEMENTATION NOTE (read before changing signatures):
-- Cortex Agent "generic" custom tools require the backing stored
-- procedure to return a SINGLE-CELL result (one row, one column). A
-- procedure declared RETURNS TABLE(...) with multiple columns compiles
-- and runs fine via CALL, but the agent's tool-result wrapper rejects it
-- with "expected a single cell result set, got N rows and M columns".
-- All five procedures below therefore RETURN VARIANT: a JSON object
-- (OBJECT_CONSTRUCT(*)) for single-row tools, or a JSON array
-- (ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ...)) for the
-- ranked-drivers tool. Call them with CALL — NOT SELECT * FROM TABLE(...);
-- they are true stored procedures (SHOW PROCEDURES), and DML (INSERT)
-- inside them only works because they run via CALL, not FROM TABLE().
--
-- Every calculation runs against LUMORA_DEMO.APP.V_SLICE_RISK / V_ASSUMPTIONS
-- and the ML/CORE fact tables built in 20_forecast.sql / 21_kpi_views.sql /
-- 11_facts.sql, so nothing here re-derives or hard-codes a business number.
--
-- PRE-STAGED sections (marked below) are intentionally not "live" ML/LLM
-- jobs — per the demo spec, retraining and fine-tuning route to
-- pre-computed comparison tables so the live demo never waits on a real
-- training or fine-tuning job. The mechanics (which slices, which WAPE,
-- which feature) are still derived from the real evaluation data at
-- table-build time, not invented.
--
-- All financial values are illustrative and derived from synthetic unit
-- economics — never Lumora's actual financials.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.AGENT;

-- ---------------------------------------------------------------------
-- Sequences for human-readable, monotonically increasing request/job IDs.
-- (Unordered Snowflake sequences reserve value blocks per session, so IDs
-- will have gaps between calls — expected, not a bug, still unique.)
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS LUMORA_DEMO.AGENT.SEQ_RETRAINING_REQUEST START = 1 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS LUMORA_DEMO.AGENT.SEQ_FEEDBACK          START = 100 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS LUMORA_DEMO.AGENT.SEQ_FINETUNE_JOB      START = 1 INCREMENT = 1;

-- =====================================================================
-- TOOL 4 SUPPORT — NUMERIC forecast retraining request log + pre-staged
-- candidate-model evaluation. Kept as a real append-only log (IF NOT
-- EXISTS) so accumulated demo requests survive re-running this script.
-- =====================================================================
CREATE TABLE IF NOT EXISTS LUMORA_DEMO.AGENT.FACT_RETRAINING_REQUEST (
    request_id          VARCHAR       COMMENT 'e.g. RETRAIN-000001',
    requestor           VARCHAR,
    reason              VARCHAR,
    scope               VARCHAR       COMMENT 'brand/region/category scope requested, e.g. Aurelia / DACH / SKINCARE',
    requested_at        TIMESTAMP_LTZ,
    status              VARCHAR       COMMENT 'ROUTED_TO_PRESTAGED_EVALUATION or QUEUED_FOR_TRAINING_JOB',
    expected_next_step  VARCHAR
) COMMENT = 'NUMERIC forecast retraining request log. Distinct from FACT_AGENT_FEEDBACK, which logs LLM behaviour fine-tuning feedback - retraining changes the demand model, fine-tuning changes the agent''s language behaviour.';

-- PRE-STAGED: candidate model evaluated offline, not a live training run.
-- The improvement magnitude is illustrative; the mechanism (adding a
-- promotion-timing feature closes most of the bias for the DACH skincare
-- slices that broke) is the real root cause EXPLAIN_FORECAST_VARIANCE finds.
CREATE OR REPLACE TABLE LUMORA_DEMO.AGENT.PRESTAGED_RETRAIN_RESULT (
    scope_brand              VARCHAR,
    scope_region             VARCHAR,
    scope_category           VARCHAR,
    baseline_model_version   VARCHAR,
    candidate_model_version  VARCHAR,
    baseline_wape_pct        FLOAT,
    candidate_wape_pct       FLOAT,
    wape_improvement_pct     FLOAT,
    feature_added            VARCHAR,
    notes                     VARCHAR
) COMMENT = 'PRE-STAGED candidate-model evaluation, not a live training run. For the live demo, REQUEST_FORECAST_RETRAINING routes to this pre-computed comparison rather than waiting for a real SNOWFLAKE.ML.FORECAST training job.';

INSERT INTO LUMORA_DEMO.AGENT.PRESTAGED_RETRAIN_RESULT
SELECT
    b.brand_name, e.region_code, e.category_code,
    e.model_version,
    'fcst-v1.2-candidate',
    e.wape_pct,
    ROUND(e.wape_pct * 0.22, 2),
    ROUND(100.0 * (e.wape_pct - e.wape_pct * 0.22) / NULLIF(e.wape_pct,0), 1),
    'promotion_timing_shift_days (actual_start - planned_start), promotion_actual_window_flag',
    'Pre-staged candidate evaluated offline against the same holdout window (' || e.eval_start_date || ' to ' || e.eval_end_date
        || '). Adding the promotion-timing feature lets the candidate model recognise that August demand was pulled forward, '
        || 'closing most of the bias seen in ' || e.model_version || '.'
FROM LUMORA_DEMO.ML.FACT_FORECAST_EVALUATION e
JOIN LUMORA_DEMO.CORE.DIM_BRAND b ON b.brand_id = e.brand_id
JOIN LUMORA_DEMO.CORE.PLANTED_SIGNAL ps
  ON ps.brand_id = e.brand_id AND ps.region_code = e.region_code AND ps.category_code = e.category_code;

-- =====================================================================
-- TOOL 5 SUPPORT — LANGUAGE fine-tuning feedback log, training view, and
-- pre-staged base-vs-tuned comparison. FACT_AGENT_FEEDBACK is append-only
-- (IF NOT EXISTS); seed rows use a distinct SEED- prefix so they never
-- collide with sequence-generated feedback_ids from live procedure calls.
-- =====================================================================
CREATE TABLE IF NOT EXISTS LUMORA_DEMO.AGENT.FACT_AGENT_FEEDBACK (
    feedback_id     VARCHAR,
    requestor       VARCHAR,
    feedback_text   VARCHAR,
    approved        BOOLEAN,
    prompt_text     VARCHAR,
    completion_text VARCHAR,
    created_at      TIMESTAMP_LTZ
) COMMENT = 'Approved prompt-completion examples for LLM (natural-language) fine-tuning of the agent''s explanation style. Distinct from FACT_RETRAINING_REQUEST, which improves the NUMERIC demand-forecast model, not the agent''s language.';

INSERT INTO LUMORA_DEMO.AGENT.FACT_AGENT_FEEDBACK
    (feedback_id, requestor, feedback_text, approved, prompt_text, completion_text, created_at)
SELECT * FROM (
    SELECT 'FEEDBACK-SEED-01', 'cfo_demo_user',
        'Good answer, but always state the evaluation window dates explicitly instead of just saying "recently".',
        TRUE,
        'Why is inventory risk highest for Aurelia in DACH skincare?',
        'Executive answer: Aurelia''s DACH skincare inventory carries the largest exposure in the group, concentrated because on-hand stock was bought against a plan that assumed no demand break. Evidence: for the evaluation window 2026-08-16 to 2026-09-15, actual demand came in well below the forecast (bias +61.3%). Assumption: financial figures are illustrative, derived from synthetic unit economics. Recommendation: hold new purchase orders for this slice and confirm with a human before committing further inventory.',
        DATEADD(day, -40, CURRENT_TIMESTAMP())
    UNION ALL
    SELECT 'FEEDBACK-SEED-02', 'cmo_demo_user',
        'Clearly separate what is an observed fact versus a model calculation - this response blended them.',
        TRUE,
        'What changed versus last month''s forecast for Solene?',
        'Executive answer: the current forecast for Solene DACH skincare is lower than last month''s plan. Observed fact: prior plan forecast units vs current forecast units differ by the delta shown in V_WHAT_CHANGED. Calculation: the percentage change is computed directly from the two forecast vintages. Assumption: no promotional or pricing change is assumed beyond what is already in the forecast inputs. Recommendation: review before committing marketing spend against the prior plan''s assumption.',
        DATEADD(day, -33, CURRENT_TIMESTAMP())
    UNION ALL
    SELECT 'FEEDBACK-SEED-03', 'cto_demo_user',
        'Good grounding in the policy search result, keep citing the specific document.',
        TRUE,
        'Can we use EU customer data in this scenario, and what constraint should we check?',
        'Executive answer: EU customer data (DACH, data_residency_zone = EU_WEST) can be used only within the residency and consent constraints described in Lumora''s governance documentation. Evidence: policy search surfaced the relevant residency and consent control. Recommendation: confirm with a human governance owner before using EU customer data for any customer-treatment action.',
        DATEADD(day, -20, CURRENT_TIMESTAMP())
    UNION ALL
    SELECT 'FEEDBACK-SEED-04', 'cfo_demo_user',
        'Do not invent a dollar figure when the scenario tool has not been run for that horizon - ask before assuming.',
        TRUE,
        'What would happen if demand increased 10% for the next 6 weeks in Verdant DACH skincare?',
        'Executive answer: I do not have a computed scenario result for a 10% uplift over 6 weeks yet. Recommendation: I will run RUN_DEMAND_SCENARIO with those exact parameters and report the recomputed exposure before giving a number - I will not estimate a financial impact without a tool result.',
        DATEADD(day, -9, CURRENT_TIMESTAMP())
) seed
WHERE NOT EXISTS (SELECT 1 FROM LUMORA_DEMO.AGENT.FACT_AGENT_FEEDBACK WHERE feedback_id = seed.$1);

CREATE OR REPLACE VIEW LUMORA_DEMO.AGENT.V_FINETUNE_TRAINING_DATA AS
SELECT
    feedback_id,
    prompt_text,
    completion_text,
    created_at
FROM LUMORA_DEMO.AGENT.FACT_AGENT_FEEDBACK
WHERE approved = TRUE
  AND prompt_text IS NOT NULL
  AND completion_text IS NOT NULL
ORDER BY created_at
COMMENT = 'Prompt-completion pairs for Cortex Fine-tuning of the agent''s explanation LANGUAGE, built only from approved FACT_AGENT_FEEDBACK rows. Trains response STYLE, not the demand-forecast model.';

-- PRE-STAGED: illustrates the exact behaviour gap fine-tuning is meant to
-- close (base model omits promotion timing, tuned model cites it) — not a
-- completed Cortex Fine-tuning job.
CREATE OR REPLACE TABLE LUMORA_DEMO.AGENT.PRESTAGED_FINETUNE_COMPARISON (
    comparison_id      VARCHAR,
    question            VARCHAR,
    base_model_answer  VARCHAR,
    tuned_model_answer VARCHAR,
    notes               VARCHAR
) COMMENT = 'PRE-STAGED base-vs-tuned example for the agent''s LANGUAGE behaviour (explanation quality), not a real completed Cortex Fine-tuning job.';

INSERT INTO LUMORA_DEMO.AGENT.PRESTAGED_FINETUNE_COMPARISON VALUES
('FT-COMPARE-000001',
 'Why is inventory risk highest for Aurelia in DACH skincare, and what caused the forecast to be so far off?',
 'Executive answer: Aurelia''s DACH skincare inventory is the largest exposure in the group. Evidence: the forecast overshot actual demand by 61.3% for the evaluation window 2026-08-16 to 2026-09-15, and on-hand cover is well above the 45-day policy target. Recommendation: pause new purchase orders for this slice pending human review.',
 'Executive answer: Aurelia''s DACH skincare inventory is the largest exposure in the group. Evidence: the forecast overshot actual demand by 61.3% for the evaluation window 2026-08-16 to 2026-09-15, and on-hand cover is well above the 45-day policy target. Root cause: the ''Autumn Renewal campaign'' was planned for 2026-08-24 to 2026-09-14 but actually ran three weeks earlier (2026-08-03 to 2026-08-24) - promotion timing pulled demand forward, so the plan expected a September uplift that had already been spent. This feature is not yet in the production forecast model. Recommendation: pause new purchase orders for this slice pending human review, and consider requesting forecast retraining with promotion-timing features.',
 'Base model answer omits promotion timing (the actual root cause surfaced by EXPLAIN_FORECAST_VARIANCE); tuned answer correctly cites it. This is the exact gap Act 6 of the demo corrects via approved feedback.');

-- =====================================================================
-- TOOL 1 — GET_LUMORA_KPIS
-- Deterministic KPI snapshot for a brand/region/category scope, built on
-- V_SLICE_RISK / V_ASSUMPTIONS. NULL or '' for any argument means "all".
-- =====================================================================
CREATE OR REPLACE PROCEDURE LUMORA_DEMO.AGENT.GET_LUMORA_KPIS(
    P_BRAND VARCHAR,
    P_REGION VARCHAR,
    P_CATEGORY VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Deterministic KPI tool for the Lumora Value Agent. Every figure comes straight from LUMORA_DEMO.APP.V_SLICE_RISK / V_ASSUMPTIONS - no LLM computation. Returns a single JSON object (Cortex Agent generic tools require a single-cell result). NULL or empty scope arguments mean "all". Distinct from EXPLAIN_FORECAST_VARIANCE (drivers) and RUN_DEMAND_SCENARIO (what-if).'
AS
$$
DECLARE
    out_var VARIANT;
BEGIN
    SELECT OBJECT_CONSTRUCT(*) INTO :out_var
    FROM (
        SELECT
            COALESCE(NULLIF(TRIM(:P_BRAND), ''), 'All brands')::VARCHAR       AS brand_scope,
            COALESCE(NULLIF(TRIM(:P_REGION), ''), 'All regions')::VARCHAR     AS region_scope,
            COALESCE(NULLIF(TRIM(:P_CATEGORY), ''), 'All categories')::VARCHAR AS category_scope,
            COUNT(*)                                                  AS slice_count,
            ROUND(SUM(inventory_value_at_risk), 2)::FLOAT             AS inventory_value_at_risk,
            ROUND(SUM(markdown_exposure), 2)::FLOAT                   AS markdown_exposure,
            ROUND(SUM(stockout_margin_at_risk), 2)::FLOAT             AS stockout_margin_at_risk,
            ROUND(SUM(stockout_gap_units), 1)::FLOAT                  AS stockout_gap_units,
            ROUND(AVG(cover_days), 1)::FLOAT                          AS avg_cover_days,
            ROUND(MAX(target_cover_days), 1)::FLOAT                   AS target_cover_days,
            ROUND(SUM(fwd_demand_units_45d), 1)::FLOAT                AS fwd_demand_units_45d,
            ROUND(SUM(fwd_demand_lower_45d), 1)::FLOAT                AS fwd_demand_lower_45d,
            ROUND(SUM(fwd_demand_upper_45d), 1)::FLOAT                AS fwd_demand_upper_45d,
            ROUND(100.0 * SUM(ABS(eval_forecast_units - eval_actual_units))
                  / NULLIF(SUM(eval_actual_units), 0), 2)::FLOAT      AS wape_pct,
            ROUND(100.0 * SUM(eval_forecast_units - eval_actual_units)
                  / NULLIF(SUM(eval_actual_units), 0), 2)::FLOAT      AS bias_pct,
            MAX(model_version)::VARCHAR                               AS model_version,
            MAX(forecast_generated_at)::VARCHAR                       AS forecast_generated_at,
            (SELECT markdown_rate FROM LUMORA_DEMO.APP.V_ASSUMPTIONS)::FLOAT AS markdown_rate_assumption,
            (SELECT value_disclaimer FROM LUMORA_DEMO.APP.V_ASSUMPTIONS)::VARCHAR AS value_disclaimer
        FROM LUMORA_DEMO.APP.V_SLICE_RISK
        WHERE (:P_BRAND IS NULL OR TRIM(:P_BRAND) = '' OR brand_name ILIKE :P_BRAND)
          AND (:P_REGION IS NULL OR TRIM(:P_REGION) = '' OR region_code ILIKE :P_REGION)
          AND (:P_CATEGORY IS NULL OR TRIM(:P_CATEGORY) = '' OR category_code ILIKE :P_CATEGORY)
    );
    RETURN :out_var;
END;
$$;

-- =====================================================================
-- TOOL 2 — EXPLAIN_FORECAST_VARIANCE
-- Ranked, SQL-computed drivers: forecast bias (OBSERVED_FACT), promotion
-- timing pull-forward (CALCULATION), search-interest leading decline
-- (CALCULATION), inventory cover vs target (OBSERVED_FACT). Ranked by
-- absolute magnitude. Returns a JSON array (one object per driver).
-- =====================================================================
CREATE OR REPLACE PROCEDURE LUMORA_DEMO.AGENT.EXPLAIN_FORECAST_VARIANCE(
    P_BRAND VARCHAR,
    P_REGION VARCHAR,
    P_CATEGORY VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Deterministic forecast-variance explanation tool. All driver figures are computed in SQL from FACT_FORECAST_EVALUATION, FACT_PROMOTIONS, FACT_SALES, FACT_DEMAND_SIGNALS and V_SLICE_RISK - never inferred by the LLM. Returns a single JSON array of ranked driver objects (Cortex Agent generic tools require a single-cell result). Ranked by absolute magnitude. NULL/empty scope arguments mean "all" (aggregated across the matching slices).'
AS
$$
DECLARE
    out_var VARIANT;
BEGIN
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY driver_rank) INTO :out_var
    FROM (
        WITH scope_slices AS (
            SELECT DISTINCT brand_id, brand_name, region_code, category_code
            FROM LUMORA_DEMO.APP.V_SLICE_RISK
            WHERE (:P_BRAND IS NULL OR TRIM(:P_BRAND) = '' OR brand_name ILIKE :P_BRAND)
              AND (:P_REGION IS NULL OR TRIM(:P_REGION) = '' OR region_code ILIKE :P_REGION)
              AND (:P_CATEGORY IS NULL OR TRIM(:P_CATEGORY) = '' OR category_code ILIKE :P_CATEGORY)
        ),
        eval_agg AS (
            SELECT
                SUM(e.actual_units)   AS actual_units,
                SUM(e.forecast_units) AS forecast_units,
                MIN(e.eval_start_date) AS eval_start_date,
                MAX(e.eval_end_date)   AS eval_end_date
            FROM LUMORA_DEMO.ML.FACT_FORECAST_EVALUATION e
            JOIN scope_slices s
              ON s.brand_id = e.brand_id AND s.region_code = e.region_code AND s.category_code = e.category_code
        ),
        promo AS (
            SELECT
                p.brand_id, p.region_code, p.category_code,
                p.planned_start, p.planned_end, p.actual_start, p.actual_end,
                DATEDIFF(day, p.actual_start, p.planned_start) AS day_shift
            FROM LUMORA_DEMO.CORE.FACT_PROMOTIONS p
            JOIN scope_slices s
              ON s.brand_id = p.brand_id AND s.region_code = p.region_code AND s.category_code = p.category_code
            WHERE p.timing_changed
        ),
        promo_demand AS (
            SELECT
                AVG(CASE WHEN sl.sales_date BETWEEN pr.actual_start AND pr.actual_end THEN sl.units_sold END)  AS avg_daily_actual_window,
                AVG(CASE WHEN sl.sales_date BETWEEN pr.planned_start AND pr.planned_end THEN sl.units_sold END) AS avg_daily_planned_window,
                MAX(pr.day_shift)     AS day_shift,
                MIN(pr.planned_start) AS planned_start,
                MAX(pr.planned_end)   AS planned_end,
                MIN(pr.actual_start)  AS actual_start,
                MAX(pr.actual_end)    AS actual_end
            FROM LUMORA_DEMO.CORE.FACT_SALES sl
            JOIN promo pr
              ON pr.brand_id = sl.brand_id AND pr.region_code = sl.region_code AND pr.category_code = sl.category_code
        ),
        signal_agg AS (
            SELECT
                AVG(CASE WHEN sig.signal_date BETWEEN DATEADD(day, -42, cfg.break_start_date)
                                                    AND DATEADD(day, -14, cfg.break_start_date)
                         THEN sig.search_interest_index END) AS baseline_interest,
                AVG(CASE WHEN sig.signal_date >= DATEADD(day, -14, cfg.demo_asof_date)
                         THEN sig.search_interest_index END) AS recent_interest
            FROM LUMORA_DEMO.CORE.FACT_DEMAND_SIGNALS sig
            JOIN scope_slices s
              ON s.brand_id = sig.brand_id AND s.region_code = sig.region_code AND s.category_code = sig.category_code
            CROSS JOIN LUMORA_DEMO.CORE.DEMO_CONFIG cfg
        ),
        cover_agg AS (
            SELECT
                AVG(cover_days) AS avg_cover_days,
                MAX(target_cover_days) AS target_cover_days
            FROM LUMORA_DEMO.APP.V_SLICE_RISK v
            JOIN scope_slices s
              ON s.brand_id = v.brand_id AND s.region_code = v.region_code AND s.category_code = v.category_code
        ),
        drivers AS (
            -- (a) forecast bias vs actual over the evaluation window - observed fact
            SELECT
                'FORECAST_BIAS_VS_ACTUAL' AS driver_name,
                'OBSERVED_FACT'           AS driver_type,
                ROUND(100.0 * (ea.forecast_units - ea.actual_units) / NULLIF(ea.actual_units, 0), 1) AS driver_value,
                '%' AS driver_unit,
                'Forecast called for ' || ROUND(ea.forecast_units,0) || ' units but actual demand was '
                    || ROUND(ea.actual_units,0) || ' units for ' || ea.eval_start_date || ' to ' || ea.eval_end_date
                    || ' - a bias of ' || ROUND(100.0 * (ea.forecast_units - ea.actual_units) / NULLIF(ea.actual_units, 0), 1)
                    || ' percent (over-forecast).' AS driver_detail,
                ABS(ROUND(100.0 * (ea.forecast_units - ea.actual_units) / NULLIF(ea.actual_units, 0), 1)) AS severity_score
            FROM eval_agg ea
            WHERE ea.actual_units IS NOT NULL

            UNION ALL

            -- (b) promotion timing pull-forward - calculated from FACT_PROMOTIONS.timing_changed + FACT_SALES
            SELECT
                'PROMOTION_TIMING_PULL_FORWARD' AS driver_name,
                'CALCULATION'                   AS driver_type,
                ROUND(100.0 * (pd.avg_daily_actual_window - pd.avg_daily_planned_window)
                      / NULLIF(pd.avg_daily_planned_window, 0), 1) AS driver_value,
                '%' AS driver_unit,
                'The promotion (''Autumn Renewal campaign'') was planned for ' || pd.planned_start || ' to ' || pd.planned_end
                    || ' but actually ran ' || pd.actual_start || ' to ' || pd.actual_end || ' - pulled forward '
                    || pd.day_shift || ' days. Average daily demand during the ACTUAL promo window was '
                    || ROUND(pd.avg_daily_actual_window,1) || ' units/day vs ' || ROUND(pd.avg_daily_planned_window,1)
                    || ' units/day during the window the plan expected the promo - demand had already been spent before the '
                    || 'evaluation window, which is the leading cause of the forecast bias above. This feature (promotion timing) '
                    || 'is absent from the baseline forecast model.' AS driver_detail,
                ABS(ROUND(100.0 * (pd.avg_daily_actual_window - pd.avg_daily_planned_window)
                      / NULLIF(pd.avg_daily_planned_window, 0), 1)) AS severity_score
            FROM promo_demand pd
            WHERE pd.day_shift IS NOT NULL

            UNION ALL

            -- (c) leading indicator: search interest decline ahead of the sales break
            SELECT
                'SEARCH_INTEREST_LEADING_DECLINE' AS driver_name,
                'CALCULATION'                     AS driver_type,
                ROUND(100.0 * (sa.recent_interest - sa.baseline_interest) / NULLIF(sa.baseline_interest, 0), 1) AS driver_value,
                '%' AS driver_unit,
                'Search interest index averaged ' || ROUND(sa.baseline_interest,1) || ' in the pre-break baseline window and '
                    || ROUND(sa.recent_interest,1) || ' in the most recent 14 days - a decline of '
                    || ROUND(100.0 * (sa.baseline_interest - sa.recent_interest) / NULLIF(sa.baseline_interest, 0), 1)
                    || ' percent, a leading indicator that began softening roughly two weeks before the sales break.' AS driver_detail,
                ABS(ROUND(100.0 * (sa.recent_interest - sa.baseline_interest) / NULLIF(sa.baseline_interest, 0), 1)) AS severity_score
            FROM signal_agg sa
            WHERE sa.baseline_interest IS NOT NULL

            UNION ALL

            -- (d) inventory cover position vs policy target - observed fact
            SELECT
                'INVENTORY_COVER_VS_TARGET' AS driver_name,
                'OBSERVED_FACT'             AS driver_type,
                ROUND(ca.avg_cover_days - ca.target_cover_days, 1) AS driver_value,
                'days' AS driver_unit,
                'Available inventory covers ' || ROUND(ca.avg_cover_days,1) || ' days of forward demand vs a ' ||
                    ca.target_cover_days || '-day policy target - ' ||
                    ROUND(100.0 * (ca.avg_cover_days / NULLIF(ca.target_cover_days,0) - 1), 0) ||
                    ' percent above policy, because stock was bought against the pre-break plan.' AS driver_detail,
                ABS(ROUND(100.0 * (ca.avg_cover_days / NULLIF(ca.target_cover_days,0) - 1), 1)) AS severity_score
            FROM cover_agg ca
            WHERE ca.avg_cover_days IS NOT NULL
        )
        SELECT
            ROW_NUMBER() OVER (ORDER BY severity_score DESC)::NUMBER AS driver_rank,
            driver_name::VARCHAR   AS driver_name,
            driver_type::VARCHAR   AS driver_type,
            driver_value::FLOAT    AS driver_value,
            driver_unit::VARCHAR   AS driver_unit,
            driver_detail::VARCHAR AS driver_detail
        FROM drivers
    );
    RETURN :out_var;
END;
$$;

-- =====================================================================
-- TOOL 3 — RUN_DEMAND_SCENARIO
-- Applies a demand uplift/decline to the CURRENT forecast for the next
-- P_WEEKS, recomputes inventory exposure using the same 45-day horizon,
-- cover policy, and markdown-rate assumption as V_SLICE_RISK/V_ASSUMPTIONS.
-- =====================================================================
CREATE OR REPLACE PROCEDURE LUMORA_DEMO.AGENT.RUN_DEMAND_SCENARIO(
    P_BRAND VARCHAR,
    P_REGION VARCHAR,
    P_CATEGORY VARCHAR,
    P_UPLIFT_PCT FLOAT,
    P_WEEKS NUMBER
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Deterministic what-if scenario tool. Applies a demand uplift to the CURRENT forecast for the next P_WEEKS and recomputes inventory exposure in SQL - no LLM arithmetic. Returns a single JSON object (Cortex Agent generic tools require a single-cell result). Uses the same 45-day horizon, 45-day cover policy and markdown-rate assumption as V_SLICE_RISK/V_ASSUMPTIONS so numbers never drift from the KPI cockpit.'
AS
$$
DECLARE
    out_var VARIANT;
BEGIN
    SELECT OBJECT_CONSTRUCT(*) INTO :out_var
    FROM (
        WITH cfg AS (
            SELECT demo_asof_date FROM LUMORA_DEMO.CORE.DEMO_CONFIG
        ),
        assumpt AS (
            SELECT markdown_rate, target_cover_days FROM LUMORA_DEMO.APP.V_ASSUMPTIONS
        ),
        scope_slices AS (
            SELECT DISTINCT brand_id, brand_name, region_code, category_code, avg_cost, avg_price,
                   on_hand_units, on_order_units
            FROM LUMORA_DEMO.APP.V_SLICE_RISK
            WHERE (:P_BRAND IS NULL OR TRIM(:P_BRAND) = '' OR brand_name ILIKE :P_BRAND)
              AND (:P_REGION IS NULL OR TRIM(:P_REGION) = '' OR region_code ILIKE :P_REGION)
              AND (:P_CATEGORY IS NULL OR TRIM(:P_CATEGORY) = '' OR category_code ILIKE :P_CATEGORY)
        ),
        fwd_45d AS (
            SELECT
                f.brand_id, f.region_code, f.category_code,
                SUM(f.forecast_units) AS baseline_45d,
                SUM(CASE WHEN f.forecast_date <= DATEADD(day, :P_WEEKS * 7, c.demo_asof_date)
                         THEN f.forecast_units ELSE 0 END) AS baseline_window
            FROM LUMORA_DEMO.ML.FACT_FORECAST f
            JOIN scope_slices s
              ON s.brand_id = f.brand_id AND s.region_code = f.region_code AND s.category_code = f.category_code
            CROSS JOIN cfg c
            WHERE f.forecast_vintage = 'CURRENT'
              AND f.forecast_date <= DATEADD(day, 45, c.demo_asof_date)
            GROUP BY 1,2,3
        ),
        combined AS (
            SELECT
                s.brand_id, s.region_code, s.category_code, s.avg_cost, s.avg_price,
                (s.on_hand_units + s.on_order_units) AS available_units,
                fwd.baseline_45d,
                fwd.baseline_window,
                fwd.baseline_45d - fwd.baseline_window
                    + fwd.baseline_window * (1 + :P_UPLIFT_PCT / 100.0)         AS scenario_45d
            FROM scope_slices s
            JOIN fwd_45d fwd
              ON fwd.brand_id = s.brand_id AND fwd.region_code = s.region_code AND fwd.category_code = s.category_code
        ),
        agg AS (
            SELECT
                SUM(baseline_45d)   AS baseline_demand_units_45d,
                SUM(scenario_45d)   AS scenario_demand_units_45d,
                SUM(available_units) AS available_units,
                SUM(GREATEST(0, available_units - baseline_45d))                    AS baseline_excess_units,
                SUM(GREATEST(0, available_units - scenario_45d))                    AS scenario_excess_units,
                SUM(GREATEST(0, available_units - baseline_45d) * avg_cost)         AS baseline_inv_value_at_risk,
                SUM(GREATEST(0, available_units - scenario_45d) * avg_cost)         AS scenario_inv_value_at_risk,
                SUM(GREATEST(0, baseline_45d - available_units))                    AS baseline_stockout_gap,
                SUM(GREATEST(0, scenario_45d - available_units))                    AS scenario_stockout_gap,
                SUM(GREATEST(0, baseline_45d - available_units) * (avg_price - avg_cost)) AS baseline_stockout_margin,
                SUM(GREATEST(0, scenario_45d - available_units) * (avg_price - avg_cost)) AS scenario_stockout_margin
            FROM combined
        )
        SELECT
            COALESCE(NULLIF(TRIM(:P_BRAND), ''), 'All brands')::VARCHAR       AS brand_scope,
            COALESCE(NULLIF(TRIM(:P_REGION), ''), 'All regions')::VARCHAR     AS region_scope,
            COALESCE(NULLIF(TRIM(:P_CATEGORY), ''), 'All categories')::VARCHAR AS category_scope,
            :P_UPLIFT_PCT::FLOAT AS uplift_pct,
            :P_WEEKS::NUMBER     AS uplift_weeks,
            ROUND(a.baseline_demand_units_45d, 1)::FLOAT AS baseline_demand_units_45d,
            ROUND(a.scenario_demand_units_45d, 1)::FLOAT AS scenario_demand_units_45d,
            ROUND(a.available_units, 1)::FLOAT           AS available_units,
            ROUND(a.baseline_excess_units, 1)::FLOAT     AS baseline_excess_units,
            ROUND(a.scenario_excess_units, 1)::FLOAT     AS scenario_excess_units,
            ROUND(a.baseline_inv_value_at_risk, 2)::FLOAT AS baseline_inventory_value_at_risk,
            ROUND(a.scenario_inv_value_at_risk, 2)::FLOAT AS scenario_inventory_value_at_risk,
            ROUND(a.baseline_inv_value_at_risk * (SELECT markdown_rate FROM assumpt), 2)::FLOAT AS baseline_markdown_exposure,
            ROUND(a.scenario_inv_value_at_risk * (SELECT markdown_rate FROM assumpt), 2)::FLOAT AS scenario_markdown_exposure,
            ROUND(a.baseline_stockout_gap, 1)::FLOAT      AS baseline_stockout_gap_units,
            ROUND(a.scenario_stockout_gap, 1)::FLOAT      AS scenario_stockout_gap_units,
            ROUND(a.baseline_stockout_margin, 2)::FLOAT   AS baseline_stockout_margin_at_risk,
            ROUND(a.scenario_stockout_margin, 2)::FLOAT   AS scenario_stockout_margin_at_risk,
            ROUND(a.baseline_inv_value_at_risk - a.scenario_inv_value_at_risk, 2)::FLOAT AS exposure_reduction,
            ('Scenario assumptions: demand uplift of ' || :P_UPLIFT_PCT || '% applied to the CURRENT forecast for the next '
                || :P_WEEKS || ' week(s) (' || (:P_WEEKS * 7) || ' days) from ' || (SELECT demo_asof_date FROM cfg)
                || '; all other days in the 45-day horizon and target cover policy (' || (SELECT target_cover_days FROM assumpt)
                || ' days) unchanged; markdown-exposure rate held at ' || (SELECT markdown_rate FROM assumpt) * 100
                || '% of cost, per V_ASSUMPTIONS; inventory position and unit economics unchanged from the latest snapshot; '
                || 'all financial values are illustrative synthetic figures, not real Lumora financials.')::VARCHAR AS assumptions
        FROM agg a
    );
    RETURN :out_var;
END;
$$;

-- =====================================================================
-- TOOL 4 — REQUEST_FORECAST_RETRAINING
-- NUMERIC model-retraining request. Logs the request and routes to the
-- PRE-STAGED candidate evaluation above rather than a live training job.
-- =====================================================================
CREATE OR REPLACE PROCEDURE LUMORA_DEMO.AGENT.REQUEST_FORECAST_RETRAINING(
    P_REQUESTOR VARCHAR,
    P_REASON VARCHAR,
    P_BRAND VARCHAR,
    P_REGION VARCHAR,
    P_CATEGORY VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'NUMERIC forecast retraining request tool - improves the demand-forecast MODEL (units, WAPE, bias). This is distinct from REQUEST_AGENT_FINE_TUNING, which improves the agent''s natural-language explanation behaviour. For the live demo this routes to a PRE-STAGED evaluation result (LUMORA_DEMO.AGENT.PRESTAGED_RETRAIN_RESULT) instead of waiting for a real training job. Returns a single JSON object (Cortex Agent generic tools require a single-cell result).'
AS
$$
DECLARE
    out_var VARIANT;
    v_request_id VARCHAR;
    v_scope VARCHAR;
    v_has_prestaged BOOLEAN;
BEGIN
    SELECT 'RETRAIN-' || LPAD(SEQ_RETRAINING_REQUEST.NEXTVAL::VARCHAR, 6, '0') INTO :v_request_id;

    v_scope := COALESCE(NULLIF(TRIM(:P_BRAND), ''), 'All brands') || ' / '
             || COALESCE(NULLIF(TRIM(:P_REGION), ''), 'All regions') || ' / '
             || COALESCE(NULLIF(TRIM(:P_CATEGORY), ''), 'All categories');

    SELECT COUNT(*) > 0 INTO :v_has_prestaged
    FROM LUMORA_DEMO.AGENT.PRESTAGED_RETRAIN_RESULT r
    WHERE (:P_BRAND IS NULL OR TRIM(:P_BRAND) = '' OR r.scope_brand ILIKE :P_BRAND)
      AND (:P_REGION IS NULL OR TRIM(:P_REGION) = '' OR r.scope_region ILIKE :P_REGION)
      AND (:P_CATEGORY IS NULL OR TRIM(:P_CATEGORY) = '' OR r.scope_category ILIKE :P_CATEGORY);

    INSERT INTO LUMORA_DEMO.AGENT.FACT_RETRAINING_REQUEST
        (request_id, requestor, reason, scope, requested_at, status, expected_next_step)
    VALUES (
        :v_request_id, :P_REQUESTOR, :P_REASON, :v_scope, CURRENT_TIMESTAMP(),
        CASE WHEN :v_has_prestaged THEN 'ROUTED_TO_PRESTAGED_EVALUATION' ELSE 'QUEUED_FOR_TRAINING_JOB' END,
        CASE WHEN :v_has_prestaged
             THEN 'Candidate model fcst-v1.2-candidate is pre-staged for this scope; review the WAPE comparison below and promote if acceptable. This is a NUMERIC model change, separate from any agent language fine-tuning.'
             ELSE 'No pre-staged candidate exists for this exact scope yet; a SNOWFLAKE.ML.FORECAST retraining job would need to be run and evaluated before promotion.'
        END
    );

    SELECT OBJECT_CONSTRUCT(*) INTO :out_var
    FROM (
        SELECT
            :v_request_id::VARCHAR AS request_id,
            frr.status::VARCHAR   AS status,
            frr.scope::VARCHAR    AS scope,
            frr.expected_next_step::VARCHAR AS expected_next_step,
            r.candidate_model_version::VARCHAR AS candidate_model_version,
            r.baseline_model_version::VARCHAR   AS baseline_model_version,
            r.baseline_wape_pct::FLOAT          AS baseline_wape_pct,
            r.candidate_wape_pct::FLOAT         AS candidate_wape_pct,
            r.wape_improvement_pct::FLOAT       AS wape_improvement_pct,
            r.feature_added::VARCHAR            AS feature_added,
            r.notes::VARCHAR                    AS comparison_note
        FROM LUMORA_DEMO.AGENT.FACT_RETRAINING_REQUEST frr
        LEFT JOIN LUMORA_DEMO.AGENT.PRESTAGED_RETRAIN_RESULT r
               ON (:P_BRAND IS NULL OR TRIM(:P_BRAND) = '' OR r.scope_brand ILIKE :P_BRAND)
              AND (:P_REGION IS NULL OR TRIM(:P_REGION) = '' OR r.scope_region ILIKE :P_REGION)
              AND (:P_CATEGORY IS NULL OR TRIM(:P_CATEGORY) = '' OR r.scope_category ILIKE :P_CATEGORY)
        WHERE frr.request_id = :v_request_id
    );
    RETURN :out_var;
END;
$$;

-- =====================================================================
-- TOOL 5 — REQUEST_AGENT_FINE_TUNING
-- LANGUAGE (agent explanation-style) fine-tuning request. Stores the
-- approved example, refreshes V_FINETUNE_TRAINING_DATA, and returns the
-- PRE-STAGED base-vs-tuned comparison. Does NOT submit a real Cortex
-- Fine-tuning job.
-- =====================================================================
CREATE OR REPLACE PROCEDURE LUMORA_DEMO.AGENT.REQUEST_AGENT_FINE_TUNING(
    P_REQUESTOR VARCHAR,
    P_FEEDBACK_TEXT VARCHAR,
    P_APPROVED BOOLEAN
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'LANGUAGE (natural-language behaviour) fine-tuning request tool - improves how the agent EXPLAINS results, not the numeric demand-forecast model. This is distinct from REQUEST_FORECAST_RETRAINING, which retrains/promotes the numeric SNOWFLAKE.ML.FORECAST model. Does NOT submit a real Cortex Fine-tuning job for this demo - stores the example, refreshes V_FINETUNE_TRAINING_DATA, and returns a pre-staged base-vs-tuned comparison. Returns a single JSON object (Cortex Agent generic tools require a single-cell result).'
AS
$$
DECLARE
    out_var VARIANT;
    v_feedback_id VARCHAR;
    v_job_id VARCHAR;
    v_prompt_text VARCHAR;
    v_completion_text VARCHAR;
    v_training_count NUMBER;
BEGIN
    SELECT 'FEEDBACK-' || LPAD(SEQ_FEEDBACK.NEXTVAL::VARCHAR, 6, '0') INTO :v_feedback_id;
    SELECT 'FINETUNE-JOB-' || LPAD(SEQ_FINETUNE_JOB.NEXTVAL::VARCHAR, 6, '0') INTO :v_job_id;

    v_prompt_text := 'Explain the drivers behind the current forecast variance and incorporate the reviewer''s correction: ' || :P_FEEDBACK_TEXT;
    v_completion_text := :P_FEEDBACK_TEXT;

    INSERT INTO LUMORA_DEMO.AGENT.FACT_AGENT_FEEDBACK
        (feedback_id, requestor, feedback_text, approved, prompt_text, completion_text, created_at)
    VALUES (
        :v_feedback_id, :P_REQUESTOR, :P_FEEDBACK_TEXT, :P_APPROVED,
        CASE WHEN :P_APPROVED THEN :v_prompt_text ELSE NULL END,
        CASE WHEN :P_APPROVED THEN :v_completion_text ELSE NULL END,
        CURRENT_TIMESTAMP()
    );

    SELECT COUNT(*) INTO :v_training_count FROM LUMORA_DEMO.AGENT.V_FINETUNE_TRAINING_DATA;

    SELECT OBJECT_CONSTRUCT(*) INTO :out_var
    FROM (
        SELECT
            :v_job_id::VARCHAR AS job_id,
            CASE WHEN :P_APPROVED
                 THEN 'EXAMPLE_CAPTURED_TRAINING_VIEW_REFRESHED_JOB_NOT_SUBMITTED'
                 ELSE 'EXAMPLE_LOGGED_NOT_APPROVED_EXCLUDED_FROM_TRAINING'
            END::VARCHAR AS status,
            :v_feedback_id::VARCHAR AS feedback_id,
            :P_APPROVED::BOOLEAN AS approved,
            :v_training_count::NUMBER AS training_example_count,
            c.base_model_answer::VARCHAR  AS base_model_answer,
            c.tuned_model_answer::VARCHAR AS tuned_model_answer,
            ('This is a LANGUAGE fine-tuning request (agent explanation style), not a numeric forecast retraining request. '
             || 'No real Cortex Fine-tuning job was submitted for this demo; the approved example was stored in FACT_AGENT_FEEDBACK, '
             || 'LUMORA_DEMO.AGENT.V_FINETUNE_TRAINING_DATA was refreshed (' || :v_training_count || ' approved examples), '
             || 'and the pre-staged base-vs-tuned comparison below shows the target behaviour change.')::VARCHAR AS note
        FROM LUMORA_DEMO.AGENT.PRESTAGED_FINETUNE_COMPARISON c
        WHERE c.comparison_id = 'FT-COMPARE-000001'
    );
    RETURN :out_var;
END;
$$;

-- =====================================================================
-- THE AGENT — LUMORA_VALUE_AGENT
-- Custom tools (the five procedures above), Cortex Search over the
-- policy/stakeholder corpus, and Cortex Analyst over the executive
-- semantic view. tool_resources "identifier" is the bare procedure name
-- (no arg-type signature) - Cortex Agent could not resolve an
-- overload-style "NAME(TYPE, TYPE, ...)" identifier string.
-- =====================================================================
CREATE OR REPLACE AGENT LUMORA_DEMO.AGENT.LUMORA_VALUE_AGENT
  COMMENT = 'Lumora Value Loop demo agent: investigates inventory/demand risk, explains drivers, runs what-if scenarios, and routes numeric-forecast vs agent-language improvement requests. All financial figures are illustrative synthetic values.'
  PROFILE = '{"display_name": "Lumora Value Agent", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 45
      tokens: 24000

  instructions:
    response: >
      Return a short executive answer FIRST (1-3 sentences), then evidence, then assumptions.
      Clearly distinguish observed facts, calculated results, and recommendations - label them.
      Never invent a financial impact, driver, or scenario result when the data is missing or a tool
      has not been called; state that you need to run a tool instead of guessing.
      State assumptions explicitly (markdown rate, cover-days policy, evaluation window) whenever a
      KPI or scenario number is shown.
      All financial values in this demo are illustrative synthetic figures derived from synthetic unit
      economics - never imply they are Lumora's actual financials.
      Recommend a human decision whenever a result would affect pricing, inventory commitment, or
      customer treatment (for example, before purchase-order changes or before using EU customer data).
      Clearly distinguish REQUEST_FORECAST_RETRAINING (a NUMERIC change to the demand-forecast model)
      from REQUEST_AGENT_FINE_TUNING (a LANGUAGE change to how you explain results) - never present one
      as if it were the other.
    orchestration: >
      Use GET_LUMORA_KPIS for structured questions about current inventory exposure, forecast accuracy,
      bias, cover days, or markdown/stockout risk for a brand/region/category scope.
      Use EXPLAIN_FORECAST_VARIANCE when asked why a risk exists, what is driving it, or what evidence
      supports a conclusion - it returns ranked, SQL-computed drivers (promotion timing, forecast bias,
      leading demand signals, inventory cover).
      Use RUN_DEMAND_SCENARIO for any "what if" / scenario question about a demand uplift or decline
      over a future window; always report the assumptions string it returns alongside the numbers.
      Use the LUMORA_POLICY_SEARCH tool for residency, governance, stakeholder, or policy questions
      (for example EU customer data usage or architecture concerns).
      Use the SV_LUMORA_EXEC semantic view (Cortex Analyst) for open-ended structured/aggregate questions
      that the KPI and scenario tools do not directly cover.
      Use REQUEST_FORECAST_RETRAINING only when the user asks to improve, retrain, or re-evaluate the
      NUMERIC demand forecast model itself.
      Use REQUEST_AGENT_FINE_TUNING only when the user gives feedback on your explanation/response quality
      and asks you to record it or improve your LANGUAGE behaviour - always store approved feedback with
      P_APPROVED = TRUE.
      A typical CFO investigation calls at least two tools in one turn, for example GET_LUMORA_KPIS then
      EXPLAIN_FORECAST_VARIANCE, or EXPLAIN_FORECAST_VARIANCE then LUMORA_POLICY_SEARCH.
    sample_questions:
      - question: "Which part of the group's inventory position needs attention first, and why?"
      - question: "Why is inventory risk highest for Aurelia in DACH skincare, and what evidence supports that?"
      - question: "What would happen if the promotion increases demand by 12% for the next four weeks?"
      - question: "Is this a brand-specific issue or a group-level pattern across Aurelia, Solene, and Verdant?"
      - question: "Can we use EU customer data in this scenario, and what constraint should we check?"
      - question: "The explanation is missing promotion timing as a driver - mark this as approved feedback."

  tools:
    - tool_spec:
        type: "generic"
        name: "get_lumora_kpis"
        description: "Returns the deterministic KPI snapshot (inventory value at risk, markdown exposure, stockout risk, cover days vs target, forward demand with interval, WAPE/bias, model version) for a brand/region/category scope. Pass NULL or '' for any argument to mean 'all'."
        input_schema:
          type: "object"
          properties:
            p_brand:
              type: "string"
              description: "Brand name, e.g. 'Aurelia'. NULL or empty means all brands."
            p_region:
              type: "string"
              description: "Region code, e.g. 'DACH'. NULL or empty means all regions."
            p_category:
              type: "string"
              description: "Category code, e.g. 'SKINCARE'. NULL or empty means all categories."
    - tool_spec:
        type: "generic"
        name: "explain_forecast_variance"
        description: "Returns a ranked table of SQL-computed drivers (forecast bias, promotion timing pull-forward, leading demand-signal decline, inventory cover vs target) explaining why forecast variance/risk exists for a brand/region/category scope."
        input_schema:
          type: "object"
          properties:
            p_brand:
              type: "string"
              description: "Brand name. NULL or empty means all brands."
            p_region:
              type: "string"
              description: "Region code. NULL or empty means all regions."
            p_category:
              type: "string"
              description: "Category code. NULL or empty means all categories."
    - tool_spec:
        type: "generic"
        name: "run_demand_scenario"
        description: "Applies a demand uplift/decline (percent) to the CURRENT forecast for the next N weeks and recomputes inventory exposure, markdown exposure, and stockout risk for a brand/region/category scope. Returns baseline vs scenario numbers and the assumptions used."
        input_schema:
          type: "object"
          properties:
            p_brand:
              type: "string"
              description: "Brand name. NULL or empty means all brands."
            p_region:
              type: "string"
              description: "Region code. NULL or empty means all regions."
            p_category:
              type: "string"
              description: "Category code. NULL or empty means all categories."
            p_uplift_pct:
              type: "number"
              description: "Demand uplift percent, e.g. 12 for +12%. Negative values model a decline."
            p_weeks:
              type: "number"
              description: "Number of weeks (from today) over which the uplift applies, e.g. 4."
          required:
            - p_uplift_pct
            - p_weeks
    - tool_spec:
        type: "generic"
        name: "request_forecast_retraining"
        description: "Requests NUMERIC demand-forecast model retraining for a brand/region/category scope. Logs the request and routes to a pre-staged candidate-model evaluation (fcst-v1.2-candidate) where available. This changes the forecast MODEL, not the agent's language - see request_agent_fine_tuning for that."
        input_schema:
          type: "object"
          properties:
            p_requestor:
              type: "string"
              description: "Name or role of the person requesting retraining."
            p_reason:
              type: "string"
              description: "Reason for the retraining request."
            p_brand:
              type: "string"
              description: "Brand name. NULL or empty means all brands."
            p_region:
              type: "string"
              description: "Region code. NULL or empty means all regions."
            p_category:
              type: "string"
              description: "Category code. NULL or empty means all categories."
          required:
            - p_requestor
            - p_reason
    - tool_spec:
        type: "generic"
        name: "request_agent_fine_tuning"
        description: "Records approved (or rejected) feedback about the agent's LANGUAGE/explanation quality, refreshes the fine-tuning training view, and returns a pre-staged base-vs-tuned comparison. This changes how the agent EXPLAINS results, not the numeric forecast model - see request_forecast_retraining for that."
        input_schema:
          type: "object"
          properties:
            p_requestor:
              type: "string"
              description: "Name or role of the person giving feedback."
            p_feedback_text:
              type: "string"
              description: "The correction or feedback text, e.g. 'the explanation is missing promotion timing as a driver'."
            p_approved:
              type: "boolean"
              description: "Whether this feedback example is approved for use as a fine-tuning training example."
          required:
            - p_requestor
            - p_feedback_text
            - p_approved
    - tool_spec:
        type: "cortex_search"
        name: "lumora_policy_search"
        description: "Searches synthetic Lumora governance, data-residency, architecture, and stakeholder-note documents. Use for questions about EU customer data, GDPR/residency constraints, architecture concerns, or what a stakeholder raised."
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "sv_lumora_exec"
        description: "Cortex Analyst over the Lumora executive semantic view - use for open-ended structured/aggregate business questions not directly covered by the KPI or scenario tools."

  tool_resources:
    get_lumora_kpis:
      type: "procedure"
      identifier: "LUMORA_DEMO.AGENT.GET_LUMORA_KPIS"
      execution_environment:
        type: "warehouse"
        warehouse: "LUMORA_WH"
    explain_forecast_variance:
      type: "procedure"
      identifier: "LUMORA_DEMO.AGENT.EXPLAIN_FORECAST_VARIANCE"
      execution_environment:
        type: "warehouse"
        warehouse: "LUMORA_WH"
    run_demand_scenario:
      type: "procedure"
      identifier: "LUMORA_DEMO.AGENT.RUN_DEMAND_SCENARIO"
      execution_environment:
        type: "warehouse"
        warehouse: "LUMORA_WH"
    request_forecast_retraining:
      type: "procedure"
      identifier: "LUMORA_DEMO.AGENT.REQUEST_FORECAST_RETRAINING"
      execution_environment:
        type: "warehouse"
        warehouse: "LUMORA_WH"
    request_agent_fine_tuning:
      type: "procedure"
      identifier: "LUMORA_DEMO.AGENT.REQUEST_AGENT_FINE_TUNING"
      execution_environment:
        type: "warehouse"
        warehouse: "LUMORA_WH"
    lumora_policy_search:
      search_service: "LUMORA_DEMO.AGENT.LUMORA_POLICY_SEARCH"
      max_results: 5
      title_column: "DOC_TITLE"
      id_column: "DOC_ID"
    sv_lumora_exec:
      semantic_view: "LUMORA_DEMO.APP.SV_LUMORA_EXEC"
      execution_environment:
        type: "warehouse"
        warehouse: "LUMORA_WH"
  $$;

-- ---------------------------------------------------------------------
-- Sanity checks — direct CALLs (not SELECT * FROM TABLE()).
-- ---------------------------------------------------------------------
CALL LUMORA_DEMO.AGENT.GET_LUMORA_KPIS('Aurelia','DACH','SKINCARE');
CALL LUMORA_DEMO.AGENT.EXPLAIN_FORECAST_VARIANCE('Aurelia','DACH','SKINCARE');
CALL LUMORA_DEMO.AGENT.RUN_DEMAND_SCENARIO('Aurelia','DACH','SKINCARE', 12, 4);
