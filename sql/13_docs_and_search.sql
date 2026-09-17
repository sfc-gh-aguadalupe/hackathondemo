-- =====================================================================
-- Lumora Value Loop demo — 13_docs_and_search.sql
-- Policy/stakeholder document corpus + Cortex Search service.
--
-- CONTENT CONTRACT
--   12 internal-style governance documents (POLICY, ARCHITECTURE_NOTE,
--   STAKEHOLDER_NOTE, STANDARD, CONTROL) give corroborating context for
--   the demo's governance beats — EU data handling, cross-brand identity
--   lineage, forecast model provenance, and markdown/write-off/pricing
--   approval authority. Documents state governance rules and named
--   owners only; they never state a conclusion or a financial figure —
--   every number in the demo comes from SQL against the fact tables.
--
-- Idempotent: safe to re-run (CREATE OR REPLACE throughout).
--
-- ALL DATA IS SYNTHETIC AND ILLUSTRATIVE.
-- =====================================================================

USE WAREHOUSE LUMORA_WH;
USE SCHEMA LUMORA_DEMO.AGENT;

-- ─────────────────────────────────────────────────────────────────────
-- 1. Document corpus table
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE LUMORA_DEMO.AGENT.DOC_POLICY_AND_STAKEHOLDER_NOTES (
    doc_id          NUMBER          NOT NULL,
    doc_title       VARCHAR(512)    NOT NULL,
    doc_type        VARCHAR(64)     NOT NULL,   -- POLICY | ARCHITECTURE_NOTE | STAKEHOLDER_NOTE | STANDARD | CONTROL
    doc_owner       VARCHAR(256)    NOT NULL,
    effective_date  DATE            NOT NULL,
    region_scope    VARCHAR(128)    NOT NULL,
    doc_body        VARCHAR(16384)  NOT NULL
)
COMMENT = 'Synthetic governance and stakeholder documents for Cortex Search. ALL CONTENT IS ILLUSTRATIVE.';

-- ─────────────────────────────────────────────────────────────────────
-- 2. Document corpus — 12 records
--    Doc IDs 101–112. Single-quote literals escaped as ''.
-- ─────────────────────────────────────────────────────────────────────

INSERT INTO LUMORA_DEMO.AGENT.DOC_POLICY_AND_STAKEHOLDER_NOTES VALUES

