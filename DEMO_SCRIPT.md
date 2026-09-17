# Lumora Value Loop Demo Script

## Purpose

This is the presenter runbook for the Lumora Value Loop demo. It is written for an executive audience and assumes the presenter understands retail and technology better than finance terminology.

The demo tells one story:

```text
data foundation -> forecast -> explanation -> scenario -> decision -> feedback -> improvement
```

The app is a decision cockpit, not a finance system of record. All source data is synthetic, all currency figures are illustrative, and all consequential recommendations require human review.

## Before The Demo

Open these tabs before the audience arrives:

- Streamlit app: `https://app.snowflake.com/<your-org>/<your-account>/streamlit-apps/LUMORA_DEMO.APP.LUMORA_COCKPIT`
- Presentation: `pitch/lumora.html`
- Optional SQL client connected to `<your-connection>` for backup evidence.

Check the following:

- The Streamlit app loads `LUMORA_DEMO.APP.V_KPI_EXEC` and shows KPI cards.
- The app displays the `Illustrative` disclaimer at the top.
- The top risk slice is Aurelia / DACH / SKINCARE.
- The Agent Decision Panel has its suggested questions.
- The deterministic fallback is available if the live agent is slow.
- The Model Improvement panel shows both pre-staged comparison tables.
- Do not start with a blank SQL worksheet. Start with the business question.

## Number Discipline

Use the numbers currently rendered by the app. The expected headline values are:

- Group inventory value at risk: approximately **EUR 251K**, illustrative.
- Top slice inventory value at risk: approximately **EUR 87.4K**, illustrative.
- Top slice share of group exposure: approximately **34.9%**.
- Top slice cover: approximately **149.8 days** versus a **45-day** target.
- Top slice prior-plan bias: approximately **+61.3%**.
- Group weighted forecast error: approximately **4.1% WAPE**.
- Group forecast bias: approximately **+2.2%**.
- Promotion timing shift: **21 days early**.
- Cross-brand customer coverage: approximately **22.2%**.
- A 12% demand uplift for four weeks removes approximately **3.3%** of the top slice's excess.
- The promotion-only breakeven uplift is approximately **365%**, which is not a credible commercial action.

If a value differs slightly after a rebuild, read the value from the app and keep the interpretation unchanged. Never substitute real Lumora financials for the synthetic numbers.

## How To Read The CFO KPI Cards

The six cards in the screenshot are **group-level cards**. They summarize all 68 brand-by-region-category slices. They do not identify the highest-risk slice by themselves. Use the heatmap, waterfall, and drill-down to move from the group total to Aurelia / DACH / SKINCARE.

A useful framing sentence is:

> “These cards tell us the size and type of the group's exposure. The heatmap and waterfall tell us where that exposure is concentrated.”

### 1. Inventory value at risk — `EUR 250,542`

**What it means:**

This is the illustrative cost value of inventory that exceeds the current forecasted demand over the next 45 days. The calculation is:

```text
available units = on-hand units + on-order units
excess units = max(available units - 45-day forecast demand, 0)
inventory value at risk = excess units x average unit cost
```

**What to say:**

> “Across the group, roughly EUR 251K of illustrative inventory is beyond the next 45 days of forecast demand. This is an exposure measure: it tells us where stock may need a commercial action, not that EUR 251K has already been lost.”

**Do not say:**

- “Lumora will lose EUR 251K.”
- “There is a 100% probability of loss.”
- “This is an accounting provision.”

The top slice is much more useful than the group total for the story: Aurelia / DACH / SKINCARE contributes about EUR 87K, or 34.9% of the group exposure.

### 2. Forecast WAPE / Bias — `4.1% / +2.2%`

These are two different measures of forecast quality. In this demo they are **group-level metrics for the prior-plan evaluation window**, not a claim that every current forecast is 4.1% accurate.

**Why do we know the forecasts have errors?**

Because the demo holds two forecast vintages, and one can be scored against real history.

