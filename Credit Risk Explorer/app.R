# =============================================================================
# Credit Risk Explorer — Shiny + querychat + Snowflake Cortex
#
# Phase 1: natural-language query chat (Cortex) over the CREDIT_RISK_ML
#          database, with linked visualizations driven by chat results.
# Phase 2: customer scoring via MODELS.SFR_CREDIT_SCORER (placeholder tab).
#
# Deploys from Posit Workbench to Posit Connect. Snowflake auth branches on
# POSIT_PRODUCT: Workbench-managed credentials, Connect viewer OAuth, or
# external-browser auth for local development. Both the ODBC connection and
# ellmer::chat_snowflake() (Cortex LLM) pick up the same ambient credentials.
# =============================================================================

# jsonlite MUST be attached before shiny: it exports validate(), which would
# otherwise mask shiny::validate() and break every output that validates data.
library(jsonlite)
library(shiny)
library(bslib)
library(bsicons)
library(DBI)
library(odbc)
library(dplyr)
library(DT)
library(plotly)
library(querychat)
library(ellmer)
library(whisker)
# Loaded for side effects: required on Posit Connect / Workbench so that
# viewer/session-based Snowflake credentials are picked up, even though
# they are never called explicitly.
library(connectcreds)
library(snowflakeauth)

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- Configuration (override via environment variables) ---------------------
DB_NAME     <- Sys.getenv("SNOWFLAKE_DATABASE", "CREDIT_RISK_ML")
RAW_SCHEMA  <- Sys.getenv("SNOWFLAKE_RAW_SCHEMA", "RAW_DATA")
FEAT_SCHEMA <- Sys.getenv("SNOWFLAKE_FEATURES_SCHEMA", "FEATURES")
WAREHOUSE   <- Sys.getenv("SNOWFLAKE_WAREHOUSE", "")
# Cortex model for the chat. Empty -> ellmer's current default.
CORTEX_MODEL <- Sys.getenv("CORTEX_MODEL", "")
MAX_COHORT   <- 2000  # cap on customer IDs passed into viz SQL IN () clauses

# Fully qualified table names
TBL_CUSTOMERS <- sprintf("%s.%s.CREDIT_CUSTOMERS", DB_NAME, RAW_SCHEMA)
TBL_LOANS     <- sprintf("%s.%s.CREDIT_LOANS", DB_NAME, RAW_SCHEMA)
TBL_PAYMENTS  <- sprintf("%s.%s.CREDIT_PAYMENTS", DB_NAME, RAW_SCHEMA)
FV_PROFILE    <- sprintf('%s.%s."CUSTOMER_PROFILE_FV$v1"', DB_NAME, FEAT_SCHEMA)
FV_PAYMENT    <- sprintf('%s.%s."PAYMENT_BEHAVIOR_FV$v1"', DB_NAME, FEAT_SCHEMA)
FV_HISTORY    <- sprintf('%s.%s."CREDIT_HISTORY_FV$v1"', DB_NAME, FEAT_SCHEMA)

# ---- Scoring model (Snowflake Model Registry) --------------------------------
MODELS_SCHEMA <- Sys.getenv("SNOWFLAKE_MODELS_SCHEMA", "MODELS")
MODEL_NAME    <- Sys.getenv("SNOWFLAKE_MODEL_NAME", "SFR_CREDIT_RISK_SCORER")
# Empty (default) = call the model's default version directly:
#   DB.SCHEMA.MODEL!PREDICT(...)
# Set SNOWFLAKE_MODEL_VERSION (e.g. "BLUE_TIGER_2") to pin a version via:
#   MODEL("DB"."SCHEMA"."MODEL", "VERSION") ! "PREDICT"(...)
MODEL_VERSION <- Sys.getenv("SNOWFLAKE_MODEL_VERSION", "")
# Optional: name of an SPCS inference service (e.g.
# "SFR_CREDIT_RISK_SCORER_BLUE_TIGER_2_SERVICE"). If set, predictions are
# invoked on the service directly instead of the model object. Alternatively,
# run once in a worksheet:
#   ALTER MODEL CREDIT_RISK_ML.MODELS.SFR_CREDIT_RISK_SCORER
#     SET DEFAULT_COMPUTE_POOL = R_CREDIT_POOL;
# and the plain model!PREDICT() call below is routed to the pool.
SCORING_SERVICE <- Sys.getenv(
  "SNOWFLAKE_SCORING_SERVICE",
  "SFR_CREDIT_RISK_SCORER_BLUE_TIGER_2_SERVICE"
)

# Input features, in the exact order of the model signature
FEATURE_COLS <- c(
  "AGE", "ANNUAL_INCOME", "EMPLOYMENT_LENGTH_YEARS", "HOME_OWNERSHIP",
  "LOG_INCOME", "AVG_DAYS_PAST_DUE", "MAX_DAYS_PAST_DUE", "PCT_MISSED",
  "PCT_ON_TIME", "AVG_PAYMENT_AMOUNT", "TOTAL_PAYMENTS", "TOTAL_APPLICATIONS",
  "AVG_LOAN_AMOUNT", "MAX_LOAN_AMOUNT", "PRIOR_DEFAULTS", "AVG_INTEREST_RATE"
)

