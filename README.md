# Lumora Value Loop Demo

Lumora Value Loop is a Snowflake demo of a governed retail decision loop:

```text
synthetic retail data
        |
        v
forecast vintages and evaluation
        |
        v
governed KPI views and semantic view
        |
        +--> deterministic agent tools
        |          |
        |          +--> Cortex Agent
        |          +--> Cortex Search policy evidence
        |
        v
Streamlit CFO cockpit
        |
        v
decision -> feedback -> numeric retraining or language improvement
```

The demo is designed for a short executive presentation. It connects inventory risk, demand forecasting, explainability, scenario analysis, governance evidence, and two separate improvement loops in one storyline.

> **Important:** all source data is synthetic and deterministic. Every financial value shown by the app, SQL views, agent, fallback answers, and deck is illustrative. It is not Lumora's actual financial performance and must not be presented as such.

## What The Demo Shows

The demo answers seven questions in sequence:

1. Which part of the group's inventory position needs attention first?
2. Why is the risk concentrated there, and what evidence supports the conclusion?
3. What happens if demand increases 12% for four weeks?
4. Is the problem specific to one brand or a group-level pattern?
5. Can EU customer data be used in the scenario, and which control applies?
6. How does approved feedback improve the numeric forecast and the agent's explanation separately?
7. What is the smallest bounded first step?

The planted narrative is computed from the data rather than written directly into the answers:

- Aurelia SKINCARE in DACH is the highest-risk slice.
- The slice has approximately 149.8 days of cover against a 45-day policy target.
- The prior plan over-forecast the slice by approximately 61.3% in the evaluation window.
- The DACH SKINCARE promotion ran 21 days earlier than planned.
- Search interest softened before the sales break.
- Aurelia, Solene, and Verdant in DACH SKINCARE together represent about 60% of group inventory exposure.
- A 12% demand uplift for four weeks removes only about 3.3% of the top slice's excess, so promotion alone is not the answer.

## Repository Layout

| Path | Purpose |
|---|---|
| `build_all.sh` | Rebuilds the database objects in dependency order. |
| `sql/00_setup.sql` | Creates `LUMORA_DEMO`, schemas, `LUMORA_WH`, and the fixed demo date configuration. |
| `sql/10_dimensions.sql` | Creates brands, regions, categories, products, and governed customer identities. |
| `sql/11_facts.sql` | Creates deterministic sales, inventory, promotions, demand signals, and customer activity. |
| `sql/13_docs_and_search.sql` | Creates the synthetic policy corpus and `LUMORA_POLICY_SEARCH`. |
| `sql/20_forecast.sql` | Trains two `SNOWFLAKE.ML.FORECAST` vintages and creates forecast evaluation rows. |
| `sql/21_kpi_views.sql` | Defines the shared KPI views used by the app and tools. |
| `sql/22_semantic_view.sql` | Creates `SV_LUMORA_EXEC` for governed semantic queries. |
| `sql/30_agent_tools.sql` | Creates five deterministic stored procedures and `LUMORA_VALUE_AGENT`. |
| `sql/40_fallback.sql` | Creates the seven-act deterministic fallback answers. |
| `sql/50_deploy_streamlit.sql` | Stages and deploys the Streamlit app. Requires local-file access for `PUT`. |
| `sql/90_acceptance.sql` | Runs machine-checkable acceptance criteria. |
| `app/lumora_app.py` | Streamlit application source. |
| `app/environment.yml` | Streamlit in Snowflake package configuration. |
| `pitch/lumora.html` | Self-contained presentation deck. |
| `pitch/index.html` | Reference deck whose visual system is cloned by `pitch/lumora.html`. |
| `DEMO_SCRIPT.md` | Presenter run-of-show and finance terminology guide. |

## Snowflake Prerequisites

The verified build target is:

- Account: `ZVB39012`
- Region: `AWS_US_WEST_2`
- Connection name: `uswest2demo`
- Role used for the build: `ACCOUNTADMIN`
- Warehouse: `COMPUTE_WH` for initial setup, then `LUMORA_WH`
- Database: `LUMORA_DEMO`

The account or role must be able to create and use:

