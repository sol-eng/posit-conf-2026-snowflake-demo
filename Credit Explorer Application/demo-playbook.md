# Credit Risk Explorer — Demo Playbook (end-to-end)

A ~15-minute play in eight beats. Each beat names what to do, what Snowflake machinery it exercises, what the audience sees, and the talking point to land. The arc: portfolio → segment → individual customer → **score her** → score the whole segment → wrap.

**Persona framing:** a credit risk analyst at a consumer lender. No SQL, no Python — a governed self-service app built in Posit Workbench, published to Posit Connect, querying Snowflake as the *viewer's own identity* via Connect's Snowflake OAuth integration. No credentials in code, no data copied out.

---

## Beat 0 — Set the scene (1 min)

Open the app fresh. Point out: 10,000 customers in view, compact KPI strip, four live charts, chat with clickable starter questions.

**Land:** "Everything here is a live Snowflake query — the raw tables, the Feature Store views, and (later) the ML model. The chat turns English into Snowflake SQL via Cortex."

## Beat 1 — Portfolio question, aggregate answer (2 min)

**Ask:** *"What is the default rate by loan purpose and home ownership?"*

- **Exercises:** `CREDIT_LOANS` ⋈ `CREDIT_CUSTOMERS` (raw ⋈ raw)
- **See:** answer as a table in the chat; expand the **Generated SQL** accordion under the results. Charts don't move — aggregates aren't a customer list.
- **Land:** transparency — "the SQL is always one click away, verifiable and reproducible. Nothing is hallucinated; numbers come from Snowflake."

## Beat 2 — Segment the book (clickable card) (2 min)

**Click the suggestion card:** *"Which customers earning under $60,000 have missed more than 20 percent of their payments?"*

- **Exercises:** `CREDIT_CUSTOMERS` ⋈ `PAYMENT_BEHAVIOR_FV$v1` (raw ⋈ Feature Store)
- **See:** the whole dashboard re-scopes — KPIs drop to the segment, scatter shows just those customers, purpose and payment-trend charts recompute.
- **Land:** "The chat result carries customer IDs and every visualization follows them. And we just joined a raw table to a Snowflake Feature Store view — same features the ML model was trained on."

## Beat 3 — Conversational refinement, three-way join (2 min)

**Follow up:** *"Of those, which also have more than 2 prior defaults? Sort by highest average days past due."*

- **Exercises:** previous segment + `CREDIT_HISTORY_FV$v1` (three sources, conversation memory)
- **See:** a tight high-risk cohort (~tens of customers); KPIs and charts tighten again. Try one of the LLM's own follow-up suggestion cards here — it proposes next questions.
- **Land:** "It remembered 'of those.' Analysts iterate toward the risk pocket — no ticket to the BI team."

## Beat 4 — Drill into one customer (1.5 min)

**Click a row** in the results table (click it again to deselect and return to the cohort view).

- **Exercises:** `CREDIT_PAYMENTS` / `CREDIT_LOANS` row-level queries
- **See:** payment chart becomes that customer's payment timeline (days past due, colored by status); loan chart becomes their loan history; orange diamond marks them on the scatter.
- **Land:** "Portfolio to a single account in two clicks."

## Beat 5 — Score that customer, then play what-if (2.5 min)

Switch to the **Score customers** tab. The focus customer is pre-selected — click **Load features** (sliders snap to her real feature values), then **Score this profile**.

- **Exercises:** the registered ML model, served on Snowpark Container Services; features fed from the same Feature Store views
- **See:** a red **Default predicted** (pick a risky customer in Beat 4!) card — "Scored live in Snowflake."
- **Now the fun part — what-if:** drag *Prior defaults* to 0 and *Pct missed* down, re-score → flips to green **No default predicted**. Note *Log income* recalculates automatically when income moves.
- **Land:** "The model runs where the data lives. The analyst can interrogate it — what would it take for this customer to be approvable? — without a data scientist in the room."

## Beat 6 — Batch score the segment (2 min)

Still on the scoring tab: the right card says how many customers are in view from the chat filter. Click **Score cohort**.

- **Exercises:** one SQL statement — feature views joined, model applied per row in Snowflake; no data pulled into R for inference
- **See:** class-count bars (red/green) and a color-coded table of predictions with income, missed rate, and prior defaults for context.
- **Land:** "Fifty customers or the whole book — one in-database call. This is the daily workflow: chat your way to a watchlist, score it, act on it."

## Beat 7 — Reset and wrap (1 min)

Back to Explore → **Reset filters** → full book returns.

**Land the close:** "One app: natural-language exploration over raw tables *and* the Feature Store, linked visual analytics, individual and batch ML scoring — all live in Snowflake, all governed by each viewer's own Snowflake role. Built in Workbench, published to Connect, zero credentials in code."

---

## Quick-reference: action → machinery → effect

| Beat | Action | Snowflake machinery | Dashboard effect |
|---|---|---|---|
| 1 | Default rate by purpose × ownership | LOANS ⋈ CUSTOMERS | Chat table + SQL only |
| 2 | <$60k, >20% missed (card) | CUSTOMERS ⋈ PAYMENT_FV | Full re-scope to segment |
| 3 | + >2 prior defaults, sorted | + CREDIT_HISTORY_FV (3-way) | Tight high-risk cohort |
| 4 | Click a row | PAYMENTS, LOANS by ID | Per-customer timelines |
| 5 | Load features → Score → what-if | Model on SPCS via Feature Store | Red/green prediction card |
| 6 | Score cohort | Set-based in-database inference | Prediction bars + ranked table |
| 7 | Reset | — | Full book |

## Prep checklist

- Warm the warehouse **and** confirm the SPCS compute pool / inference service is running — score one customer before the audience arrives (first SPCS call can be slow).
- Do Beat 4 on a customer with prior defaults so Beat 5 opens with a red card (the Beat 3 cohort is sorted worst-first — pick the top row).
- Have the Beat 3 follow-up question typed somewhere handy.
- Aggregate answers (no CUSTOMER_ID) intentionally don't move the charts — that's the Beat 1 talking point, not a bug.
- Cohorts cap at 2,000 IDs for chart/scoring queries; irrelevant at demo scale.
- Model returns a yes/no label (no probabilities), so batch results are two classes, not a ranking — if asked, that's a model-registration choice, not an app limitation.
- If Cortex responses feel slow, pin a faster model via `CORTEX_MODEL`.
