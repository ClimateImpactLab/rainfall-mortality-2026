# ============================================================
# 02_usa_flow_regs.R
#
# USA annual mortality regs with rainfall flow, on the panel from
# 01_build_usa_panel.R
#
# Follows regressions/01_main_response.R: the same fit_response() call, the
# main two FE specs (new_panel_specs), the wind controls, and response curves
# from build_response() with SEs from the clustered vcov recomputed with
# vcov_fix = FALSE. The flow terms and the 10 sets below are the only changes.
#
# Each reg: temp poly x age + wind controls x age + the set's terms x age,
# clustered by state. One reg per set and FE spec:
#   prcp                precip poly only, the baseline for the precip curves
#   flow                flow poly
#   flow_prcp           flow poly + precip poly
#   prcp_upstream       precip poly + upstream poly
#   flow_z              flow poly + z-scores of annual mean and max flow
#   prcp_upstream_z     precip poly + upstream poly + z-scores
#   flow_spi            flow poly + flow SPI
#   prcp_upstream_spi   precip poly + upstream poly + flow SPI
#   flow_bins           flow poly + drought and flood percentile bins
#   prcp_upstream_bins  precip poly + upstream poly + the same bins
#
# Bins (01_build_usa_panel.R), with the Brazil cutoffs vs the county's 20
# previous years (the z-score baseline): drought = annual mean flow <= p10
# or p10-25, flood = annual max flow p75-90 or >= p90. Kept next to the linear z-score and SPI
# sets, so drought and flood get their own coefficients.
#
# SEs: like the main regs, the vcov is read with
# vcov(fit, cluster = ~adm1_code, vcov_fix = FALSE), not taken from the fit.
# fixest raises every eigenvalue of the vcov stored in the fit below 1e-12 to
# 1e-12 (mat_posdef_fix(), checked in the fixest 0.13.2 source). The flow and
# precip poly terms in raw units have variances that small, so in the Oct 16
# run (coeftable() and wald() on the stored vcov) that floor set their SEs.
# With vcov_fix = FALSE fixest still prints "The VCOV matrix is not positive
# semi-definite and was 'fixed'", but it leaves the matrix as it is.
# All terms are in raw units, as in the main regs.
#
# Outputs:
#   - response curves, f(x) - f(x_ref), for temp (every reg) and the set's
#     flow, upstream and precip polys
#   - z-score, SPI and bin coefficients by age group, with SEs from the same
#     recomputed vcov, as in regressions/05_wind_control_coefficients.R
#   - how much variation in each flow and precip measure the FE leave, and
#     how correlated the measures are after the FE (no regs, one table per
#     run; the same for levels and Poisson)
#
# Sample: 1970-2010 (the z-scores start in 1970), keeping only rows with every
# variable used by any set, so all regs use the same rows.
#
# Options:
#   --outcome_model = levels | poisson
#   --weighted = true | false
#   --wind_control = none | windmax | winddays | both
#
# Input:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
#   flows/usa_annual/usa_annual_flow_regression_panel.rds
#
# Outputs (output/data/flows/usa-annual/), read by
# 03_run_outputs/01_usa_flow_reg_outputs.R:
#   usa_flow_response_<run_id>.csv           response curves
#   usa_flow_coefficients_<run_id>.csv       z-score, SPI and bin coefficients
#   usa_flow_models_<run_id>.csv             one row per reg (set, FE spec, N)
#   usa_flow_variable_summary_<run_id>.csv   county-year summary of the measures
#   usa_flow_fe_collinearity_<run_id>.csv    variation left and correlations after the FE
#   usa_flow_all_coefficients_<run_id>.csv   every coefficient of every reg (stacked
#                                            across runs by 02_make_overleaf_doc.R)
#
# Dependencies: dplyr, readr, glue, fixest; ../../../0_utils/paths.R,
# ../../../0_utils/functions.R and ../../regressions/00_prep_analysis_panel.R,
# so run this script from its own folder.
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

args <- commandArgs(FALSE)

# sbatch passes options like --outcome_model=poisson
# If running this script directly, edit the default values below
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# Same defaults as 01_main_response.R
outcome_model <- get_arg("outcome_model", "levels")  # levels or Poisson
weighted_arg <- tolower(get_arg("weighted", "true")) # use population weights
wind_control <- get_arg("wind_control", "both")      # annual wind controls

