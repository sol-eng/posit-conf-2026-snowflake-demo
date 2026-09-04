# Credit Risk Demo Configuration
# Source this file at the top of each .qmd document.
# Edit the values below to match your Snowflake environment.

#renv::install("https://github.com/Snowflake-Labs/snowflakeR/releases/download/v0.2.0/snowflakeR_0.2.0.tar.gz")
# -- Connection profile name (from ~/.snowflake/connections.toml) -------------
CR_CONNECTION_NAME <- "workbench" #this is the connections.toml profile for native app

# -- Database layout ----------------------------------------------------------
CR_DATABASE        <- "CREDIT_RISK_ML"
CR_SOURCE_SCHEMA   <- "RAW_DATA"
CR_FEATURE_SCHEMA  <- "FEATURES"
CR_TRAINING_SCHEMA <- "TRAINING"
CR_REGISTRY_SCHEMA <- "MODELS"

# -- Helpers ------------------------------------------------------------------
fqn_source  <- function(name) paste(CR_DATABASE, CR_SOURCE_SCHEMA, name, sep = ".")
fqn_feature <- function(name) paste(CR_DATABASE, CR_FEATURE_SCHEMA, name, sep = ".")
fqn_training <- function(name) paste(CR_DATABASE, CR_TRAINING_SCHEMA, name, sep = ".")
fqn_model   <- function(name) paste(CR_DATABASE, CR_REGISTRY_SCHEMA, name, sep = ".")
