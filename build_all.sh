#!/usr/bin/env bash
# =====================================================================
# Lumora Value Loop demo — full rebuild from scratch.
#
#   ./build_all.sh [connection_name]
#
# Every script is idempotent (CREATE OR REPLACE), and the synthetic data
# is deterministic (HASH-derived, no RANDOM()), so a rebuild reproduces
# the identical numbers the demo storyline quotes.
#
# Order matters: facts depend on dimensions, the forecast depends on
# FACT_SALES, the KPI views depend on the forecast, and the fallback
# answers are generated from the KPI views.
# =====================================================================
set -euo pipefail

CONN="${1:-uswest2demo}"
cd "$(dirname "$0")"

SCRIPTS=(
  00_setup             # database, schemas, warehouse, demo anchor date
  10_dimensions        # brands, regions, categories, products, identities
  11_facts             # sales, inventory, promotions, signals + planted signals
  13_docs_and_search   # policy/stakeholder corpus + Cortex Search service
  20_forecast          # ML.FORECAST, two vintages, evaluation
  21_kpi_views         # one view per KPI
  22_semantic_view     # governed metric definitions
  30_agent_tools       # deterministic tools + Cortex Agent
  31_customer360       # Customer 360 RFM segments, GET_CUSTOMER_SEGMENTS, FACT_PROMOTION_BRIEF
  40_fallback          # deterministic per-act fallback answers
)

for s in "${SCRIPTS[@]}"; do
  echo "=== ${s}.sql"
  snow sql -c "$CONN" -f "sql/${s}.sql" >/dev/null
done

echo "=== deploy Streamlit app"
echo "Run sql/50_deploy_streamlit.sql (contains the PUT commands, which must"
echo "run from a client rather than a server-side session)."

echo
echo "Build complete. Verify with:"
echo "  snow sql -c $CONN -q 'SELECT * FROM LUMORA_DEMO.APP.V_KPI_EXEC'"
