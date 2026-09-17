-- =====================================================================
-- Lumora Value Loop demo — 40_fallback.sql
--
-- DETERMINISTIC FALLBACK for all 7 acts.
--
-- If the agent or a model service stalls during the presentation, the app
-- renders these answers instead. The point is that they are GENERATED FROM
-- THE DATA at build time, not typed by hand — so the fallback cannot drift
-- away from the live numbers on the KPI cards.
--
-- The app must label a fallback answer as such. It is a safety net, not a
-- way to fake an agent.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.AGENT;

-- ---------------------------------------------------------------------
-- Every number the storyline depends on, computed once.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.AGENT.V_FALLBACK_FACTS AS
WITH totals AS (
    SELECT SUM(inventory_value_at_risk) AS group_exposure,
           SUM(markdown_exposure)       AS group_markdown,
           SUM(stockout_margin_at_risk) AS group_stockout
    FROM LUMORA_DEMO.APP.V_SLICE_RISK
),
top_slice AS (
    SELECT brand_name, region_code, category_code, data_residency_zone,
           inventory_value_at_risk, markdown_exposure, cover_days,
           target_cover_days, bias_pct, wape_pct, excess_units,
           on_hand_units, on_order_units, fwd_demand_units_45d, model_version
    FROM LUMORA_DEMO.APP.V_SLICE_RISK
    ORDER BY inventory_value_at_risk DESC
    LIMIT 1
),
-- the group-level pattern: same region + category, multiple brands
pattern AS (
    SELECT COUNT(*)                          AS slice_count,
           SUM(inventory_value_at_risk)      AS pattern_exposure,
           LISTAGG(brand_name, ', ') WITHIN GROUP (ORDER BY inventory_value_at_risk DESC) AS brands
    FROM LUMORA_DEMO.APP.V_SLICE_RISK
    WHERE region_code = 'DACH' AND category_code = 'SKINCARE'
),
promo AS (
    SELECT DATEDIFF(day, actual_start, planned_start) AS shift_days,
           promo_name, planned_start, planned_end, actual_start, actual_end
    FROM LUMORA_DEMO.CORE.FACT_PROMOTIONS
    WHERE timing_changed AND brand_id = 1 AND region_code = 'DACH' AND category_code = 'SKINCARE'
    LIMIT 1
),
-- leading indicator: search interest after the break vs the prior baseline
signal AS (
    SELECT
        ROUND(AVG(CASE WHEN signal_date >= DATE '2026-07-21' THEN search_interest_index END), 1) AS post_break_index,
        ROUND(AVG(CASE WHEN signal_date BETWEEN DATE '2026-05-01' AND DATE '2026-07-06'
                       THEN search_interest_index END), 1)                                       AS baseline_index
    FROM LUMORA_DEMO.CORE.FACT_DEMAND_SIGNALS
    WHERE brand_id = 1 AND region_code = 'DACH' AND category_code = 'SKINCARE'
),
-- Act 3 scenario: +12% demand for 4 weeks, applied to the live forecast
scenario AS (
    SELECT
        SUM(CASE WHEN forecast_date <= DATEADD(day, 28, DATE '2026-09-15')
                 THEN forecast_units END)                                    AS demand_4w,
        SUM(forecast_units)                                                  AS demand_45d
    FROM LUMORA_DEMO.ML.FACT_FORECAST
    WHERE forecast_vintage = 'CURRENT' AND brand_id = 1
      AND region_code = 'DACH' AND category_code = 'SKINCARE'
      AND forecast_date <= DATEADD(day, 45, DATE '2026-09-15')
),
cross_brand AS (
    SELECT cross_brand_coverage_pct, multi_brand_customers, total_customers
    FROM LUMORA_DEMO.APP.V_KPI_EXEC
)
SELECT
    t.group_exposure, t.group_markdown, t.group_stockout,
    ts.brand_name, ts.region_code, ts.category_code, ts.data_residency_zone,
    ts.inventory_value_at_risk, ts.markdown_exposure, ts.cover_days,
    ts.target_cover_days, ts.bias_pct, ts.wape_pct, ts.excess_units,
    ts.on_hand_units, ts.on_order_units, ts.fwd_demand_units_45d, ts.model_version,
    ROUND(100.0 * ts.inventory_value_at_risk / NULLIF(t.group_exposure,0), 1) AS top_slice_pct_of_group,
    p.slice_count AS pattern_slice_count, p.pattern_exposure, p.brands AS pattern_brands,
    ROUND(100.0 * p.pattern_exposure / NULLIF(t.group_exposure,0), 1)         AS pattern_pct_of_group,
    pr.shift_days, pr.promo_name, pr.planned_start, pr.actual_start,
    sg.post_break_index, sg.baseline_index,
    ROUND(100.0 * (sg.post_break_index - sg.baseline_index) / NULLIF(sg.baseline_index,0), 1) AS search_change_pct,
    sc.demand_4w, sc.demand_45d,
    ROUND(sc.demand_4w * 0.12, 0)                                            AS scenario_extra_units,
    GREATEST(0, ROUND(ts.on_hand_units + ts.on_order_units - sc.demand_45d))  AS baseline_excess_units,
    GREATEST(0, ROUND(ts.on_hand_units + ts.on_order_units - sc.demand_45d - sc.demand_4w * 0.12)) AS scenario_excess_units,
    -- how much of the exposure a 12% four-week uplift actually removes
    ROUND(100.0 * (sc.demand_4w * 0.12)
          / NULLIF(GREATEST(0, ts.on_hand_units + ts.on_order_units - sc.demand_45d), 0), 1) AS scenario_reduction_pct,
    -- the uplift that WOULD clear the excess over the same four weeks.
    -- For a slice holding this much cover the answer is implausibly large,
    -- which is the real finding: promotion cannot fix this position.
    ROUND(100.0 * GREATEST(0, ts.on_hand_units + ts.on_order_units - sc.demand_45d)
          / NULLIF(sc.demand_4w, 0), 0)                                       AS breakeven_uplift_pct,
    cb.cross_brand_coverage_pct, cb.multi_brand_customers, cb.total_customers
