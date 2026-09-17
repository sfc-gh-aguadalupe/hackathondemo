"""
Lumora Value Loop — CFO Decision Cockpit
==========================================
Streamlit in Snowflake app for the Lumora demo. Reads governed views in
LUMORA_DEMO.APP / CORE / ML and calls agent tools in LUMORA_DEMO.AGENT.
See /tmp/demo_doc.md for the full spec this app implements.
"""

import json
from datetime import datetime, timezone

import pandas as pd
import streamlit as st
import altair as alt
from snowflake.snowpark.context import get_active_session

# ---------------------------------------------------------------------------
# Page config & constants
# ---------------------------------------------------------------------------
st.set_page_config(page_title="Lumora Value Loop", layout="wide", page_icon="📊")

session = get_active_session()

DB = "LUMORA_DEMO"
AGENT_DB, AGENT_SCHEMA, AGENT_NAME = "LUMORA_DEMO", "AGENT", "LUMORA_VALUE_AGENT"

# One consistent colour per the spec: risk / forecast / confirmed evidence.
COLOR_RISK = "#C0392B"        # risk / exposure
COLOR_FORECAST = "#2E86AB"    # forecast / model output
COLOR_EVIDENCE = "#1E8449"    # confirmed evidence / observed fact
COLOR_ASSUMPTION = "#B7950B"  # assumption / uncertain
COLOR_MUTED = "#7F8C8D"

ICON_FACT = "🟢"
ICON_CALC = "🔵"
ICON_ASSUMPTION = "🟡"
ICON_RECOMMENDATION = "🟠"

ILLUSTRATIVE = "🔖 Illustrative"

SUGGESTED_QUESTIONS = [
    "Why is inventory risk highest for this brand?",
    "What changed versus last month's forecast?",
    "Which stakeholders would care about this issue?",
    "What is the lowest-risk action we can take?",
    "What would happen if demand increased 12% during the promotion?",
    "What evidence supports this recommendation?",
]

# ---------------------------------------------------------------------------
# Data access — every query cached, every one runs against governed views
# ---------------------------------------------------------------------------
@st.cache_data(ttl=300)
def q(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


@st.cache_data(ttl=300)
def load_kpi_exec() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.APP.V_KPI_EXEC")


@st.cache_data(ttl=300)
def load_slice_risk() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.APP.V_SLICE_RISK ORDER BY inventory_value_at_risk DESC")


@st.cache_data(ttl=300)
def load_heatmap() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.APP.V_BRAND_RISK_HEATMAP")


@st.cache_data(ttl=300)
def load_actual_vs_forecast() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.APP.V_ACTUAL_VS_FORECAST ORDER BY date_key")


@st.cache_data(ttl=300)
def load_what_changed() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.APP.V_WHAT_CHANGED ORDER BY ABS(delta_units) DESC")


@st.cache_data(ttl=3600)
def load_forecast_overlap_window() -> dict:
    """Return the start and end date of the window where both forecast vintages overlap.

    The prior-plan model was trained through 2026-08-15 and forecasts 60 days forward.
    The current model was trained through 2026-09-15 and forecasts 60 days forward.
    The only window where BOTH have predictions is their intersection — that is what
    'overlapping window' means in the What Changed callout.
    """
    row = q(f"""
        SELECT
            GREATEST(
                MIN(CASE WHEN forecast_vintage='PRIOR_PLAN' THEN forecast_date END),
                MIN(CASE WHEN forecast_vintage='CURRENT'    THEN forecast_date END)
            )::VARCHAR AS overlap_start,
            LEAST(
                MAX(CASE WHEN forecast_vintage='PRIOR_PLAN' THEN forecast_date END),
                MAX(CASE WHEN forecast_vintage='CURRENT'    THEN forecast_date END)
            )::VARCHAR AS overlap_end,
            MIN(CASE WHEN forecast_vintage='PRIOR_PLAN' THEN trained_through_date END)::VARCHAR AS prior_trained_through,
            MIN(CASE WHEN forecast_vintage='CURRENT'    THEN trained_through_date END)::VARCHAR AS current_trained_through
        FROM {DB}.ML.FACT_FORECAST
    """)
    if row.empty:
        return {"overlap_start": "2026-09-16", "overlap_end": "2026-10-14",
                "prior_trained_through": "2026-08-15", "current_trained_through": "2026-09-15"}
    return row.iloc[0].to_dict()


@st.cache_data(ttl=300)
def load_cross_brand() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.APP.V_CROSS_BRAND_CUSTOMERS")


@st.cache_data(ttl=300)
def load_assumptions() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.APP.V_ASSUMPTIONS")


@st.cache_data(ttl=300)
def load_customer_rfm(brand: str, region: str) -> pd.DataFrame:
    b_filter = "" if (not brand or brand in ("All", "")) else f"AND brand_name ILIKE '{brand}'"
    r_filter = "" if (not region or region in ("All", "")) else f"AND region_code ILIKE '{region}'"
    return q(f"""
        SELECT customer_group_id, brand_name, region_code, rfm_segment,
               sensitivity_class, data_residency_zone, is_eu,
               recency_months, total_orders, total_revenue,
               is_cross_brand, r_score, f_score, m_score, rfm_total
        FROM {DB}.AGENT.V_CUSTOMER_RFM
        WHERE 1=1 {b_filter} {r_filter}
    """)


@st.cache_data(ttl=300)
def load_promotion_briefs() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.AGENT.FACT_PROMOTION_BRIEF ORDER BY created_at DESC LIMIT 20")


@st.cache_data(ttl=300)
def load_fallback() -> pd.DataFrame:
    return q(f"SELECT * FROM {DB}.AGENT.DEMO_FALLBACK ORDER BY act_no")


@st.cache_data(ttl=300)
def load_promotions(brand_id, region, category) -> pd.DataFrame:
    return q(f"""
        SELECT promo_name, planned_start, planned_end, actual_start, actual_end,
               uplift_factor, timing_changed
        FROM {DB}.CORE.FACT_PROMOTIONS
        WHERE brand_id = {int(brand_id)} AND region_code = '{region}' AND category_code = '{category}'
        ORDER BY planned_start
    """)


@st.cache_data(ttl=300)
def load_customer_activity(brand_id, region) -> pd.DataFrame:
    return q(f"""
        SELECT activity_month, SUM(orders) AS orders, SUM(revenue_amount) AS revenue_amount
        FROM {DB}.CORE.FACT_CUSTOMER_ACTIVITY
        WHERE brand_id = {int(brand_id)} AND region_code = '{region}'
        GROUP BY 1 ORDER BY 1
    """)


@st.cache_data(ttl=300)
def load_channel_mix(brand_id, region, category) -> pd.DataFrame:
    return q(f"""
        SELECT channel, SUM(units_sold) AS units_sold, SUM(revenue_amount) AS revenue_amount
        FROM {DB}.CORE.FACT_SALES
        WHERE brand_id = {int(brand_id)} AND region_code = '{region}' AND category_code = '{category}'
        GROUP BY 1 ORDER BY 1
    """)


@st.cache_data(ttl=300)
def load_recent_velocity(brand_id, region, category) -> pd.DataFrame:
    return q(f"""
        SELECT sales_date, SUM(units_sold) AS units_sold
        FROM {DB}.CORE.FACT_SALES
        WHERE brand_id = {int(brand_id)} AND region_code = '{region}' AND category_code = '{category}'
          AND sales_date >= DATEADD(day, -60, (SELECT demo_asof_date FROM {DB}.CORE.DEMO_CONFIG))
        GROUP BY 1 ORDER BY 1
    """)


@st.cache_data(ttl=300)
def load_customer_identity(region) -> pd.DataFrame:
    return q(f"""
        SELECT data_residency_zone, sensitivity_class, COUNT(DISTINCT customer_group_id) AS customer_groups
        FROM {DB}.CORE.DIM_CUSTOMER_IDENTITY
        WHERE region_code = '{region}'
        GROUP BY 1, 2
    """)


@st.cache_data(ttl=300)
def search_policy_docs(query: str, limit: int = 3):
    try:
        from snowflake.core import Root
        root = Root(session)
        svc = (
            root.databases[DB].schemas["AGENT"].cortex_search_services["LUMORA_POLICY_SEARCH"]
        )
        res = svc.search(query, columns=["doc_id", "doc_title", "doc_owner", "region_scope", "doc_body"], limit=limit)
        return res.results
    except Exception:
        return []


def call_tool_procedure(proc_call: str):
    """Run a governed AGENT-schema stored procedure (CALL ...); return None on failure."""
    try:
        row = session.sql(proc_call).collect()
        if row:
            return row[0][0]
    except Exception as e:
        return {"error": str(e)}
    return None


def _sql_str(a):
    return "NULL" if a is None else "'" + str(a).replace("'", "''") + "'"


def call_tool(fqn: str, raw_args: list):
    """Call a governed AGENT-schema tool procedure.

    All five tools are stored procedures returning a single-cell VARIANT:
    an OBJECT for scalar results (KPIs, scenario, request status) and an
    ARRAY of OBJECTs for ranked results (variance drivers). Cortex Agent
    custom tools reject multi-column result sets, which is why the tools
    return VARIANT rather than TABLE(...).

    Returns a dict, a list of dicts, or None if the call failed.
    """
    arg_str = ", ".join(raw_args)
    try:
        rows = session.sql(f"CALL {fqn}({arg_str})").collect()
    except Exception:
        return None
    if not rows or rows[0][0] is None:
        return None
    payload = rows[0][0]
    if isinstance(payload, (dict, list)):
        return payload
    try:
        return json.loads(payload)
    except (ValueError, TypeError):
        return None


def call_tool_df(fqn: str, raw_args: list) -> pd.DataFrame:
    """Same call, shaped as a DataFrame for direct rendering."""
    payload = call_tool(fqn, raw_args)
    if isinstance(payload, list) and payload:
        return pd.DataFrame(payload)
    if isinstance(payload, dict):
        return pd.DataFrame([payload])
    return pd.DataFrame()


def fallback_for_act(act_no: int) -> dict:
    df = load_fallback()
    hit = df[df["ACT_NO"] == act_no]
    if hit.empty:
        return {}
    return hit.iloc[0].to_dict()


import re as _re
def _safe_md(text: str) -> str:
    """Escape bare $ signs used as currency before passing to st.markdown.

    Streamlit renders $...$ as LaTeX math. A currency amount like $101.2K gets
    treated as a LaTeX expression and renders garbled (each character on its own
    line). This replaces leading $ currency markers with \\$ so they render as
    a literal dollar sign, while leaving double-dollar ($$) block math alone.
    """
    # Replace $ followed by a digit, comma, or decimal point (currency pattern)
    # but not $$ (LaTeX block math) and not \$ (already escaped).
    return _re.sub(r'(?<!\\)(?<!\$)\$(?=[\d,.])', r'\\$', text)

def render_chart_interpretation(avf_df: pd.DataFrame, slice_data=None, compact: bool = False):
    """Render a data-driven 'how to read this chart' panel below any actual-vs-forecast chart.

    avf_df  : the chart dataframe (DATE_KEY, ACTUAL_UNITS, FORECAST_UNITS,
              FORECAST_LOWER, FORECAST_UPPER, PRIOR_PLAN_UNITS).
    slice_data : a pandas Series row from V_SLICE_RISK (optional; used for cover/bias metrics).
    compact : if True, render as a collapsed expander rather than an open info block.
    """
    if avf_df is None or avf_df.empty:
        return

    # ── Normalise dates so all comparisons are timezone-naive datetime64 ──────
    df = avf_df.copy()
    df["DATE_KEY"] = pd.to_datetime(df["DATE_KEY"])
    anchor = pd.Timestamp("2026-09-15")

    hist = df[df["DATE_KEY"] <= anchor]
    fwd  = df[df["DATE_KEY"] >  anchor]

    # ── Compute the three daily averages that explain the gap ─────────────────
    pre_break  = hist[hist["DATE_KEY"] < pd.Timestamp("2026-07-21")]["ACTUAL_UNITS"].mean()
    post_break = hist[hist["DATE_KEY"] >= pd.Timestamp("2026-07-21")]["ACTUAL_UNITS"].mean()
    pp_fwd     = fwd["PRIOR_PLAN_UNITS"].mean()    if not fwd.empty and "PRIOR_PLAN_UNITS"  in fwd else None
    fc_fwd     = fwd["FORECAST_UNITS"].mean()      if not fwd.empty and "FORECAST_UNITS"    in fwd else None

    has_gap = pp_fwd is not None and fc_fwd is not None and pp_fwd > 0
    gap_pct = round(100.0 * (fc_fwd - pp_fwd) / pp_fwd, 0) if has_gap else None

    # ── Cover and bias from V_SLICE_RISK row (if provided) ────────────────────
    cover_days  = float(slice_data["COVER_DAYS"])  if slice_data is not None and "COVER_DAYS"  in slice_data.index else None
    target_days = float(slice_data["TARGET_COVER_DAYS"]) if slice_data is not None and "TARGET_COVER_DAYS" in slice_data.index else 45.0
    bias_pct    = float(slice_data["BIAS_PCT"])    if slice_data is not None and "BIAS_PCT"    in slice_data.index else None

    # ── Build the panel ───────────────────────────────────────────────────────
    label = "📊 How to read this chart" if not compact else "📊 Chart interpretation"
    with st.expander(label, expanded=not compact):

        # Legend key — mirrors the visual colours
        lcol1, lcol2, lcol3, lcol4 = st.columns(4)
        lcol1.markdown(f"<span style='color:{COLOR_EVIDENCE}'>━━</span> &nbsp;**Actuals**<br>"
                       f"<small>historical daily demand</small>", unsafe_allow_html=True)
        lcol2.markdown(f"<span style='color:{COLOR_FORECAST}'>━━</span> &nbsp;**Current forecast**<br>"
                       f"<small>new model, trained Sep 15</small>", unsafe_allow_html=True)
        lcol3.markdown(f"<span style='color:{COLOR_MUTED}'>╌╌</span> &nbsp;**Prior plan**<br>"
                       f"<small>last month's model</small>", unsafe_allow_html=True)
        lcol4.markdown(f"<span style='color:{COLOR_FORECAST}; opacity:0.4'>▓▓</span> &nbsp;**Confidence band**<br>"
                       f"<small>90% prediction interval</small>", unsafe_allow_html=True)

        st.divider()

        # ── Gap 1: the demand break ───────────────────────────────────────────
        if not hist.empty and pre_break > 0 and not pd.isna(pre_break) and not pd.isna(post_break):
            drop_pct = round(100.0 * (post_break - pre_break) / pre_break, 0)
            st.markdown(f"**{ICON_FACT} Gap 1 — the demand break (green line collapses ~August)**")
            st.markdown(
                f"Before the break, this slice ran at roughly **{pre_break:,.0f} units/day**. "
                f"After the break it averaged roughly **{post_break:,.0f} units/day** — "
                f"a fall of about **{abs(drop_pct):.0f}%**. "
                f"This happened because the promotion ran ~21 days earlier than planned, "
                f"pulling demand forward into August. When September arrived, the uplift "
                f"the plan expected had already been spent."
            )
        else:
            st.markdown(f"**{ICON_FACT} Gap 1 — the demand break**")
            st.markdown("The green line shows historical actual demand. A downward shift indicates "
                        "the demand break driven by the early promotion.")

        st.markdown("")

        # ── Gap 2: prior plan vs current forecast ─────────────────────────────
        if has_gap:
            st.markdown(f"**{ICON_CALC} Gap 2 — last month's plan vs the current forecast (grey vs blue)**")
            direction = "lower" if gap_pct < 0 else "higher"
            st.markdown(
                f"The grey dashed line — last month's plan — continues forward at roughly "
                f"**{pp_fwd:,.0f} units/day**. The new blue line sits at roughly "
                f"**{fc_fwd:,.0f} units/day** — **{abs(gap_pct):.0f}% {direction}**. "
                f"This is the gap that generates the inventory exposure: "
                f"stock was bought to support the grey level, but the current model "
                f"expects only the blue level."
            )
            if cover_days and bias_pct:
                st.markdown(
                    f"{ICON_ASSUMPTION} The prior plan over-forecast this slice by "
                    f"**{bias_pct:+.1f}%** in the evaluation window, leaving "
                    f"**{cover_days:.1f} days** of cover against a {target_days:.0f}-day target."
                )
        else:
            st.markdown(f"**{ICON_CALC} Gap 2 — prior plan vs current forecast**")
            st.markdown("Compare the grey dashed line (last month's expectation) with the blue solid "
                        "line (new model). The gap between them is where the inventory exposure lives.")

        st.markdown("")

        # ── Confidence band ───────────────────────────────────────────────────
        st.markdown(f"**{ICON_ASSUMPTION} The wide blue band — honest uncertainty**")
        st.markdown(
            "The shaded area is the 90% prediction interval: the model expects 9 in 10 "
            "outcomes to fall within it. The band is wide here because the model is "
            "extrapolating beyond a structural demand break with limited post-break history. "
            "A narrow band after a break would be false confidence."
        )

        st.divider()
        st.caption(
            f"{ICON_RECOMMENDATION} **Decision implication:** "
            "the gap between the grey plan and the blue forecast is the quantity the "
            "business bought but may not sell. That is the inventory exposure on the KPI "
            "cards — not a predicted loss, but an action trigger."
        )


# ---------------------------------------------------------------------------
# Cortex Agent invocation via _snowflake.send_snow_api_request
# ---------------------------------------------------------------------------
def run_agent(question: str, timeout_ms: int = 50000):
    """Call the LUMORA_VALUE_AGENT agent object. Returns (content_blocks, error)."""
    try:
        import _snowflake
    except ImportError:
        return None, "not_in_sis"

    url = f"/api/v2/databases/{AGENT_DB}/schemas/{AGENT_SCHEMA}/agents/{AGENT_NAME}:run"
    payload = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
        "stream": False,
    }
    try:
        resp = _snowflake.send_snow_api_request(
            "POST", url, {}, {}, payload, None, timeout_ms
        )
        if resp.get("status") != 200:
            return None, f"HTTP {resp.get('status')}: {resp.get('content')}"
        content = json.loads(resp["content"])
        return content.get("content", []), None
    except Exception as e:
        return None, str(e)