```
Timeline (demo anchor = 15 September 2026):

Mar 2025 ─────────────────── Aug 15 ──── Sep 15  ← today
          actual sales data        │
                                   │
PRIOR PLAN trained here ───────────┘
  predicted Aug 16 → Oct 14
  actual sales for Aug 16 → Sep 15 now exist
  ∴ we can compare: forecast vs what really happened   ← WAPE and Bias come from here

CURRENT MODEL trained here ────────────────────────────┘
  predicts Sep 16 → Nov 14
  no future actuals yet → cannot be scored
```

The one-month window **16 August → 15 September** is the out-of-sample evaluation window. It is genuinely out-of-sample because the prior-plan model had never seen that data when it was trained.

**WAPE — 4.1%:**

```
WAPE = sum(|forecast − actual|) / sum(actual) × 100
```

Each day, the forecast was either too high or too low by some number of units. WAPE totals those gaps (regardless of direction), divides by total actual demand, and expresses it as a percentage. Lower is better. 4.1% looks healthy — until you look at individual slices. Aurelia DACH SKINCARE is 61.3% inside that same group average.

**Bias — +2.2%:**

```
Bias = sum(forecast − actual) / sum(actual) × 100
```

Unlike WAPE, this keeps direction. Over- and under-forecast errors cancel each other. A **positive bias means the plan expected more demand than arrived** — the model was systematically over-optimistic. That directly causes overstock: you buy inventory to meet demand that does not come.

The +2.2% group figure is small, but Aurelia DACH SKINCARE is +61.3% — meaning the prior plan expected 61% more demand than actually arrived for that slice. That over-forecast is the mechanical cause of the excess inventory position.

**The one thing averages hide:**

A 4.1% group WAPE can easily coexist with one slice at 61% if the affected slice is small by volume. The demo uses this deliberately: the group looks fine; the slice-level drill-down reveals the problem. This is why the heatmap and waterfall exist — to find the concentrated exceptions inside an acceptable average.

**What to say:**

> "At group level, the prior plan had 4.1% weighted absolute error and a small positive bias of 2.2%, meaning it slightly over-forecast overall. That average hides the important exception: Aurelia DACH SKINCARE was over-forecast by about 61.3%, which is why we drill into the slices instead of relying on the average."

> "We know the prior plan had errors because we can compare it against what actually happened. The plan was trained in August. By September 15 we have a month of real sales. That comparison gives us the WAPE and Bias numbers."

**Why both metrics matter:**

- WAPE answers: "How large were the errors?"
- Bias answers: "Did we generally over- or under-forecast?"
- A low group average does not mean every brand or category is healthy.
- **Positive bias → over-forecast → overstock.** Negative bias → under-forecast → stockout risk.


**WAPE — 4.1%:**

Weighted absolute percentage error measures the total size of the forecast errors relative to total actual demand. It ignores direction, so errors do not cancel each other. Lower is better.

**Bias — +2.2%:**

Bias measures direction. Positive bias means the plan forecast more demand than actually arrived overall. Negative bias would mean the plan under-forecast.

The evaluation window is `2026-08-16` through `2026-09-15`, using the `PRIOR_PLAN` vintage against actual sales.

**What to say:**

> “At group level, the prior plan had 4.1% weighted absolute error and a small positive bias of 2.2%, meaning it slightly over-forecast overall. That average hides the important exception: Aurelia DACH SKINCARE was over-forecast by about 61.3%, which is why we drill into the slices instead of relying on the average.”

**Why both metrics matter:**

- WAPE answers: “How large were the errors?”
- Bias answers: “Did we generally over- or under-forecast?”
- A low group average does not mean every brand or category is healthy.

### 3. Stockout margin at risk — `EUR 441,507`

**What it means:**

This is the illustrative gross margin associated with forecast demand that is not covered by available inventory:

```text
stockout gap = max(45-day forecast demand - available units, 0)
stockout margin at risk = stockout gap x (average price - average unit cost)
```

It is a modeled opportunity or contribution exposure, not guaranteed lost revenue.

**What to say:**

