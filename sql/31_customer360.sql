-- =====================================================================
-- Lumora Value Loop demo — 31_customer360.sql
--
-- Customer 360 segmentation layer for the promotion builder tab.
-- Computes RFM (Recency, Frequency, Monetary) segments from
-- FACT_CUSTOMER_ACTIVITY, cross-brand identity flags, and residency
-- classification from DIM_CUSTOMER_IDENTITY.
--
-- The EU governance hard gate in the app depends on the sensitivity_class
-- and is_eu flags propagated here from DIM_CUSTOMER_IDENTITY. No
-- identified personal data is exposed — the grain is customer_group_id
-- (the governed synthetic identity key), not any source-system PII.
--
-- ALL DATA IS SYNTHETIC AND ILLUSTRATIVE.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.AGENT;

-- ---------------------------------------------------------------------
-- RFM calculation.
-- Anchor date: the demo date 2026-09-15.
-- Recency in months since the last activity month.
-- Frequency: total orders in the 18-month window.
-- Monetary:  total illustrative revenue.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW LUMORA_DEMO.AGENT.V_CUSTOMER_RFM AS
WITH anchor AS (
    SELECT demo_asof_date FROM LUMORA_DEMO.CORE.DEMO_CONFIG
),
agg AS (
    SELECT
        ca.customer_group_id,
        ca.brand_id,
        b.brand_name,
        ca.region_code,
        MAX(ca.activity_month)                                                AS last_activity_month,
        COUNT(DISTINCT ca.activity_month)                                     AS active_months,
        SUM(ca.orders)                                                        AS total_orders,
        ROUND(SUM(ca.revenue_amount), 2)                                      AS total_revenue,
        -- flag customers visible across >1 brand (from the identity table)
        MAX(CASE WHEN ci.brand_count > 1 THEN 1 ELSE 0 END)                  AS is_cross_brand
    FROM LUMORA_DEMO.CORE.FACT_CUSTOMER_ACTIVITY ca
    JOIN LUMORA_DEMO.CORE.DIM_BRAND b ON b.brand_id = ca.brand_id
    LEFT JOIN (
        SELECT customer_group_id, COUNT(DISTINCT brand_id) AS brand_count
        FROM LUMORA_DEMO.CORE.DIM_CUSTOMER_IDENTITY GROUP BY 1
    ) ci ON ci.customer_group_id = ca.customer_group_id
    GROUP BY 1,2,3,4
),
with_recency AS (
    SELECT a.*,
           DATEDIFF('month', a.last_activity_month, anc.demo_asof_date) AS recency_months
    FROM agg a CROSS JOIN anchor anc
),
-- Score each dimension 1-4 using NTILE — deterministic since there is
-- no RANDOM() in the source data.
scored AS (
    SELECT *,
           NTILE(4) OVER (PARTITION BY brand_id, region_code ORDER BY recency_months ASC)  AS r_score,  -- lower recency = better
           NTILE(4) OVER (PARTITION BY brand_id, region_code ORDER BY total_orders ASC)    AS f_score,
           NTILE(4) OVER (PARTITION BY brand_id, region_code ORDER BY total_revenue ASC)   AS m_score
    FROM with_recency
)
SELECT
    s.customer_group_id,
    s.brand_id,
    s.brand_name,
    s.region_code,
    ci.sensitivity_class,
    ci.data_residency_zone,
    rgn.is_eu,
    s.last_activity_month,
    s.recency_months,
    s.active_months,
    s.total_orders,
    s.total_revenue,
    s.is_cross_brand::BOOLEAN AS is_cross_brand,
    s.r_score,
    s.f_score,
    s.m_score,
    s.r_score + s.f_score + s.m_score AS rfm_total,
    -- Segment labels CFO/CMO audiences will recognise immediately
    CASE
        WHEN s.r_score >= 3 AND s.f_score >= 3 AND s.m_score >= 3 THEN 'Champions'
        WHEN s.r_score >= 3 AND s.f_score >= 2                    THEN 'Loyal'
        WHEN s.r_score <= 2 AND s.f_score >= 3 AND s.m_score >= 3 THEN 'At Risk'
        WHEN s.r_score <= 2 AND s.f_score >= 2                    THEN 'At Risk'
        WHEN s.r_score >= 3 AND s.f_score = 1                     THEN 'New'
        ELSE 'Lapsed'
    END AS rfm_segment
FROM scored s
-- IS_EU lives on DIM_REGION, not DIM_CUSTOMER_IDENTITY
LEFT JOIN LUMORA_DEMO.CORE.DIM_REGION rgn ON rgn.region_code = s.region_code
LEFT JOIN (
    SELECT customer_group_id, brand_id,
           MAX(sensitivity_class)    AS sensitivity_class,
           MAX(data_residency_zone)  AS data_residency_zone
    FROM LUMORA_DEMO.CORE.DIM_CUSTOMER_IDENTITY
    GROUP BY 1,2
) ci ON ci.customer_group_id = s.customer_group_id AND ci.brand_id = s.brand_id;