FROM totals t
CROSS JOIN top_slice t2
CROSS JOIN top_slice ts
CROSS JOIN pattern p
CROSS JOIN promo pr
CROSS JOIN signal sg
CROSS JOIN scenario sc
CROSS JOIN cross_brand cb;

-- ---------------------------------------------------------------------
-- DEMO_FALLBACK — one row per act, assembled from the facts above.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE LUMORA_DEMO.AGENT.DEMO_FALLBACK AS
WITH f AS (SELECT * FROM LUMORA_DEMO.AGENT.V_FALLBACK_FACTS)
SELECT 1 AS act_no,
    'The CFO question' AS act_title,
    'Which part of the group''s inventory position needs attention first, and why?' AS question,
    'Start with ' || f.brand_name || ' ' || f.category_code || ' in ' || f.region_code ||
    '. It carries EUR ' || TO_VARCHAR(ROUND(f.inventory_value_at_risk), '999,999,999') ||
    ' of illustrative inventory value at risk — ' || f.top_slice_pct_of_group ||
    '% of the group total of EUR ' || TO_VARCHAR(ROUND(f.group_exposure), '999,999,999') ||
    ' — from a single brand, region and category.' AS executive_answer,
    'Observed: ' || f.cover_days || ' days of forward cover against a ' || f.target_cover_days ||
    '-day policy target. On hand ' || TO_VARCHAR(f.on_hand_units) || ' units plus ' ||
    TO_VARCHAR(f.on_order_units) || ' on order, against forecast 45-day demand of ' ||
    TO_VARCHAR(ROUND(f.fwd_demand_units_45d)) || ' units. Calculated: ' ||
    TO_VARCHAR(f.excess_units) || ' excess units at cost.' AS evidence,
    'Markdown exposure assumes a 40% markdown rate on excess stock at cost. All values are illustrative and derived from synthetic data.' AS assumptions,
    'GET_LUMORA_KPIS' AS tools_used,
    'Review before the next replenishment commitment for this slice. A stock commitment decision requires a human owner.' AS recommendation