> “The group also has shortage exposure in some slices: if forecast demand arrives and available stock is insufficient, the illustrative gross margin associated with that uncovered demand is about EUR 442K. This is a different risk from the Aurelia slice, which is primarily overstocked.”

**Important distinction:**

The same group can have both excess inventory in some slices and stockout risk in others. The group card sums across all slices; it does not mean Aurelia DACH SKINCARE has both risks. The governance line shows `41 at stockout risk` across the group, while the top slice has a zero stockout gap.

### 4. Markdown exposure — `EUR 100,217`

**What it means:**

This is the illustrative markdown planning exposure on excess inventory. The demo assumes a 40% markdown rate applied to excess inventory at cost:

```text
markdown exposure = inventory value at risk x assumed 40% markdown rate
```

**What to say:**

> “If excess stock requires discounting, the modeled markdown exposure is about EUR 100K under the demo's assumed 40% rate. The rate is an explicit planning assumption, not an observed Lumora rate and not an accounting reserve.”

**Do not say:**

- “We will write off EUR 100K.”
- “The markdown rate is 40% in the real business.”

A markdown is a price reduction to move stock. A write-off is a more severe accounting outcome where the value is not expected to be recovered.

### 5. Cross-brand coverage — `22.2%`

**What it means:**

This is not forecast coverage and not data completeness. It is the share of governed customer groups that are visible across more than one brand:

```text
cross-brand coverage = customer groups linked to 2+ brands / all customer groups
```

In the current synthetic data, 665 of 3,000 customer groups span more than one brand, which is approximately 22.2%.

**What to say:**

> “About 22% of governed customer groups appear across multiple brands. That shared identity view lets us see group-level demand and customer patterns that remain hidden when each brand only sees its local customer ID.”

**Do not say:**

- “22% of customers are ready for marketing.”
- “The company can automatically target those customers.”
- “Identity resolution gives permission to use personal data for any purpose.”

The `customer_group_id` is a governed analytical link. The governance policy and human approval still control customer-level use.

### 6. Forecast refresh — `2026-09-16 ...`

**What it means:**

This is the timestamp when the current forecast rows were generated. It is not the amount of time the refresh took.

The governance line beneath the cards provides the complementary metadata:

- **Model version:** `fcst-v1.1-trained-2026-09-15` identifies the forecast model used.
- **Trained through:** `2026-09-15` identifies the last historical date used for training.
- **68 slices:** the number of brand-by-region-category series in scope.
- **3 overstocked:** slices above 1.5 times the 45-day target, or more than 67.5 days of cover.
- **41 at stockout risk:** slices where forecast demand exceeds available stock.

**What to say:**

> “The forecast was trained through September 15 and generated on September 16. The model version is visible, so a decision can be traced back to the forecast that produced the number.”

**Do not say:**

- “The forecast refreshed in zero seconds.”
- “The timestamp proves the forecast is accurate.”
- “The current model is registered in Model Registry.”

### A 45-Second KPI Readout

Use this exact sequence when the audience first sees the cards:

> “Start with the group position: about EUR 251K of illustrative inventory exposure, plus about EUR 100K of modeled markdown exposure under a stated 40% assumption. Forecast quality at group level is 4.1% WAPE with +2.2% bias for the prior-plan evaluation window. There is also shortage exposure in other slices, represented by about EUR 442K of illustrative stockout margin at risk. The 22.2% cross-brand coverage tells us the shared customer identity layer can expose behavior across brands. The model version and refresh timestamp make the result traceable. Now we move from the group totals to the heatmap and waterfall to find the slice driving the decision: Aurelia SKINCARE in DACH.”

### Card-To-Question Map

| Card | Business question it answers |
|---|---|
| Inventory value at risk | "How much stock exposure exists at group level?" |
| WAPE / Bias | "How large were the prior-plan errors, and were they high or low?" |
| Stockout margin at risk | "Where could insufficient stock prevent profitable sales?" |
| Markdown exposure | "What modeled discount exposure exists if excess stock needs action?" |
| Cross-brand coverage | "Can we see the same governed customer group across brands?" |
| Forecast refresh | "Which model and training date produced this result?" |