MODEL_CALL <- if (nzchar(SCORING_SERVICE)) {
  sprintf(
    "%s.%s.%s!PREDICT(%s)",
    DB_NAME, MODELS_SCHEMA, SCORING_SERVICE,
    paste(FEATURE_COLS, collapse = ", ")
  )
} else if (nzchar(MODEL_VERSION)) {
  sprintf(
    'MODEL("%s"."%s"."%s", "%s") ! "PREDICT"(%s)',
    DB_NAME, MODELS_SCHEMA, MODEL_NAME, MODEL_VERSION,
    paste(FEATURE_COLS, collapse = ", ")
  )
} else {
  sprintf(
    "%s.%s.%s!PREDICT(%s)",
    DB_NAME, MODELS_SCHEMA, MODEL_NAME,
    paste(FEATURE_COLS, collapse = ", ")
  )
}
MODEL_VERSION_LABEL <- if (nzchar(SCORING_SERVICE)) {
  paste0("service: ", SCORING_SERVICE)
} else if (nzchar(MODEL_VERSION)) {
  MODEL_VERSION
} else {
  "default version"
}

# SELECT list pulling all 16 model features from the joined feature views
FEATURES_SELECT <- "
  c.CUSTOMER_ID, c.AGE, c.ANNUAL_INCOME, c.EMPLOYMENT_LENGTH_YEARS,
  c.HOME_OWNERSHIP, c.LOG_INCOME,
  p.AVG_DAYS_PAST_DUE, p.MAX_DAYS_PAST_DUE, p.PCT_MISSED, p.PCT_ON_TIME,
  p.AVG_PAYMENT_AMOUNT, p.TOTAL_PAYMENTS,
  h.TOTAL_APPLICATIONS, h.AVG_LOAN_AMOUNT, h.MAX_LOAN_AMOUNT,
  h.PRIOR_DEFAULTS, h.AVG_INTEREST_RATE"

# Parse the VARIANT/JSON returned by !PREDICT into a numeric score.
# This model returns {"prediction": "yes"/"no"} (yes = default predicted).
# Also handles numeric labels/probabilities in case the model changes.
parse_score <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x)) return(NA_real_)
  obj <- tryCatch(jsonlite::fromJSON(as.character(x)), error = function(e) NULL)
  if (is.null(obj)) return(suppressWarnings(as.numeric(x)))
  flat <- unlist(obj, use.names = TRUE)
  if (length(flat) == 0) return(NA_real_)
  # Categorical labels (yes/no)
  labs <- tolower(trimws(as.character(flat)))
  if (any(labs %in% c("yes", "true", "default"))) return(1)
  if (any(labs %in% c("no", "false", "no_default"))) return(0)
  # Numeric outputs: prefer probability-like fields
  vals <- suppressWarnings(as.numeric(flat))
  pref <- grep("proba|probability|score|_1$", names(flat), ignore.case = TRUE)
  pref <- pref[!is.na(vals[pref])]
  if (length(pref) > 0) return(vals[pref[length(pref)]])
  ok <- which(!is.na(vals))
  if (length(ok) > 0) return(vals[ok[1]])
  NA_real_
}

score_label <- function(v) {
  ifelse(v >= 0.5, "Default", "No default")
}

format_score <- function(v) {
  if (is.na(v)) return("Score unavailable")
  if (abs(v - round(v)) > 1e-9 && v >= 0 && v <= 1) {
    sprintf("%.1f%% default probability", 100 * v)
  } else if (v >= 0.5) {
    "Default predicted"
  } else {
    "No default predicted"
  }
}

# ---- Snowflake connection (Workbench / Connect / local) ---------------------
create_connection <- function() {
  on_connect   <- Sys.getenv("POSIT_PRODUCT") == "CONNECT"
  on_workbench <- Sys.getenv("POSIT_PRODUCT") == "WORKBENCH"

  args <- list(odbc::snowflake(), database = DB_NAME, schema = RAW_SCHEMA)
  if (nzchar(WAREHOUSE)) args$warehouse <- WAREHOUSE

  if (on_workbench || on_connect) {
    # Workbench: managed Snowflake credentials via the session token.
    # Connect: connectcreds retrieves the viewer's OAuth token automatically.
    do.call(DBI::dbConnect, args)
  } else {
    # Local development fallback: browser-based SSO
    args$account       <- Sys.getenv("SNOWFLAKE_ACCOUNT")
    args$uid           <- Sys.getenv("SNOWFLAKE_USER")
    args$authenticator <- "externalbrowser"
    do.call(DBI::dbConnect, args)
  }
}