def summarize_agent_trace(content_blocks):
    """Extract tool-use / tool-result / final text from an agent response for the trace panel."""
    tools_used, sources, final_text = [], [], []
    for block in content_blocks or []:
        btype = block.get("type")
        if btype == "tool_use":
            tu = block.get("tool_use", {})
            tools_used.append(tu.get("name", "unknown_tool"))
        elif btype == "tool_result":
            tr = block.get("tool_result", {})
            sources.append({"tool": tr.get("name"), "status": tr.get("status")})
        elif btype == "text":
            final_text.append(block.get("text", ""))
    return "\n\n".join(final_text), tools_used, sources


# ===========================================================================
# HEADER
# ===========================================================================
st.title("📊 Lumora Value Loop — CFO Decision Cockpit")
st.caption(
    "A governed retail decision loop: data foundation → forecast → explanation → scenario → decision → feedback. "
    "All financial figures are **illustrative** and derived from synthetic unit economics."
)

kpi = load_kpi_exec()
assumptions = load_assumptions()
kpi_row = kpi.iloc[0] if not kpi.empty else None

tabs = st.tabs([
    "1️⃣ CFO Cockpit",
    "2️⃣ Forecast Explorer",
    "3️⃣ Customer & Demand Drill-Down",
    "4️⃣ Agent Decision Panel",
    "5️⃣ Model Improvement",
    "6️⃣ Customer 360 & Promotion Builder",
])

