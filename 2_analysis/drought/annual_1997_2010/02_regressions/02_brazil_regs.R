# ============================================================
# 02_brazil_regs.R
#
# Brazil annual mortality regs, one drought measure at a time, on the panel
# from 01_build_brazil_panel.R.
#
# Each reg: drought x age group + temp x age group, clustered by state.
# By default there is no precip poly (--prcp_poly=true adds it back).
# Most regs have one drought measure. A few have several terms together:
#   - the same measure this year, last year and next year (placebo)
#   - the annual rainfall deviation + a very-wet-year dummy (control)
#   - 4 bins for how dry or wet the year was vs the municipality's own
#     1981-2010 years (driest 10%, 10-25%, 75-90%, wettest 10%), compared
#     with a normal year (25-75%)
#
# Each reg is also compared with the same reg without drought (the base),
# by how much within R2 it adds.
#
# Options:
#   --outcome_model=levels | poisson
#       levels: FE OLS on winsorized death rates.
#       poisson: FE Poisson on deaths with log(population) offset.
#   --fe_spec = main | saturated | statetrend | region | both
#       main: ADM2 x age FE + year x age FE
#       saturated: main + ADM1 x year x age FE
#       statetrend: main + a linear year trend per ADM1 x age
#       region: ADM2 x age FE + macro-region x year x age FE
#       both: main and saturated
#   --weighted = true | false
#       population weights. Default: true for levels, false for Poisson
#       (Poisson already uses population through the log(pop) offset)
#   --prcp_poly = true | false
#       true adds the annual precip poly (prcp_poly_1-3) x age group, so the
#       drought and precip poly effects are estimated in the same reg
#   --temp = tavg | tmax
#       tavg: age-specific tavg_poly_1-2
#       tmax: tavg_poly_1-2 plus age-specific tmax_poly_1-4
#   --sample = all | northeast
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(glue)
library(fixest)


# -----------------------------
# Options
# -----------------------------

# Defaults: death-rate levels, main FE, population weights
args <- commandArgs(FALSE)

get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

outcome_model <- get_arg("outcome_model", "levels")
fe_spec <- get_arg("fe_spec", "main")
weighted_default <- if (outcome_model == "poisson") "false" else "true"
weighted_arg <- tolower(get_arg("weighted", weighted_default))
prcp_poly_arg <- tolower(get_arg("prcp_poly", "false"))
temp_spec <- get_arg("temp", "tavg")
sample_spec <- get_arg("sample", "all")

# true/false options as TRUE/FALSE
weighted <- weighted_arg %in% c("true", "t", "1", "yes")
use_prcp_poly <- prcp_poly_arg %in% c("true", "t", "1", "yes")
log_mort <- outcome_model == "poisson"
weight_label <- if (weighted) "weighted" else "unweighted"


# -----------------------------
# Paths
# -----------------------------

# paths.R gives DIR_REPO_RAINFALL_MORTALITY (the repo on RCC)
USER <- Sys.getenv("USER")
source("../../../../0_utils/paths.R")

PANEL_FILE <- paste0("/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
                     "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds")

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "drought", "brazil-annual")

# Run name used in the output file names, for ex saturated_poisson_unweighted_prcpoly
run_id <- paste(fe_spec, outcome_model, weight_label, sep = "_")
if (use_prcp_poly) run_id <- paste(run_id, "prcpoly", sep = "_")
if (temp_spec == "tmax") run_id <- paste(run_id, "tmax", sep = "_")
if (sample_spec == "northeast") run_id <- paste(run_id, "northeast", sep = "_")
coef_file <- file.path(OUTPUT_DIR, paste0("brazil_annual_drought_coefficients_", run_id, ".csv"))
model_file <- file.path(OUTPUT_DIR, paste0("brazil_annual_drought_models_", run_id, ".csv"))
joint_file <- file.path(OUTPUT_DIR, paste0("brazil_annual_drought_joint_tests_", run_id, ".csv"))


# -----------------------------
# Regression setup
# -----------------------------

# In the Brazil-only sample, country-year-age FE are just year-age FE, so
# the main spec only removes shocks common to all of Brazil. The lead placebo
# fails there, which points to regional trends/shocks lining up with rainfall.

# The saturated FE adds ADM1-year-age FE (compare within state and year).

# Two middle-ground checks keep more regional drought variation:
#   1. statetrend: main FE + a linear year trend per state x age
#      removes slow state trends but keeps state-wide year-to-year droughts
#   2. region: macro-region x year x age FE (5 regions) instead of year x age