weighted <- weighted_arg %in% c("true", "t", "1", "yes")   # treat true/t/1/yes as weighted
log_mort <- outcome_model == "poisson"                     # Poisson runs use the log-link model
weight_label <- if (weighted) "weighted" else "unweighted" # used in output file names


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R")                   # DATA_DIR, DIR_REPO_RAINFALL_MORTALITY
source("../../../0_utils/functions.R")               # fit_response(), make_coef_names(), build_response()
source("../../regressions/00_prep_analysis_panel.R") # filter_regression_sample(), new_panel_specs


# -----------------------------
# Paths
# -----------------------------

PANEL_FILE <- file.path(
  DATA_DIR, "climate_data", "ERA5-LAND", "flows", "usa_annual", "usa_annual_flow_regression_panel.rds"
)

# Run name used in the output file names, for ex levels_weighted_both
run_id <- paste(outcome_model, weight_label, sep = "_")
if (wind_control != "none") {
  run_id <- paste(run_id, wind_control, sep = "_")
}

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual")
response_file <- file.path(OUTPUT_DIR, paste0("usa_flow_response_", run_id, ".csv"))
coef_file <- file.path(OUTPUT_DIR, paste0("usa_flow_coefficients_", run_id, ".csv"))
model_file <- file.path(OUTPUT_DIR, paste0("usa_flow_models_", run_id, ".csv"))
summary_file <- file.path(OUTPUT_DIR, paste0("usa_flow_variable_summary_", run_id, ".csv"))
collinearity_file <- file.path(OUTPUT_DIR, paste0("usa_flow_fe_collinearity_", run_id, ".csv"))
all_coef_file <- file.path(OUTPUT_DIR, paste0("usa_flow_all_coefficients_", run_id, ".csv"))
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Controls
# -----------------------------

# Annual wind controls, estimated separately by age group (as in 01_main_response.R)
wind_control_terms <- switch(
  wind_control,
  none = character(),
  windmax = "i(agegroup, windmax_pop_annual)",
  winddays = "i(agegroup, winddays_17p5_pop_annual)",
  both = c(
    "i(agegroup, windmax_pop_annual)",
    "i(agegroup, winddays_17p5_pop_annual)"
  )
)

wind_control_vars <- switch(
  wind_control,
  none = character(),
  windmax = "windmax_pop_annual",
  winddays = "winddays_17p5_pop_annual",
  both = c("windmax_pop_annual", "winddays_17p5_pop_annual")
)


# -----------------------------
# Regression setup
# -----------------------------

FIRST_YEAR <- 1970     # first year with the flow z-scores
LAST_YEAR <- 2010      # last year of the USA mortality data
PRCP_ORDER <- 3        # precip poly order, the main regs' default
RESPONSE_POINTS <- 301 # points on each flow and upstream response curve

# Flow-side terms, each x age group. Precip enters through
# fit_response(prcp_order = PRCP_ORDER), as in the main regs, so it has no
# variables here
flow_groups <- list(
  flow = paste0("flow_poly_", 1:3, "_pop"),
  upstream = paste0("upstream_poly_", 1:3, "_pop"),
  z = c("flowmean_z_pop", "flowmax_z_pop"),
  spi = "spi12_flow_pop",
  bins = c(
    "flowmean_bin_p00_10_pop", "flowmean_bin_p10_25_pop",
    "flowmax_bin_p75_90_pop", "flowmax_bin_p90_100_pop"
  )
)

# One row per reg: short name, label, and the variable groups in the reg.
# Precip only comes first: it is the baseline the other precip curves are
# compared with
sets <- tibble::tribble(
  ~set_id, ~set_label, ~set_groups,
  "prcp", "Precip only", "prcp",
  "flow", "Flow", "flow",
  "flow_prcp", "Flow + precip", c("flow", "prcp"),
  "prcp_upstream", "Precip + upstream", c("prcp", "upstream"),
  "flow_z", "Flow + z-scores", c("flow", "z"),
  "prcp_upstream_z", "Precip + upstream + z-scores", c("prcp", "upstream", "z"),
  "flow_spi", "Flow + SPI", c("flow", "spi"),
  "prcp_upstream_spi", "Precip + upstream + SPI", c("prcp", "upstream", "spi"),
  "flow_bins", "Flow + bins", c("flow", "bins"),
  "prcp_upstream_bins", "Precip + upstream + bins", c("prcp", "upstream", "bins")
)