# ===========================================================================
# AREA 1 — CFO COCKPIT
# ===========================================================================
with tabs[0]:
    if kpi_row is None:
        st.warning("No KPI data available.")
    else:
        st.markdown(f"**{ILLUSTRATIVE}** — {kpi_row['VALUE_DISCLAIMER']}")
        c1, c2, c3, c4, c5, c6 = st.columns(6)
        c1.metric("Inventory value at risk", f"€{kpi_row['INVENTORY_VALUE_AT_RISK']:,.0f}")
        c2.metric("Forecast WAPE / Bias", f"{kpi_row['FORECAST_WAPE_PCT']:.1f}% / {kpi_row['FORECAST_BIAS_PCT']:+.1f}%")
        c3.metric("Stockout margin at risk", f"€{kpi_row['STOCKOUT_MARGIN_AT_RISK']:,.0f}")
        c4.metric("Markdown exposure", f"€{kpi_row['MARKDOWN_EXPOSURE']:,.0f}")
        c5.metric("Cross-brand coverage", f"{kpi_row['CROSS_BRAND_COVERAGE_PCT']:.1f}%")
        refresh_age = kpi_row['FORECAST_GENERATED_AT']
        c6.metric("Forecast refresh", pd.to_datetime(str(refresh_age)).strftime("%Y-%m-%d %H:%M") if refresh_age is not None else "n/a")

        st.caption(
            f"Governance: model version `{kpi_row['MODEL_VERSION']}` · trained through `{kpi_row['TRAINED_THROUGH_DATE']}` "
            f"· {int(kpi_row['SLICE_COUNT'])} brand×region×category slices · {int(kpi_row['OVERSTOCKED_SLICES'])} overstocked · "
            f"{int(kpi_row['STOCKOUT_SLICES'])} at stockout risk."
        )

        st.divider()
        left, right = st.columns([1, 1])

        # --- Brand x region risk heatmap -----------------------------------
        with left:
            st.subheader("Brand × region risk heatmap")
            hm = load_heatmap()
            if not hm.empty:
                chart = (
                    alt.Chart(hm)
                    .mark_rect()
                    .encode(
                        x=alt.X("REGION_CODE:N", title="Region"),
                        y=alt.Y("BRAND_NAME:N", title="Brand"),
                        color=alt.Color("INVENTORY_VALUE_AT_RISK:Q", title="Value at risk (€, illustrative)",
                                         scale=alt.Scale(scheme="reds")),
                        tooltip=["BRAND_NAME", "REGION_CODE", "DATA_RESIDENCY_ZONE",
                                 "INVENTORY_VALUE_AT_RISK", "MARKDOWN_EXPOSURE", "BIAS_PCT"],
                    )
                    .properties(height=320)
                )
                st.altair_chart(chart, use_container_width=True)
            else:
                st.info("No heatmap data.")

        # --- Inventory risk waterfall ---------------------------------------
        with right:
            st.subheader("Inventory risk composition (waterfall)")
            sr = load_slice_risk()
            if not sr.empty:
                top_n = sr.nlargest(6, "INVENTORY_VALUE_AT_RISK")[["BRAND_NAME", "REGION_CODE", "CATEGORY_CODE", "INVENTORY_VALUE_AT_RISK"]].copy()
                other_val = sr["INVENTORY_VALUE_AT_RISK"].sum() - top_n["INVENTORY_VALUE_AT_RISK"].sum()
                top_n["LABEL"] = top_n["BRAND_NAME"] + " · " + top_n["REGION_CODE"] + " · " + top_n["CATEGORY_CODE"]
                wf = pd.concat([
                    top_n[["LABEL", "INVENTORY_VALUE_AT_RISK"]],
                    pd.DataFrame([{"LABEL": "All other slices", "INVENTORY_VALUE_AT_RISK": max(other_val, 0)}]),
                ])
                wf["cum_end"] = wf["INVENTORY_VALUE_AT_RISK"].cumsum()
                wf["cum_start"] = wf["cum_end"] - wf["INVENTORY_VALUE_AT_RISK"]
                chart = (
                    alt.Chart(wf)
                    .mark_bar(color=COLOR_RISK)
                    .encode(
                        x=alt.X("LABEL:N", sort=None, title=None),
                        y=alt.Y("cum_start:Q", title="Cumulative value at risk (€, illustrative)"),
                        y2="cum_end:Q",
                        tooltip=["LABEL", "INVENTORY_VALUE_AT_RISK"],
                    )
                    .properties(height=320)
                )
                st.altair_chart(chart, use_container_width=True)
            else:
                st.info("No slice-risk data.")

        st.divider()
        st.subheader("Actual vs. forecast — top risk slice")
        if not sr.empty:
            top_slice = sr.iloc[0]
            avf = load_actual_vs_forecast()
            avf_slice = avf[
                (avf["BRAND_ID"] == top_slice["BRAND_ID"])
                & (avf["REGION_CODE"] == top_slice["REGION_CODE"])
                & (avf["CATEGORY_CODE"] == top_slice["CATEGORY_CODE"])
            ]
            if not avf_slice.empty:
                base = alt.Chart(avf_slice).encode(x=alt.X("DATE_KEY:T", title="Date"))
                band = base.mark_area(opacity=0.2, color=COLOR_FORECAST).encode(
                    y="FORECAST_LOWER:Q", y2="FORECAST_UPPER:Q"
                )
                fc_line = base.mark_line(color=COLOR_FORECAST).encode(y=alt.Y("FORECAST_UNITS:Q", title="Units"))
                actual_line = base.mark_line(color=COLOR_EVIDENCE, strokeWidth=2).encode(y="ACTUAL_UNITS:Q")
                prior_line = base.mark_line(color=COLOR_MUTED, strokeDash=[4, 4]).encode(y="PRIOR_PLAN_UNITS:Q")
                st.altair_chart((band + fc_line + actual_line + prior_line).properties(height=320),
                                 use_container_width=True)
                st.caption(f"{COLOR_EVIDENCE}●  actuals  ·  {COLOR_FORECAST}●  current forecast + interval  ·  "
                           f"{COLOR_MUTED}●  prior month's plan  —  {top_slice['BRAND_NAME']} / {top_slice['REGION_CODE']} / {top_slice['CATEGORY_CODE']}")
                render_chart_interpretation(avf_slice, slice_data=top_slice, compact=False)

        st.subheader('💬 "What changed?"')
        wc = load_what_changed()
        ow = load_forecast_overlap_window()

        # Format the window dates for display — strip the time portion if present
        def _fmt_date(d):
            return str(d).split(" ")[0].replace('"', '').strip()

        ow_start = _fmt_date(ow.get("overlap_start", "2026-09-16"))
        ow_end   = _fmt_date(ow.get("overlap_end",   "2026-10-14"))
        prior_tt = _fmt_date(ow.get("prior_trained_through",   "2026-08-15"))
        curr_tt  = _fmt_date(ow.get("current_trained_through", "2026-09-15"))

        # Explain what "overlapping window" means — show it above the callout
        with st.expander("ℹ️ What is the overlapping window?", expanded=False):
            st.markdown(
                f"Two forecast models are compared here:\n\n"
                f"| | Trained through | Forecast covers |\n"
                f"|---|---|---|\n"
                f"| **Prior plan** (grey dashed line) | {prior_tt} | {prior_tt} + 60 days |\n"
                f"| **Current model** (blue line) | {curr_tt} | {curr_tt} + 60 days |\n\n"
                f"The two ranges only overlap between **{ow_start}** and **{ow_end}** — "
                f"that 29-day window is the only period where both models have a prediction "
                f"for the same dates. Comparing them outside that window would mix a "
                f"real forecast number against a gap.\n\n"
                f"The delta shown below is the sum of *(current − prior plan)* across every "
                f"day in **{ow_start} → {ow_end}**, for each brand / region / category slice."
            )

        if not wc.empty:
            biggest = wc.iloc[0]
            direction = "down" if biggest["DELTA_PCT"] < 0 else "up"
            st.info(
                f"**{biggest['BRAND_NAME']} / {biggest['REGION_CODE']} / {biggest['CATEGORY_CODE']}** "
                f"shows the largest revision: the current forecast is "
                f"**{direction} {abs(biggest['DELTA_PCT']):.1f}%** "
                f"({biggest['DELTA_UNITS']:+,.0f} units) versus last month's plan — "
                f"measured over the overlapping window **{ow_start} → {ow_end}**."
            )
            with st.expander(f"All slices — current vs prior plan  ({ow_start} → {ow_end})"):
                st.dataframe(wc, use_container_width=True, hide_index=True)

# ===========================================================================
# AREA 2 — FORECAST EXPLORER
# ===========================================================================
with tabs[1]:
    st.subheader("Forecast explorer")
    st.caption(
        "Select a single slice or choose **All** for any dimension to see an aggregated view. "
        "Aggregation sums actual units, forecast units, and confidence band across all matching slices."
    )
    sr_all = load_slice_risk()
    if sr_all.empty:
        st.warning("No forecast data available.")
    else:
        c1, c2, c3, c4 = st.columns(4)
        ALL = "All"
        brand_name = c1.selectbox("Brand", [ALL] + sorted(sr_all["BRAND_NAME"].unique()))
        # Region and category options are independent when an upstream is "All"
        region_pool = sr_all if brand_name == ALL else sr_all[sr_all["BRAND_NAME"] == brand_name]
        region = c2.selectbox("Region", [ALL] + sorted(region_pool["REGION_CODE"].unique()))
        cat_pool = region_pool if region == ALL else region_pool[region_pool["REGION_CODE"] == region]
        category = c3.selectbox("Category", [ALL] + sorted(cat_pool["CATEGORY_CODE"].unique()))
        horizon = c4.selectbox("Horizon (days)", [30, 45, 60], index=1)

        # ── Resolve aggregation scope ─────────────────────────────────────
        is_agg = (brand_name == ALL or region == ALL or category == ALL)
        scope_label = " / ".join([
            brand_name if brand_name != ALL else "All brands",
            region    if region    != ALL else "All regions",
            category  if category  != ALL else "All categories",
        ])
        if is_agg:
            st.info(
                f"**Aggregated view: {scope_label}** — "
                f"units, forecast and confidence band are summed across all matching slices. "
                f"Bias and cover days are volume-weighted averages. {ILLUSTRATIVE}."
            )

        # ── Filter V_SLICE_RISK to matching rows ──────────────────────────
        smask = pd.Series([True] * len(sr_all), index=sr_all.index)
        if brand_name != ALL: smask &= sr_all["BRAND_NAME"]   == brand_name
        if region     != ALL: smask &= sr_all["REGION_CODE"]  == region
        if category   != ALL: smask &= sr_all["CATEGORY_CODE"] == category
        matching_slices = sr_all[smask]

        if not matching_slices.empty:
            # For single slice, keep the row; for aggregated, synthesise a summary row
            if not is_agg:
                slice_row = matching_slices.iloc[0]
                gov_caption = (
                    f"**Model version:** `{slice_row['MODEL_VERSION']}`  ·  "
                    f"**Last refresh:** `{slice_row['FORECAST_GENERATED_AT']}`  ·  "
                    f"**Residency:** {slice_row['DATA_RESIDENCY_ZONE']}  ·  "
                    f"**Source system:** {slice_row['SOURCE_SYSTEM']}"
                )
            else:
                # Build an aggregated pseudo-row for metrics
                agg_actual  = matching_slices["EVAL_ACTUAL_UNITS"].sum()
                agg_fcast   = matching_slices["EVAL_FORECAST_UNITS"].sum()
                agg_ivar    = matching_slices["INVENTORY_VALUE_AT_RISK"].sum()
                agg_excess  = matching_slices["EXCESS_UNITS"].sum()
                agg_bias    = 100.0 * (agg_fcast - agg_actual) / agg_actual if agg_actual else 0
                agg_wape    = 100.0 * (matching_slices["EVAL_FORECAST_UNITS"] - matching_slices["EVAL_ACTUAL_UNITS"]).abs().sum() / agg_actual if agg_actual else 0
                agg_cover   = matching_slices["COVER_DAYS"].mean()
                slice_row   = pd.Series({
                    "MODEL_VERSION": matching_slices["MODEL_VERSION"].iloc[0],
                    "FORECAST_GENERATED_AT": matching_slices["FORECAST_GENERATED_AT"].iloc[0],
                    "DATA_RESIDENCY_ZONE": "Multiple" if matching_slices["DATA_RESIDENCY_ZONE"].nunique() > 1 else matching_slices["DATA_RESIDENCY_ZONE"].iloc[0],
                    "SOURCE_SYSTEM": "Multiple" if matching_slices["SOURCE_SYSTEM"].nunique() > 1 else matching_slices["SOURCE_SYSTEM"].iloc[0],
                    "BIAS_PCT": round(agg_bias, 2),
                    "WAPE_PCT": round(agg_wape, 2),
                    "COVER_DAYS": round(agg_cover, 1),
                    "TARGET_COVER_DAYS": 45,
                    "INVENTORY_VALUE_AT_RISK": round(agg_ivar, 2),
                    "EXCESS_UNITS": round(agg_excess, 0),
                })
                gov_caption = (
                    f"**{len(matching_slices)} slices**  ·  "
                    f"**Model version:** `{slice_row['MODEL_VERSION']}`  ·  "
                    f"**Residency zones:** {matching_slices['DATA_RESIDENCY_ZONE'].unique().tolist()}  ·  "
                    f"**Source systems:** {matching_slices['SOURCE_SYSTEM'].unique().tolist()}"
                )

            st.caption(gov_caption)

            # ── Aggregated KPI summary bar (aggregated view only) ──────────
            if is_agg:
                k1, k2, k3, k4 = st.columns(4)
                k1.metric(f"Inventory value at risk ({scope_label})",
                           f"€{slice_row['INVENTORY_VALUE_AT_RISK']:,.0f}",
                           help=f"Sum across {len(matching_slices)} slices. {ILLUSTRATIVE}.")
                k2.metric("Aggregated forecast bias",
                           f"{slice_row['BIAS_PCT']:+.1f}%",
                           help="Volume-weighted: positive = the plan over-forecast demand.")
                k3.metric("Aggregated WAPE",
                           f"{slice_row['WAPE_PCT']:.1f}%",
                           help="Volume-weighted absolute error across all matching slices.")
                k4.metric("Avg cover days",
                           f"{slice_row['COVER_DAYS']:.0f}d",
                           delta=f"{slice_row['COVER_DAYS'] - 45:+.0f}d vs 45d policy",
                           delta_color="inverse")

            # ── Filter and aggregate the actual-vs-forecast dataframe ─────
            avf = load_actual_vs_forecast()
            avf["DATE_KEY"] = pd.to_datetime(avf["DATE_KEY"])
            amask = pd.Series([True] * len(avf), index=avf.index)
            if brand_name != ALL: amask &= avf["BRAND_NAME"]   == brand_name
            if region     != ALL: amask &= avf["REGION_CODE"]  == region
            if category   != ALL: amask &= avf["CATEGORY_CODE"] == category
            avf_filtered = avf[amask].copy()

            if is_agg:
                num_cols = ["ACTUAL_UNITS", "FORECAST_UNITS",
                            "FORECAST_LOWER", "FORECAST_UPPER", "PRIOR_PLAN_UNITS"]
                avf_slice = avf_filtered.groupby("DATE_KEY", as_index=False)[num_cols].sum()
            else:
                avf_slice = avf_filtered.copy()

            cutoff = pd.Timestamp("2026-09-15") - pd.Timedelta(days=horizon)
            avf_slice = avf_slice[avf_slice["DATE_KEY"] >= cutoff]

            if not avf_slice.empty:
                base = alt.Chart(avf_slice).encode(x=alt.X("DATE_KEY:T", title="Date"))
                band       = base.mark_area(opacity=0.2, color=COLOR_FORECAST).encode(y="FORECAST_LOWER:Q", y2="FORECAST_UPPER:Q")
                fc_line    = base.mark_line(color=COLOR_FORECAST).encode(y=alt.Y("FORECAST_UNITS:Q", title="Units" + (" (aggregated)" if is_agg else "")))
                actual_line= base.mark_line(color=COLOR_EVIDENCE, strokeWidth=2).encode(y="ACTUAL_UNITS:Q")
                prior_line = base.mark_line(color=COLOR_MUTED, strokeDash=[4, 4]).encode(y="PRIOR_PLAN_UNITS:Q")
                st.altair_chart(
                    (band + fc_line + actual_line + prior_line).properties(
                        height=350,
                        title=f"Actual vs forecast — {scope_label}" + (" (sum)" if is_agg else "")
                    ),
                    use_container_width=True
                )
                st.caption(
                    f"{COLOR_EVIDENCE}●  history/actuals  ·  "
                    f"{COLOR_FORECAST}●  current forecast + interval  ·  "
                    f"{COLOR_MUTED}●  prior month's plan"
                    + (f"  ·  {len(matching_slices)} slices aggregated" if is_agg else "")
                )
                render_chart_interpretation(avf_slice, slice_data=slice_row, compact=True)

            if not is_agg:
                st.markdown("##### Top drivers / explanatory signals")
                drivers_df = call_tool_df(
                    f"{DB}.AGENT.EXPLAIN_FORECAST_VARIANCE",
                    [_sql_str(brand_name), _sql_str(region), _sql_str(category)],
                )
                if not drivers_df.empty:
                    if "DRIVER_RANK" in drivers_df.columns:
                        drivers_df = drivers_df.sort_values("DRIVER_RANK")
                    cols = [c for c in ["DRIVER_RANK", "DRIVER_NAME", "DRIVER_TYPE",
                                        "DRIVER_VALUE", "DRIVER_UNIT", "DRIVER_DETAIL"]
                            if c in drivers_df.columns]
                    st.dataframe(drivers_df[cols] if cols else drivers_df,
                                 use_container_width=True, hide_index=True)
                    st.caption(f"{ICON_FACT} OBSERVED_FACT rows are measured; "
                               f"{ICON_CALC} CALCULATION rows are derived in SQL. Ranked by contribution.")
                else:
                    fb = fallback_for_act(2)
                    st.caption("Live tool unavailable — showing deterministic fallback (Act 2 evidence).")
                    if fb:
                        st.markdown(f"{ICON_FACT} {_safe_md(fb.get('EVIDENCE', ''))}")
            else:
                st.info(
                    f"Driver analysis is available at the single-slice level. "
                    f"Select a specific brand, region, and category to see ranked drivers."
                )