FROM f
UNION ALL
SELECT 2, 'The investigation',
    'Why is this risk concentrated here, and what evidence supports that conclusion?',
    'The plan over-forecast this slice by ' || f.bias_pct || '% over the last month, so stock was bought against demand that did not arrive. The largest identifiable driver is promotion timing: the ' ||
    f.promo_name || ' was planned to start ' || TO_VARCHAR(f.planned_start) || ' but actually ran from ' ||
    TO_VARCHAR(f.actual_start) || ' — ' || f.shift_days || ' days early — pulling demand forward out of the period the plan expected it in.',
    'Observed: promotion timing shift of ' || f.shift_days || ' days (source: promotion records, timing_changed flag). Observed: search interest ran ' ||
    f.search_change_pct || '% below its pre-break baseline (' || f.post_break_index || ' vs ' || f.baseline_index ||
    '), beginning about two weeks before the sales decline. Calculated: forecast bias ' || f.bias_pct ||
    '%, WAPE ' || f.wape_pct || '% for 2026-08-16 to 2026-09-15 against model ' || f.model_version || '.',
    'Uncertain: the promotion shift and the demand decline are correlated in this window; the data supports timing as a driver but does not isolate it from underlying category softness.',
    'GET_LUMORA_KPIS, EXPLAIN_FORECAST_VARIANCE, LUMORA_POLICY_SEARCH',
    'Re-baseline the demand plan for this slice. Group promotional calendar governance requires re-baselining when a promotion moves more than 14 days.'
FROM f
UNION ALL
SELECT 3, 'The scenario',
    'What happens if the promotion increases demand by 12% for the next four weeks?',
    'It helps, but it does not solve the problem. A 12% uplift over four weeks adds about ' ||
    TO_VARCHAR(f.scenario_extra_units) || ' units and removes only ' || f.scenario_reduction_pct ||
    '% of the excess on this slice, taking it from ' || TO_VARCHAR(f.baseline_excess_units) ||
    ' to ' || TO_VARCHAR(f.scenario_excess_units) || ' units. Clearing the position through demand alone would need an uplift of roughly ' ||
    TO_VARCHAR(f.breakeven_uplift_pct) || '% over the same four weeks, which is not a realistic promotional outcome. This is therefore a markdown or re-buy decision, not a promotional one.',
    'Calculated from the current forecast vintage: baseline four-week demand ' ||
    TO_VARCHAR(ROUND(f.demand_4w)) || ' units, 45-day demand ' || TO_VARCHAR(ROUND(f.demand_45d)) ||
    ' units, excess ' || TO_VARCHAR(f.baseline_excess_units) || ' units against available stock of ' ||
    TO_VARCHAR(f.on_hand_units + f.on_order_units) || ' units.',
    'Assumes the uplift applies evenly across the four weeks, no change to the 45-day cover policy, and no incremental buying. A promotion that shifts demand rather than creating it would not improve the position at all.',
    'RUN_DEMAND_SCENARIO',
    'Requires human decision: cancel or defer the outstanding on-order quantity, and decide markdown depth. Promotion alone will not clear this.'