# The z-scores, SPI and bins are single terms, reported as coefficients.
# Bin labels follow the Brazil rainfall bins
coef_labels <- c(
  flowmean_z_pop = "Annual mean flow z-score",
  flowmax_z_pop = "Annual max flow z-score",
  spi12_flow_pop = "Flow SPI",
  flowmean_bin_p00_10_pop = "Driest 10% (mean flow)",
  flowmean_bin_p10_25_pop = "10th-25th pct (mean flow)",
  flowmax_bin_p75_90_pop = "75th-90th pct (max flow)",
  flowmax_bin_p90_100_pop = "Wettest 10% (max flow)"
)

# Polynomial response curves, f(x) - f(x_ref). Temp and precip use the main
# regs' reference values (27 C, 0 mm)
curve_settings <- tibble::tribble(
  ~group, ~id, ~prefix, ~suffix, ~poly_order, ~x_ref,
  "temp", "Temperature", "tavg_poly_", "", 2, 27,
  "prcp", "Precipitation", "prcp_poly_", "", PRCP_ORDER, 0,
  "flow", "Flow", "flow_poly_", "_pop", 3, 0,
  "upstream", "Upstream", "upstream_poly_", "_pop", 3, 0
)

# Main FE and saturated FE, from 00_prep_analysis_panel.R
specs <- new_panel_specs


# -----------------------------
# Regression sample
# -----------------------------

panel <- readRDS(PANEL_FILE)

# The wind columns are stored as text in new_mortality_panel.rds (the main
# regs read the CSV version, where read_csv parses them as numbers). As text,
# i(agegroup, windmax_pop_annual) would make one dummy per distinct value, so
# convert them, and stop if any value is not a number
for (wind_var in wind_control_vars) {
  wind_numeric <- suppressWarnings(as.numeric(panel[[wind_var]]))

  if (any(is.na(wind_numeric) & !is.na(panel[[wind_var]]))) {
    stop(wind_var, " has values that are not numbers", call. = FALSE)
  }

  panel[[wind_var]] <- wind_numeric
}

# Same rows in every reg: 1970-2010 and no missing reg variable.
# filter_regression_sample() is the main regs' complete-case filter
df <- panel %>%
  filter(year >= FIRST_YEAR, year <= LAST_YEAR) %>%
  filter_regression_sample(
    tavg_order = 2,
    prcp_order = PRCP_ORDER,
    extra_vars = c(wind_control_vars, unlist(flow_groups, use.names = FALSE))
  )

message(glue(
  "USA flow sample: {nrow(df)} rows | ",
  "{n_distinct(df$admin_code)} counties | ",
  "{n_distinct(df$adm1_code)} states | ",
  "{min(df$year)}-{max(df$year)} | ",
  "wind_control = {wind_control}"
))


# -----------------------------
# Variable summary
# -----------------------------

# The flow measures are county-year values repeated across age groups, so
# the summary uses one row per county-year
county_years <- df %>%
  distinct(admin_code, year, .keep_all = TRUE)

# For the 0/1 bins, the mean is the share of county-years in the bin
summary_vars <- c(
  "flow_poly_1_pop", "upstream_poly_1_pop", "prcp_poly_1",
  "flowmean_z_pop", "flowmax_z_pop", "spi12_flow_pop",
  flow_groups$bins
)

variable_summary <- bind_rows(lapply(summary_vars, function(variable) {
  x <- county_years[[variable]]

  tibble(
    variable = variable,
    county_years = length(x),
    mean = mean(x),
    sd = sd(x),
    min = min(x),
    p10 = quantile(x, 0.10, names = FALSE),
    p50 = quantile(x, 0.50, names = FALSE),
    p90 = quantile(x, 0.90, names = FALSE),
    p99 = quantile(x, 0.99, names = FALSE),
    max = max(x)
  )
}))

# Flow and upstream curves run from 0 to the 99th percentile of the
# county-year average month (annual sum / 12). x is one month's value in a
# grid cell, the unit the polynomial powers are taken on
flow_x_max <- quantile(county_years$flow_poly_1_pop / 12, 0.99, names = FALSE)
upstream_x_max <- quantile(county_years$upstream_poly_1_pop / 12, 0.99, names = FALSE)

response_x <- list(
  temp = seq(-20, 45, by = 0.25),
  prcp = 0:300,
  flow = seq(0, flow_x_max, length.out = RESPONSE_POINTS),
  upstream = seq(0, upstream_x_max, length.out = RESPONSE_POINTS)
)