# ===========================================================================
# AREA 3 — CUSTOMER & DEMAND DRILL-DOWN
# ===========================================================================
with tabs[2]:
    st.subheader("Customer & demand drill-down")
    st.markdown(
        "This tab provides the **underlying evidence** behind the inventory risk for any slice. "
        "It answers: *what does actual demand look like, what happened with the promotion, "
        "who are the customers, and what governance constraints apply?* "
        "Select the slice you want to investigate using the three dropdowns."
    )

    sr_all = load_slice_risk()
    if sr_all.empty:
        st.warning("No data available.")
    else:
        # ── Slice selector ──────────────────────────────────────────────────
        dd1, dd2, dd3 = st.columns(3)
        brand_name3 = dd1.selectbox("Brand", sorted(sr_all["BRAND_NAME"].unique()), key="dd_brand")
        regions3 = sorted(sr_all[sr_all["BRAND_NAME"] == brand_name3]["REGION_CODE"].unique())
        region3 = dd2.selectbox("Region", regions3, key="dd_region")
        cats3 = sorted(sr_all[(sr_all["BRAND_NAME"] == brand_name3) & (sr_all["REGION_CODE"] == region3)]["CATEGORY_CODE"].unique())
        category3 = dd3.selectbox("Category", cats3, key="dd_category")

        row3 = sr_all[(sr_all["BRAND_NAME"] == brand_name3) & (sr_all["REGION_CODE"] == region3)
                       & (sr_all["CATEGORY_CODE"] == category3)].iloc[0]
        brand_id3 = int(row3["BRAND_ID"])

        # ── Governance metadata ─────────────────────────────────────────────
        st.markdown("---")
        st.markdown("#### 🏛️ Governance metadata")
        st.caption(
            "These four fields travel with every number in this tab. They identify *whose data* "
            "it is, *which system* produced it, and *what rules* apply to it. "
            "An architect or CDAO audience will look here first."
        )
        gov1, gov2, gov3, gov4 = st.columns(4)
        gov1.metric("Region", region3,
                    help="The geographic region for this slice.")
        gov2.metric("Residency zone", row3["DATA_RESIDENCY_ZONE"],
                    help="The data residency zone determines which privacy and transfer rules apply. "
                         "EU_WEST and EU_NORTH zones are subject to EU data protection rules.")
        gov3.metric("Source system", row3["SOURCE_SYSTEM"],
                    help="The ERP or POS system that originally produced this brand's data. "
                         "Preserving this shows the data fragmentation problem the demo solves.")
        gov4.metric("EU region", "Yes" if row3["IS_EU"] else "No",
                    help="EU regions require additional governance controls before personal data "
                         "can be used for customer treatment or targeting.")

        # ── Inventory position summary ──────────────────────────────────────
        st.markdown("---")
        st.markdown("#### 📦 Inventory position for this slice")
        st.caption(
            "This is the starting position: how much stock exists, what the forecast expects, "
            "and how many days the stock will last. The excess is what the scenario simulator "
            "in the Agent panel tries to work through."
        )
        ip1, ip2, ip3, ip4, ip5 = st.columns(5)
        ip1.metric("On-hand units", f"{row3['ON_HAND_UNITS']:,.0f}",
                   help="Units physically in the warehouse.")
        ip2.metric("On-order units", f"{row3['ON_ORDER_UNITS']:,.0f}",
                   help="Units already ordered and in transit — committed spend.")
        ip3.metric("Excess units", f"{row3['EXCESS_UNITS']:,.0f}",
                   help="Stock beyond what the 45-day forecast expects to sell. "
                        "This is the quantity driving the inventory value at risk.")
        ip4.metric("Cover days", f"{row3['COVER_DAYS']:.0f}d",
                   delta=f"{row3['COVER_DAYS'] - row3['TARGET_COVER_DAYS']:+.0f}d vs {row3['TARGET_COVER_DAYS']:.0f}d target",
                   delta_color="inverse",
                   help="Available units ÷ daily forecast demand. Policy target is 45 days.")
        ip5.metric("Inventory value at risk",
                   f"€{row3['INVENTORY_VALUE_AT_RISK']:,.0f}",
                   help=f"Excess units × unit cost. {ILLUSTRATIVE}.")

        # ── Section 1: Demand signals ───────────────────────────────────────
        st.markdown("---")
        st.markdown("#### 📉 Demand signals — is demand falling, holding, or rising?")
        st.caption(
            "The sales velocity and channel mix show the *direction and shape* of demand for this slice. "
            "If velocity is trending down, it supports the over-stock story. If it is flat or rising, "
            "the excess may resolve through normal trading."
        )

        sig1, sig2 = st.columns(2)
        with sig1:
            st.markdown("**Recent sales velocity (trailing 60 days)**")
            st.caption(
                "Each point is one day's actual sales in units. A downward trend here is "
                "the demand break showing in raw sales data — the same event that caused "
                "the forecast bias."
            )
            vel = load_recent_velocity(brand_id3, region3, category3)
            if not vel.empty:
                vel_chart = alt.Chart(vel).mark_line(color=COLOR_RISK, strokeWidth=1.5).encode(
                    x=alt.X("SALES_DATE:T", title="Date"),
                    y=alt.Y("UNITS_SOLD:Q", title="Units sold per day"),
                    tooltip=["SALES_DATE:T", "UNITS_SOLD:Q"],
                ).properties(height=220)
                # 7-day rolling average line for readability
                vel["rolling_avg"] = vel["UNITS_SOLD"].rolling(7, min_periods=1).mean()
                trend_chart = alt.Chart(vel).mark_line(
                    color=COLOR_EVIDENCE, strokeWidth=2, strokeDash=[1, 0]
                ).encode(
                    x="SALES_DATE:T",
                    y=alt.Y("rolling_avg:Q"),
                    tooltip=["SALES_DATE:T", alt.Tooltip("rolling_avg:Q", title="7-day avg", format=".0f")],
                )
                st.altair_chart((vel_chart + trend_chart), use_container_width=True)
                st.caption(f"{COLOR_RISK}● daily units  ·  {COLOR_EVIDENCE}● 7-day rolling average")
            else:
                st.caption("No velocity data for this slice.")

        with sig2:
            st.markdown("**Online vs. store channel split**")
            st.caption(
                "Shows how demand is split between online and physical store. "
                "A channel with falling store demand while online holds is different from "
                "a broad category decline. The split is also relevant for any markdown "
                "or clearance plan, since the channel affects the mechanism."
            )
            cm = load_channel_mix(brand_id3, region3, category3)
            if not cm.empty:
                st.altair_chart(
                    alt.Chart(cm).mark_bar(color=COLOR_FORECAST).encode(
                        x=alt.X("CHANNEL:N", title="Channel"),
                        y=alt.Y("UNITS_SOLD:Q", title="Units sold (total period)"),
                        tooltip=["CHANNEL:N", "UNITS_SOLD:Q"],
                        color=alt.Color("CHANNEL:N",
                                        scale=alt.Scale(
                                            domain=["ONLINE", "STORE"],
                                            range=[COLOR_FORECAST, COLOR_EVIDENCE]
                                        ), legend=None),
                    ).properties(height=220),
                    use_container_width=True
                )
            else:
                st.caption("No channel mix data for this slice.")

        # ── Section 2: Promotion history ────────────────────────────────────
        st.markdown("---")
        st.markdown("#### 🗓️ Promotion history — planned vs. actual dates")
        st.caption(
            "This table is the most important piece of evidence in the drill-down "
            "for the Aurelia / DACH / SKINCARE slice. It shows whether any promotion "
            "ran earlier or later than planned — and whether the demand model knew about it."
        )

        promos = load_promotions(brand_id3, region3, category3)
        if not promos.empty:
            promos = promos.copy()
            promos["TIMING_FLAG"] = promos["TIMING_CHANGED"].map(
                lambda x: "⚠️ Ran early/late — demand was pulled forward or pushed back"
                          if x else "✅ Ran as planned"
            )
            # Highlight timing-changed rows
            timing_changed_rows = promos[promos["TIMING_CHANGED"] == True]
            if not timing_changed_rows.empty:
                for _, promo_row in timing_changed_rows.iterrows():
                    try:
                        shift = abs((pd.Timestamp(str(promo_row["ACTUAL_START"])) -
                                     pd.Timestamp(str(promo_row["PLANNED_START"]))).days)
                        direction = "earlier" if pd.Timestamp(str(promo_row["ACTUAL_START"])) < pd.Timestamp(str(promo_row["PLANNED_START"])) else "later"
                        st.warning(
                            f"⚠️ **Promotion timing change detected: '{promo_row['PROMO_NAME']}'**\n\n"
                            f"- Planned to start: **{str(promo_row['PLANNED_START'])[:10]}**\n"
                            f"- Actually started: **{str(promo_row['ACTUAL_START'])[:10]}** "
                            f"— **{shift} days {direction}**\n\n"
                            f"When a promotion runs earlier than planned, demand arrives "
                            f"before the period the plan expected it in. The forecast model "
                            f"was trained before this change was fully visible, so it "
                            f"expected demand that had already been spent. This is the "
                            f"**pull-forward effect** that drove the +61% forecast bias "
                            f"and the overstock position."
                        )
                    except Exception:
                        pass

            display_cols = [c for c in ["PROMO_NAME", "PLANNED_START", "PLANNED_END",
                                         "ACTUAL_START", "ACTUAL_END", "UPLIFT_FACTOR",
                                         "TIMING_FLAG"] if c in promos.columns]
            st.dataframe(promos[display_cols], use_container_width=True, hide_index=True)
            with st.expander("ℹ️ How to read this table"):
                st.markdown(
                    "- **PLANNED_START / PLANNED_END**: the dates the promotion was originally scheduled.\n"
                    "- **ACTUAL_START / ACTUAL_END**: when it actually ran.\n"
                    "- **UPLIFT_FACTOR**: the multiplier applied to baseline demand during the promo window "
                    "(e.g. 1.29 = 29% more demand than normal trading).\n"
                    "- **TIMING_FLAG**: whether the actual dates matched the plan. "
                    "A timing change does not automatically invalidate the forecast — "
                    "but a shift of more than 14 days, per the synthetic governance policy, "
                    "requires the demand baseline to be refreshed."
                )
        else:
            st.caption("No promotions recorded for this slice.")

        # ── Section 3: Cross-brand customers ───────────────────────────────
        st.markdown("---")
        st.markdown("#### 👥 Cross-brand customer activity")
        st.caption(
            "Shows monthly revenue from customers buying from **this brand in this region**. "
            "The underlying identity table links brand-local customer IDs to a governed "
            "`customer_group_id`, so the same customer buying from Aurelia and Solene "
            "appears as a single group rather than two unrelated records. "
            "This chart is illustrative — the Y-axis is synthetic revenue from "
            "the demo's unit economics."
        )
        ca = load_customer_activity(brand_id3, region3)
        if not ca.empty:
            st.altair_chart(
                alt.Chart(ca).mark_area(
                    color=COLOR_EVIDENCE, opacity=0.15, line={"color": COLOR_EVIDENCE}
                ).encode(
                    x=alt.X("ACTIVITY_MONTH:T", title="Month"),
                    y=alt.Y("REVENUE_AMOUNT:Q", title="Revenue (illustrative)"),
                    tooltip=["ACTIVITY_MONTH:T",
                             alt.Tooltip("REVENUE_AMOUNT:Q", title="Revenue (illustrative)", format=",.0f")],
                ).properties(height=200),
                use_container_width=True
            )
            st.caption(f"{ILLUSTRATIVE} · derived from synthetic unit economics")
        else:
            st.caption("No customer activity data for this slice.")

        with st.expander("ℹ️ What is customer_group_id and why does it matter?"):
            st.markdown(
                "Each brand's source system has its own local customer ID. "
                "Aurelia's ERP calls a customer `C001245`. Solene's POS calls the same person `S-88321`. "
                "Without a governed mapping, those look like two different customers.\n\n"
                "The `customer_group_id` is the Lumora-wide identity key that links "
                "brand-local IDs to a single governed record — but only where the "
                "identity resolution process has confirmed the match. "
                "It is an analytical link, not a permission to use the data for any purpose.\n\n"
                "In this demo, roughly **22% of customer groups** span more than one brand. "
                "That cross-brand visibility is invisible in isolated source systems — "
                "each brand only sees its own local IDs."
            )

        # ── Section 4: Residency and sensitivity ────────────────────────────
        st.markdown("---")
        st.markdown("#### 🔒 Residency & sensitivity classification")
        st.caption(
            "Every customer record carries a residency zone and a sensitivity class. "
            "These fields control which analytics are permitted and what governance steps "
            "are required before extending a workflow to customer-level treatment."
        )
        ident = load_customer_identity(region3)
        if not ident.empty:
            st.dataframe(ident.head(10), use_container_width=True, hide_index=True)
            st.caption(
                "RESTRICTED_PII = EU personal data, subject to data protection controls. "
                "STANDARD_PII = non-EU records with standard handling. "
                "This classification is applied at source — it is not added retrospectively."
            )
        with st.expander("ℹ️ Why does residency classification matter for AI use cases?"):
            st.markdown(
                "EU data protection rules distinguish between:\n\n"
                "1. **Aggregate analytics** — summarising demand by brand or region. "
                "Generally permitted without individual-level consent.\n"
                "2. **Identified-person processing** — targeting a specific customer. "
                "Requires a lawful basis, documented purpose, and in most cases a human "
                "approval step.\n\n"
                "This demo keeps all customer-level analysis at the aggregate level. "
                "The residency zone and sensitivity class are shown so the system can "
                "surface the right governance constraint when a question would cross "
                "that boundary — which is what Act 5 of the demo demonstrates."
            )

        # ── Section 5: Policy documents ─────────────────────────────────────
        st.markdown("---")
        st.markdown("#### 📄 Relevant policy & stakeholder documents")
        st.caption(
            "These documents are retrieved from the Cortex Search service over the synthetic "
            "policy corpus. They provide governance context — the rules, controls, and "
            "stakeholder notes that a decision on this slice should be checked against. "
            "In the demo they ground Act 5: the EU data question and the promotion governance check."
        )
        docs = search_policy_docs(f"{brand_name3} {region3} {category3} inventory residency governance")
        if docs:
            for d in docs:
                with st.expander(f"📄 {d.get('doc_title', 'Document')} — {d.get('doc_owner', '')} · {d.get('doc_type', '')}"):
                    body = d.get("doc_body", "")
                    st.markdown(body[:1500] + ("…" if len(body) > 1500 else ""))
                    if d.get("effective_date"):
                        st.caption(f"Effective: {d.get('effective_date')} · Scope: {d.get('region_scope', 'Group')}")
        else:
            st.caption("Cortex Search unavailable — see Agent Decision Panel for policy Q&A fallback.")