## How To Read The Actual vs. Forecast Chart

This chart appears in **CFO Cockpit area 1** for the top risk slice, and in **Forecast Explorer area 2** for any selected slice. It is the most information-dense visual in the demo and the one most likely to generate CFO questions.

### What Each Line Is

```text
──────────────   Green solid line   = actual historical sales (what really happened)
- - - - - - -   Grey dashed line   = prior plan forecast (what last month's model expected)
──────────────   Blue solid line    = current forecast (what the new model expects)
░░░░░░░░░░░░░   Blue shaded band   = 90% confidence interval around the current forecast
```

The green line ends where history ends — at the demo anchor date of 2026-09-15. Beyond that point only the blue and grey forecast lines continue.

### How To Read The Gap

The visual gap from roughly August 2026 onwards divides into two separate gaps, and they tell different parts of the story.

**Gap 1: Green line collapses (August actual demand fell sharply)**

From April 2025 through July 2026, actual daily demand for this slice runs at roughly **138 units per day**. In the August–September 2026 evaluation window it falls to roughly **81 units per day** — a drop of about 41%.

This is the demand break. It is a real data event in the synthetic history, not a chart artefact. The cause is that the promotion ran in early August (when it pulled demand forward), and then regular demand continued at the lower post-promotion level without the September uplift the plan expected.

**Gap 2: Grey dashed line versus blue solid line after September**

The grey dashed line continues forward at approximately **130 units per day** — essentially flat from the historical average. This is what the prior-plan model expected from October onwards.

The blue solid line sits at approximately **58 units per day** with a wide confidence band.

The gap between these two lines — roughly **55%** lower in the current forecast compared to the prior plan — is the core financial risk. The business bought inventory to support 130 units per day, but the current model expects only 58. That is why 149.8 days of cover exists.

**What the confidence band means:**

The shaded blue area is the model's 90% prediction interval: the range within which the model expects 9 out of 10 outcomes to fall. The band is wide here because the model is extrapolating beyond a structural break with limited post-break history. A wide band means genuine uncertainty, not a calculation error. It is honest.

### The Four-Sentence Summary To Use In The Demo

> "The green line is what actually happened. You can see demand running steadily around 130–140 units per day until August, then falling sharply.

> The grey dashed line is what last month's plan expected to happen next — around 130 units per day, flat from the historical average. The plan did not see the break coming.

> The blue solid line is what the new model expects — around 58 units per day, less than half of the plan. The shaded area is the uncertainty range.

> The gap between the grey and the blue is where the inventory exposure lives. The business bought to plan. The current forecast is much lower. That is the overstock."

### What Generated The Break (For The Technically Curious)

The demand break has three components, all visible in the data:

1. **The promo pulled demand forward.** The Autumn Renewal campaign was planned to run 24 Aug – 14 Sep. It actually ran 3 Aug – 24 Aug, three weeks earlier. Demand arrived in August rather than September, so September actuals arrived without the expected uplift.

2. **Search interest declined early.** The `search_interest_index` signal in the demand data softened about two weeks before the sales break — a leading indicator the explanation tool surfaces.

3. **The prior plan model was trained through 15 August** — which means it saw the start of the promotion correctly but did not see enough of the post-promo demand collapse to adjust its forward expectations.

### What To Say When The CFO Points At The Drop

> "The green line collapsing in August is the promotion pull-forward. Demand arrived early, before the model or the buying team knew it was coming. The prior plan expected a September uplift that had already happened in August. The current model, trained through September 15, has now seen the full break and is forecasting the lower demand level going forward. The gap between grey and blue is the exposure: inventory was bought to the grey level, demand is expected at the blue level."

### What To Say About The Wide Confidence Band

> "The blue shaded area is the 90% prediction interval — the range within which we expect about 90% of actual outcomes to fall. It is wide because the model is forecasting beyond a structural change and has limited post-break history. We intentionally do not hide this uncertainty. A narrow band after a demand break would be false confidence."