-- GET_CUSTOMER_SEGMENTS — agent tool.
-- Returns a VARIANT containing:
--   segment_summary : distribution table
--   audience_stats  : total, eu_count, restricted_pii_count, cross_brand_count
--   governance_note : plain-English summary for the agent to cite
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE LUMORA_DEMO.AGENT.GET_CUSTOMER_SEGMENTS(
    P_BRAND    VARCHAR,
    P_REGION   VARCHAR,
    P_CATEGORY VARCHAR    -- accepted for signature parity; category does not filter
)                         -- customers since they are tracked at brand×region level
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    out_var VARIANT;
BEGIN
    SELECT OBJECT_CONSTRUCT(
        'scope',         OBJECT_CONSTRUCT(
                             'brand',    COALESCE(NULLIF(TRIM(:P_BRAND),    ''), 'All brands'),
                             'region',   COALESCE(NULLIF(TRIM(:P_REGION),   ''), 'All regions'),
                             'category', COALESCE(NULLIF(TRIM(:P_CATEGORY), ''), 'All categories')
                         ),
        'audience_stats', OBJECT_CONSTRUCT(
                             'total_customers',      SUM(1),
                             'eu_count',             SUM(CASE WHEN is_eu THEN 1 ELSE 0 END),
                             'restricted_pii_count', SUM(restricted_pii_count),
                             'cross_brand_count',    SUM(CASE WHEN is_cross_brand THEN 1 ELSE 0 END),
                             'cross_brand_pct',      ROUND(100.0 * SUM(CASE WHEN is_cross_brand THEN 1 ELSE 0 END) / NULLIF(SUM(1),0), 1)
                         ),
        'segment_summary', ARRAY_AGG(OBJECT_CONSTRUCT(
                             'segment',       rfm_segment,
                             'count',         seg_count,
                             'pct_of_base',   seg_pct,
                             'avg_orders',    avg_orders,
                             'avg_revenue',   avg_revenue,
                             'eu_count',      eu_count,
                             'cross_brand_count', cross_brand_count
                         )) WITHIN GROUP (ORDER BY rfm_segment),
        'governance_note', CASE
            WHEN SUM(CASE WHEN is_eu THEN 1 ELSE 0 END) > 0
            THEN 'This audience includes EU customers classified RESTRICTED_PII (residency zones: EU_WEST, EU_NORTH). Aggregate demand analysis is permitted. Using this audience for targeted promotion or personalised marketing constitutes identified-person processing and requires documented human approval per the EU data processing policy before the audience can be activated. Status: PENDING_EU_APPROVAL.'
            ELSE 'This audience contains no EU-classified customers. Standard data-handling policies apply. Status: READY.'
        END,
        'value_disclaimer', 'All financial values are illustrative and derived from synthetic unit economics'
    ) INTO :out_var
    FROM (
        SELECT rfm_segment, is_eu, is_cross_brand,
               COUNT(*)                                                                   AS seg_count,
               ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                        AS seg_pct,
               ROUND(AVG(total_orders), 1)                                                AS avg_orders,
               ROUND(AVG(total_revenue), 2)                                               AS avg_revenue,
               SUM(CASE WHEN is_eu           THEN 1 ELSE 0 END)                          AS eu_count,
               SUM(CASE WHEN sensitivity_class='RESTRICTED_PII' THEN 1 ELSE 0 END)       AS restricted_pii_count,
               SUM(CASE WHEN is_cross_brand  THEN 1 ELSE 0 END)                          AS cross_brand_count
        FROM LUMORA_DEMO.AGENT.V_CUSTOMER_RFM
        WHERE (:P_BRAND  IS NULL OR TRIM(:P_BRAND)  = '' OR brand_name  ILIKE :P_BRAND)
          AND (:P_REGION IS NULL OR TRIM(:P_REGION) = '' OR region_code ILIKE :P_REGION)
        GROUP BY rfm_segment, is_eu, is_cross_brand
    ) agg;
    RETURN :out_var;
END;
$$;

-- ---------------------------------------------------------------------
-- FACT_PROMOTION_BRIEF — saved promotion briefs generated via the app.
-- Append-only (IF NOT EXISTS) so accumulated briefs survive rebuilds.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS LUMORA_DEMO.AGENT.FACT_PROMOTION_BRIEF (
    brief_id              VARCHAR   COMMENT 'e.g. BRIEF-000001',
    created_by            VARCHAR,
    brand                 VARCHAR,
    region                VARCHAR,
    category              VARCHAR,
    target_segments       VARCHAR   COMMENT 'Comma-separated list of selected RFM segments',
    audience_size         NUMBER    COMMENT 'Total customers in the selected segments',
    eu_customer_count     NUMBER    COMMENT 'EU/RESTRICTED_PII customers in the audience',
    expected_uplift_units FLOAT     COMMENT 'Estimated incremental units if the audience responds at the assumed rate',
    governance_status     VARCHAR   COMMENT 'READY or PENDING_EU_APPROVAL',
    agent_recommendation  VARCHAR   COMMENT 'Full agent response text',
    notes                 VARCHAR,
    created_at            TIMESTAMP_LTZ
) COMMENT = 'Saved promotion briefs for the Customer 360 tab. governance_status=PENDING_EU_APPROVAL when the audience includes EU RESTRICTED_PII customers — those briefs require documented human approval before the audience can be activated for targeting.';

CREATE SEQUENCE IF NOT EXISTS LUMORA_DEMO.AGENT.SEQ_BRIEF START = 1 INCREMENT = 1;

-- ---------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------
SELECT 'V_CUSTOMER_RFM' AS object_name, COUNT(*) AS row_count FROM LUMORA_DEMO.AGENT.V_CUSTOMER_RFM
UNION ALL
SELECT 'segments available', COUNT(DISTINCT rfm_segment) FROM LUMORA_DEMO.AGENT.V_CUSTOMER_RFM
UNION ALL
SELECT 'EU RESTRICTED_PII customers', COUNT(*) FROM LUMORA_DEMO.AGENT.V_CUSTOMER_RFM WHERE sensitivity_class='RESTRICTED_PII'
UNION ALL
SELECT 'cross-brand customers', COUNT(*) FROM LUMORA_DEMO.AGENT.V_CUSTOMER_RFM WHERE is_cross_brand;
