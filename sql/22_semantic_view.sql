-- =====================================================================
-- Lumora Value Loop demo — 22_semantic_view.sql
--
-- Governed KPI definitions for Cortex Analyst / the agent. Built on
-- V_SLICE_RISK so the semantic layer, the KPI cards and the agent tools
-- cannot disagree about what a metric means.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.APP;

CREATE OR REPLACE SEMANTIC VIEW LUMORA_DEMO.APP.SV_LUMORA_EXEC
  TABLES (
    slice AS LUMORA_DEMO.APP.V_SLICE_RISK
      PRIMARY KEY (brand_id, region_code, category_code)
      COMMENT = 'One row per brand x region x category: inventory position, live forecast demand, and forecast accuracy. All financial values are illustrative synthetic figures.'
  )
  DIMENSIONS (
    slice.brand_name          AS brand_name          COMMENT = 'Lumora group brand',
    slice.source_system       AS source_system       COMMENT = 'Originating source system for this brand — retained so data fragmentation stays visible',
    slice.region_code         AS region_code         COMMENT = 'Sales region: DACH, NORDICS, UK_IE, NORTH_AMERICA',
    slice.data_residency_zone AS data_residency_zone COMMENT = 'Data residency zone: EU_WEST, EU_NORTH, UK, US',
    slice.is_eu               AS is_eu               COMMENT = 'TRUE where the region is in the EU and EU data protection rules apply',
    slice.category_code       AS category_code       COMMENT = 'Product category',
    slice.model_version       AS model_version       COMMENT = 'Version of the demand forecast model behind the forward demand figures',
    slice.snapshot_date       AS snapshot_date       COMMENT = 'Date of the inventory snapshot'
  )
  METRICS (
    slice.inventory_value_at_risk AS SUM(slice.inventory_value_at_risk)
      COMMENT = 'Illustrative value of inventory (on hand plus on order) beyond what the current forecast is expected to consume over the next 45 days, valued at unit cost',
    slice.markdown_exposure AS SUM(slice.markdown_exposure)
      COMMENT = 'Illustrative markdown or write-off exposure: excess inventory at cost multiplied by an ASSUMED 40 percent markdown rate. The rate is an assumption, not an observed figure',
    slice.stockout_margin_at_risk AS SUM(slice.stockout_margin_at_risk)
      COMMENT = 'Illustrative gross margin at risk where forecast demand over the next 45 days exceeds available stock',
    slice.excess_units AS SUM(slice.excess_units)
      COMMENT = 'Units of stock beyond forecast 45-day demand',
    slice.stockout_gap_units AS SUM(slice.stockout_gap_units)
      COMMENT = 'Units of forecast 45-day demand not covered by available stock',
    slice.on_hand_value AS SUM(slice.on_hand_value)
      COMMENT = 'Illustrative value of inventory on hand at unit cost',
    slice.forward_demand_units AS SUM(slice.fwd_demand_units_45d)
      COMMENT = 'Forecast demand in units for the next 45 days, from the current model version',
    slice.avg_cover_days AS AVG(slice.cover_days)
      COMMENT = 'Average days of forward demand cover held. Group policy target is 45 days',
    slice.forecast_wape_pct AS SUM(ABS(slice.eval_forecast_units - slice.eval_actual_units)) * 100 / NULLIF(SUM(slice.eval_actual_units), 0)
      COMMENT = 'Weighted absolute percentage error of the prior forecast vintage against actuals for 2026-08-16 to 2026-09-15. Lower is better',
    slice.forecast_bias_pct AS SUM(slice.eval_forecast_units - slice.eval_actual_units) * 100 / NULLIF(SUM(slice.eval_actual_units), 0)
      COMMENT = 'Forecast bias of the prior forecast vintage. Positive means demand was over-forecast, so stock was bought against demand that did not arrive',
    slice.slice_count AS COUNT(slice.category_code)
      COMMENT = 'Number of brand-region-category slices in scope'
  )
  COMMENT = 'Lumora executive decision cockpit semantic model. SYNTHETIC, ILLUSTRATIVE DATA — not Lumora financials.';

-- Validate: this must return the same group totals as V_KPI_EXEC.
SELECT * FROM SEMANTIC_VIEW(
    LUMORA_DEMO.APP.SV_LUMORA_EXEC
    METRICS inventory_value_at_risk, markdown_exposure, forecast_bias_pct
);