- A database, schemas, and warehouse.
- `SNOWFLAKE.ML.FORECAST` models.
- Cortex Search services.
- Cortex Agents and custom tools.
- A semantic view.
- A Streamlit in Snowflake application and stage.

The local Snowflake CLI must have a working connection named `uswest2demo`:

```bash
snow connection list
snow sql -c uswest2demo -q "select current_account(), current_role(), current_warehouse()"
```

If authentication fails with an invalid or expired session token, refresh the Snowflake CLI authentication before running the rebuild. The SQL objects can also be executed one statement at a time through an authenticated Snowflake SQL client.

## Build The Demo

From the repository root:

```bash
./build_all.sh uswest2demo
```

The rebuild is idempotent for the main views, tables, models, services, and agent. The synthetic data is anchored to `2026-09-15` so that the storyline does not drift as the calendar advances.

`build_all.sh` does not deploy Streamlit. Deployment is separate because the deployment script uses local-file `PUT` commands.

## Verify The Build

Run the acceptance checks after the build:

```bash
snow sql -c uswest2demo -f sql/90_acceptance.sql
```

The checks cover:

- Agreement between the KPI layer and semantic view.
- Two forecast vintages with 68 series each.
- Concentrated inventory exposure.
- The 21-day promotion timing shift.
- Forecast bias and leading demand signal behavior.
- Scenario-tool existence.
- The cross-brand DACH SKINCARE pattern.
- Policy corpus availability and residency classification.
- Separate numeric retraining and language fine-tuning procedures.
- Seven complete fallback acts.
- Illustrative-value labeling.
- Rounded unit economics used to preserve rebuild determinism.

The full rebuild was verified with `HASH_AGG(*)` checks before and after rebuilding `FACT_SALES` and `FACT_INVENTORY`. Both tables were bit-identical after the deterministic rounding fix.

## Deploy The Streamlit App

The deployed app is:

```text
LUMORA_DEMO.APP.LUMORA_COCKPIT
```

The verified app URL is:

```text
https://app.snowflake.com/SFSEEUROPE/USWEST2DEMO/streamlit-apps/LUMORA_DEMO.APP.LUMORA_COCKPIT
```

Deploy from the repository root with a client that can read local files:

```bash
snow sql -c uswest2demo -f sql/50_deploy_streamlit.sql
```

The script creates or updates:

- Stage: `LUMORA_DEMO.APP.APP_STAGE`
- Streamlit app: `LUMORA_DEMO.APP.LUMORA_COCKPIT`
- Query warehouse: `LUMORA_WH`
- Main file: `lumora_app.py`

If an existing Streamlit app already has a live version, `ADD LIVE VERSION FROM LAST` may be rejected by the lifecycle state. In that case, upload the files with `PUT ... OVERWRITE = TRUE` and recreate the Streamlit object, or use the current Streamlit version-management command supported by the target account.

## Important Tool Contract

The five agent tools are stored procedures that return a single-cell `VARIANT`. They are not table functions. Call them with `CALL`, not `SELECT * FROM TABLE(...)`.

```sql
CALL LUMORA_DEMO.AGENT.GET_LUMORA_KPIS('Aurelia', 'DACH', 'SKINCARE');
CALL LUMORA_DEMO.AGENT.EXPLAIN_FORECAST_VARIANCE('Aurelia', 'DACH', 'SKINCARE');
CALL LUMORA_DEMO.AGENT.RUN_DEMAND_SCENARIO('Aurelia', 'DACH', 'SKINCARE', 12, 4);
CALL LUMORA_DEMO.AGENT.REQUEST_FORECAST_RETRAINING(
  'CFO Demo User',
  'Add promotion timing as a forecast feature',
  'Aurelia', 'DACH', 'SKINCARE'
);
CALL LUMORA_DEMO.AGENT.REQUEST_AGENT_FINE_TUNING(
  'CFO Demo User',
  'The explanation is missing promotion timing as a driver.',
  TRUE
);
```

The return shapes are:

- `GET_LUMORA_KPIS`: one JSON object.
- `EXPLAIN_FORECAST_VARIANCE`: a JSON array of ranked driver objects.
- `RUN_DEMAND_SCENARIO`: one JSON object.
- `REQUEST_FORECAST_RETRAINING`: one JSON object with a request ID and pre-staged evaluation comparison.
- `REQUEST_AGENT_FINE_TUNING`: one JSON object with a job ID, captured feedback, and pre-staged base-versus-tuned responses.