# -----------------------------
# Collinearity after the FE
# -----------------------------

# How much of each measure's variation the FE leave, and how correlated the
# measures are once the FE are taken out. Each measure is demeaned on the
# same FE and weights as the regs (fixest::demean), so this is the variation
# the coefficients are identified from. It does not take out the temp and
# wind controls, and it is the OLS version: Poisson reweights observations
# while fitting, so for Poisson it is a close guide, not exact. Singletons,
# which the regs drop, are kept here (they demean to 0)
collinearity_vars <- c(
  paste0("prcp_poly_", 1:3),
  flow_groups$upstream,
  flow_groups$flow,
  flow_groups$z,
  flow_groups$spi
)

# Pairs reported as correlations: every precip term with every upstream term,
# then flow and the anomaly measures
collinearity_pairs <- rbind(
  expand.grid(var1 = paste0("prcp_poly_", 1:3), var2 = flow_groups$upstream, stringsAsFactors = FALSE),
  data.frame(
    var1 = c("flow_poly_1_pop", "flow_poly_1_pop", "flowmean_z_pop", "flowmean_z_pop", "flowmax_z_pop", "flow_poly_1_pop", "flow_poly_1_pop"),
    var2 = c("prcp_poly_1", "upstream_poly_1_pop", "flowmax_z_pop", "spi12_flow_pop", "spi12_flow_pop", "flowmean_z_pop", "spi12_flow_pop"),
    stringsAsFactors = FALSE
  )
)

# FE terms like admin_code^agegroup as one factor column each
fe_columns <- function(data, fe_terms) {
  as.data.frame(lapply(setNames(fe_terms, fe_terms), function(term) {
    do.call(paste, c(data[strsplit(term, "^", fixed = TRUE)[[1]]], sep = "_"))
  }))
}

collinearity_weights <- if (weighted) df$weight else rep(1, nrow(df))

weighted_share_left <- function(x, residual, w) {
  sum(w * residual^2) / sum(w * (x - weighted.mean(x, w))^2)
}

weighted_cor <- function(a, b, w) {
  cov.wt(cbind(a, b), wt = w / sum(w), cor = TRUE)$cor[1, 2]
}

collinearity <- bind_rows(lapply(seq_len(nrow(specs)), function(spec_i) {
  spec <- specs[spec_i, ]
  fe_terms <- unlist(spec$fe, use.names = FALSE)

  residuals <- demean(
    X = as.matrix(df[collinearity_vars]),
    f = fe_columns(df, fe_terms),
    weights = collinearity_weights
  )
  colnames(residuals) <- collinearity_vars

  share_left <- tibble(
    measure = "share_left",
    var1 = collinearity_vars,
    var2 = NA_character_,
    value = vapply(
      collinearity_vars,
      function(v) weighted_share_left(df[[v]], residuals[, v], collinearity_weights),
      numeric(1)
    )
  )

  correlations <- tibble(
    measure = "correlation",
    var1 = collinearity_pairs$var1,
    var2 = collinearity_pairs$var2,
    value = mapply(
      function(v1, v2) weighted_cor(residuals[, v1], residuals[, v2], collinearity_weights),
      collinearity_pairs$var1,
      collinearity_pairs$var2
    )
  )

  bind_rows(share_left, correlations) %>%
    mutate(spec_id = spec$spec_id, spec_short = spec$spec_short, weighted = weighted)
}))


# -----------------------------
# Coefficient extraction
# -----------------------------

# z-score, SPI and bin coefficients by age group. SEs come from the same
# recomputed vcov as the response curves (as in 05_wind_control_coefficients.R)
extract_flow_coefs <- function(fit, coef_vars) {
  b <- coef(fit)
  v <- vcov(fit, cluster = ~adm1_code, vcov_fix = FALSE)

  # Missing terms remain in the output as missing estimates
  rows <- list()

  for (coef_var in coef_vars) {
    for (age in levels(df$agegroup)) {
      term_name <- paste0("agegroup::", age, ":", coef_var)

      if (term_name %in% names(b)) {
        estimate <- unname(b[[term_name]])
        se <- sqrt(v[term_name, term_name])
      } else {
        estimate <- NA_real_
        se <- NA_real_
      }

      rows[[length(rows) + 1]] <- tibble(
        agegroup = age,
        coef_var = coef_var,
        coef_label = unname(coef_labels[coef_var]),
        term = term_name,
        estimate = estimate,
        se = se,
        lo = estimate - 1.96 * se,
        hi = estimate + 1.96 * se
      )
    }
  }

  bind_rows(rows)
}

