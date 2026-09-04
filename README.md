# Posit + Snowflake: R Model Deployment Demo

**Demo for Posit conf 2026**

An end-to-end credit risk scoring demo showing how to build, evaluate, and deploy R tidymodels entirely within Snowflake — from raw lending data through a live REST-scoring endpoint on Snowpark Container Services (SPCS).

> This demo was originally created for Snowflake Notebook and has been modified to run as a native Positron/Quarto workflow. It uses the [`snowflakeR`](https://github.com/Snowflake-Labs/snowflakeR) (skiPatrol) package to register and deploy R tidymodels into SPCS.

---

## What the Demo Does

1. Connects to Snowflake from Positron using Workbench-managed credentials
2. Creates a dedicated database (`CREDIT_RISK_ML`) with isolated schemas for raw data, features, training artefacts, and model registry
3. Generates synthetic lending data (~50K loans, 10K customers, ~500K payments)
4. Builds reusable features in the Snowflake Feature Store
5. Trains two competing models with tidymodels — logistic regression vs. XGBoost
6. Evaluates and compares model performance
7. Registers both models in the Snowflake Model Registry with metrics
8. Selects the champion model programmatically and deploys it to SPCS via `snowflakeR`
9. Scores new applications via REST and SQL
10. Verifies ML Observability autocapture

## Database Layout

| Schema | Contents |
|---|---|
| `RAW_DATA` | Source tables — customers, loans, payments |
| `FEATURES` | Feature Store (entity, feature views, dynamic tables) |
| `TRAINING` | Materialised training datasets |
| `MODELS` | Model Registry (versioned models, metrics, services) |

---

## Files

| File | Purpose |
|---|---|
| `00_setup.qmd` | One-time environment setup: create database layout and generate synthetic data |
| `01_demo.qmd` | Main demo: feature engineering → model training → registry → SPCS deployment |
| `_config.R` | Snowflake connection and database configuration — **edit this before running** |
| `renv.lock` | R package lockfile for reproducibility |

---

## Prerequisites

- **Positron** (or RStudio) with R ≥ 4.4
- **Posit Workbench** with a Snowflake connection configured in `~/.snowflake/connections.toml` under the profile name `workbench`
- A Snowflake account with permissions to create databases, Feature Store objects, Model Registry entries, and SPCS services
- The `snowflakeR` package (skiPatrol):

```r
install.packages(
  "https://github.com/Snowflake-Labs/snowflakeR/releases/download/v0.2.0/snowflakeR_0.2.0.tar.gz",
  repos = NULL, type = "source"
)
```

- Python dependencies (managed automatically via `reticulate::py_require()`):
  - `snowflake-ml-python >= 1.5.0`
  - `snowflake-snowpark-python`
  - `pandas`

---

## Getting Started

### 1. Configure your connection

Edit `_config.R` and verify the connection profile name and database settings match your Snowflake environment:

```r
CR_CONNECTION_NAME <- "workbench"   # connections.toml profile
CR_DATABASE        <- "CREDIT_RISK_ML"
```

### 2. Restore the R environment

```r
renv::restore()
```

### 3. Run setup (once)

Open and render `00_setup.qmd`. This creates the database layout and populates synthetic data — run it once before the main demo.

### 4. Run the demo

Open and render `01_demo.qmd` to walk through the full ML workflow from feature engineering to SPCS deployment.

---

## Key Packages

| Package | Role |
|---|---|
| `snowflakeR` (skiPatrol) | Register and deploy R models to SPCS |
| `tidymodels` | Model training, tuning, and evaluation |
| `xgboost` / `ranger` | Model engines |
| `reticulate` | Bridge to Snowflake Python SDKs |
| `DBI` / `odbc` | Snowflake SQL connectivity |