specs <- tibble::tribble(
  ~spec_id, ~spec_label, ~fe,
  "main",
  "ADM2 x age FE, country x year x age FE",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup")),

  "saturated",
  "ADM2 x age FE, country x year x age FE, ADM1 x year x age FE",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup", "adm1_code^year^agegroup")),

  "statetrend",
  "ADM2 x age FE, country x year x age FE, ADM1 x age linear trends",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup", "adm1_code^agegroup[year]")),

  "region",
  "ADM2 x age FE, macro-region x year x age FE",
  list(c("admin_code^agegroup", "macro_region^year^agegroup"))
)

if (fe_spec == "both") {
  specs <- specs %>% filter(spec_id %in% c("main", "saturated"))
} else {
  specs <- specs %>% filter(spec_id == fe_spec)
}

if (nrow(specs) == 0) {
  stop("fe_spec must be main, saturated, statetrend, region or both", call. = FALSE)
}

# Drought measure sets. Every term is coded so larger = drier, except the
# wet-year control and the wet rainfall bins, which are labelled as wet.
#
# Annual summaries of the monthly measures (one term each):
#   -log annual rainfall, RS drought months, worst RS log/percent deviation
#   (cut at zero), 6-month p10/p5 window counts, worst 6-month z severity
#   (cut at zero), largest 6-month deficit.
#
# Calendar-year measures:
#   rain_dev          calendar-year rainfall vs 1981-2010 mean, wet years negative
#   rain_dev_lag_lead same + last year's + next year's (placebo) deviation
#   rain_dev_wet      same + very-wet-year indicator (>= p90)
#   rain_bins         percentile bins, 25th-75th is the omitted normal group
#   spi12             -SPI of calendar-year rainfall, wet years negative
#   spi06_worst       worst 6-month SPI severity, built like the worst 6-month z
#   very_dry          calendar-year rainfall in the driest 10% of the ADM2's own
#                     1981-2010 years (0/1), vs all other years
#   spi12_lag_lead &
#   very_dry_lag_lead same lead placebo as rain_dev_lag_lead, for the other
#                     two calendar-year measures

# One row per reg: 
#   - short name (used in file names)
#   - label (used in tables and figures)
#   - and the panel variable(s) that go in the reg
# Regs with several terms have them in c(...) on the next line

drought_sets <- tibble::tribble(
  ~set_id, ~set_label, ~terms,
  "gs_neglog", "-log annual rainfall", "gs_neglog_annual_rain_pop",
  "rs_months", "Rocha-Soares drought months", "rs_drought_months_12m_pop",
  "rs_worst_logdev", "Worst Rocha-Soares log deviation", "rs_worst_logdev_severity_pop",
  "rs_worst_pctdev", "Worst Rocha-Soares percent deviation", "rs_worst_pctdev_severity_pop",
  "low10_6m", "6-month windows below 10th percentile", "drought_6m_low10_months_pop",
  "low05_6m", "6-month windows below 5th percentile", "drought_6m_low05_months_pop",
  "worst_z_6m", "Worst 6-month z-score severity", "drought_6m_worst_z_severity_pop",
  "deficit_6m", "Largest 6-month rainfall deficit", "deficit_mm_max_06m_pop",

  "rain_dev", "Annual rain log deviation", "rain_dry_logdev_pop",
  "rain_dev_lag_lead", "Annual rain log deviation + lag + lead",
      c("rain_dry_logdev_pop", "rain_dry_logdev_lag1_pop", "rain_dry_logdev_lead1_pop"),
  "rain_dev_wet", "Annual rain log deviation + very wet year",
      c("rain_dry_logdev_pop", "rain_wet_p90_pop"),
  "rain_bins", "Annual rain percentile bins",
      c("rain_bin_p00_10_pop", "rain_bin_p10_25_pop", "rain_bin_p75_90_pop", "rain_bin_p90_100_pop"),
  "spi12", "Annual SPI", "spi12_dry_pop",
  "spi06_worst", "Worst 6-month SPI severity", "spi06_worst_severity_pop",
  "very_dry", "Very dry year (below p10)", "rain_bin_p00_10_pop",
  "spi12_lag_lead", "Annual SPI + lag + lead",
      c("spi12_dry_pop", "spi12_dry_lag1_pop", "spi12_dry_lead1_pop"),
  "very_dry_lag_lead", "Very dry year + lag + lead",
      c("rain_bin_p00_10_pop", "rain_bin_p00_10_lag1_pop", "rain_bin_p00_10_lead1_pop")
)