# ---- Context for the LLM ----------------------------------------------------
data_description <- paste0(
  "Snowflake database ", DB_NAME, " contains consumer credit risk data.\n\n",
  "RAW TABLES (schema ", RAW_SCHEMA, "):\n\n",
  "1. ", TBL_CUSTOMERS, " (10,000 rows) - one row per customer.\n",
  "   Columns: CUSTOMER_ID (NUMBER, PK), AGE (NUMBER), ANNUAL_INCOME (NUMBER, dollars),\n",
  "   EMPLOYMENT_LENGTH_YEARS (NUMBER, decimal), HOME_OWNERSHIP (TEXT: RENT, MORTGAGE, etc.),\n",
  "   STATE (TEXT, US state abbreviation).\n\n",
  "2. ", TBL_LOANS, " (50,000 rows) - loan applications, ~5 per customer.\n",
  "   Columns: APPLICATION_ID (NUMBER, PK), CUSTOMER_ID (NUMBER, FK), APPLICATION_DATE (DATE),\n",
  "   LOAN_AMOUNT (NUMBER, dollars), LOAN_TERM_MONTHS (NUMBER: 36, 48, 60, ...),\n",
  "   INTEREST_RATE (FLOAT, annual percent), LOAN_PURPOSE (TEXT: HOME_IMPROVEMENT, EDUCATION,\n",
  "   OTHER, etc.), DEFAULTED (NUMBER: 1 = defaulted, 0 = not; this is the ML target label).\n\n",
  "3. ", TBL_PAYMENTS, " (200,000 rows) - payment history, ~20 per customer.\n",
  "   Columns: CUSTOMER_ID (NUMBER, FK), PAYMENT_DATE (DATE), PAYMENT_AMOUNT (NUMBER, dollars),\n",
  "   DAYS_PAST_DUE (NUMBER, 0 = on time), PAYMENT_STATUS (TEXT: ON_TIME, MISSED, etc.).\n\n",
  "FEATURE VIEWS (schema ", FEAT_SCHEMA, ", one row per customer, entity key CUSTOMER_ID):\n\n",
  "4. ", FV_PROFILE, " - profile features:\n",
  "   CUSTOMER_ID, AGE, ANNUAL_INCOME, EMPLOYMENT_LENGTH_YEARS, HOME_OWNERSHIP,\n",
  "   LOG_INCOME (FLOAT, engineered log-transformed income).\n\n",
  "5. ", FV_PAYMENT, " - aggregated payment behavior:\n",
  "   CUSTOMER_ID, AVG_DAYS_PAST_DUE, MAX_DAYS_PAST_DUE, PCT_MISSED (0.0-1.0),\n",
  "   PCT_ON_TIME (0.0-1.0), AVG_PAYMENT_AMOUNT, TOTAL_PAYMENTS.\n\n",
  "6. ", FV_HISTORY, " - aggregated loan history:\n",
  "   CUSTOMER_ID, TOTAL_APPLICATIONS, AVG_LOAN_AMOUNT, MAX_LOAN_AMOUNT,\n",
  "   PRIOR_DEFAULTS (count), AVG_INTEREST_RATE.\n\n",
  "RELATIONSHIPS: all tables and feature views join on CUSTOMER_ID.\n",
  "CREDIT_CUSTOMERS -> CUSTOMER_PROFILE_FV, CREDIT_PAYMENTS -> PAYMENT_BEHAVIOR_FV,\n",
  "CREDIT_LOANS -> CREDIT_HISTORY_FV. DEFAULTED in CREDIT_LOANS is the ML target label."
)

extra_instructions <- paste0(
  "- The backing database is Snowflake: write Snowflake SQL only.\n",
  "- Always use fully qualified table names exactly as given in the data description,\n",
  "  e.g. ", TBL_LOANS, " or ", FV_PAYMENT, ".\n",
  "- Feature view names contain a $ and a lowercase v; they MUST be double-quoted exactly:\n",
  '  "CUSTOMER_PROFILE_FV$v1", "PAYMENT_BEHAVIOR_FV$v1", "CREDIT_HISTORY_FV$v1".\n',
  "- You may (and should) JOIN across any of these tables to answer questions.\n",
  "- When updating the dashboard, ALWAYS include the CUSTOMER_ID column in the result set\n",
  "  whenever the result is at the customer or loan level. The app uses CUSTOMER_ID to link\n",
  "  the visualizations to your results.\n",
  "- Queries are read-only: never issue DDL or DML."
)

# Each list item below is a <span class="suggestion"> — shinychat (>= 0.4.0)
# renders a list of these as a grid of clickable cards. Clicking a card
# submits the body text as the user's message; the title is the card heading.
greeting <- paste0(
  "### Credit Risk Explorer\n\n",
  "Ask about customers, loans, and payment behavior in plain English. ",
  "Answers come straight from Snowflake, and the dashboard follows the ",
  "customers in each result.\n\n",
  '- <span class="suggestion" title="High-risk customers">',
  "Show customers with more than 2 prior defaults and an average of 15 or more days past due",
  "</span>\n",
  '- <span class="suggestion" title="Delinquent segment">',
  "Which customers earning under $60,000 have missed more than 20 percent of their payments?",
  "</span>\n",
  '- <span class="suggestion" title="Portfolio breakdown">',
  "What is the default rate by loan purpose and home ownership?",
  "</span>\n",
  '- <span class="suggestion" title="Emerging risk">',
  "Show renters under 35 whose education loans defaulted in the last two years",
  "</span>\n"
)

# ---- QueryChat (deferred data source: connection is per-session) ------------
qc <- QueryChat$new(
  NULL,
  table_name = "CREDIT_CUSTOMERS",
  id = "credit_chat",
  greeting = greeting,
  data_description = data_description,
  extra_instructions = extra_instructions,
  tools = c("filter", "query")
)

# What-if feature inputs (ids follow f_<feature> in lower case).
# Sliders for numeric features; ranges sized to the demo data.
# ticks = FALSE keeps the sliders clean (no tick-label grid).
fslider <- function(id, label, min, max, value, step, ...) {
  sliderInput(id, label, min = min, max = max, value = value, step = step,
              ticks = FALSE, ...)
}

