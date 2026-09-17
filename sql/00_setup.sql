-- =====================================================================
-- Lumora Value Loop demo — 00_setup.sql
-- Database, schemas, warehouse. Idempotent: safe to re-run.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS LUMORA_DEMO
  COMMENT = 'Lumora Value Loop demo. ALL DATA IS SYNTHETIC AND ILLUSTRATIVE.';

CREATE SCHEMA IF NOT EXISTS LUMORA_DEMO.CORE  COMMENT = 'Governed retail data foundation';
CREATE SCHEMA IF NOT EXISTS LUMORA_DEMO.ML    COMMENT = 'Forecast, evaluation, feature views';
CREATE SCHEMA IF NOT EXISTS LUMORA_DEMO.AGENT COMMENT = 'Agent tools, search corpus, feedback';
CREATE SCHEMA IF NOT EXISTS LUMORA_DEMO.APP   COMMENT = 'Streamlit app + KPI views';

CREATE WAREHOUSE IF NOT EXISTS LUMORA_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Lumora demo compute';

USE WAREHOUSE LUMORA_WH;
USE SCHEMA LUMORA_DEMO.CORE;

-- Demo-wide constants. DEMO_ASOF is the anchor date for the whole storyline:
-- every window (history, forecast, "last 8 weeks") is derived from it, so the
-- demo does not drift as the calendar moves.
CREATE OR REPLACE VIEW LUMORA_DEMO.CORE.DEMO_CONFIG AS
SELECT
    DATE '2026-09-15'                                   AS demo_asof_date,
    DATEADD(day, -548, DATE '2026-09-15')               AS history_start_date,  -- 549 days ~ 18 months
    60                                                  AS forecast_horizon_days,
    DATEADD(week, -8, DATE '2026-09-15')                AS break_start_date,
    'Illustrative — synthetic data, not Lumora financials' AS value_disclaimer;

SELECT 'setup complete' AS status, current_account() AS account, current_version() AS version;