# Short labels for terms inside multi-term sets.
term_labels <- c(
  rain_dry_logdev_pop = "this year",
  rain_dry_logdev_lag1_pop = "last year",
  rain_dry_logdev_lead1_pop = "next year (placebo)",
  rain_wet_p90_pop = "very wet year (control)",
  rain_bin_p00_10_pop = "driest 10%",
  rain_bin_p10_25_pop = "10th-25th pct",
  rain_bin_p75_90_pop = "75th-90th pct (wet)",
  rain_bin_p90_100_pop = "wettest 10% (wet)"
)


# -----------------------------
# Read Brazil panel
# -----------------------------

df <- readRDS(PANEL_FILE) %>%
  mutate(agegroup = as.factor(agegroup))

# Poisson needs deaths and a positive population (log(pop) offset)
if (log_mort) {
  df <- df %>%
    filter(!is.na(deaths), !is.na(population), population > 0)
}

# Northeast only: the semi-arid region, where drought should matter most
# also a check on the main FE results, which mostly compare the Northeast with the rest of Brazil
if (sample_spec == "northeast") {
  df <- df %>% filter(northeast)
}

# Keep only the measure sets whose terms are all in the panel
drought_sets <- drought_sets %>%
  filter(sapply(terms, function(x) all(x %in% names(df))))

# Sample size, printed to the log
message(glue(
  "Brazil annual drought sample: {nrow(df)} rows | ",
  "{n_distinct(df$admin_code)} ADM2s | ",
  "{n_distinct(df$adm1_code)} ADM1s | ",
  "{min(df$year)}-{max(df$year)}"
))


# -----------------------------
# Model helpers
# -----------------------------

# Keep temp controls in every model
temperature_terms <- c(
  "i(agegroup, tavg_poly_1)",
  "i(agegroup, tavg_poly_2)"
)

# Heat check: daily-max temperature terms (annual sums of daily Tmax^k)
# Dry years are hotter within an ADM2 (corr -0.58 with annual rainfall), and the
# tavg terms only see annual mean temperature 
if (temp_spec == "tmax") {
  temperature_terms <- c(temperature_terms, paste0("i(agegroup, tmax_poly_", 1:4, ")"))
}

# Optional annual precip polynomial:the direct check for whether the drought coef 
# was partly picking up less extreme-rainfall / flood damage.
# prcp_poly_1 is annual rainfall itself, so the two-sided annual rainfall measures are
# nearly collinear with it. we should read those with-poly results with care.
prcp_terms <- paste0("i(agegroup, prcp_poly_", 1:3, ")")
base_terms <- if (use_prcp_poly) c(temperature_terms, prcp_terms) else temperature_terms

# Levels use death rates. Poisson uses deaths with log(population) as exposure
fit_model <- function(data, rhs, fe) {
  fe <- unlist(fe, use.names = FALSE)
  outcome <- if (log_mort) "deaths" else "deathrate_w99"
  rhs_text <- paste(rhs, collapse = " + ")

  if (log_mort) {
    rhs_text <- paste(rhs_text, "offset(log(population))", sep = " + ")
  }

  f <- as.formula(sprintf(
    "%s ~ %s | %s",
    outcome,
    rhs_text,
    paste(fe, collapse = " + ")
  ))

  if (log_mort) {
    fepois(f, data = data, weights = if (weighted) ~weight else NULL,
           cluster = ~adm1_code, lean = FALSE)
  } else {
    feols(f, data = data, weights = if (weighted) ~weight else NULL,
          cluster = ~adm1_code, lean = FALSE)
  }
}

# Extract one fit statistic as a number (here the within-R2)
get_fitstat <- function(fit, type) {
  out <- fitstat(fit, type)
  as.numeric(out[[type]])
}

# The model table compares drought sets using delta_within_r2
model_summary <- function(fit, data, spec, model_id, set = NULL,
                          base_within_r2 = NA_real_) {
  tibble(
    model_id = model_id,
    spec_id = spec$spec_id,
    spec_label = spec$spec_label,
    drought_var = if (is.null(set)) NA_character_ else set$set_id,
    set_label = if (is.null(set)) NA_character_ else set$set_label,
    nobs = nobs(fit),
    adm1_clusters = n_distinct(data$adm1_code),
    within_r2 = get_fitstat(fit, "wr2"),
    delta_within_r2 = get_fitstat(fit, "wr2") - base_within_r2,
    outcome_model = outcome_model,
    weighted = weighted,
    prcp_poly = use_prcp_poly,
    temp = temp_spec,
    sample = sample_spec
  )
}