feature_inputs <- list(
  fslider("f_age", "Age", 18, 90, 40, 1),
  fslider("f_annual_income", "Annual income", 0, 500000, 65000, 1000, pre = "$"),
  fslider("f_employment_length_years", "Employment (years)", 0, 40, 5, 0.5),
  selectInput("f_home_ownership", "Home ownership",
              choices = c("RENT", "MORTGAGE", "OWN", "OTHER")),
  fslider("f_log_income", "Log income (auto)", 0, 14, 11.08, 0.01),
  fslider("f_avg_days_past_due", "Avg days past due", 0, 60, 5, 0.5),
  fslider("f_max_days_past_due", "Max days past due", 0, 120, 15, 1),
  fslider("f_pct_missed", "Pct missed", 0, 1, 0.1, 0.01),
  fslider("f_pct_on_time", "Pct on time", 0, 1, 0.8, 0.01),
  fslider("f_avg_payment_amount", "Avg payment", 0, 5000, 500, 10, pre = "$"),
  fslider("f_total_payments", "Total payments", 0, 100, 20, 1),
  fslider("f_total_applications", "Total applications", 0, 30, 5, 1),
  fslider("f_avg_loan_amount", "Avg loan amount", 0, 100000, 15000, 500, pre = "$"),
  fslider("f_max_loan_amount", "Max loan amount", 0, 200000, 25000, 500, pre = "$"),
  fslider("f_prior_defaults", "Prior defaults", 0, 10, 0, 1),
  fslider("f_avg_interest_rate", "Avg interest rate (%)", 0, 36, 12, 0.1)
)

# Compact KPI card: small icon + title + value in a single row
kpi_box <- function(title, output_id, icon, theme) {
  card(
    fill = FALSE,
    class = sprintf("text-bg-%s shadow-sm", theme),
    card_body(
      padding = c("0.6rem", "0.9rem"), fillable = FALSE,
      div(
        class = "d-flex align-items-center gap-3",
        bs_icon(icon, size = "1.5rem"),
        div(
          div(class = "small lh-1 opacity-75", title),
          div(class = "fs-5 fw-semibold lh-sm", textOutput(output_id, inline = TRUE))
        )
      )
    )
  )
}

# ---- UI ----------------------------------------------------------------------
ui <- page_navbar(
  title = "Credit Risk Explorer",
  fillable = TRUE,
  sidebar = sidebar(
    width = 400,
    fillable = TRUE,
    qc$ui(icon_assistant = bs_icon("bank")),
    tags$small(
      class = "text-muted",
      "Tip: click a row in the results table to drill into that customer."
    ),
    actionButton("reset", "Reset filters", class = "btn-sm w-100")
  ),
  nav_panel(
    "Explore",
    layout_column_wrap(
      width = 1 / 4, fill = FALSE,
      kpi_box("Customers in view", "vb_n", "people", "primary"),
      kpi_box("Avg annual income", "vb_income", "cash-stack", "success"),
      kpi_box("Avg on-time payment rate", "vb_ontime", "clock-history", "info"),
      kpi_box("Customers with prior default", "vb_defaults", "exclamation-triangle", "warning")
    ),
    layout_columns(
      col_widths = c(7, 5),
      card(
        full_screen = TRUE,
        card_header(textOutput("results_title", inline = TRUE)),
        card_body(
          min_height = "340px",
          DTOutput("results")
        ),
        card_body(
          fill = FALSE, padding = 0,
          accordion(
            open = FALSE,
            accordion_panel(
              "Generated SQL",
              icon = bs_icon("code-slash"),
              tags$small(verbatimTextOutput("sql", placeholder = TRUE))
            )
          )
        )
      ),
      card(
        full_screen = TRUE,
        card_header("Income vs delinquency"),
        plotlyOutput("scatter")
      )
    ),
    layout_columns(
      col_widths = c(4, 4, 4),
      card(
        full_screen = TRUE,
        card_header("Default rate by loan purpose"),
        plotlyOutput("purpose_plot")
      ),
      card(
        full_screen = TRUE,
        card_header(textOutput("payments_title", inline = TRUE)),
        plotlyOutput("payments_plot")
      ),
      card(
        full_screen = TRUE,
        card_header(textOutput("loans_title", inline = TRUE)),
        plotlyOutput("loans_plot")
      )
    )
  ),
  nav_panel(
    "Score customers",
    layout_columns(
      col_widths = c(5, 7),
      card(
        full_screen = TRUE,
        card_header("What-if scoring"),
        card_body(
          fillable = FALSE,
          div(
            class = "d-flex align-items-end gap-2",
            div(
              class = "flex-grow-1",
              selectizeInput(
                "score_customer", "Customer",
                choices = NULL, width = "100%",
                options = list(placeholder = "Pick a customer")
              )
            ),
            div(
              class = "mb-3 flex-shrink-0",
              actionButton("load_features", "Load features",
                           class = "btn-sm btn-outline-primary")
            )
          ),
          do.call(layout_column_wrap,
                  c(list(width = 1 / 2, fill = FALSE, gap = "0.75rem"),
                    feature_inputs)),
          actionButton("score_one", "Score this profile",
                       class = "btn-primary w-100 mt-3"),
          uiOutput("score_result")
        )
      ),
      card(
        full_screen = TRUE,
        card_header("Batch score the current cohort"),
        card_body(
          p(class = "text-muted small", textOutput("cohort_desc", inline = TRUE)),
          actionButton("score_cohort", "Score cohort", class = "btn-primary"),
          plotlyOutput("score_dist", height = "240px"),
          DTOutput("score_table")
        )
      )
    )
  )
)