### What To Say About The Flat Grey Line

> "The grey dashed line was the prior plan's forward view — essentially flat from the historical average. It was not a bad forecast before the promotion moved. The model did not have enough post-break history at the time it was trained. This is precisely the argument for re-baselining when a promotion shifts more than 14 days."

## Eight-Minute Run Of Show

### Opening: Set The Frame

**Action:** Show the title slide in `pitch/lumora.html`, then move to the Streamlit app.

**Say:**

> “Lumora can move from fragmented brand data to a governed decision loop: identify demand risk, explain why it exists, test an action, and learn from the outcome. The numbers in this demo are synthetic and illustrative. The workflow is the point.”

Do not say that the demo predicts actual Lumora financial results.

---

### Act 1 — Find The Risk

**Time:** 60 seconds

**Action:** In the app, open `1 CFO Cockpit`. Point to:

- Inventory value at risk.
- Forecast WAPE and bias.
- Markdown exposure.
- Cross-brand coverage.
- The brand-by-region heatmap.
- The inventory risk waterfall.

**Say:**

> “The CFO question is: which part of the group needs attention first? The answer is Aurelia SKINCARE in DACH. It carries about EUR 87K of illustrative inventory exposure, or roughly 35% of the group total. That is not a predicted loss. It is the modeled cost of stock beyond the next 45 days of forecast demand.”

> “The slice has about 150 days of cover against a 45-day policy target. That tells us the immediate problem is excess inventory, not a shortage.”

**Explain if asked:**

- “Inventory value at risk” is an exposure measure, not a probability. It is the cost value of units that the current forecast does not expect to sell within the policy horizon.
- “Illustrative” means the units, costs, prices, and currency totals were generated for this demo.
- The waterfall shows how exposure is distributed across slices. It is not a statutory inventory valuation.

**Transition:**

> “The KPI identifies where to look. It does not yet explain why the position developed. That is the agent's job.”

---

### Act 2 — Explain The Risk

**Time:** 90 seconds

**Action:** Open `4 Agent Decision Panel`. Click the suggested question:

> `Why is inventory risk highest for this brand?`

If needed, type:

> “Why is inventory risk highest for Aurelia skincare in DACH, and what evidence supports that conclusion?”

Open the tool trace after the answer appears.

**Look for:**

- `get_lumora_kpis`.
- `explain_forecast_variance`.
- The observed-fact and calculation distinction.
- Promotion timing as a driver.

**Say:**

> “The agent is not calculating the KPI in natural language. It calls governed SQL tools, then explains the returned evidence.”

> “The prior plan over-forecast this slice by about 61%. The campaign was planned for August 24 but actually ran on August 3, 21 days early. Demand was pulled forward, so the plan expected demand in September that had already happened in August.”

> “Search interest also softened before the sales break. That is a corroborating leading signal, not proof by itself.”

**Finance translation:**

- A **forecast bias of +61.3%** means the prior plan expected substantially more demand than actually arrived. Positive bias here means over-forecasting.
- **Forecast error** describes how far the forecast was from actual demand. It does not automatically tell us whether the error was too high or too low.
- **WAPE** means weighted absolute percentage error. It measures the size of the errors without allowing over- and under-forecast errors to cancel each other. Lower is better.

**Say if the agent labels a number:**

> “Observed fact means it came directly from a recorded business event or data field. Calculation means SQL derived it from those facts. Assumption means we chose a planning convention. Recommendation means a human still has to decide.”

**Transition:**

> “Now we can test whether a commercial action is large enough to change the position.”

---

### Act 3 — Test A Scenario

**Time:** 75 seconds

**Action:** Stay in the Agent Decision Panel and use the scenario controls:

- Demand uplift: `12%`.
- Promotion window: `4 weeks`.

The app should show the sensitivity curve, remaining excess, and breakeven uplift. If using the suggested question, click:

