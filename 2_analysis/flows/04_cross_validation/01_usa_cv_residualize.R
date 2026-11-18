# ============================================================
# 01_usa_cv_residualize.R
#
# Step 1 of the precip-vs-flow cross-validation.
# Regress the outcome and every rain regressor on the controls 
# and fixed effects, save the residuals, and cross-validate on the residuals. 
#
# Residualized:
#   outcome   deathrate_w99
#   precip    prcp_poly_1..3  (order 3)
#   flow      flow_poly_1..3_pop  (order 3)
# Partialled out: temperature poly (order 2) + the 2 annual wind controls +
# saturated FE (county x age, country x year x age, state x year x age).
# Population weights (the main regs' weights) are used in every regression.
#
# All terms and FE are age-specific, so the regs split exactly by age group;
# the residualization is run separately for each age group.
#
# Sample: USA, 1968-2010, 3 age groups, complete cases on the variables used
# here only (outcome, temperature, precip, flow, wind). 
#
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(fixest)

# -----------------------------
# Project files
# -----------------------------

source("../../../0_utils/paths.R")                   # DATA_DIR, DIR_REPO_RAINFALL_MORTALITY
source("../../../0_utils/functions.R")               # helpers used by 00_prep_analysis_panel.R
source("../../regressions/00_prep_analysis_panel.R") # filter_regression_sample(), new_panel_specs

# -----------------------------
# Settings
# -----------------------------

FIRST_YEAR <- 1968
LAST_YEAR <- 2010
TAVG_ORDER <- 2
PRCP_ORDER <- 3
FLOW_ORDER <- 3

# The main regs' defaults: levels OLS, population weights, both wind controls
wind_control_vars <- c("windmax_pop_annual", "winddays_17p5_pop_annual")

prcp_vars <- paste0("prcp_poly_", seq_len(PRCP_ORDER))
flow_vars <- paste0("flow_poly_", seq_len(FLOW_ORDER), "_pop")
tavg_vars <- paste0("tavg_poly_", seq_len(TAVG_ORDER))

PANEL_FILE <- file.path(
  DATA_DIR, "climate_data", "ERA5-LAND", "flows", "usa_annual", "usa_annual_flow_regression_panel.rds"
)

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual")
cv_dir <- file.path(OUTPUT_DIR, "cv_precip_vs_flow")
residual_file <- file.path(cv_dir, "usa_cv_residual_panel.rds")
dir.create(cv_dir, recursive = TRUE, showWarnings = FALSE)

saturated_fe <- unlist(new_panel_specs$fe[new_panel_specs$spec_id == "saturated"], use.names = FALSE)

# -----------------------------
# Sample
# -----------------------------

panel <- readRDS(PANEL_FILE)

# The wind columns are stored as text in the panel so convert them
for (wind_var in wind_control_vars) {
  wind_numeric <- suppressWarnings(as.numeric(panel[[wind_var]]))

  if (any(is.na(wind_numeric) & !is.na(panel[[wind_var]]))) {
    stop(wind_var, " has values that are not numbers", call. = FALSE)
  }

  panel[[wind_var]] <- wind_numeric
}

# Complete cases on the variables used here only (filter_regression_sample
# adds the outcome, weights, IDs, temperature and precip)
sample_vars <- c(wind_control_vars, flow_vars)

df <- panel %>%
  filter(year >= FIRST_YEAR, year <= LAST_YEAR) %>%
  filter_regression_sample(tavg_order = TAVG_ORDER, prcp_order = PRCP_ORDER, extra_vars = sample_vars)
rm(panel)

stopifnot(
  !anyDuplicated(df[c("admin_code", "agegroup", "year")]),
  is.factor(df$agegroup)
)

message(
  "CV sample: ", nrow(df), " rows | ", n_distinct(df$admin_code), " counties | ",
  n_distinct(df$adm1_code), " states | ", min(df$year), "-", max(df$year)
)

# -----------------------------
# Residualize, separately by age group
# -----------------------------

# The FE with the age interaction dropped: within one age group they are
# the same FE as `saturated_fe`
fe_within_age <- sub("\\^agegroup", "", sub("agegroup\\^", "", saturated_fe))

rhs_controls <- paste(c(tavg_vars, wind_control_vars), collapse = " + ")
vars_to_residualize <- c(deathrate_w99 = "y_res", setNames(paste0("prcp_res_", seq_len(PRCP_ORDER)), prcp_vars),
                         setNames(paste0("flow_res_", seq_len(FLOW_ORDER)), flow_vars))

# All variables in one feols call: c(y, x1, ...) ~ controls | FE
fml <- as.formula(paste0(
  "c(", paste(names(vars_to_residualize), collapse = ", "), ") ~ ", rhs_controls,
  " | ", paste(fe_within_age, collapse = " + ")
))

residual_by_age <- lapply(levels(df$agegroup), function(age) {
  d <- df %>% filter(agegroup == age)
  fit <- feols(fml, data = d, weights = ~weight, notes = FALSE)

  # One column per variable, one row per row of d, NA on the FE singletons
  # (the same rows for every variable: same FE and complete-case data)
  res <- resid(fit)
  colnames(res) <- unname(vars_to_residualize[models(fit)$lhs])

  out <- d %>%
    select(admin_code, adm1_code, adm1_id, agegroup, year, weight) %>%
    bind_cols(as_tibble(res)) %>%
    filter(!is.na(y_res))

  message("Age group ", age, ": ", nrow(d), " rows, ", nrow(out), " kept, ",
          nrow(d) - nrow(out), " dropped as FE singletons")
  out
})

resid_panel <- bind_rows(residual_by_age)


# -----------------------------
# Write
# -----------------------------

message("Dropped as FE singletons in total: ", nrow(df) - nrow(resid_panel), " of ", nrow(df), " rows")
message("States in the residual panel: ", n_distinct(resid_panel$adm1_code))

saveRDS(resid_panel, residual_file)
message("Wrote the residual panel to: ", residual_file)