FROM f
UNION ALL
SELECT 4, 'The cross-brand value',
    'Is this a brand-specific issue or a group-level pattern?',
    'It is a group-level pattern. The same region and category is exposed across ' ||
    f.pattern_slice_count || ' brands (' || f.pattern_brands || '), together holding EUR ' ||
    TO_VARCHAR(ROUND(f.pattern_exposure), '999,999,999') || ' — ' || f.pattern_pct_of_group ||
    '% of total group exposure. In isolated brand systems each one looks like a local merchandising miss.',
    'Observed: three brands, one region, one category, each running above the 45-day cover policy. Calculated: combined exposure ' ||
    f.pattern_pct_of_group || '% of the group total. Cross-brand customer view: ' ||
    f.cross_brand_coverage_pct || '% of customer groups (' || TO_VARCHAR(f.multi_brand_customers) ||
    ' of ' || TO_VARCHAR(f.total_customers) || ') are visible in more than one brand once identity is resolved.',
    'Cross-brand customer counts depend on the governed customer_group_id mapping; brand-local identifiers alone would not reveal the overlap.',
    'GET_LUMORA_KPIS, Cortex Analyst over SV_LUMORA_EXEC',
    'Treat the promotional calendar change as a group-level decision rather than a brand-level one.'
FROM f
UNION ALL
SELECT 5, 'The governed AI moment',
    'Can we use EU customer data in this scenario, and what constraint should we check?',
    'This region is in residency zone ' || f.data_residency_zone ||
    ', so EU data protection rules apply. Aggregated demand and inventory analysis of the kind used here is permitted. Extending the same workflow to identified individuals — for example targeting affected customers — is a different processing purpose and requires documented approval before it proceeds.',
    'Observed from the governed document corpus: the EU data processing policy distinguishes aggregate analytics from processing of identified individuals, and the control framework requires a documented human approval before EU personal data enters a new use case. Observed from the data: this slice is classified ' ||
    f.data_residency_zone || ' and EU customer records carry a RESTRICTED_PII sensitivity class.',
    'The answer covers the analysis shown. It is not a legal opinion, and it does not authorise a new processing purpose.',
    'LUMORA_POLICY_SEARCH',
    'Requires human confirmation: obtain documented approval before extending this to customer-level treatment.'
FROM f
UNION ALL
SELECT 6, 'The learning loop',
    'The explanation is missing promotion timing as a driver. Mark this as approved feedback and prepare the next model-improvement request.',
    'Feedback recorded. Two separate improvements follow, and they are not the same thing. First, numeric forecast retraining: add promotion timing as a feature and refit the demand model, which changes the forecast numbers. Second, language-model fine-tuning: teach the agent to cite promotion timing when it explains a variance, which changes how the answer is written, not what the numbers are.',
    'Recorded in the agent feedback log as an approved example and added to the fine-tuning training view. A candidate retrained model with promotion-timing features is pre-staged for comparison against the current version.',
    'The retraining result and the tuned-model response shown here are PRE-STAGED for the demo rather than trained live. The request and status flow is real; the completed artefacts were prepared in advance.',
    'REQUEST_FORECAST_RETRAINING, REQUEST_AGENT_FINE_TUNING',
    'Promote the retrained model only after its evaluation is reviewed. Model promotion is a human decision.'
FROM f
UNION ALL
SELECT 7, 'The CFO close',
    'What is the smallest funded first step?',
    'Unify ' || f.brand_name || ' and the two other affected brands for this one category and region, operationalise the demand forecast on that scope, and run the governed agent over the resulting decision workflow. Measure it on forecast quality, decision speed, and reduction in avoidable inventory exposure.',
    'The scope is already bounded by the data: ' || f.pattern_slice_count || ' brands, one region, one category, ' ||
    f.pattern_pct_of_group || '% of current group exposure.',
    'No return on investment is claimed. The exposure figures are illustrative and derived from synthetic data; the measurable commitment is to the three metrics named, not to a financial outcome.',
    'GET_LUMORA_KPIS',
    'Fund the bounded first step and review against the three named measures before extending scope.'
FROM f;

-- ---------------------------------------------------------------------
-- Sanity output
-- ---------------------------------------------------------------------
SELECT act_no, act_title, LEFT(executive_answer, 130) AS answer_preview
FROM LUMORA_DEMO.AGENT.DEMO_FALLBACK ORDER BY act_no;