-- ── Doc 101 ── EU Data Processing and GDPR Policy ───────────────────
(101,
 'EU Personal Data Processing and Cross-Border Transfer Policy',
 'POLICY',
 'Helena Kraemer, Group Data Protection Officer',
 '2025-01-10',
 'EU_WEST, EU_NORTH',
 'POLICY REF: EU-DPP-2025-001. Owner: Helena Kraemer, Group Data Protection Officer. Review cycle: annual.

Purpose: This policy governs the processing of personal data belonging to data subjects in the European Economic Area, specifically the DACH (data_residency_zone = EU_WEST) and NORDICS (data_residency_zone = EU_NORTH) residency zones. All processing must comply with the General Data Protection Regulation and applicable national laws.

Clause EU-DPP-1.1 Permitted Processing: Aggregate analytics derived from EU customer records are permitted for internal business intelligence where no individual is re-identifiable from the output. The minimum aggregation threshold is 25 individuals per reporting cell. Analytics on fewer than 25 EU data subjects must not be exposed in any report, dashboard, or agent response.

Clause EU-DPP-1.2 Cross-Border Transfer: Personal data for EU data subjects must not leave EU-designated storage zones without a valid transfer mechanism (Standard Contractual Clauses or an adequacy decision). Aggregate, anonymised, or pseudonymised outputs may cross borders provided that re-identification risk has been formally assessed and documented.

Clause EU-DPP-1.3 New Use Case Control — Human Confirmation Required: Before EU personal data is introduced into any new analytics, AI, or data-sharing use case, a Data Processing Impact Assessment must be completed. Control CTRL-EU-001 in the Group Approval Authority Register requires Group DPO sign-off and a recorded human confirmation event before EU personal data — including resolved cross-brand customer identifiers — enters a new use case or model training pipeline. This confirmation must be logged with requestor, approver, date, and use-case identifier. No automated system may substitute for this human confirmation.

Clause EU-DPP-1.4 Sensitive Categories: Customer data classified as sensitivity_class = HIGH is subject to enhanced controls regardless of residency zone.

Clause EU-DPP-1.5 Retention: EU personal data must not be retained beyond the period specified in the Group Data Retention Standard (GRS-2025-003).

Approved by: Group Data Protection Officer. Effective: 10 January 2025.'),

-- ── Doc 102 ── Architecture Review Note ─────────────────────────────
(102,
 'Architecture Review Note AR-2025-041: Cross-Brand Identity and Forecast Lineage Concerns',
 'ARCHITECTURE_NOTE',
 'Marcus Foley, Group Enterprise Architect',
 '2025-07-22',
 'GLOBAL',
 'ARCHITECTURE NOTE REF: AR-2025-041. Author: Marcus Foley, Group Enterprise Architect. Addressee: Lumora Data and AI Governance Committee. Date: 22 July 2025. Classification: Medium-Risk Governance Finding.

This note records two formal concerns raised during the architecture review of the cross-brand analytics and forecast integration programme.

CONCERN 1 — Cross-Brand Customer Identity Resolution Without Source Lineage
The current implementation derives customer_group_id in the analytics layer (BI reporting tool and downstream data products). No lineage exists from these resolved identifiers back to the originating brand-level source systems. If the resolution logic changes — or if a brand source system is migrated — resolved identity groupings will update silently with no record of what changed or when. This creates an audit risk under GDPR Article 30 processing records and a data quality risk for any campaign, personalisation, or audience segmentation use case.

Recommendation: Resolved identity must be computed in a governed, version-controlled mapping table owned and operated by the Group Data Engineering team, with a full change log. No downstream tool, BI product, or AI system may perform cross-brand identity resolution independently of this governed mapping. Violations to be treated as governance exceptions under the Cross-Brand Identity Resolution Standard.

CONCERN 2 — Forecast Outputs Consumed Without Recorded Model Version
Forecasts produced by the ML forecasting service are being consumed by the demand planning team and, as of Q3 2025, referenced in commercial decision-making. No model version number or forecast generation timestamp accompanies the forecast outputs in the operational views available to planners. A decision made on a stale or superseded forecast is indistinguishable from one made on the current production model.

Recommendation: Every forecast row exposed in the semantic layer must carry a model_version field and a forecast_generated_at timestamp. Any commercial action that references a forecast — including inventory commitment, markdown approval, or pricing actions — must record the model version at the point of decision. This requirement is formalised in the Forecast Model Governance Standard (FMG-2025-008).

Both concerns are classified as medium-risk governance findings. Resolution is required before the platform is extended to additional brands or use cases. Architecture checkpoint scheduled Q4 2025.'),

-- ── Doc 103 ── Approval Authority Control Register ───────────────────
(103,
 'Inventory, Markdown and Pricing Approval Authority Control Register',
 'CONTROL',
 'Stefanie Bauer, Group Financial Controller',
 '2025-02-01',
 'GLOBAL',
 'CONTROL REGISTER REF: CAR-2025-002. Owner: Stefanie Bauer, Group Financial Controller. Effective: 01 February 2025.

This register defines the approval authorities for inventory commitment, markdown, write-off, and pricing actions across the Lumora group.

CTRL-INV-001 — Inventory Commitment Authority
Purchase order commitments above GBP 500k equivalent require dual approval from the Brand Commercial Director and the Group Supply Chain Director. Commitments above GBP 2m require Group CFO sign-off. Automated inventory reorder signals generated by any system — including ML forecasting or AI agents — must not trigger commitments above GBP 100k without documented human review and approval.

CTRL-MKD-001 — Markdown Approval Authority
Markdown decisions (permanent price reductions) require the following approvals:
- Up to 15% reduction: Brand Trading Manager.
- 15 to 30% reduction: Brand Commercial Director.
- Over 30% reduction: Group CFO and Group Trading Director, jointly.
All markdown decisions must be recorded with approving authority, date, affected SKU range, and expected financial impact. System-generated recommendations must additionally record the model version and source system.

CTRL-WOF-001 — Write-Off Approval Authority
Inventory write-offs require:
- Up to GBP 50k: Brand Finance Business Partner.
- GBP 50k to GBP 250k: Brand Finance Director.
- Above GBP 250k: Group CFO, with Board notification above GBP 1m.

CTRL-PRC-001 — Pricing Action Authority
Any system-generated pricing recommendation, including recommendations from AI or agentic systems, that would affect published consumer prices requires explicit human sign-off before implementation. Approving authority is the Brand Commercial Director for brand-level actions and the Group CMO for cross-brand or promotional pricing. An AI or agentic system may propose but not enact a pricing action.

CTRL-EU-001 — EU Personal Data in New Use Cases
New analytics, AI, or data-sharing use cases that will process EU personal data require Group DPO written approval and a logged human confirmation event (see EU Data Processing Policy EU-DPP-1.3). This control applies to DACH and NORDICS data.

All controls are subject to annual review by the Group Financial Controller.'),

-- ── Doc 104 ── Markdown Ageing and Write-Off Policy ─────────────────
(104,
 'Markdown, Ageing and Write-Off Policy',
 'POLICY',
 'Helena Mistry, Group Head of Trading Finance',
 '2025-04-01',
 'GLOBAL',
 'POLICY REF: MKD-2025-004. Owner: Helena Mistry, Group Head of Trading Finance. Effective: 01 April 2025.

Purpose: To define the group-wide treatment of slow-moving, aged, and impaired inventory, including markdown triggers, ageing thresholds, write-off criteria, and approval authorities.

Section 4.1 — Inventory Ageing Classification
Inventory is classified by age from goods-received date as follows:

Current (0 to 45 days): Standard commercial treatment. No review required.
Watch (46 to 90 days): Weekly review by Brand Trading Manager. Markdown may be considered.
At-Risk (91 to 150 days): Mandatory markdown review. Brand Commercial Director must approve or provide written deferral rationale.
Impaired (151 to 270 days): Default treatment is a markdown of at least 20%. Write-off assessment required at 270 days.
Write-Off Eligible (over 270 days without a sale): Write-off proposal must be submitted within 30 calendar days.

Section 4.2 — Markdown Decision Record
Every markdown decision must be logged with: SKU or SKU group, age band at time of decision, markdown percentage, approving authority, effective date, and expected clearance period. Decisions driven by system or AI-generated recommendations must additionally record the model version and recommendation source.

Section 4.3 — Write-Off Treatment
Inventory written off is removed from available stock immediately upon approval. The financial impairment is recognised in the period in which the write-off is approved. Reversal of a write-off requires Group CFO sign-off with documented justification.

Section 4.4 — Inventory Cover Interaction
Where inventory cover falls below 15 days as a direct result of markdown clearance, a replenishment review must be initiated concurrently. See Inventory Cover and Commitment Policy (INV-COV-2025-006).

Section 4.5 — Approval Authorities
Refer to Control Register CAR-2025-002, controls CTRL-MKD-001 and CTRL-WOF-001. These authorities are mandatory and may not be delegated below the specified level without written approval from the Group Financial Controller.'),

-- ── Doc 105 ── Cross-Brand Identity Resolution Standard ──────────────
(105,
 'Cross-Brand Customer Identity Resolution Standard',
 'STANDARD',
 'Priya Nair, Group Head of Data Engineering',
 '2025-03-01',
 'GLOBAL',
 'STANDARD REF: CBID-2025-005. Owner: Priya Nair, Group Head of Data Engineering. Effective: 01 March 2025.

Purpose: To define the governed method for resolving customer identities across the Lumora brand portfolio, and to prohibit ungoverned identity merging in downstream tools, dashboards, or AI systems.

Section 5.1 — The Governed Identifier: customer_group_id
The field customer_group_id is the only authorised cross-brand customer identity key in the Lumora data platform. It is computed by the Group Data Engineering team using deterministic matching rules applied to email hash, loyalty card token, and device-level identity signals as available per brand. The computation is performed in a versioned, audited transformation job. The governing output table is LUMORA_DEMO.CORE.DIM_CUSTOMER_IDENTITY. Approximately 22% of known customer identities resolve across two or more brands via this mechanism, representing the addressable cross-brand audience.

Section 5.2 — Brand-Local Identifiers
Each brand operates one or more brand-local customer identifiers (brand_customer_id). These identifiers are valid for brand-level analytics only and must not be used in any cross-brand context.

Section 5.3 — Prohibition on Downstream Identity Merging
Brand-local IDs must never be merged, joined, or compared across brands in any report, dashboard, model, API response, or AI agent output without first mapping through the governed customer_group_id. Any cross-brand query or analysis that joins brand-local identifiers directly without using the governed mapping table is a standards violation. Violations must be raised to the Group Head of Data Engineering within 2 business days of detection and logged as governance exceptions.

Section 5.4 — Lineage and Version Requirement
All analytical outputs using customer_group_id must record the mapping table version used. Any change to the matching logic must be communicated to all consuming teams at least 10 business days before deployment.

Section 5.5 — EU Residency Intersection
For customers in EU residency zones (EU_WEST or EU_NORTH), identity resolution and cross-brand customer views are additionally governed by EU Data Processing Policy EU-DPP-1.1. Individual-level EU customer data must not be exposed below the 25-individual minimum aggregation threshold.'),

-- ── Doc 106 ── Promotional Calendar Governance Standard ─────────────
(106,
 'Promotional Calendar Governance Standard',
 'STANDARD',
 'Leonie Schreiber, Group Demand Planning Director',
 '2025-01-15',
 'GLOBAL',
 'STANDARD REF: PCGS-2025-006. Owner: Leonie Schreiber, Group Demand Planning Director. Effective: 15 January 2025.

Purpose: To ensure that changes to the promotional calendar are reflected in the demand plan, that forecast validity is maintained when promotion timing shifts, and that the governed relationship between promotional timing and forecast baselines is enforced.

Section 6.1 — Baseline Dependency
The group demand forecast is calibrated against the approved promotional calendar for each brand x region x category slice. Promotional timing is a primary input to the baseline forecast. Any change to promotion start or end dates materially affects forecast accuracy for that slice.

Section 6.2 — Re-Baselining Requirement
Promotion timing changes require formal re-baselining of the demand plan for the affected brand x region x category slice. The Demand Planning team must be notified of any calendar change within 2 business days of approval. A revised forecast must be published within 5 business days of notification.

Section 6.3 — Forecast Invalidation Trigger
A promotion that is moved by more than 14 calendar days from its originally planned start date invalidates the forecast baseline for that brand x region x category slice. The previous forecast must be flagged as superseded and must not be used for commercial decision-making, inventory commitment, or markdown analysis until a revised forecast is published. The field forecast_invalidated must be set to TRUE on all affected forecast rows.

Section 6.4 — Escalation for Shared-Category Promotions
Where a promotional timing change affects a category sold by more than one brand (for example SKINCARE, sold by Aurelia, Solene and Verdant), the Brand Commercial Director requesting the change must notify the Group Demand Planning Director in writing before the change is confirmed in the calendar, so that cross-brand re-baselining can be scoped jointly rather than brand by brand.

Section 6.5 — Cross-Brand Calendar Coordination
Where multiple brands operate in the same region and category during overlapping promotional windows, the Group Demand Planning Director must review for cannibalization or amplification effects before the calendar is finalised.'),

-- ── Doc 107 ── Group Data Retention Standard ────────────────────────
(107,
 'Group Data Retention Standard',
 'STANDARD',
 'Helena Kraemer, Group Data Protection Officer',
 '2025-01-10',
 'GLOBAL',
 'STANDARD REF: GRS-2025-003. Owner: Helena Kraemer, Group Data Protection Officer. Effective: 10 January 2025.

Purpose: To define retention periods for all data classes held in the Lumora group data platform, in compliance with GDPR Article 5(1)(e) and applicable national regulations.

Retention Schedule (GRS-2025-003):

Transaction and sales records: 7 years (tax and audit compliance).
Customer personal data — identified individuals: 3 years from last interaction (GDPR Article 17 right to erasure).
Customer analytics — pseudonymised records: 5 years (legitimate interest basis, documented).
Inventory snapshot records: 3 years (operational).
Promotional calendar records: 5 years (commercial audit trail).
Demand forecast outputs: 2 years (operational; see clause 7.3 exception below).
ML model artefacts — weights, configurations, evaluation results: 3 years post-decommission (AI Act readiness).
Agent interaction logs: 1 year (audit and explainability).
Governance event logs — approvals, DPIAs, human confirmation records: 7 years (regulatory obligation).

Section 7.1 — EU Personal Data
Data held in the EU_WEST (DACH) and EU_NORTH (NORDICS) residency zones must not be retained beyond the applicable period without an active legal basis. Retention extension requires written approval from the Group Data Protection Officer with a documented legal basis.

Section 7.2 — Deletion Verification
Automated deletion jobs run quarterly. Deletion confirmation must be logged. Data exceeding its retention period by more than 30 days must be escalated to the Group DPO within 5 business days of detection.

Section 7.3 — Forecast Retention Exception
Demand forecast outputs are ordinarily subject to the 2-year retention period. However, any forecast version that was used as the basis for a commercial decision — inventory commitment, markdown approval, or pricing action — must be retained for 7 years as part of the commercial decision audit trail (see also Forecast Model Governance Standard FMG-2025-008, Section 8.4).'),

-- ── Doc 108 ── Forecast Model Governance Standard ───────────────────
(108,
 'Forecast Model Governance Standard',
 'STANDARD',
 'Dr. Amara Osei, Group Head of Predictive Analytics',
 '2025-06-01',
 'GLOBAL',
 'STANDARD REF: FMG-2025-008. Owner: Dr. Amara Osei, Group Head of Predictive Analytics. Effective: 01 June 2025.

Purpose: To ensure that all demand forecast models used in commercial decision-making are versioned, evaluated, and fully traceable to the decisions they inform.

Section 8.1 — Model Version Requirement
Every demand forecast produced for commercial use must carry a model_version identifier and a forecast_generated_at timestamp. Forecast outputs lacking these fields must not be used for inventory commitment, markdown approval, pricing decisions, or senior-level reporting. Any dashboard, semantic view, or agent tool that exposes forecast data must surface these fields alongside the forecast values.

Section 8.2 — Evaluation Before Production Promotion
Before a new model version is promoted to PRODUCTION status, it must be evaluated on a held-out period of at least 8 weeks. The evaluation must record: WAPE (Weighted Absolute Percentage Error), forecast bias (signed directional error), stockout risk rate, and inventory value at risk. All evaluation metrics must be stored in the forecast evaluation table and linked to the model version.

Section 8.3 — Model Lifecycle States
Valid model lifecycle states are: TRAINING, EVALUATION, STAGING, PRODUCTION, RETIRED. A model in STAGING state may be used for scenario analysis and planning exercises but must not underpin commercial commitments. Only PRODUCTION-state models may support decisions subject to financial approval controls.

Section 8.4 — Decision Audit Record
Any commercial decision that references a forecast must record: the decision type, the model version relied upon, the forecast value used, the decision maker, and the approval date. This record is part of the commercial audit trail and subject to the extended 7-year retention period (see Group Data Retention Standard GRS-2025-003, Section 7.3).

Section 8.5 — Stale Forecast Definition
A forecast older than 14 days from its forecast_generated_at timestamp is considered stale for inventory commitment purposes. A stale forecast may inform trend analysis but must be labelled as stale in any presentation to senior stakeholders or in any agent response.'),

-- ── Doc 109 ── Inventory Cover and Commitment Policy ─────────────────
(109,
 'Inventory Cover and Commitment Policy',
 'POLICY',
 'James Thornton, Group Supply Chain Director',
 '2025-05-01',
 'GLOBAL',
 'POLICY REF: INV-COV-2025-006. Owner: James Thornton, Group Supply Chain Director. Effective: 01 May 2025.

Purpose: To define group standards for inventory cover targets, reorder triggers, and commitment governance across all brands and regions.

Section 9.1 — Target Cover
The group inventory cover target is 45 days of forward demand cover. Cover is calculated as stock-on-hand divided by the daily demand forecast, evaluated at brand x region x category level. The forecast used must be the current PRODUCTION-state model output. Cover thresholds:
- Critical stockout alert: cover below 15 days.
- Reorder signal: cover below 30 days.
- Target range: 30 to 60 days.
- Excess inventory review trigger: cover above 90 days.

Section 9.2 — Cover Calculation Basis
Cover must be calculated using the current PRODUCTION-state demand forecast. Use of a STAGING, stale (older than 14 days), or superseded forecast for cover calculation is a policy violation and may result in erroneous commitments. Where the forecast is flagged as invalidated under the Promotional Calendar Governance Standard Clause 6.3, the cover calculation must be suspended pending a revised forecast.

Section 9.3 — Reorder Trigger and Human Review
A reorder signal generated when cover falls below 30 days must be reviewed by the Brand Supply Planner before a purchase order is raised. Automated commitment above GBP 100k is prohibited without documented human approval (see CTRL-INV-001).

Section 9.4 — Promotional Uplift Adjustment
During a promotional period, cover must be calculated using the promotional demand estimate, not the baseline forecast. Where the promotional calendar has been amended and the forecast has not yet been re-baselined, inventory commitment decisions must be deferred or explicitly flagged as pending a revised forecast.

Section 9.5 — Excess Inventory Clearance
Cover above 90 days at SKU level for more than 30 consecutive days triggers a mandatory review. The Brand Trading Manager must present a clearance plan to the Brand Commercial Director within 15 business days.'),

-- ── Doc 110 ── DACH Skincare Stakeholder Note ────────────────────────
(110,
 'DACH Skincare Trading Conditions — Stakeholder Note Q3/Q4 2026',
 'STAKEHOLDER_NOTE',
 'Isabeau Richter, Brand Commercial Director (DACH)',
 '2026-06-30',
 'DACH',
 'STAKEHOLDER NOTE. From: Isabeau Richter, Brand Commercial Director — DACH Region. To: Group Demand Planning; Group Trading Finance; DACH Brand Teams. Date: 30 June 2026. Subject: DACH Skincare Trading Conditions — Q3/Q4 2026 Outlook.

This note summarises the commercial team assessment of DACH skincare trading conditions and records decisions relevant to demand planning and inventory management.

Market Conditions: The DACH skincare market has shown softening consumer sentiment in the standard-price tier since Q2 2026, driven by cost-of-living pressure particularly in Germany and Austria. Premium sub-categories have held better but early July data shows initial signs of trade-down behaviour. Category volume growth is tracking below the original plan.

Promotional Calendar Amendment: The autumn promotional programme for DACH skincare has been amended. At the request of the Brand Commercial Director, the planned promotional window has been moved earlier to capture seasonal demand ahead of competitor activity. The Demand Planning team has been formally notified in accordance with the Promotional Calendar Governance Standard (PCGS-2025-006, Clause 6.2). A re-baselining assessment is required under Clause 6.3 of that standard; the magnitude of the timing shift relative to the 14-day invalidation threshold must be confirmed by the Demand Planning team.

Inventory Position: The DACH team notes elevated inventory in the skincare category following the inventory build undertaken against the original demand plan. This position should be reviewed against the revised demand plan once re-baselining is complete. Premature markdown or clearance actions should be avoided until the revised forecast is available.

Recommendation to Demand Planning: Prioritise the DACH skincare forecast re-baselining. Do not use the current forecast for inventory commitment or markdown approval until the revised version is published and validated.

Note for Governance Record: Financial impact figures are not included in this stakeholder note. Impact estimates must be derived from the updated forecast and actuals data in the group data platform.'),

-- ── Doc 111 ── Data Quality and Freshness Standard ──────────────────
(111,
 'Data Quality and Freshness Standard',
 'STANDARD',
 'Priya Nair, Group Head of Data Engineering',
 '2025-03-15',
 'GLOBAL',
 'STANDARD REF: DQF-2025-007. Owner: Priya Nair, Group Head of Data Engineering. Effective: 15 March 2025.

Purpose: To define the data quality and freshness standards for the Lumora group data platform, ensuring that KPIs, forecasts, and agent-generated insights are grounded in data meeting minimum quality thresholds.

Section 11.1 — Freshness Service Level Agreements
FACT_SALES (daily grain): maximum permitted lag 28 hours from close of business; alert threshold 36 hours.
FACT_INVENTORY (weekly snapshot): maximum lag 4 hours from snapshot time; alert threshold 8 hours.
FACT_PROMOTIONS (event-driven): maximum lag 4 hours from update; alert threshold 6 hours.
Demand forecast outputs: maximum lag 24 hours from model run; alert threshold 48 hours.
Agent search corpus (Cortex Search target lag): 1 hour; alert threshold 4 hours.

Section 11.2 — Completeness Requirements
All fact tables must have at least 99.5% row completeness for mandatory dimensions: brand_id, region_id, category, and event_date. Rows with NULL mandatory dimensions must be quarantined to an exceptions table and must not be used in KPI calculation or agent responses.

Section 11.3 — Residency Classification Coverage
At least 99% of customer records must carry a valid data_residency_zone value. Records lacking residency classification must not be included in any analytics where the EU/non-EU distinction is material to the use case.

Section 11.4 — Forecast Completeness
Forecast coverage must be 100% at brand x region x category level for the active 60-day forward horizon. Missing forecast coverage for any combination currently in the sales mix is a blocking issue for the demand planning process.

Section 11.5 — Governance and Escalation
Data quality exceptions are tracked in the governance exception register. Unresolved blocking exceptions must be reviewed by the Group Head of Data Engineering within 24 hours of detection. Exceptions affecting EU-resident customer data must additionally be reported to the Group Data Protection Officer.'),

-- ── Doc 112 ── Data Residency Architecture Note ──────────────────────
(112,
 'Architecture Note AR-2025-058: Residency Classification Completeness for AI Use Cases',
 'ARCHITECTURE_NOTE',
 'Marcus Foley, Group Enterprise Architect',
 '2025-09-10',
 'EU_WEST, EU_NORTH',
 'ARCHITECTURE NOTE REF: AR-2025-058. Author: Marcus Foley, Group Enterprise Architect. Addressee: Lumora Data and AI Governance Committee. Date: 10 September 2025.

Subject: Residency classification completeness ahead of planned agentic AI use-case expansion.

Context: The Lumora Data and AI programme is planned to extend agentic AI capabilities across all brand regions in H1 2026. This note records an architecture concern that must be resolved before that expansion proceeds.

Concern: Residency Classification Dependency in AI Outputs
The current Cortex Search and Cortex Agent architecture surfaces documents, KPIs, and recommendations derived from aggregated data that spans EU and non-EU residency zones. The data_residency_zone field exists on customer and inventory records in the core data model. However, the AI serving layer — including the Cortex Search corpus and semantic views — does not yet enforce residency-based filtering at query time.

Risk Assessment: An agent response that surfaces EU-resident customer-level insights below the 25-individual aggregation threshold (as defined in EU Data Processing Policy EU-DPP-1.1) could constitute a GDPR data processing violation. The most likely scenario is a drill-down or anomaly-explanation query where the agent is given access to granular data without an aggregation guard.

Recommendations:
1. Apply row-level security or semantic-layer minimum-aggregation filters on all agent-facing views where EU data may be present.
2. Review the Cortex Search corpus to confirm that no document contains individually identifiable EU customer data.
3. For any new use case processing DACH (EU_WEST) or NORDICS (EU_NORTH) data, invoke CTRL-EU-001 before deployment.
4. Surface the sensitivity_class column in all agent tool responses so the agent can reason explicitly about data sensitivity before responding.

Architecture review checkpoint: Q1 2026. This note supplements AR-2025-041 on identity lineage.');


-- ─────────────────────────────────────────────────────────────────────
-- 3. Verify row count
-- ─────────────────────────────────────────────────────────────────────

SELECT COUNT(*) AS row_count FROM LUMORA_DEMO.AGENT.DOC_POLICY_AND_STAKEHOLDER_NOTES;


-- ─────────────────────────────────────────────────────────────────────
-- 4. Cortex Search service
--    ON doc_body  (the search column)
--    ATTRIBUTES = filterable metadata columns
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE CORTEX SEARCH SERVICE LUMORA_DEMO.AGENT.LUMORA_POLICY_SEARCH
    ON doc_body
    ATTRIBUTES doc_title, doc_type, doc_owner, effective_date, region_scope
    WAREHOUSE = LUMORA_WH
    TARGET_LAG = '1 hour'
    COMMENT = 'Lumora demo policy and stakeholder document search. Synthetic content — illustrative only.'
AS
    SELECT
        doc_id,
        doc_title,
        doc_type,
        doc_owner,
        effective_date,
        region_scope,
        doc_body
    FROM LUMORA_DEMO.AGENT.DOC_POLICY_AND_STAKEHOLDER_NOTES;


-- ─────────────────────────────────────────────────────────────────────
-- 5. Check service status
-- ─────────────────────────────────────────────────────────────────────

SHOW CORTEX SEARCH SERVICES IN SCHEMA LUMORA_DEMO.AGENT;

DESCRIBE CORTEX SEARCH SERVICE LUMORA_DEMO.AGENT.LUMORA_POLICY_SEARCH;


-- ─────────────────────────────────────────────────────────────────────
-- 6. Acceptance test queries  (run after service reaches READY state)
-- ─────────────────────────────────────────────────────────────────────

-- Test 1: EU personal data use case
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'LUMORA_DEMO.AGENT.LUMORA_POLICY_SEARCH',
        '{
            "query": "Can we use EU customer data in this scenario, and what constraint should we check?",
            "columns": ["doc_id", "doc_title", "doc_type", "doc_owner", "region_scope"],
            "limit": 3
        }'
    )
)['results'] AS results;

-- Test 2: Architecture stakeholder concern
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'LUMORA_DEMO.AGENT.LUMORA_POLICY_SEARCH',
        '{
            "query": "What concern did the architecture stakeholder raise?",
            "columns": ["doc_id", "doc_title", "doc_type", "doc_owner", "region_scope"],
            "limit": 3
        }'
    )
)['results'] AS results;

-- Test 3: Which control is relevant to this scenario
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'LUMORA_DEMO.AGENT.LUMORA_POLICY_SEARCH',
        '{
            "query": "Which control is relevant to this scenario?",
            "columns": ["doc_id", "doc_title", "doc_type", "doc_owner", "region_scope"],
            "limit": 3
        }'
    )
)['results'] AS results;