# One coefficient per term x age group
# Multi-term sets get "set: term"
# labels so 03_run_outputs/01 can plot each term on its own row
coef_table <- function(fit, spec, model_id, set) {
  ct <- as.data.frame(coeftable(fit))
  ct$term <- rownames(ct)
  # The test column is "t value" for levels (OLS) and "z value" for Poisson
  stat_col <- grep(" value$", names(ct), value = TRUE)[[1]]
  p_col <- grep("^Pr\\(", names(ct), value = TRUE)[[1]]
  terms <- set$terms[[1]]

  # fixest names the coefs like agegroup::2:spi12_dry_pop. Split into the
  # variable and the age group, and keep only the drought terms (not temp
  # or precip poly)
  ct %>%
    mutate(variable = sub("^agegroup::[^:]+:", "", term)) %>%
    filter(variable %in% terms) %>%
    # Lag/lead sets list this year, last year, next year in that order
    mutate(term_label = if (grepl("_lag_lead$", set$set_id)) {
      c("this year", "last year", "next year (placebo)")[match(variable, terms)]
    } else {
      unname(term_labels[variable])
    }) %>%
    transmute(
      model_id = model_id,
      spec_id = spec$spec_id,
      spec_label = spec$spec_label,
      set_id = set$set_id,
      set_label = set$set_label,
      variable,
      measure_label = if (length(terms) == 1) set$set_label else paste0(set$set_label, ": ", term_label),
      agegroup = sub("^agegroup::([^:]+):.*$", "\\1", term),
      estimate = Estimate,
      std_error = `Std. Error`,
      statistic = .data[[stat_col]],
      p_value = .data[[p_col]],
      outcome_model = outcome_model,
      weighted = weighted,
      prcp_poly = use_prcp_poly,
      temp = temp_spec,
      sample = sample_spec
    )
}

# Joint test of all drought terms in the set, across age groups
# one thing tl note: w/ Northeast sample there are only 9 state clusters, so a test on
# many terms (for ex 4 bins x 3 ages) has a singular VCOV (so those tests are NA)
joint_test <- function(fit, spec, model_id, set) {
  pattern <- paste0(":(", paste(set$terms[[1]], collapse = "|"), ")$")
  terms <- names(coef(fit))[grepl(pattern, names(coef(fit)))]
  test <- tryCatch({
    invisible(capture.output(out <- wald(fit, keep = terms)))
    out
  }, error = function(e) list(stat = NA_real_, p = NA_real_))

  tibble(
    model_id = model_id,
    spec_id = spec$spec_id,
    spec_label = spec$spec_label,
    variable = set$set_id,
    measure_label = set$set_label,
    statistic = unname(test$stat),
    p_value = unname(test$p),
    outcome_model = outcome_model,
    weighted = weighted,
    prcp_poly = use_prcp_poly,
    temp = temp_spec,
    sample = sample_spec
  )
}


# -----------------------------
# Estimate regressions
# -----------------------------

coef_results <- list()
model_results <- list()
joint_results <- list()
result_i <- 1

# For each FE spec: the base reg (no drought), then one reg per drought
# measure, each compared with the base
for (spec_i in seq_len(nrow(specs))) {
  spec <- specs[spec_i, ]
  message("Running base model: ", spec$spec_label)

  # Base model for delta-within-R2: temp controls only, or temp + precip poly
  base_fit <- fit_model(df, rhs = base_terms, fe = spec$fe[[1]])
  base_within_r2 <- get_fitstat(base_fit, "wr2")

  model_results[[result_i]] <- model_summary(
    base_fit, df, spec, model_id = paste(spec$spec_id, "base", sep = "_"),
    base_within_r2 = base_within_r2
  )
  result_i <- result_i + 1

  for (set_i in seq_len(nrow(drought_sets))) {
    set <- drought_sets[set_i, ]
    model_id <- paste(spec$spec_id, set$set_id, sep = "_")

    message("Running drought model: ", set$set_label)

    # Same reg as the base + the drought term(s) x age group
    rhs <- c(base_terms, paste0("i(agegroup, ", set$terms[[1]], ")"))
    fit <- fit_model(df, rhs = rhs, fe = spec$fe[[1]])

    coef_results[[length(coef_results) + 1]] <- coef_table(fit, spec, model_id, set)

    model_results[[result_i]] <- model_summary(
      fit, df, spec, model_id, set, base_within_r2
    )
    result_i <- result_i + 1

    joint_results[[length(joint_results) + 1]] <- joint_test(fit, spec, model_id, set)
  }
}


# -----------------------------
# Write results
# -----------------------------

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

coef_results <- bind_rows(coef_results)
model_results <- bind_rows(model_results)
joint_results <- bind_rows(joint_results)

write_csv(coef_results, coef_file)
write_csv(model_results, model_file)
write_csv(joint_results, joint_file)

message("Wrote coefficients to: ", coef_file)
message("Wrote model comparison table to: ", model_file)
message("Wrote joint tests to: ", joint_file)