> `What would happen if demand increased 12% during the promotion?`

**Say:**

> “A 12% demand uplift over four weeks adds demand, but it only removes about 3% of the excess position. The promotion-only breakeven is roughly 365%, which is not a credible commercial plan.”

> “That changes the decision. This is not primarily a promotion problem. It is a markdown, purchase-order, or inventory-commitment decision that needs a human owner.”

**Finance translation:**

- A **demand uplift** is a percentage change applied to forecast units for a defined period. It is not automatically a 12% revenue increase or a 12% profit increase.
- **Markdown exposure** is the modeled value of discount risk on excess units. This demo uses an assumed 40% rate applied to excess inventory at cost. It is not an actual expected write-off.
- A **markdown** is a price reduction used to move inventory. A **write-off** is recognizing that inventory will not recover its recorded value.

**Important wording:**

> “The scenario changes the forecast assumption. It does not approve a promotion, cancel an order, or authorize a markdown.”

**Transition:**

> “The next question is whether this is one brand's problem or a pattern the group could only see after unifying the data.”

---

### Act 4 — Show The Cross-Brand Pattern

**Time:** 60 seconds

**Action:** Open `2 Forecast Explorer` or `3 Customer & Demand Drill-Down`.

Show:

- The actual-versus-forecast chart.
- The prior plan line compared with the current forecast.
- The model version and refresh timestamp.
- The DACH SKINCARE slices for Aurelia, Solene, and Verdant.
- Cross-brand customer coverage if using the drill-down tab.

Use the suggested question:

> `What changed versus last month's forecast?`

**Say:**

> “This is a group pattern: three brands in the same region and category are exposed. The source systems are different, but the governed model preserves the source-system field and creates a shared customer_group_id for cross-brand analysis.”

> “About 22% of customer groups are visible across more than one brand after identity resolution. That is the kind of group-level view that isolated brand systems cannot provide.”

**Finance translation:**

- **Days of cover** equals available units divided by average daily forecast demand. It answers: “If demand follows the current forecast, how many days can current stock support?”
- **Re-baselining** means replacing the forecast baseline after a material event changes the assumptions. A promotion moved more than 14 days from its planned start is treated by the synthetic governance policy as a reason to re-baseline.
- A **customer_group_id** is the governed cross-brand identity key. It links brand-local customer IDs only where the identity-resolution process says the link is valid.

---

### Act 5 — Make Governance Visible

**Time:** 60 seconds

**Action:** Open `3 Customer & Demand Drill-Down`. Show:

- Region and residency zone.
- Customer sensitivity classification.
- Source system.
- Promotion planned versus actual dates.
- Policy search results, if available.

Ask:

> “Can we use EU customer data in this scenario, and what constraint should we check?”

**Say:**

> “The synthetic policy distinguishes aggregate analytics from identified-person processing. Aggregate demand and inventory analysis can be used for this decision. Extending the workflow to target identified EU customers is a different processing purpose and requires documented human approval.”

> “This is a governance answer, not a legal opinion. The agent grounds the answer in the policy corpus and flags the control that still requires a human decision.”

**Architecture language:**

> “Residency zone, sensitivity class, source system, and model version travel with the result. They are not hidden metadata added after the answer.”

**Do not say:**

- “The system has automatically approved GDPR use.”
- “The agent is a lawyer.”
- “EU data is unrestricted because the KPI is aggregated.”

---

### Act 6 — Separate The Two Learning Loops

**Time:** 75 seconds

**Action:** Open `5 Model Improvement`. Show both columns:

- Numeric forecast retraining.
- LLM fine-tuning for explanation behavior.

Show the pre-staged comparison tables. If time permits, submit one request in each panel.

**Say:**

> “The CFO correction is: the explanation is missing promotion timing. That creates two different improvement paths.”

> “Numeric forecast retraining changes the numbers. We add promotion timing as a feature, refit the demand model, evaluate it, and decide whether to promote the candidate. The pre-staged comparison shows WAPE improving from about 61.3% to 13.5% for the affected slice.”