# Every coefficient of a reg (temp, precip, flow, upstream, anomaly, bin and
# wind terms), each x age group, with SEs from the same recomputed vcov as the
# response curves. p-values use the normal distribution, like the 1.96 CIs in
# this script (fixest's own p-values use a t with clusters - 1 df). The
# polynomial coefficients are per unit of x^k in raw units, so they are tiny
# numbers; the response curves are the way to read them
term_groups <- c(
  setNames(rep("temp", 2), paste0("tavg_poly_", 1:2)),
  setNames(rep("prcp", PRCP_ORDER), paste0("prcp_poly_", seq_len(PRCP_ORDER))),
  setNames(rep(names(flow_groups), lengths(flow_groups)), unlist(flow_groups, use.names = FALSE)),
  setNames(rep("wind", length(wind_control_vars)), wind_control_vars)
)

term_labels <- c(
  setNames(paste0("Temperature k=", 1:2), paste0("tavg_poly_", 1:2)),
  setNames(paste0("Precip k=", seq_len(PRCP_ORDER)), paste0("prcp_poly_", seq_len(PRCP_ORDER))),
  setNames(paste0("Flow k=", 1:3), flow_groups$flow),
  setNames(paste0("Upstream k=", 1:3), flow_groups$upstream),
  coef_labels,
  windmax_pop_annual = "Annual max wind",
  winddays_17p5_pop_annual = "High-wind days"
)

extract_all_coefs <- function(fit) {
  b <- coef(fit)
  v <- vcov(fit, cluster = ~adm1_code, vcov_fix = FALSE)

  # fixest names the coefs like agegroup::2:flow_poly_1_pop
  tibble(
    term = names(b),
    variable = sub("^agegroup::[^:]+:", "", names(b)),
    agegroup = sub("^agegroup::([^:]+):.*$", "\\1", names(b)),
    estimate = unname(b),
    se = sqrt(unname(diag(v)[names(b)]))
  ) %>%
    mutate(
      group = unname(term_groups[variable]),
      term_label = unname(term_labels[variable]),
      statistic = estimate / se,
      p_value = 2 * pnorm(-abs(statistic)),
      lo = estimate - 1.96 * se,
      hi = estimate + 1.96 * se
    )
}


# -----------------------------
# Estimate models
# -----------------------------

rf_flow <- list()
coef_flow <- list()
all_coef_flow <- list()
model_flow <- list()