## Key Snowflake Objects

### Executive and risk views

- `LUMORA_DEMO.APP.V_KPI_EXEC`: one-row executive KPI summary.
- `LUMORA_DEMO.APP.V_SLICE_RISK`: one row per brand, region, and category.
- `LUMORA_DEMO.APP.V_BRAND_RISK_HEATMAP`: brand-by-region risk aggregation.
- `LUMORA_DEMO.APP.V_ACTUAL_VS_FORECAST`: chart-ready actuals and forecast vintages.
- `LUMORA_DEMO.APP.V_WHAT_CHANGED`: current forecast versus prior plan.
- `LUMORA_DEMO.APP.V_ASSUMPTIONS`: explicit markdown-rate and illustrative-value assumptions.
- `LUMORA_DEMO.APP.SV_LUMORA_EXEC`: governed semantic view.

### Agent and governance objects

- `LUMORA_DEMO.AGENT.LUMORA_VALUE_AGENT`: Cortex Agent.
- `LUMORA_DEMO.AGENT.LUMORA_POLICY_SEARCH`: Cortex Search service.
- `LUMORA_DEMO.AGENT.DOC_POLICY_AND_STAKEHOLDER_NOTES`: synthetic policy and stakeholder corpus.
- `LUMORA_DEMO.AGENT.DEMO_FALLBACK`: seven deterministic fallback answers.
- `LUMORA_DEMO.AGENT.PRESTAGED_RETRAIN_RESULT`: candidate numeric-model comparison.
- `LUMORA_DEMO.AGENT.PRESTAGED_FINETUNE_COMPARISON`: base-versus-tuned explanation comparison.

## What Is Live Versus Pre-Staged

Live in the demo:

- Deterministic synthetic data and SQL calculations.
- Two Snowflake ML forecast vintages.
- KPI, variance, and scenario procedures.
- Cortex Search policy retrieval.
- Cortex Agent orchestration.
- Streamlit visualizations and tool trace.
- Feedback and request records.

Pre-staged for timing and reliability:

- The candidate forecast retraining evaluation.
- The base-versus-tuned language response comparison.

The pre-staged results are deliberately labeled in the app, SQL comments, deck, and presenter script. They demonstrate the workflow without waiting for a training job during the presentation.

## Troubleshooting

### The app shows fallback answers

This is an expected safety path if the live agent call is unavailable. The fallback answers come from `LUMORA_DEMO.AGENT.DEMO_FALLBACK` and include evidence, assumptions, tools, and recommendations. Confirm the app can read `LUMORA_DEMO.APP.V_KPI_EXEC` and `LUMORA_DEMO.AGENT.DEMO_FALLBACK`.

### A tool returns no rows

Use `CALL`, not a table-function query. Confirm the procedure signature:

```sql
SHOW PROCEDURES IN SCHEMA LUMORA_DEMO.AGENT;
```

Then test the procedure directly with the examples above.

### The Streamlit app cannot find the files

Check the stage:

```sql
LIST @LUMORA_DEMO.APP.APP_STAGE/lumora_cockpit/;
```

The stage should contain `lumora_app.py` and `environment.yml`. Re-run the `PUT` commands from the repository root if necessary.

### The forecast model fails to train

Confirm that the target account supports `SNOWFLAKE.ML.FORECAST`, that `LUMORA_WH` is available, and that `LUMORA_DEMO.CORE.FACT_SALES` contains the expected daily history. The build uses 68 daily series and the `fast` forecast method to fit a hackathon-sized build.

### The finance numbers are questioned

Do not defend the numbers as real financials. Say that they are deterministic synthetic values used to demonstrate the workflow. The business meaning of each metric is explained in `DEMO_SCRIPT.md`.

## Presentation Assets

Open the deck directly in a browser:

```bash
open pitch/lumora.html
```

Use `DEMO_SCRIPT.md` alongside the deck and Streamlit app. The script gives exact presenter wording, finance definitions, fallback instructions, and audience questions.