> “Language-model fine-tuning changes how the agent explains the result. It teaches the response to cite promotion timing. It does not recalculate demand, inventory, or financial exposure.”

**Finance translation:**

- **Model version** identifies which forecast produced a number. A decision should not use an unlabeled forecast.
- **Retraining** changes the numeric model and can change predicted units.
- **Fine-tuning** changes language behavior such as structure, classification, or explanation style. It is not a replacement for numeric model retraining.
- **Pre-staged** means the workflow and comparison are shown live, but the completed candidate result was prepared before the presentation so nobody waits for a training job.

**If a request returns a status:**

> “The request record is live. The completed comparison is pre-staged. Promotion of the model or use of the tuned response still requires review.”

---

### Act 7 — Close With A Bounded First Step

**Time:** 40 seconds

**Action:** Return to `1 CFO Cockpit` or the closing deck slide.

**Say:**

> “The smallest funded first step is bounded: unify Aurelia, Solene, and Verdant for SKINCARE in DACH; operationalize the forecast; and run the governed agent over that decision workflow.”

> “Measure success by forecast quality, decision speed, and reduction of avoidable inventory exposure. We are not claiming a precise ROI from synthetic data.”

> “The value is the loop: data foundation, forecast, explanation, scenario, decision, feedback, improvement.”

Stop there. Do not add an unsupported savings estimate.

## Finance Terminology Cheat Sheet

| Term | Plain-English meaning | How to explain it in the demo | What it is not |
|---|---|---|---|
| Inventory | Products the company owns or has ordered for sale. | “The stock position we need to manage.” | Cash profit or revenue. |
| Inventory value at risk | Cost value of available stock beyond the current forecast horizon. | “Stock we may need to discount, cancel, or hold longer than policy intends.” | A guaranteed loss or probability of loss. |
| Days of cover | Available units divided by average daily forecast demand. | “How many days current stock can support if the forecast is right.” | A sales forecast by itself. |
| Target cover | The policy amount of inventory coverage the business wants to hold. | “The 45-day policy target used in this demo.” | A universal best practice for every business. |
| Forecast | Expected future demand in units. | “What the model expects customers to buy.” | A commitment that customers will buy it. |
| Forecast bias | Directional error: forecast minus actual, divided by actual. | “Positive bias means the plan expected too much demand here.” | The same thing as WAPE. |
| WAPE | Weighted absolute percentage error: total absolute error divided by total actual demand. | “How large the forecast errors were overall, without over- and under-forecast canceling.” | A measure of profitability. |
| Stockout risk | Forecast demand exceeds available inventory. | “Demand may arrive when we do not have enough product.” | The same as excess inventory risk. |
| Stockout margin at risk | Uncovered demand multiplied by illustrative gross margin per unit. | “The margin we might miss if demand arrives without stock.” | Revenue lost with certainty. |
| Gross margin | Selling price minus direct unit cost, before other operating costs. | “The contribution left after the product cost.” | Net income or EBITDA. |
| Markdown | A reduction in selling price to move inventory. | “A commercial action to clear excess stock.” | A model output that management must accept automatically. |
| Markdown exposure | Excess inventory at cost multiplied by an assumed markdown rate. | “A modeled planning exposure if excess stock needs discounting.” | An actual accounting reserve or realized loss. |
| Write-off | Recognizing that inventory value will not be recovered. | “A more severe outcome than a markdown.” | The same thing as a promotion. |
| Demand uplift | Percentage increase applied to forecast demand for a stated window. | “A what-if assumption, such as 12% for four weeks.” | A guaranteed increase in revenue or profit. |
| Re-baseline | Replace the forecast baseline after a material assumption changes. | “A promotion moved 21 days, so the old baseline no longer describes the plan.” | Retraining the language model. |
| Model version | Identifier for the forecast model that generated a result. | “The number is traceable to `fcst-v1.1-trained-2026-09-15`.” | Proof that the model is accurate. |
| Customer group ID | Governed key that links a person's brand-local identities across brands when approved. | “The shared identity key that makes cross-brand behavior visible.” | Permission to use personal data for any purpose. |

