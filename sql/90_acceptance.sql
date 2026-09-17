-- =====================================================================
-- Lumora Value Loop demo — 90_acceptance.sql
--
-- Machine-checkable subset of the spec's acceptance criteria. Every row
-- returns PASS or FAIL, so the demo can be re-verified after any rebuild
-- instead of being eyeballed.
--
-- Criteria that cannot be checked in SQL (8-minute run time, visual
-- design, the team being able to explain retraining vs fine-tuning) are
-- rehearsal items, not assertions.
-- =====================================================================

USE SCHEMA LUMORA_DEMO.APP;

WITH c AS (

    -- Every KPI has a definition and a source: the semantic view must agree
    -- with the KPI view, or the chat panel and the cards can disagree.
    SELECT 'KPI layer and semantic view agree on exposure' AS criterion,
           IFF(ABS((SELECT inventory_value_at_risk FROM LUMORA_DEMO.APP.V_KPI_EXEC)
                 - (SELECT inventory_value_at_risk FROM SEMANTIC_VIEW(
                        LUMORA_DEMO.APP.SV_LUMORA_EXEC METRICS inventory_value_at_risk))) < 0.01,
               'PASS', 'FAIL') AS result

    -- The forecast must be reproducible: both vintages present, complete,
    -- and stamped with a model version.
    UNION ALL SELECT 'Two forecast vintages, 68 series each, model version stamped',
           IFF((SELECT COUNT(*) FROM (
                    SELECT forecast_vintage,
                           COUNT(DISTINCT brand_id || region_code || category_code) AS n,
                           COUNT(DISTINCT model_version) AS mv
                    FROM LUMORA_DEMO.ML.FACT_FORECAST GROUP BY 1
                    HAVING n = 68 AND mv = 1)) = 2,
               'PASS', 'FAIL')

    -- Act 1: exposure must actually concentrate, or the CFO question has no answer.
    UNION ALL SELECT 'Act 1: top slice holds >25% of group exposure',
           IFF((SELECT MAX(pct) FROM (
                    SELECT 100.0 * inventory_value_at_risk
                           / SUM(inventory_value_at_risk) OVER () AS pct
                    FROM LUMORA_DEMO.APP.V_SLICE_RISK)) > 25,
               'PASS', 'FAIL')

    -- Act 2: the hidden driver must be discoverable from the data.
    UNION ALL SELECT 'Act 2: promotion timing shift >14 days is recorded',
           IFF((SELECT MAX(DATEDIFF(day, actual_start, planned_start))
                FROM LUMORA_DEMO.CORE.FACT_PROMOTIONS WHERE timing_changed) > 14,
               'PASS', 'FAIL')

    UNION ALL SELECT 'Act 2: forecast bias on top slice exceeds noise floor by 5x',
           IFF((SELECT MAX(bias_pct) FROM LUMORA_DEMO.APP.V_SLICE_RISK)
             > 5 * (SELECT MEDIAN(ABS(bias_pct)) FROM LUMORA_DEMO.APP.V_SLICE_RISK),
               'PASS', 'FAIL')

    UNION ALL SELECT 'Act 2: leading indicator declines before the sales break',
           IFF((SELECT AVG(CASE WHEN signal_date >= DATE '2026-07-21' THEN search_interest_index END)
                     < AVG(CASE WHEN signal_date BETWEEN DATE '2026-05-01' AND DATE '2026-07-06'
                                THEN search_interest_index END) * 0.9
                FROM LUMORA_DEMO.CORE.FACT_DEMAND_SIGNALS
                WHERE brand_id = 1 AND region_code = 'DACH' AND category_code = 'SKINCARE'),
               'PASS', 'FAIL')

    -- Act 3: the scenario must move the numbers, and the tool must exist.
    UNION ALL SELECT 'Act 3: scenario tool exists',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.INFORMATION_SCHEMA.PROCEDURES
                WHERE procedure_schema = 'AGENT' AND procedure_name = 'RUN_DEMAND_SCENARIO') > 0,
               'PASS', 'FAIL')

    -- Act 4: the pattern must be group-level, not single-brand.
    UNION ALL SELECT 'Act 4: >=3 brands exposed in the same region and category',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.APP.V_SLICE_RISK
                WHERE region_code = 'DACH' AND category_code = 'SKINCARE'
                  AND cover_days > target_cover_days) >= 3,
               'PASS', 'FAIL')

    -- Act 5: governed answer must be groundable in the document corpus.
    UNION ALL SELECT 'Act 5: policy corpus indexed and residency classified',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.AGENT.DOC_POLICY_AND_STAKEHOLDER_NOTES) >= 10
           AND (SELECT COUNT(*) FROM LUMORA_DEMO.APP.V_SLICE_RISK
                WHERE data_residency_zone IS NULL) = 0,
               'PASS', 'FAIL')

    -- No document may pre-empt the analysis with a financial conclusion.
    UNION ALL SELECT 'Governance: no policy document states a financial impact',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.AGENT.DOC_POLICY_AND_STAKEHOLDER_NOTES
                WHERE doc_body RLIKE '.*(EUR [0-9]|€[0-9]|value at risk of).*') = 0,
               'PASS', 'FAIL')

    -- Act 6: the two improvement loops must be separate objects.
    UNION ALL SELECT 'Act 6: retraining and fine-tuning are separate procedures',
           IFF((SELECT COUNT(DISTINCT procedure_name) FROM LUMORA_DEMO.INFORMATION_SCHEMA.PROCEDURES
                WHERE procedure_schema = 'AGENT'
                  AND procedure_name IN ('REQUEST_FORECAST_RETRAINING','REQUEST_AGENT_FINE_TUNING')) = 2,
               'PASS', 'FAIL')

    -- A deterministic fallback must exist for every act.
    UNION ALL SELECT 'Fallback: all 7 acts have a deterministic answer',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.AGENT.DEMO_FALLBACK) = 7
           AND (SELECT COUNT(*) FROM LUMORA_DEMO.AGENT.DEMO_FALLBACK
                WHERE executive_answer IS NULL OR evidence IS NULL
                   OR assumptions IS NULL OR recommendation IS NULL) = 0,
               'PASS', 'FAIL')

    -- The UI must be able to separate fact / calculation / assumption /
    -- recommendation, which requires the data to carry all four.
    UNION ALL SELECT 'Fallback: every act separates evidence, assumptions and recommendation',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.AGENT.DEMO_FALLBACK
                WHERE LENGTH(evidence) > 40 AND LENGTH(assumptions) > 30
                  AND LENGTH(recommendation) > 30) = 7,
               'PASS', 'FAIL')

    -- Determinism. Full reproducibility is proven by rebuilding and comparing
    -- HASH_AGG(*) (see below), which SQL cannot assert about itself. What IS
    -- assertable here is the fix that made it reproducible: unrounded
    -- floating-point averages summed in a parallelism-dependent order and
    -- drifted in their last bits between rebuilds, so the stored unit
    -- economics must carry no more than 4 decimal places.
    --
    -- To re-prove reproducibility manually:
    --   SELECT HASH_AGG(*) FROM LUMORA_DEMO.CORE.FACT_SALES;      -- note value
    --   ./build_all.sh                                            -- rebuild
    --   SELECT HASH_AGG(*) FROM LUMORA_DEMO.CORE.FACT_SALES;      -- must match
    UNION ALL SELECT 'Determinism: stored unit economics are rounded, not raw floats',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.CORE.FACT_INVENTORY
                WHERE avg_cost <> ROUND(avg_cost, 4) OR avg_price <> ROUND(avg_price, 4)) = 0
           AND (SELECT COUNT(*) FROM LUMORA_DEMO.CORE.FACT_SALES
                WHERE avg_cost <> ROUND(avg_cost, 4) OR avg_price <> ROUND(avg_price, 4)) = 0,
               'PASS', 'FAIL')

    -- The fallback answers are generated FROM the KPI views, so they must not
    -- have gone stale relative to the numbers currently on the cards.
    UNION ALL SELECT 'Fallback exposure figure matches the live KPI view',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.AGENT.DEMO_FALLBACK f
                WHERE f.act_no = 1
                  AND f.executive_answer LIKE '%' || TRIM(TO_VARCHAR(
                        ROUND((SELECT inventory_value_at_risk FROM LUMORA_DEMO.APP.V_KPI_EXEC)),
                        '999,999,999')) || '%') = 1,
               'PASS', 'FAIL')

    -- Every financial figure must be labelled illustrative somewhere the UI reads.
    UNION ALL SELECT 'Disclaimer: illustrative-value labelling is available to the UI',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.APP.V_ASSUMPTIONS
                WHERE value_disclaimer ILIKE '%illustrative%') = 1,
               'PASS', 'FAIL')

    -- Act 6: both pre-staged comparison artefacts must be present, since the
    -- demo shows completed results rather than waiting for live jobs.
    UNION ALL SELECT 'Act 6: pre-staged retrain and fine-tune comparisons exist',
           IFF((SELECT COUNT(*) FROM LUMORA_DEMO.INFORMATION_SCHEMA.TABLES
                WHERE table_schema = 'AGENT'
                  AND table_name IN ('PRESTAGED_RETRAIN_RESULT','PRESTAGED_FINETUNE_COMPARISON')) = 2,
               'PASS', 'FAIL')
)
SELECT result, criterion FROM c ORDER BY result, criterion;

-- The agent object is not exposed in INFORMATION_SCHEMA, so it is verified
-- separately rather than asserted above.
SHOW AGENTS IN SCHEMA LUMORA_DEMO.AGENT;
