# Credit Risk Explorer — Shiny + querychat + Snowflake Cortex

Phase 1 demo: a natural-language query chat (powered by Snowflake Cortex via
`ellmer::chat_snowflake()`) over the `CREDIT_RISK_ML` database, with linked
visualizations that follow the customers returned by the chat.

## How the pieces fit

- **querychat** (v0.3.0) drives the chat sidebar. The Snowflake ODBC connection
  is created *per session* and passed via the deferred data-source pattern
  (`QueryChat$new(NULL, ...)` then `qc$server(data_source = con, client = ...)`).
- **Cortex** is the LLM: `chat_snowflake()` uses the same ambient credentials
  as the ODBC connection on both Workbench and Connect.
- Chat results (`qc_vals$df()`) are harvested for `CUSTOMER_ID`s; those IDs
  scope every chart. A focus-customer picker (or clicking a table row) drills
  the payment/loan charts into a single customer.
- The LLM is instructed (via `extra_instructions`) to always include
  `CUSTOMER_ID` in dashboard results and to join across all six tables with
  fully qualified, correctly quoted names (the `"...FV$v1"` views).

## Requirements

R packages: `shiny`, `bslib`, `bsicons`, `DBI`, `odbc` (>= 1.4.0 with
`odbc::snowflake()`), `dplyr`, `DT`, `plotly`, `querychat` (>= 0.3.0),
`ellmer` (>= 0.4.0), `connectcreds`, `snowflakeauth`.

A Snowflake ODBC driver must be installed on Workbench and Connect
(usually already configured by your admin).

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `SNOWFLAKE_ACCOUNT` | — | Account identifier, e.g. `myorg-myaccount`. Needed by `chat_snowflake()` and local dev. |
| `SNOWFLAKE_DATABASE` | `CREDIT_RISK_ML` | |
| `SNOWFLAKE_RAW_SCHEMA` | `PUBLIC` | Schema containing CREDIT_CUSTOMERS / CREDIT_LOANS / CREDIT_PAYMENTS |
| `SNOWFLAKE_FEATURES_SCHEMA` | `FEATURES` | Schema containing the `*_FV$v1` feature views |
| `SNOWFLAKE_WAREHOUSE` | (unset) | Optional; set if no default warehouse on the role |
| `CORTEX_MODEL` | (ellmer default) | e.g. `claude-sonnet-4-5`, `mistral-large2` — must be enabled in your Cortex region |
| `SNOWFLAKE_USER` | — | Local dev only (external browser auth) |

## Auth branching

`POSIT_PRODUCT` decides the path — no code changes between environments:

- **Workbench**: managed Snowflake credentials (sign in via the Workbench
  credentials pane). Both `odbc::snowflake()` and `chat_snowflake()` pick up
  the session token automatically.
- **Connect**: the Snowflake OAuth integration must be added to the deployed
  content (Content settings → Access → Add integration). `connectcreds`
  exchanges the viewer's session token automatically; each viewer queries
  Snowflake **as themselves**.
- **Local**: `externalbrowser` SSO using `SNOWFLAKE_ACCOUNT` / `SNOWFLAKE_USER`.

## Deploying from Workbench to Connect

1. In Workbench, sign in to Snowflake via managed credentials and run the app
   to test.
2. Publish (push-button or `rsconnect::deployApp()`).
3. On Connect: set the environment variables above in the content's Vars pane.
4. On Connect: attach the Snowflake OAuth integration to the content.
5. Open the app — viewers authenticate to Snowflake with their own identity.

## Phase 2 (planned)

Score customers with `CREDIT_RISK_ML.MODELS.SFR_CREDIT_SCORER` from a new tab:
user provides feature inputs (or picks a customer), app calls the model
function in Snowflake and displays the score.