## How To Classify Every Statement

Use these labels when speaking and when reading the agent trace:

- **Observed fact:** directly recorded in source data, such as a promotion's actual start date.
- **Calculation:** derived by SQL, such as forecast bias, days of cover, or inventory exposure.
- **Assumption:** a chosen planning convention, such as the 45-day target or 40% markdown rate.
- **Recommendation:** a proposed next action that a human must review.

A safe sentence pattern is:

> “Observed fact: the promotion moved 21 days. Calculation: the affected slice has +61.3% forecast bias and 149.8 days of cover. Assumption: the demo uses a 45-day target and a 40% markdown rate. Recommendation: pause or review the next inventory commitment with a human owner.”

## Fallback Instructions

If the live agent does not respond:

1. Stay in `4 Agent Decision Panel`.
2. Wait briefly for the warning that the live call is unavailable.
3. Use the displayed deterministic fallback answer.
4. Open `Tool trace (fallback)` and `Evidence & assumptions (fallback)`.
5. Say:

> “The live orchestration path is unavailable in this moment, so the app is rendering the deterministic answer generated from the same governed views. The numbers remain inspectable; I am not presenting an invented answer.”

The fallback acts are stored in:

```text
LUMORA_DEMO.AGENT.DEMO_FALLBACK
```

If the scenario procedure is slow, use the sensitivity curve already rendered by the app. It is calculated from the same `V_SLICE_RISK` forecast and inventory values.

If a request button fails, show the pre-staged comparison table and say:

> “The request workflow is shown, but this presentation is not waiting for a live training job. The completed comparison is pre-staged and labeled as such.”

## Likely Questions

### “Is EUR 251K a real Lumora exposure?”

> “No. It is synthetic and illustrative. It demonstrates how the metric is calculated and governed; it is not a Lumora financial statement or forecast.”

### “Why is the top slice called value at risk if it is not a probability?”

> “Here, risk means exposure: the cost value of stock beyond the current forecast horizon. We intentionally do not present it as a probability of loss.”

### “Why does a 12% promotion not solve the problem?”

> “Because the slice holds roughly 150 days of cover. A four-week uplift affects only a small part of the excess. The computed breakeven uplift is around 365%, so the decision is likely inventory action rather than promotion alone.”

### “What is the difference between WAPE and bias?”

> “WAPE tells us how large the errors were. Bias tells us the direction. This slice has both a large error and positive bias, meaning it was over-forecast.”

### “Can the agent approve a markdown or cancel a purchase order?”

> “No. It can calculate exposure and recommend a bounded next step. Pricing, inventory commitment, customer treatment, and model promotion remain human decisions.”

### “Why preserve the source system?”

> “Because unification should not erase lineage. The CFO sees one group view, while the architect can still ask which source produced the underlying records.”

### “Why do the tools return JSON instead of a table?”

> “Cortex Agent generic tools require a single-cell result. The stored procedures therefore return a single JSON object or array, while the calculations remain relational SQL inside the procedure.”

### “Did you fine-tune the language model live?”

> “No. The feedback is captured live and the base-versus-tuned comparison is pre-staged. That is deliberate for a short demo. Numeric forecast retraining and language fine-tuning are separate workflows.”

### “Where is the Model Registry?”

> “It is not part of this minimum viable build. The demo shows model version and evaluation metadata without implying that the built-in forecast object is a registered model. Model Registry and drift monitoring are stretch items.”

### “Can the app handle real customer data?”

> “The architecture includes residency and sensitivity metadata and a policy-search path. Any real deployment would require the organization's approved privacy, security, access-control, and retention process. This demo uses synthetic data.”

## Closing Reminder

The winning message is not “we built a forecast” or “we built an agent.” It is:

> “We built a governed retail decision loop that turns fragmented data into a traceable decision, tests the next action, and learns in two distinct ways: better numbers and better explanations.”