# ===========================================================================
# AREA 4 — AGENT DECISION PANEL
# ===========================================================================
with tabs[3]:
    st.subheader("Agent decision panel")
    st.caption("Tool use and evidence are shown below the answer. Chain-of-thought is never displayed.")

    if "chat_history" not in st.session_state:
        st.session_state.chat_history = []

    st.markdown("**Suggested questions**")
    qcols = st.columns(3)
    clicked_q = None
    for i, sq in enumerate(SUGGESTED_QUESTIONS):
        if qcols[i % 3].button(sq, key=f"sq_{i}", use_container_width=True):
            clicked_q = sq

    user_q = st.chat_input("Ask the Lumora Value Agent…")
    question = clicked_q or user_q

    for turn in st.session_state.chat_history:
        with st.chat_message(turn["role"]):
            st.markdown(_safe_md(turn["text"]))
            if turn.get("trace"):
                with st.expander("🔍 Tool trace"):
                    st.json(turn["trace"])

    if question:
        st.session_state.chat_history.append({"role": "user", "text": question})
        with st.chat_message("user"):
            st.markdown(question)

        with st.chat_message("assistant"):
            with st.spinner("Consulting governed tools…"):
                blocks, err = run_agent(question)

            if blocks:
                answer_text, tools_used, sources = summarize_agent_trace(blocks)
                if not answer_text:
                    answer_text = "The agent returned no final text; showing tool trace only."
                st.markdown(_safe_md(answer_text))
                trace = {
                    "intent_detected": question,
                    "tools_selected": tools_used or ["none"],
                    "data_sources_used": sources or [],
                    "mode": "live agent",
                }
                with st.expander("🔍 Tool trace"):
                    st.json(trace)
                st.session_state.chat_history.append({"role": "assistant", "text": answer_text, "trace": trace})
            else:
                # Deterministic fallback — matched to the closest scripted act.
                fb_map = {
                    SUGGESTED_QUESTIONS[0]: 2, SUGGESTED_QUESTIONS[1]: 4, SUGGESTED_QUESTIONS[2]: 5,
                    SUGGESTED_QUESTIONS[3]: 1, SUGGESTED_QUESTIONS[4]: 3, SUGGESTED_QUESTIONS[5]: 2,
                }
                act_no = fb_map.get(question, 1)
                fb = fallback_for_act(act_no)
                st.warning(f"⚠️ Live agent call unavailable ({err}). Showing deterministic fallback — Act {act_no}: {fb.get('ACT_TITLE', '')}")
                answer = fb.get("EXECUTIVE_ANSWER", "No fallback answer available.")
                st.markdown(_safe_md(answer))
                trace = {
                    "intent_detected": question,
                    "tools_selected": (fb.get("TOOLS_USED") or "").split(", "),
                    "data_sources_used": ["LUMORA_DEMO.AGENT.DEMO_FALLBACK"],
                    "scenario_assumptions": fb.get("ASSUMPTIONS", ""),
                    "result_and_recommendation": fb.get("RECOMMENDATION", ""),
                    "mode": "deterministic fallback",
                }
                with st.expander("🔍 Tool trace (fallback)"):
                    st.json(trace)
                with st.expander("📋 Evidence & assumptions (fallback)"):
                    st.markdown(f"{ICON_FACT} **Evidence:** {fb.get('EVIDENCE', '')}")
                    st.markdown(f"{ICON_ASSUMPTION} **Assumptions:** {fb.get('ASSUMPTIONS', '')}")
                    st.markdown(f"{ICON_RECOMMENDATION} **Recommendation:** {fb.get('RECOMMENDATION', '')}")
                st.session_state.chat_history.append({"role": "assistant", "text": answer, "trace": trace})

    st.divider()

    # ── Scenario simulator ────────────────────────────────────────────────────
    st.markdown("### 🎯 Promotion scenario simulator")
    st.markdown(
        "**Question: can a promotion clear the excess inventory, and how big would it need to be?**\n\n"
        "Use this tool to test whether a promotional demand uplift is large enough to work through "
        "the excess stock on any slice, or whether the position requires a different action "
        "(markdown, order cancellation, re-buy deferral)."
    )

    sr_all4 = load_slice_risk()
    if sr_all4.empty:
        st.warning("No slice data available.")
    else:
        # ── Slice selector with "All" support ─────────────────────────────────
        sc1, sc2, sc3 = st.columns(3)
        SIM_ALL = "All"
        sim_brand_opts = [SIM_ALL] + sorted(sr_all4["BRAND_NAME"].unique())
        sel_brand = sc1.selectbox("Brand", sim_brand_opts,
                                  index=1,    # default to top-risk brand (index 1 = first real brand after "All")
                                  key="sim_brand")
        sim_region_pool = sr_all4 if sel_brand == SIM_ALL else sr_all4[sr_all4["BRAND_NAME"] == sel_brand]
        sel_region = sc2.selectbox("Region", [SIM_ALL] + sorted(sim_region_pool["REGION_CODE"].unique()), key="sim_region")
        sim_cat_pool = sim_region_pool if sel_region == SIM_ALL else sim_region_pool[sim_region_pool["REGION_CODE"] == sel_region]
        sel_cat = sc3.selectbox("Category", [SIM_ALL] + sorted(sim_cat_pool["CATEGORY_CODE"].unique()), key="sim_cat")

        sim_is_agg = (sel_brand == SIM_ALL or sel_region == SIM_ALL or sel_cat == SIM_ALL)
        sim_scope  = " / ".join([
            sel_brand  if sel_brand  != SIM_ALL else "All brands",
            sel_region if sel_region != SIM_ALL else "All regions",
            sel_cat    if sel_cat    != SIM_ALL else "All categories",
        ])

        # Filter V_SLICE_RISK to the selected scope and aggregate if needed
        simmask = pd.Series([True] * len(sr_all4), index=sr_all4.index)
        if sel_brand  != SIM_ALL: simmask &= sr_all4["BRAND_NAME"]   == sel_brand
        if sel_region != SIM_ALL: simmask &= sr_all4["REGION_CODE"]  == sel_region
        if sel_cat    != SIM_ALL: simmask &= sr_all4["CATEGORY_CODE"] == sel_cat
        sim_slices = sr_all4[simmask]

        if sim_slices.empty:
            st.warning("No data for this combination.")
        else:
            if sim_is_agg:
                # Aggregate across all matching slices into a single pseudo-row
                on_hand   = float(sim_slices["ON_HAND_UNITS"].sum()  or 0)
                on_order  = float(sim_slices["ON_ORDER_UNITS"].sum() or 0)
                fwd_45d   = float(sim_slices["FWD_DEMAND_UNITS_45D"].sum() or 0)
                ivar      = float(sim_slices["INVENTORY_VALUE_AT_RISK"].sum() or 0)
                cover     = float(sim_slices["COVER_DAYS"].mean() or 0)
                target    = 45.0
                n_slices  = len(sim_slices)
                n_exposed = (sim_slices["EXCESS_UNITS"] > 0).sum()
                st.info(
                    f"**Aggregated view: {sim_scope}** — "
                    f"{n_slices} slices, {n_exposed} with excess inventory. "
                    f"Metrics below are summed across all matching slices. {ILLUSTRATIVE}."
                )
            else:
                sim_row = sim_slices.iloc[0]
                on_hand   = float(sim_row["ON_HAND_UNITS"]  or 0)
                on_order  = float(sim_row["ON_ORDER_UNITS"] or 0)
                fwd_45d   = float(sim_row["FWD_DEMAND_UNITS_45D"] or 0)
                ivar      = float(sim_row["INVENTORY_VALUE_AT_RISK"] or 0)
                cover     = float(sim_row["COVER_DAYS"] or 0)
                target    = float(sim_row["TARGET_COVER_DAYS"] or 45)
                n_slices  = 1
                n_exposed = 1

            available = on_hand + on_order
            excess    = max(0, available - fwd_45d)

            # ── Step 1: Current inventory position ───────────────────────────
            st.markdown("---")
            st.markdown("#### Step 1 — Current inventory position")
            st.caption(
                "This is what you are starting from before any promotion is considered."
                + (f" Summed across {n_slices} slices ({n_exposed} with excess stock)." if sim_is_agg else "")
            )

            p1, p2, p3, p4, p5 = st.columns(5)
            p1.metric("On-hand units", f"{on_hand:,.0f}",
                      help="Physical stock in the warehouse." + (" Sum across all matching slices." if sim_is_agg else ""))
            p2.metric("On-order units", f"{on_order:,.0f}",
                      help="Stock ordered and in transit — committed spend.")
            p3.metric("Total available", f"{available:,.0f}",
                      help="On-hand + on-order. This is the stock you need to work through.")
            p4.metric("45-day forecast demand", f"{fwd_45d:,.0f}",
                      help="What the current model expects to be sold in the next 45 days at normal trading."
                           + (" Sum across slices." if sim_is_agg else ""))
            p5.metric("Cover days vs target",
                      f"{cover:.0f}d  /  {target:.0f}d",
                      delta=f"{cover - target:+.0f} days",
                      delta_color="inverse",
                      help="Available units ÷ daily forecast demand. Policy target is 45 days."
                           + (" Average across slices." if sim_is_agg else ""))

            st.info(
                f"**{sim_scope}** — excess units: **{excess:,.0f}** "
                f"(available stock beyond the 45-day forecast). "
                f"Illustrative inventory value at risk: **€{ivar:,.0f}**. {ILLUSTRATIVE}."
            )

            daily = fwd_45d / 45.0 if fwd_45d else 0

            if excess == 0:
                st.success("No excess inventory on this scope — the forecast covers all available stock. "
                           "Try selecting a different slice or a broader aggregation to explore the scenario.")
            else:
                # ── Step 2: Set the promotion parameters ─────────────────────────
                st.markdown("---")
                st.markdown("#### Step 2 — Set promotion parameters")
                st.caption(
                    "A demand uplift means the promotion is expected to create *additional* demand "
                    "above the normal forecast level — for example, customers who would not have bought "
                    "otherwise. A promotion that only *shifts* demand forward (e.g. buy next week instead "
                    "of the week after) does **not** create uplift and does **not** reduce the excess."
                )

                sim_col1, sim_col2 = st.columns(2)
                uplift_pct = sim_col1.slider(
                    "Promotional demand uplift (%)",
                    min_value=0, max_value=200, value=12, step=5,
                    help="The extra demand the promotion generates as a % of the baseline forecast. "
                         "Start at 12% (modest) — a typical promotional uplift for a beauty category. "
                         "Try 50% or 100% to see how much it would take to make a real dent."
                )
                weeks = sim_col2.slider(
                    "Promotion runs for (weeks)",
                    min_value=1, max_value=8, value=4, step=1,
                    help="How many weeks the promotion runs. Longer promotions generate more incremental "
                         "demand but also have higher cost and customer fatigue risk."
                )

                window_days    = weeks * 7
                window_demand  = daily * window_days
                extra_units    = window_demand * (uplift_pct / 100.0)
                excess_after   = max(0, excess - extra_units)
                reduction      = excess - excess_after
                reduction_pct  = (reduction / excess * 100.0) if excess > 0 else 0
                breakeven_pct  = (excess / window_demand * 100.0) if window_demand > 0 else None

                # ── Step 3: Results ───────────────────────────────────────────────
                st.markdown("---")
                st.markdown("#### Step 3 — What the simulation shows")

                uplift_range = list(range(0, 210, 10))
                curve_df = pd.DataFrame({
                    "uplift_pct": uplift_range,
                    "excess_after": [max(0, excess - window_demand * (u / 100.0)) for u in uplift_range],
                })
                selected_pt = pd.DataFrame({"uplift_pct": [uplift_pct], "excess_after": [excess_after]})
                zero_pt = None
                if breakeven_pct and breakeven_pct <= 200:
                    zero_pt = pd.DataFrame({"uplift_pct": [breakeven_pct], "excess_after": [0]})

                ch1, ch2 = st.columns([3, 2])
                with ch1:
                    base_curve = alt.Chart(curve_df).mark_line(
                        color=COLOR_RISK, strokeWidth=2
                    ).encode(
                        x=alt.X("uplift_pct:Q", title="Promotional demand uplift (%)",
                                 scale=alt.Scale(domain=[0, 200])),
                        y=alt.Y("excess_after:Q", title="Remaining excess units after promotion"),
                        tooltip=["uplift_pct", "excess_after"],
                    )
                    baseline_line = alt.Chart(
                        pd.DataFrame({"y": [excess]})
                    ).mark_rule(color=COLOR_MUTED, strokeDash=[4, 4]).encode(y="y:Q")
                    zero_line = alt.Chart(
                        pd.DataFrame({"y": [0]})
                    ).mark_rule(color=COLOR_EVIDENCE, opacity=0.4).encode(y="y:Q")
                    sel_marker = alt.Chart(selected_pt).mark_point(
                        size=200, color=COLOR_FORECAST, shape="diamond", filled=True
                    ).encode(x="uplift_pct:Q", y="excess_after:Q",
                              tooltip=["uplift_pct", "excess_after"])
                    layers = [base_curve, baseline_line, zero_line, sel_marker]
                    if zero_pt is not None:
                        be_marker = alt.Chart(zero_pt).mark_point(
                            size=200, color=COLOR_EVIDENCE, shape="triangle-up", filled=True
                        ).encode(x="uplift_pct:Q", y="excess_after:Q",
                                  tooltip=[alt.Tooltip("uplift_pct:Q", title="Breakeven uplift %")])
                        layers.append(be_marker)
                    st.altair_chart(
                        alt.layer(*layers).properties(
                            height=300,
                            title=f"Excess units remaining — {sim_scope}"
                        ),
                        use_container_width=True
                    )
                    st.caption(
                        f"╌╌ Baseline = {excess:,.0f} units excess  ·  "
                        f"◆ Your scenario  ·  "
                        + (f"▲ Breakeven at {breakeven_pct:,.0f}%  ·  " if breakeven_pct and breakeven_pct <= 200 else "")
                        + f"━ Zero excess target"
                    )

                with ch2:
                    st.markdown("**Your scenario**")
                    st.metric("Uplift", f"{uplift_pct}% for {weeks} week{'s' if weeks > 1 else ''}",
                               help="The demand uplift you selected.")
                    st.metric("Extra units sold", f"{extra_units:,.0f}",
                               help=f"Baseline demand in the window ({window_demand:,.0f} units) × {uplift_pct}% uplift.")
                    st.metric("Excess remaining after promo", f"{excess_after:,.0f}",
                               delta=f"-{reduction:,.0f} ({reduction_pct:.1f}% cleared)",
                               delta_color="inverse" if excess_after > 0 else "normal")
                    st.markdown("---")
                    if breakeven_pct is not None:
                        if breakeven_pct > 100:
                            st.metric("Uplift needed to fully clear",
                                      f"{breakeven_pct:,.0f}%",
                                      help="The promotional uplift that would reduce excess to zero over this window.")
                        else:
                            st.metric("Breakeven uplift (clears all excess)",
                                      f"{breakeven_pct:,.0f}%",
                                      delta="Achievable with promotion",
                                      delta_color="normal")

                # ── Conclusion card ───────────────────────────────────────────────
                st.markdown("")
                if breakeven_pct is not None and breakeven_pct > 100:
                    st.error(
                        f"**{ICON_RECOMMENDATION} Promotion alone cannot clear this position.**\n\n"
                        f"Fully clearing the **{excess:,.0f} excess units** through demand would require "
                        f"a **{breakeven_pct:,.0f}% uplift** over {weeks} week{'s' if weeks > 1 else ''} — "
                        f"not a realistic promotional outcome. At {uplift_pct}%, only **{reduction_pct:.1f}%** "
                        f"of the excess is cleared.\n\n"
                        f"The decision is likely one of: **cancel or defer the on-order quantity "
                        f"({on_order:,.0f} units)**, negotiate a markdown, or extend the sell-through "
                        f"horizon. Each option requires a human owner."
                    )
                elif breakeven_pct is not None and breakeven_pct <= 100:
                    if uplift_pct >= breakeven_pct:
                        st.success(
                            f"**{ICON_RECOMMENDATION} This scenario clears the excess.**\n\n"
                            f"A {uplift_pct}% uplift over {weeks} week{'s' if weeks > 1 else ''} generates enough "
                            f"incremental demand to absorb the {excess:,.0f} excess units. "
                            f"The breakeven is {breakeven_pct:.0f}%. Note: this assumes the uplift "
                            f"creates *new* demand, not demand shifted from another period."
                        )
                    else:
                        st.warning(
                            f"**{ICON_RECOMMENDATION} Partial clearance — a larger promotion or longer window would work.**\n\n"
                            f"At {uplift_pct}%, {reduction_pct:.1f}% of excess is cleared. "
                            f"The breakeven is {breakeven_pct:.0f}% — achievable. "
                            f"Increase the uplift or the window to test a clearing scenario."
                        )

                st.caption(
                    f"{ICON_ASSUMPTION} Assumptions: uplift creates *incremental* demand (not shifted demand); "
                    f"45-day forecast and cover policy unchanged; no additional buying; "
                    f"markdown rate {int(float(load_assumptions().iloc[0]['MARKDOWN_RATE']) * 100)}% used for exposure. "
                    f"{ILLUSTRATIVE}."
                )

                # Live tool output only available for single-slice (aggregated not supported by the tool)
                if not sim_is_agg:
                    scenario_result = call_tool(
                        f"{DB}.AGENT.RUN_DEMAND_SCENARIO",
                        [_sql_str(sel_brand), _sql_str(sel_region), _sql_str(sel_cat),
                         f"{uplift_pct}::FLOAT", f"{weeks}"],
                    )
                    if isinstance(scenario_result, dict) and scenario_result:
                        with st.expander("Full scenario tool output (all values)"):
                            money_keys = [
                                ("Baseline inventory value at risk (€)", "BASELINE_INVENTORY_VALUE_AT_RISK"),
                                ("Scenario inventory value at risk (€)", "SCENARIO_INVENTORY_VALUE_AT_RISK"),
                                ("Baseline markdown exposure (€)",       "BASELINE_MARKDOWN_EXPOSURE"),
                                ("Scenario markdown exposure (€)",       "SCENARIO_MARKDOWN_EXPOSURE"),
                            ]
                            unit_keys = [
                                ("Baseline 45-day demand (units)",  "BASELINE_DEMAND_UNITS_45D"),
                                ("Scenario 45-day demand (units)",  "SCENARIO_DEMAND_UNITS_45D"),
                                ("Baseline excess (units)",         "BASELINE_EXCESS_UNITS"),
                                ("Scenario excess (units)",         "SCENARIO_EXCESS_UNITS"),
                            ]
                            tbl = (
                                [{"Measure": l, "Value": f"€{scenario_result[k]:,.2f}"} for l, k in money_keys if k in scenario_result] +
                                [{"Measure": l, "Value": f"{scenario_result[k]:,.0f} units"} for l, k in unit_keys if k in scenario_result]
                            )
                            if tbl:
                                st.dataframe(pd.DataFrame(tbl), use_container_width=True, hide_index=True)
                            if scenario_result.get("ASSUMPTIONS"):
                                st.caption(f"{ICON_ASSUMPTION} {scenario_result['ASSUMPTIONS']}")