# ---- Server -------------------------------------------------------------------
server <- function(input, output, session) {
  con <- create_connection()
  session$onSessionEnded(function() {
    try(DBI::dbDisconnect(con), silent = TRUE)
  })

  # Cortex chat client: same credential branching as the ODBC connection
  # (Workbench-managed credentials, Connect viewer OAuth, or env vars locally).
  #
  # On Connect we must supply credentials explicitly, closing over this
  # session: ellmer's default credential closure calls connectcreds at request
  # time, which happens inside querychat's async ExtendedTask where no Shiny
  # session is available -- the token exchange fails there ("Can't convert a
  # call to a string"). Passing `session` explicitly makes it work anywhere.
  client <- local({
    args <- list()
    if (nzchar(CORTEX_MODEL)) args$model <- CORTEX_MODEL
    if (Sys.getenv("POSIT_PRODUCT") == "CONNECT") {
      sf_url <- sprintf(
        "https://%s.snowflakecomputing.com",
        Sys.getenv("SNOWFLAKE_ACCOUNT")
      )
      shiny_session <- session
      args$credentials <- function() {
        token <- connectcreds::connect_viewer_token(
          sf_url,
          session = shiny_session
        )
        list(
          Authorization = paste("Bearer", token$access_token),
          `X-Snowflake-Authorization-Token-Type` = "OAUTH"
        )
      }
    }
    do.call(chat_snowflake, args)
  })

  qc_vals <- qc$server(data_source = con, client = client)

  observeEvent(input$reset, {
    qc_vals$sql("")
    qc_vals$title(NULL)
  })

  # ---- Chat results -> cohort of customer IDs -------------------------------
  chat_df <- reactive({
    df <- qc_vals$df()
    shiny::validate(shiny::need(is.data.frame(df), "Waiting for data..."))
    df
  })

  filter_active <- reactive({
    nzchar(qc_vals$sql() %||% "") || !is.null(qc_vals$title())
  })

  cohort_ids <- reactive({
    if (!filter_active()) return(NULL)  # NULL = full population
    df <- chat_df()
    id_col <- intersect(c("CUSTOMER_ID", "customer_id"), names(df))
    if (length(id_col) == 0) return(NULL)
    ids <- unique(df[[id_col[1]]])
    ids <- as.integer(ids[!is.na(ids)])
    if (length(ids) == 0) return(integer(0))
    head(ids, MAX_COHORT)
  })

  all_ids <- reactive({
    dbGetQuery(con, sprintf(
      "SELECT CUSTOMER_ID FROM %s ORDER BY CUSTOMER_ID", TBL_CUSTOMERS
    ))$CUSTOMER_ID
  })

  # Focus customer = the selected row in the results table (NULL when
  # deselected, which also clears the chart drill-downs and highlight)
  focus_id <- reactive({
    sel <- input$results_rows_selected
    if (is.null(sel) || length(sel) == 0) return(NULL)
    df <- chat_df()
    id_col <- intersect(c("CUSTOMER_ID", "customer_id"), names(df))
    if (length(id_col) == 0) return(NULL)
    as.integer(df[[id_col[1]]][sel[1]])
  })

  # ---- SQL helpers -----------------------------------------------------------
  in_where <- function(ids, col = "CUSTOMER_ID") {
    if (is.null(ids)) return("")
    if (length(ids) == 0) return(sprintf("WHERE %s IS NULL", col))  # empty cohort
    sprintf("WHERE %s IN (%s)", col, paste(ids, collapse = ","))
  }

  # ---- Data reactives (Snowflake queries scoped to the cohort) ---------------
  features_df <- reactive({
    sql <- sprintf(
      "SELECT c.CUSTOMER_ID, c.AGE, c.ANNUAL_INCOME, c.EMPLOYMENT_LENGTH_YEARS,
              c.HOME_OWNERSHIP,
              p.AVG_DAYS_PAST_DUE, p.MAX_DAYS_PAST_DUE, p.PCT_MISSED, p.PCT_ON_TIME,
              p.AVG_PAYMENT_AMOUNT, p.TOTAL_PAYMENTS,
              h.TOTAL_APPLICATIONS, h.AVG_LOAN_AMOUNT, h.MAX_LOAN_AMOUNT,
              h.PRIOR_DEFAULTS, h.AVG_INTEREST_RATE
       FROM %s c
       LEFT JOIN %s p ON c.CUSTOMER_ID = p.CUSTOMER_ID
       LEFT JOIN %s h ON c.CUSTOMER_ID = h.CUSTOMER_ID
       %s",
      FV_PROFILE, FV_PAYMENT, FV_HISTORY, in_where(cohort_ids(), "c.CUSTOMER_ID")
    )
    dbGetQuery(con, sql)
  })

  purpose_df <- reactive({
    sql <- sprintf(
      "SELECT LOAN_PURPOSE, COUNT(*) AS N_LOANS,
              AVG(DEFAULTED) AS DEFAULT_RATE, AVG(LOAN_AMOUNT) AS AVG_AMOUNT
       FROM %s %s
       GROUP BY LOAN_PURPOSE ORDER BY N_LOANS DESC",
      TBL_LOANS, in_where(cohort_ids())
    )
    dbGetQuery(con, sql)
  })

  payments_df <- reactive({
    fid <- focus_id()
    if (!is.null(fid)) {
      dbGetQuery(con, sprintf(
        "SELECT PAYMENT_DATE, PAYMENT_AMOUNT, DAYS_PAST_DUE, PAYMENT_STATUS
         FROM %s WHERE CUSTOMER_ID = %d ORDER BY PAYMENT_DATE",
        TBL_PAYMENTS, fid
      ))
    } else {
      dbGetQuery(con, sprintf(
        "SELECT DATE_TRUNC('MONTH', PAYMENT_DATE) AS MONTH,
                AVG(DAYS_PAST_DUE) AS AVG_DPD,
                AVG(CASE WHEN PAYMENT_STATUS = 'MISSED' THEN 1 ELSE 0 END) AS MISSED_RATE
         FROM %s %s GROUP BY 1 ORDER BY 1",
        TBL_PAYMENTS, in_where(cohort_ids())
      ))
    }
  })

  loans_df <- reactive({
    fid <- focus_id()
    if (!is.null(fid)) {
      dbGetQuery(con, sprintf(
        "SELECT APPLICATION_DATE, LOAN_AMOUNT, LOAN_TERM_MONTHS, INTEREST_RATE,
                LOAN_PURPOSE, DEFAULTED
         FROM %s WHERE CUSTOMER_ID = %d ORDER BY APPLICATION_DATE",
        TBL_LOANS, fid
      ))
    } else {
      dbGetQuery(con, sprintf(
        "SELECT LOAN_AMOUNT, INTEREST_RATE, DEFAULTED FROM %s %s LIMIT 5000",
        TBL_LOANS, in_where(cohort_ids())
      ))
    }
  })

  # ---- Value boxes -----------------------------------------------------------
  output$vb_n <- renderText({
    format(nrow(features_df()), big.mark = ",")
  })
  output$vb_income <- renderText({
    v <- mean(features_df()$ANNUAL_INCOME, na.rm = TRUE)
    if (is.nan(v)) "-" else paste0("$", format(round(v), big.mark = ","))
  })
  output$vb_ontime <- renderText({
    v <- mean(features_df()$PCT_ON_TIME, na.rm = TRUE)
    if (is.nan(v)) "-" else sprintf("%.1f%%", 100 * v)
  })
  output$vb_defaults <- renderText({
    df <- features_df()
    format(sum(df$PRIOR_DEFAULTS > 0, na.rm = TRUE), big.mark = ",")
  })

  # ---- Results table + SQL ---------------------------------------------------
  output$results_title <- renderText({
    qc_vals$title() %||% "All customers"
  })
  output$results <- renderDT({
    datatable(
      chat_df(),
      fillContainer = TRUE, rownames = FALSE,
      selection = "single",
      options = list(scrollX = TRUE, pageLength = 10, dom = "tip")
    )
  })
  output$sql <- renderText({
    sql <- qc_vals$sql() %||% ""
    if (nzchar(sql)) sql else sprintf("SELECT * FROM %s", TBL_CUSTOMERS)
  })

  # ---- Charts ---------------------------------------------------------------
  output$scatter <- renderPlotly({
    df <- features_df()
    shiny::validate(shiny::need(nrow(df) > 0, "No customers in the current view."))
    if (nrow(df) > 3000) df <- df[sample.int(nrow(df), 3000), ]
    df$RISK <- ifelse(
      !is.na(df$PRIOR_DEFAULTS) & df$PRIOR_DEFAULTS > 0,
      "Prior default", "No prior default"
    )
    p <- plot_ly(
      df,
      x = ~ANNUAL_INCOME, y = ~AVG_DAYS_PAST_DUE,
      color = ~RISK, colors = c("Prior default" = "#d62728", "No prior default" = "#1f77b4"),
      type = "scatter", mode = "markers",
      text = ~paste0("Customer ", CUSTOMER_ID),
      marker = list(opacity = 0.55, size = 7)
    )
    fid <- focus_id()
    if (!is.null(fid) && fid %in% df$CUSTOMER_ID) {
      fdf <- df[df$CUSTOMER_ID == fid, ]
      p <- add_markers(
        p, data = fdf, x = ~ANNUAL_INCOME, y = ~AVG_DAYS_PAST_DUE,
        name = paste("Customer", fid), inherit = FALSE,
        marker = list(size = 16, symbol = "diamond", color = "#ff7f0e",
                      line = list(width = 2, color = "#000000"))
      )
    }
    layout(p,
      xaxis = list(title = "Annual income ($)"),
      yaxis = list(title = "Avg days past due"),
      legend = list(orientation = "h")
    )
  })

  output$purpose_plot <- renderPlotly({
    df <- purpose_df()
    shiny::validate(shiny::need(nrow(df) > 0, "No loans in the current view."))
    plot_ly(
      df,
      x = ~reorder(LOAN_PURPOSE, -DEFAULT_RATE), y = ~DEFAULT_RATE,
      type = "bar",
      text = ~paste0(N_LOANS, " loans"),
      marker = list(color = "#1f77b4")
    ) |>
      layout(
        xaxis = list(title = ""),
        yaxis = list(title = "Default rate", tickformat = ".0%")
      )
  })

  output$payments_title <- renderText({
    fid <- focus_id()
    if (is.null(fid)) "Payment behavior over time (cohort)"
    else sprintf("Payment history — customer %d", fid)
  })
  output$payments_plot <- renderPlotly({
    df <- payments_df()
    shiny::validate(shiny::need(nrow(df) > 0, "No payments in the current view."))
    if (!is.null(focus_id())) {
      # One chronological line through all payments; dots colored by status
      df <- df[order(df$PAYMENT_DATE), ]
      status_cols <- c(
        "ON_TIME" = "#2ca02c", "LATE" = "#ff7f0e", "MISSED" = "#d62728"
      )
      plot_ly(df, x = ~PAYMENT_DATE, y = ~DAYS_PAST_DUE) |>
        add_lines(
          line = list(color = "#c8c8c8", width = 1.5),
          showlegend = FALSE, hoverinfo = "skip"
        ) |>
        add_markers(
          color = ~PAYMENT_STATUS, colors = status_cols,
          marker = list(size = 9),
          text = ~paste0("$", format(PAYMENT_AMOUNT, big.mark = ",")),
          hovertemplate = paste0(
            "%{x|%b %d, %Y}<br>",
            "%{y} days past due<br>",
            "Payment: %{text}",
            "<extra></extra>"
          )
        ) |>
        layout(
          xaxis = list(title = ""),
          yaxis = list(title = "Days past due", rangemode = "tozero"),
          legend = list(orientation = "h")
        )
    } else {
      plot_ly(df, x = ~MONTH) |>
        add_lines(y = ~MISSED_RATE, name = "Missed rate", yaxis = "y",
                  hovertemplate = "%{x|%b %Y}: %{y:.1%} missed<extra></extra>") |>
        add_lines(y = ~AVG_DPD, name = "Avg days past due", yaxis = "y2",
                  hovertemplate = "%{x|%b %Y}: %{y:.1f} days<extra></extra>") |>
        layout(
          xaxis = list(title = ""),
          yaxis = list(title = "Missed rate", tickformat = ".0%"),
          yaxis2 = list(title = "Avg DPD", overlaying = "y", side = "right"),
          legend = list(orientation = "h")
        )
    }
  })

  output$loans_title <- renderText({
    fid <- focus_id()
    if (is.null(fid)) "Loan amount distribution (cohort)"
    else sprintf("Loan history — customer %d", fid)
  })
  output$loans_plot <- renderPlotly({
    df <- loans_df()
    shiny::validate(shiny::need(nrow(df) > 0, "No loans in the current view."))
    df$STATUS <- ifelse(df$DEFAULTED == 1, "Defaulted", "Repaid")
    if (!is.null(focus_id())) {
      plot_ly(
        df,
        x = ~APPLICATION_DATE, y = ~LOAN_AMOUNT,
        color = ~STATUS, colors = c(Defaulted = "#d62728", Repaid = "#2ca02c"),
        type = "bar",
        text = ~paste0(LOAN_PURPOSE, " | ", LOAN_TERM_MONTHS, "mo @ ",
                       round(INTEREST_RATE, 1), "%")
      ) |>
        layout(
          xaxis = list(title = ""),
          yaxis = list(title = "Loan amount ($)"),
          legend = list(orientation = "h")
        )
    } else {
      # Smoothed (kernel density) distribution by status for easier comparison
      cols <- c(Defaulted = "#d62728", Repaid = "#2ca02c")
      dens <- lapply(split(df$LOAN_AMOUNT, df$STATUS), function(x) {
        x <- x[!is.na(x)]
        if (length(x) < 5) return(NULL)
        d <- stats::density(x, adjust = 1.2, from = 0)
        data.frame(x = d$x, y = d$y)
      })
      p <- plot_ly()
      for (nm in names(dens)) {
        if (is.null(dens[[nm]])) next
        p <- add_trace(
          p, data = dens[[nm]], x = ~x, y = ~y,
          type = "scatter", mode = "lines", name = nm,
          fill = "tozeroy",
          line = list(color = cols[[nm]], width = 2.5),
          fillcolor = toRGB(cols[[nm]], alpha = 0.45)
        )
      }
      layout(p,
        xaxis = list(title = "Loan amount ($)"),
        yaxis = list(title = "Density", showticklabels = FALSE),
        legend = list(orientation = "h")
      )
    }
  })

  # ==========================================================================
  # Phase 2: scoring with the Model Registry model
  # ==========================================================================

  # Customer picker: all IDs, kept in sync with the Explore tab's focus customer
  observe({
    updateSelectizeInput(session, "score_customer", choices = all_ids(),
                         selected = character(0), server = TRUE)
  })
  observeEvent(focus_id(), {
    updateSelectizeInput(session, "score_customer",
                         selected = as.character(focus_id()))
  })

  # Load the selected customer's features from the feature views
  observeEvent(input$load_features, {
    req(nzchar(input$score_customer))
    df <- dbGetQuery(con, sprintf(
      "SELECT %s FROM %s c
       LEFT JOIN %s p ON c.CUSTOMER_ID = p.CUSTOMER_ID
       LEFT JOIN %s h ON c.CUSTOMER_ID = h.CUSTOMER_ID
       WHERE c.CUSTOMER_ID = %d",
      FEATURES_SELECT, FV_PROFILE, FV_PAYMENT, FV_HISTORY,
      as.integer(input$score_customer)
    ))
    req(nrow(df) == 1)
    for (col in FEATURE_COLS) {
      input_id <- paste0("f_", tolower(col))
      if (col == "HOME_OWNERSHIP") {
        updateSelectInput(session, input_id, selected = df[[col]])
      } else {
        updateSliderInput(session, input_id, value = df[[col]])
      }
    }
  })

  # Keep LOG_INCOME consistent with ANNUAL_INCOME during what-if edits
  observeEvent(input$f_annual_income, {
    if (!is.na(input$f_annual_income) && input$f_annual_income > 0) {
      updateSliderInput(session, "f_log_income",
                        value = round(log(input$f_annual_income), 2))
    }
  }, ignoreInit = TRUE)

  # ---- What-if scoring -------------------------------------------------------
  single_score <- reactiveVal(NULL)
  single_raw   <- reactiveVal(NULL)  # raw PREDICT output, for diagnostics

  observeEvent(input$score_one, {
    vals <- lapply(FEATURE_COLS, function(col) input[[paste0("f_", tolower(col))]])
    names(vals) <- FEATURE_COLS
    missing <- names(vals)[vapply(
      vals,
      function(v) is.null(v) || is.na(v) || !nzchar(as.character(v)),
      logical(1)
    )]
    if (length(missing) > 0) {
      showNotification(
        paste("Fill in all features first. Missing:", paste(missing, collapse = ", ")),
        type = "warning"
      )
      return()
    }
    sql_vals <- vapply(FEATURE_COLS, function(col) {
      v <- vals[[col]]
      if (col == "HOME_OWNERSHIP") {
        sprintf("'%s'", gsub("'", "''", v))
      } else {
        format(as.numeric(v), scientific = FALSE)
      }
    }, character(1))
    sql <- sprintf(
      "WITH INPUT_ROW AS (SELECT %s)
       SELECT %s AS SCORE_OBJ FROM INPUT_ROW",
      paste(sprintf("%s AS %s", sql_vals, FEATURE_COLS), collapse = ", "),
      MODEL_CALL
    )
    res <- tryCatch(dbGetQuery(con, sql), error = function(e) e)
    if (inherits(res, "error")) {
      showNotification(paste("Scoring failed:", conditionMessage(res)), type = "error")
      return()
    }
    single_raw(as.character(res$SCORE_OBJ[1]))
    single_score(parse_score(as.character(res$SCORE_OBJ[1])))
  })

  output$score_result <- renderUI({
    v <- single_score()
    req(!is.null(v))
    if (is.na(v)) {
      # Parsing failed: surface the raw model output for diagnosis
      return(div(
        class = "card mt-3 p-3 text-bg-warning",
        div(class = "fw-bold", "Could not parse the model output"),
        div(class = "small", "Raw PREDICT result:"),
        tags$pre(class = "small mb-0",
                 single_raw() %||% "(empty)")
      ))
    }
    risk_class <- if (v >= 0.5) "text-bg-danger" else "text-bg-success"
    div(
      class = paste("card mt-3 p-3 text-center", risk_class),
      div(class = "fs-4 fw-bold", format_score(v)),
      div(class = "small opacity-75", "Scored live in Snowflake")
    )
  })

  # ---- Batch scoring of the current cohort ----------------------------------
  output$cohort_desc <- renderText({
    ids <- cohort_ids()
    if (is.null(ids)) {
      "No chat filter active: scores the full book of customers."
    } else {
      sprintf("Scores the %d customers currently in view on the Explore tab (cap %d).",
              length(ids), MAX_COHORT)
    }
  })

  batch_scores <- reactiveVal(NULL)

  observeEvent(input$score_cohort, {
    withProgress(message = "Scoring in Snowflake...", value = 0.4, {
      sql <- sprintf(
        "WITH FEATS AS (
           SELECT %s FROM %s c
           JOIN %s p ON c.CUSTOMER_ID = p.CUSTOMER_ID
           JOIN %s h ON c.CUSTOMER_ID = h.CUSTOMER_ID
           %s
         )
         SELECT CUSTOMER_ID, ANNUAL_INCOME, PCT_MISSED, PRIOR_DEFAULTS,
                %s AS SCORE_OBJ
         FROM FEATS",
        FEATURES_SELECT, FV_PROFILE, FV_PAYMENT, FV_HISTORY,
        in_where(cohort_ids(), "c.CUSTOMER_ID"), MODEL_CALL
      )
      res <- tryCatch(dbGetQuery(con, sql), error = function(e) e)
      if (inherits(res, "error")) {
        showNotification(paste("Batch scoring failed:", conditionMessage(res)),
                         type = "error")
        return()
      }
      res$SCORE <- vapply(as.character(res$SCORE_OBJ), parse_score, numeric(1),
                          USE.NAMES = FALSE)
      res$SCORE_OBJ <- NULL
      res$PREDICTION <- score_label(res$SCORE)
      batch_scores(res[order(-res$SCORE), ])
    })
  })

  output$score_dist <- renderPlotly({
    df <- batch_scores()
    req(!is.null(df))
    if (all(df$SCORE %in% c(0, 1), na.rm = TRUE)) {
      # Categorical model output: bar chart of predicted classes
      counts <- as.data.frame(table(PREDICTION = df$PREDICTION))
      cols <- c("Default" = "#d62728", "No default" = "#2ca02c")
      plot_ly(counts, x = ~PREDICTION, y = ~Freq, type = "bar",
              marker = list(color = cols[as.character(counts$PREDICTION)])) |>
        layout(
          xaxis = list(title = ""),
          yaxis = list(title = "Customers")
        )
    } else {
      plot_ly(df, x = ~SCORE, type = "histogram", nbinsx = 40,
              marker = list(color = "#1f77b4", opacity = 0.75)) |>
        layout(
          xaxis = list(title = "Default probability"),
          yaxis = list(title = "Customers")
        )
    }
  })

  output$score_table <- renderDT({
    df <- batch_scores()
    req(!is.null(df))
    df$SCORE <- NULL  # the label column is what users need
    datatable(
      df,
      rownames = FALSE, selection = "none",
      options = list(pageLength = 10, scrollX = TRUE, dom = "tip")
    ) |>
      formatStyle(
        "PREDICTION",
        color = styleEqual(c("Default", "No default"), c("#d62728", "#2ca02c")),
        fontWeight = "bold"
      )
  })
}

shinyApp(ui = ui, server = server)