for (spec_i in seq_len(nrow(specs))) {
  spec <- specs[spec_i, ]

  for (set_i in seq_len(nrow(sets))) {
    set <- sets[set_i, ]
    set_groups <- set$set_groups[[1]]
    set_flow_vars <- unlist(flow_groups[intersect(names(flow_groups), set_groups)], use.names = FALSE)

    # Precip only has no flow-side terms. paste0() would turn the empty
    # vector into a broken "i(agegroup, )" term, so build the terms only
    # when there are variables
    set_flow_terms <- if (length(set_flow_vars) > 0) {
      paste0("i(agegroup, ", set_flow_vars, ")")
    } else {
      character()
    }

    message("Running ", spec$spec_label, " | ", set$set_label)

    # `fit_response()` is defined in `0_utils/functions.R`, the same call as
    # 01_main_response.R. The flow-side terms go in with the wind controls,
    # each x age group. The FE are unlisted as in
    # 05_wind_control_coefficients.R: with tibble 3.3.1, spec$fe[[1]] is still
    # a list around the FE vector
    fit <- fit_response(
      df,
      tavg_order = 2,
      prcp_order = if ("prcp" %in% set_groups) PRCP_ORDER else 0,
      fe = unlist(spec$fe, use.names = FALSE),
      controls = c(set_flow_terms, wind_control_terms),
      weights = if (weighted) ~weight else NULL,
      cluster = ~adm1_code,
      log_mort = log_mort
    )

    # One row per reg, for the setup TeX
    model_flow[[length(model_flow) + 1]] <- tibble(
      spec_id = spec$spec_id,
      spec_short = spec$spec_short,
      spec_label = spec$spec_label,
      set_id = set$set_id,
      set_label = set$set_label,
      set_groups = paste(set_groups, collapse = ";"),
      sample_rows = nrow(df),
      counties = n_distinct(df$admin_code),
      state_clusters = n_distinct(df$adm1_code),
      nobs = nobs(fit),
      formula = paste(deparse(formula(fit), width.cutoff = 500L), collapse = " "),
      outcome_model = outcome_model,
      weighted = weighted,
      wind_control = wind_control
    )

    # Every coefficient of this reg, for the combined coefficient file
    all_coef_flow[[length(all_coef_flow) + 1]] <- extract_all_coefs(fit) %>%
      mutate(
        outcome_model = outcome_model,
        weighted = weighted,
        wind_control = wind_control,
        spec_id = spec$spec_id,
        spec_short = spec$spec_short,
        set_id = set$set_id,
        set_label = set$set_label,
        nobs = nobs(fit)
      )

    # Temp curve in every reg, plus the set's polynomial curves.
    # `make_coef_names()` and `build_response()` are defined in
    # `0_utils/functions.R`
    for (curve_i in which(curve_settings$group %in% c("temp", set_groups))) {
      curve <- curve_settings[curve_i, ]

      rf_flow[[length(rf_flow) + 1]] <- build_response(
        fit,
        x = response_x[[curve$group]],
        x_ref = curve$x_ref,
        poly_order = curve$poly_order,
        groups = tibble(agegroup = levels(df$agegroup)),
        key = make_coef_names(prefix = curve$prefix, suffix = curve$suffix),
        id = curve$id,
        vcov_cluster = ~adm1_code,
        vcov_fix = FALSE
      ) %>%
        mutate(
          spec_id = spec$spec_id,
          spec_short = spec$spec_short,
          spec_label = spec$spec_label,
          set_id = set$set_id,
          set_label = set$set_label,
          product = "ERA5-Land",
          outcome_model = outcome_model,
          weighted = weighted,
          wind_control = wind_control
        )
    }

    # z-score, SPI and bin coefficients, for the sets that have them
    set_coef_vars <- intersect(set_flow_vars, names(coef_labels))

    if (length(set_coef_vars) > 0) {
      coef_flow[[length(coef_flow) + 1]] <- extract_flow_coefs(fit, set_coef_vars) %>%
        mutate(
          spec_id = spec$spec_id,
          spec_short = spec$spec_short,
          spec_label = spec$spec_label,
          set_id = set$set_id,
          set_label = set$set_label,
          outcome_model = outcome_model,
          weighted = weighted,
          wind_control = wind_control
        )
    }
  }
}


# -----------------------------
# Write results
# -----------------------------

# One row per x value, age group, reg and FE spec
rf_flow <- bind_rows(rf_flow) %>%
  mutate(response_scale = if_else(log_mort, "poisson_delta_deathrate", "deathrate_levels"))

# One row per z-score, SPI or bin term, age group, reg and FE spec.
# `lo` and `hi` are the ends of the 95% confidence interval
coef_flow <- bind_rows(coef_flow) %>%
  mutate(response_scale = if_else(log_mort, "poisson", "deathrate_levels"))

model_flow <- bind_rows(model_flow)

# One row per coefficient, age group, reg and FE spec, in a fixed column order
age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

all_coef_flow <- bind_rows(all_coef_flow) %>%
  mutate(
    age_label = unname(age_labels[agegroup]),
    coef_scale = if_else(log_mort, "log death rate", "deaths per 100,000")
  ) %>%
  select(
    outcome_model, weighted, wind_control, spec_id, spec_short, set_id, set_label,
    group, variable, term_label, agegroup, age_label, term,
    estimate, se, statistic, p_value, lo, hi, coef_scale, nobs
  )

print(model_flow %>% select(spec_id, set_id, nobs), n = Inf)

write_csv(rf_flow, response_file)
write_csv(coef_flow, coef_file)
write_csv(all_coef_flow, all_coef_file)
write_csv(model_flow, model_file)
write_csv(variable_summary, summary_file)
write_csv(collinearity, collinearity_file)

message("Wrote response curves to: ", response_file)
message("Wrote z-score, SPI and bin coefficients to: ", coef_file)
message("Wrote every coefficient of every reg to: ", all_coef_file)
message("Wrote model list to: ", model_file)
message("Wrote variable summary to: ", summary_file)
message("Wrote collinearity after the FE to: ", collinearity_file)