# ===========================================================================
# AREA 5 — MODEL IMPROVEMENT PANEL
# ===========================================================================
with tabs[4]:
    st.subheader("Model improvement panel")
    st.markdown(
        "Two **separate** improvement paths. Fine-tuning the language model is **not** the same as retraining "
        "the numeric demand forecast."
    )

    col_a, col_b = st.columns(2)
    with col_a:
        st.markdown("### 🔢 Numeric forecast retraining")
        st.caption("Changes the forecast **numbers** — adds features, refits the demand model.")
        with st.form("retrain_form"):
            requestor = st.text_input("Requestor", value="CFO Demo User")
            reason = st.text_area("Reason", value="Add promotion timing as a feature; current model missed a promo-pull-forward event.")
            submitted = st.form_submit_button("Request forecast retraining")
        if submitted:
            sr5 = load_slice_risk()
            top5 = sr5.iloc[0] if not sr5.empty else None
            if top5 is not None:
                result = call_tool(
                    f"{DB}.AGENT.REQUEST_FORECAST_RETRAINING",
                    [_sql_str(requestor), _sql_str(reason), _sql_str(top5["BRAND_NAME"]),
                     _sql_str(top5["REGION_CODE"]), _sql_str(top5["CATEGORY_CODE"])],
                )
                if isinstance(result, dict) and result:
                    st.success(f"Retraining request {result.get('REQUEST_ID', '')} — "
                               f"{result.get('STATUS', '')}")
                    st.dataframe(
                        pd.DataFrame([{"Field": k, "Value": v} for k, v in result.items()]),
                        use_container_width=True, hide_index=True,
                    )
                else:
                    st.warning("Live retraining tool unavailable right now — request/status flow not confirmed this run.")

        st.markdown("**PRE-STAGED retrain evaluation comparison**")
        try:
            cmp_df = q(f"SELECT * FROM {DB}.AGENT.PRESTAGED_RETRAIN_RESULT")
            st.dataframe(cmp_df, use_container_width=True, hide_index=True)
        except Exception:
            st.info("PRESTAGED_RETRAIN_RESULT not available yet.")
        st.caption(f"{ICON_ASSUMPTION} PRE-STAGED for the demo — not trained live. Model promotion is a human decision.")

    with col_b:
        st.markdown("### 🗣️ LLM fine-tuning (explanation behaviour)")
        st.caption("Changes **how the agent explains** results — not the underlying forecast numbers.")
        with st.form("finetune_form"):
            ft_requestor = st.text_input("Requestor", value="CFO Demo User", key="ft_requestor")
            fb_text = st.text_area("Approved feedback", value="The explanation is missing promotion timing as a driver.")
            approved = st.checkbox("Mark as approved training example", value=True)
            submitted2 = st.form_submit_button("Request agent fine-tuning")
        if submitted2:
            result2 = call_tool(
                f"{DB}.AGENT.REQUEST_AGENT_FINE_TUNING",
                [_sql_str(ft_requestor), _sql_str(fb_text), "TRUE" if approved else "FALSE"],
            )
            if isinstance(result2, dict) and result2:
                st.success(f"Fine-tuning job {result2.get('JOB_ID', '')} — {result2.get('STATUS', '')}")
                base_ans = result2.get("BASE_MODEL_ANSWER")
                tuned_ans = result2.get("TUNED_MODEL_ANSWER")
                meta = {k: v for k, v in result2.items()
                        if k not in ("BASE_MODEL_ANSWER", "TUNED_MODEL_ANSWER")}
                st.dataframe(
                    pd.DataFrame([{"Field": k, "Value": v} for k, v in meta.items()]),
                    use_container_width=True, hide_index=True,
                )
                if base_ans and tuned_ans:
                    b1, b2 = st.columns(2)
                    b1.markdown("**Base model answer**")
                    b1.info(base_ans)
                    b2.markdown("**Tuned model answer**")
                    b2.success(tuned_ans)
            else:
                st.warning("Live fine-tuning tool unavailable right now — request/status flow not confirmed this run.")

        st.markdown("**PRE-STAGED base-vs-tuned answer comparison**")
        try:
            ft_df = q(f"SELECT * FROM {DB}.AGENT.PRESTAGED_FINETUNE_COMPARISON")
            st.dataframe(ft_df, use_container_width=True, hide_index=True)
        except Exception:
            st.info("PRESTAGED_FINETUNE_COMPARISON not available yet.")
        st.caption(f"{ICON_ASSUMPTION} PRE-STAGED for the demo — the request/status flow is real, the artefacts were prepared in advance.")

# ===========================================================================
# AREA 6 — CUSTOMER 360 & PROMOTION BUILDER
# ===========================================================================
# Segment colours — consistent across both charts
SEG_COLORS = {
    "Champions":  COLOR_EVIDENCE,
    "Loyal":      COLOR_FORECAST,
    "At Risk":    COLOR_ASSUMPTION,
    "Lapsed":     COLOR_RISK,
    "New":        "#9B59B6",
}

with tabs[5]:
    st.subheader("Customer 360 & Promotion Builder")
    st.markdown(
        "The scenario simulator shows **how much demand you need** to clear the excess. "
        "This tab answers: **who are the customers that could generate it, "
        "which segment should you target, and what does the governance check say?**\n\n"
        "Select a slice, pick a segment, and ask the agent to build a promotion recommendation."
    )

    sr_c360 = load_slice_risk()
    if sr_c360.empty:
        st.warning("No slice data.")
    else:
        # ── Slice selector with "All" support ─────────────────────────────
        C360_ALL = "All"
        cc1, cc2, cc3 = st.columns(3)
        c360_brand_opts  = [C360_ALL] + sorted(sr_c360["BRAND_NAME"].unique())
        c360_brand       = cc1.selectbox("Brand",  c360_brand_opts, key="c360_brand")
        c360_region_pool = sr_c360 if c360_brand == C360_ALL else sr_c360[sr_c360["BRAND_NAME"] == c360_brand]
        c360_region      = cc2.selectbox("Region", [C360_ALL] + sorted(c360_region_pool["REGION_CODE"].unique()), key="c360_region")
        c360_cat_pool    = c360_region_pool if c360_region == C360_ALL else c360_region_pool[c360_region_pool["REGION_CODE"] == c360_region]
        c360_cat         = cc3.selectbox("Category", [C360_ALL] + sorted(c360_cat_pool["CATEGORY_CODE"].unique()), key="c360_cat")

        c360_is_agg = (c360_brand == C360_ALL or c360_region == C360_ALL or c360_cat == C360_ALL)
        c360_scope  = " / ".join([
            c360_brand  if c360_brand  != C360_ALL else "All brands",
            c360_region if c360_region != C360_ALL else "All regions",
            c360_cat    if c360_cat    != C360_ALL else "All categories",
        ])

        # ── Inventory context — aggregate matching slices ──────────────────
        c360_inv_mask = pd.Series([True] * len(sr_c360), index=sr_c360.index)
        if c360_brand  != C360_ALL: c360_inv_mask &= sr_c360["BRAND_NAME"]   == c360_brand
        if c360_region != C360_ALL: c360_inv_mask &= sr_c360["REGION_CODE"]  == c360_region
        if c360_cat    != C360_ALL: c360_inv_mask &= sr_c360["CATEGORY_CODE"] == c360_cat
        c360_inv_slices = sr_c360[c360_inv_mask]

        c360_excess = float(c360_inv_slices["EXCESS_UNITS"].sum() or 0)
        c360_ivar   = float(c360_inv_slices["INVENTORY_VALUE_AT_RISK"].sum() or 0)
        if c360_is_agg:
            st.info(
                f"**Aggregated scope: {c360_scope}** ({len(c360_inv_slices)} slices) — "
                f"total excess units: **{c360_excess:,.0f}**, "
                f"illustrative inventory value at risk: **€{c360_ivar:,.0f}**. {ILLUSTRATIVE}."
            )
        else:
            st.info(
                f"**Slice: {c360_scope}** — "
                f"excess units: **{c360_excess:,.0f}**, "
                f"illustrative inventory value at risk: **€{c360_ivar:,.0f}**. {ILLUSTRATIVE}."
            )

        # ── Section 1: Customer base overview ─────────────────────────────
        st.markdown("---")
        st.markdown(
            f"#### 👥 Section 1 — Customer base: {c360_scope}"
            + (" (aggregated)" if c360_is_agg else "")
        )
        st.caption(
            "Customers are tracked at brand × region level. "
            "RFM segments come from 18 months of purchase history: "
            "**R**ecency (how recently), **F**requency (how often), **M**onetary (how much). "
            + (f"Showing all matching customers across {len(c360_inv_slices)} brand-region combinations. " if c360_is_agg else "")
            + "All revenue values are illustrative."
        )

        rfm_brand  = None if c360_brand  == C360_ALL else c360_brand
        rfm_region = None if c360_region == C360_ALL else c360_region
        rfm_df = load_customer_rfm(rfm_brand or "All", rfm_region or "All")
        if rfm_df.empty:
            st.warning("No customer data for this brand/region.")
        else:
            total_c = len(rfm_df)
            eu_c    = rfm_df["IS_EU"].sum()
            xbrand  = rfm_df["IS_CROSS_BRAND"].sum()

            m1, m2, m3, m4 = st.columns(4)
            m1.metric("Total customers", f"{total_c:,}", help="Unique customer_group_id records for this brand/region.")
            m2.metric("EU / RESTRICTED_PII", f"{eu_c:,}", delta=f"{100*eu_c//total_c}% of base",
                      help="Customers in residency zones EU_WEST or EU_NORTH — subject to EU data protection rules.")
            m3.metric("Cross-brand customers", f"{xbrand:,}", delta=f"{100*xbrand//total_c}% of base",
                      help="Customers also visible under at least one other Lumora brand via the governed customer_group_id.")
            m4.metric("Avg monthly orders",
                      f"{rfm_df['TOTAL_ORDERS'].mean() / rfm_df['RECENCY_MONTHS'].clip(lower=1).mean():.1f}",
                      help="Total orders ÷ active months, averaged across customers.")

            # Segment distribution bar
            seg_counts = (rfm_df.groupby("RFM_SEGMENT", as_index=False)
                          .agg(count=("CUSTOMER_GROUP_ID", "count"),
                               avg_rev=("TOTAL_REVENUE", "mean"),
                               avg_orders=("TOTAL_ORDERS", "mean"),
                               eu_count=("IS_EU", "sum")))
            seg_counts["pct"] = (100 * seg_counts["count"] / total_c).round(1)

            sc1, sc2 = st.columns([2, 1])
            with sc1:
                seg_bar = alt.Chart(seg_counts).mark_bar().encode(
                    x=alt.X("count:Q", title="Number of customers"),
                    y=alt.Y("RFM_SEGMENT:N", title=None, sort="-x"),
                    color=alt.Color("RFM_SEGMENT:N",
                                    scale=alt.Scale(
                                        domain=list(SEG_COLORS.keys()),
                                        range=list(SEG_COLORS.values())
                                    ), legend=None),
                    tooltip=["RFM_SEGMENT", "count", "pct",
                             alt.Tooltip("avg_rev:Q", title="Avg revenue (illustrative)", format=",.0f"),
                             alt.Tooltip("avg_orders:Q", title="Avg orders", format=".1f"),
                             alt.Tooltip("eu_count:Q", title="EU customers")],
                ).properties(height=220, title="Customer segments by size")
                pct_text = alt.Chart(seg_counts).mark_text(align="left", dx=4, color="#aaa", size=12).encode(
                    x="count:Q", y=alt.Y("RFM_SEGMENT:N", sort="-x"),
                    text=alt.Text("pct:Q", format=".0f", formatType="number")
                )
                st.altair_chart((seg_bar + pct_text), use_container_width=True)

            with sc2:
                st.markdown("**What each segment means:**")
                for seg, meaning in [
                    ("Champions",  "Bought recently, often, high spend. Best candidates for loyalty rewards or premium offers."),
                    ("Loyal",      "Regular buyers, solid spend. Good for re-purchase or cross-sell."),
                    ("At Risk",    "Used to buy often but recent activity has slowed. Win-back offers."),
                    ("Lapsed",     "Not seen for 4+ months. Need stronger incentive to re-engage."),
                    ("New",        "First or second purchase. Nurture to build habit."),
                ]:
                    color = SEG_COLORS.get(seg, "#888")
                    st.markdown(
                        f"<span style='color:{color};font-weight:700'>{seg}</span> — {meaning}",
                        unsafe_allow_html=True
                    )

            # Scatter: recency vs monetary, coloured by segment
            scatter = alt.Chart(rfm_df.sample(min(500, len(rfm_df)), random_state=42)).mark_circle(
                size=40, opacity=0.6
            ).encode(
                x=alt.X("RECENCY_MONTHS:Q", title="Months since last purchase (lower = more recent)"),
                y=alt.Y("TOTAL_REVENUE:Q", title="Total revenue — illustrative"),
                color=alt.Color("RFM_SEGMENT:N",
                                scale=alt.Scale(domain=list(SEG_COLORS.keys()), range=list(SEG_COLORS.values())),
                                legend=alt.Legend(title="Segment")),
                tooltip=["RFM_SEGMENT", "RECENCY_MONTHS", alt.Tooltip("TOTAL_REVENUE:Q", format=",.0f"),
                         "TOTAL_ORDERS", "IS_EU", "IS_CROSS_BRAND"],
            ).properties(height=250, title="Recency vs revenue (sample of 500 customers)")
            st.altair_chart(scatter, use_container_width=True)
            st.caption(f"{ILLUSTRATIVE} · sample of up to 500 customers shown")

        # ── Section 2: Target audience selector ───────────────────────────
        st.markdown("---")
        st.markdown("#### 🎯 Section 2 — Build your promotion audience")
        st.caption(
            "Select the segments to include in the promotion. The governance check runs automatically: "
            "if any EU/RESTRICTED_PII customers are in the audience, a human approval step is required."
        )

        if not rfm_df.empty:
            all_segs = sorted(rfm_df["RFM_SEGMENT"].unique())
            target_segs = st.multiselect(
                "Target segments",
                options=all_segs,
                default=[s for s in ["At Risk", "Lapsed"] if s in all_segs],
                help="Select one or more segments. 'At Risk' and 'Lapsed' are typically the highest-value "
                     "re-engagement targets for a clearance promotion."
            )

            if target_segs:
                audience = rfm_df[rfm_df["RFM_SEGMENT"].isin(target_segs)]
                aud_total   = len(audience)
                aud_eu      = int(audience["IS_EU"].sum())
                aud_xbrand  = int(audience["IS_CROSS_BRAND"].sum())
                aud_rev_avg = audience["TOTAL_REVENUE"].mean()
                aud_ord_avg = audience["TOTAL_ORDERS"].mean()

                a1, a2, a3, a4 = st.columns(4)
                a1.metric("Audience size", f"{aud_total:,}")
                a2.metric("EU / RESTRICTED_PII", f"{aud_eu:,}",
                          delta="⚠️ Requires approval" if aud_eu > 0 else "None",
                          delta_color="off" if aud_eu > 0 else "normal")
                a3.metric("Cross-brand", f"{aud_xbrand:,}",
                          help="These customers are visible under other brands — a coordinated group offer may be more effective.")
                a4.metric("Avg illustrative revenue", f"€{aud_rev_avg:,.0f}",
                          help=f"Average total revenue per customer in the selected segments. {ILLUSTRATIVE}.")

                # ── EU HARD GATE ───────────────────────────────────────────
                gov_cleared = False
                if aud_eu > 0:
                    st.error(
                        f"🔒 **EU governance gate — human approval required**\n\n"
                        f"This audience includes **{aud_eu:,} EU customers** classified "
                        f"RESTRICTED_PII (residency zone: {', '.join(audience[audience['IS_EU']]['DATA_RESIDENCY_ZONE'].unique())}). "
                        f"Using identified EU personal data for targeted promotion constitutes "
                        f"identified-person processing and requires documented human approval "
                        f"before the audience can be activated.\n\n"
                        f"The promotion brief will be saved as **PENDING_EU_APPROVAL**."
                    )
                    gov_cleared = st.checkbox(
                        "✅ I confirm this audience will be reviewed by a human governance owner "
                        "before it is used for any customer-level targeting or personalisation.",
                        key="eu_gate"
                    )
                    gov_status = "PENDING_EU_APPROVAL"
                else:
                    st.success("✅ No EU-classified customers in this audience. Standard data-handling policies apply.")
                    gov_cleared = True
                    gov_status  = "READY"

        # ── Section 3: Agent recommendation ───────────────────────────────
        st.markdown("---")
        st.markdown("#### 🤖 Section 3 — Agent promotion recommendation")
        st.caption(
            "Ask the agent to recommend a promotion approach for the selected audience. "
            "It will call the customer segments tool and the policy search, "
            "estimate the expected uplift contribution from this audience, "
            "and state the governance steps required."
        )

        if not rfm_df.empty and target_segs:
            ask_disabled = not gov_cleared
            ask_label = "Ask agent to build promotion recommendation"
            if ask_disabled:
                st.info("Tick the governance confirmation above to enable the agent recommendation.")

            if st.button(ask_label, disabled=ask_disabled, type="primary"):
                question = (
                    f"I am planning a promotion to help clear {c360_excess:,.0f} excess units "
                    f"for scope: {c360_scope} "
                    f"(illustrative inventory value at risk: EUR {c360_ivar:,.0f}"
                    + (f", aggregated across {len(c360_inv_slices)} slices" if c360_is_agg else "")
                    + f"). "
                    f"Target audience: {', '.join(target_segs)} segments "
                    f"({aud_total} customers, {aud_eu} EU RESTRICTED_PII, "
                    f"{aud_xbrand} cross-brand). "
                    f"What promotion approach would you recommend, what uplift could this audience realistically contribute, "
                    f"and what governance steps are required before the audience can be activated?"
                )
                with st.spinner("Agent building promotion recommendation…"):
                    blocks, err = run_agent(question)

                if blocks:
                    answer_text, tools_used, sources = summarize_agent_trace(blocks)
                    if not answer_text:
                        answer_text = "The agent returned no final text."
                    st.markdown(_safe_md(answer_text))
                    with st.expander("🔍 Tool trace"):
                        st.json({"tools_selected": tools_used, "data_sources": sources, "mode": "live agent"})
                    # Store for the brief
                    if "c360_agent_rec" not in st.session_state:
                        st.session_state["c360_agent_rec"] = ""
                    st.session_state["c360_agent_rec"] = answer_text
                else:
                    st.warning(f"Live agent unavailable ({err}). Showing fallback.")
                    fb = fallback_for_act(3)
                    st.markdown(_safe_md(fb.get("EXECUTIVE_ANSWER", "")))
                    st.session_state["c360_agent_rec"] = fb.get("EXECUTIVE_ANSWER", "")

        # ── Section 4: Save promotion brief ───────────────────────────────
        st.markdown("---")
        st.markdown("#### 💾 Section 4 — Save promotion brief")
        st.caption(
            "Record the audience definition, governance status, and agent recommendation "
            "as a promotion brief in Snowflake. This creates an auditable record of the decision."
        )

        if not rfm_df.empty and target_segs and gov_cleared:
            with st.form("brief_form"):
                requestor  = st.text_input("Requestor", value="CFO Demo User")
                notes      = st.text_area("Notes", value="Clearance promotion to reduce excess DACH SKINCARE inventory.")
                resp_rate  = st.slider("Assumed response rate (%)", 1, 30, 8,
                                       help="The % of the audience expected to make an additional purchase. "
                                            "Used only to estimate incremental units — it is an assumption.")
                save_brief = st.form_submit_button("Save promotion brief")

            if save_brief:
                avg_units_per_order = max(1, c360_excess / max(1, aud_total * (resp_rate / 100.0)))
                expected_uplift = round(aud_total * (resp_rate / 100.0) * avg_units_per_order, 0)
                agent_rec = st.session_state.get("c360_agent_rec", "Not yet generated.")
                try:
                    brief_id = f"BRIEF-{coco.tool('sql_execute', {'connection': 'uswest2demo', 'sql': 'SELECT LUMORA_DEMO.AGENT.SEQ_BRIEF.NEXTVAL AS nv', 'description': 'brief seq'})}"
                except Exception:
                    brief_id = f"BRIEF-{datetime.now().strftime('%Y%m%d%H%M%S')}"
                try:
                    sql_brand    = c360_brand  if c360_brand  != C360_ALL else "All"
                    sql_region   = c360_region if c360_region != C360_ALL else "All"
                    sql_cat      = c360_cat    if c360_cat    != C360_ALL else "All"
                    coco.tool("sql_execute", {
                        "connection": "uswest2demo",
                        "description": "insert promotion brief",
                        "sql": f"""
                            INSERT INTO LUMORA_DEMO.AGENT.FACT_PROMOTION_BRIEF
                            (brief_id, created_by, brand, region, category, target_segments,
                             audience_size, eu_customer_count, expected_uplift_units,
                             governance_status, agent_recommendation, notes, created_at)
                            VALUES (
                                CONCAT('BRIEF-', LUMORA_DEMO.AGENT.SEQ_BRIEF.NEXTVAL::VARCHAR),
                                '{requestor}', '{sql_brand}', '{sql_region}', '{sql_cat}',
                                '{", ".join(target_segs)}',
                                {aud_total}, {aud_eu}, {expected_uplift},
                                '{gov_status}',
                                $${agent_rec[:3000]}$$,
                                '{notes}',
                                CURRENT_TIMESTAMP()
                            )"""
                    })
                    st.success(
                        f"Brief saved — governance status: **{gov_status}**. "
                        + ("Audience is ready to activate." if gov_status == "READY"
                           else "Brief is PENDING_EU_APPROVAL — human review required before activation.")
                    )
                    st.caption(
                        f"{ICON_ASSUMPTION} Expected uplift ({aud_total:,} customers × {resp_rate}% response rate) "
                        f"is an assumption, not a forecast. {ILLUSTRATIVE}."
                    )
                    # Refresh the briefs table cache
                    load_promotion_briefs.clear()
                except Exception as e:
                    st.error(f"Could not save brief: {e}")

            # Show existing briefs
            briefs = load_promotion_briefs()
            if not briefs.empty:
                st.markdown("**Saved promotion briefs**")
                disp = [c for c in ["BRIEF_ID", "BRAND", "REGION", "CATEGORY",
                                    "TARGET_SEGMENTS", "AUDIENCE_SIZE", "EU_CUSTOMER_COUNT",
                                    "EXPECTED_UPLIFT_UNITS", "GOVERNANCE_STATUS", "CREATED_AT"]
                        if c in briefs.columns]
                st.dataframe(briefs[disp], use_container_width=True, hide_index=True)
                st.caption(
                    "PENDING_EU_APPROVAL briefs must be reviewed by a human governance owner "
                    "before the audience can be used for any customer-level targeting."
                )
        elif not rfm_df.empty and target_segs and not gov_cleared:
            st.info("Tick the governance confirmation in Section 2 to save a brief for an EU audience.")

st.divider()
st.caption(
    f"Lumora Value Loop demo · rendered {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} · "
    f"{ICON_FACT} observed fact  {ICON_CALC} calculation  {ICON_ASSUMPTION} assumption  {ICON_RECOMMENDATION} recommendation"
)
