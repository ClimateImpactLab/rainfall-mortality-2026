# ============================================================
# 01_main_response.R
#
# Estimate the main rainfall and temperature response functions
#
# This script runs the main age-specific regressions and saves the response
# function data used for plotting. It does not make figures.
#
# `fit_response()`, `make_coef_names()`, and `build_response()` are defined in
# `0_utils/functions.R`.
#
# Options:
#   --outcome_model = levels | poisson
#   --response = precip | temp | both
#   --spec_set = main_two | four_spec
#   --climate_product = ERA5LAND
#   --weighted = true | false
#   --prcp_order = 2 | 3 | 4 | 5
#   --wind_control = none | windmax | winddays | both
#   --daily_overlap_control = none | rain100 | rain200 | both
#   --daily_overlap_exclusion = none | rain100 | rain200
#
# `main_two` runs the two preferred fixed-effect specifications
# `four_spec` runs the four-spec comparison
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

# Use the value passed by sbatch, or the default if nothing is passed.
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# These options are usually set in the sbatch files.
outcome_model <- get_arg("outcome_model", "levels")       # levels or Poisson
response <- get_arg("response", "both")                   # rainfall, temperature, or both
spec_set <- get_arg("spec_set", "main_two")               # main specs or four-spec comparison
climate_product <- get_arg("climate_product", "ERA5LAND") # climate variables to use
weighted_arg <- tolower(get_arg("weighted", "true"))      # use population weights
prcp_order <- as.integer(get_arg("prcp_order", "3"))      # rainfall polynomial order
wind_control <- get_arg("wind_control", "none")           # annual wind controls
daily_overlap_control <- get_arg("daily_overlap_control", "none")     # rain-wind overlap controls
daily_overlap_exclusion <- get_arg("daily_overlap_exclusion", "none") # drop rain-wind overlap years

weighted <- weighted_arg %in% c("true", "t", "1", "yes") # treat true/t/1/yes as weighted
log_mort <- outcome_model == "poisson"                   # Poisson runs use the log-link model
weight_label <- if (weighted) "weighted" else "unweighted" # used in output file names


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")
source("../../0_utils/functions.R") # fit_response(), make_coef_names(), build_response()
source("00_prep_analysis_panel.R")  # load_new_panel(), filter_regression_sample()

# -----------------------------
# Output path
# -----------------------------

# Include the main regression choices in the output name
run_id <- paste(spec_set, outcome_model, paste0("p", prcp_order), weight_label, sep = "_")
if (wind_control != "none") {
  run_id <- paste(run_id, wind_control, sep = "_")
}
if (daily_overlap_control != "none") {
  run_id <- paste(run_id, paste0("overlapctl_", daily_overlap_control), sep = "_")
}
if (daily_overlap_exclusion != "none") {
  run_id <- paste(run_id, paste0("exclude_overlap_", daily_overlap_exclusion), sep = "_")
}

rf_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf",
  "analysis-panel", "main-response"
)
rf_file <- paste0("main_response_", run_id, ".csv")
dir.create(rf_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Controls
# -----------------------------

# Annual wind controls, estimated separately by age group
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

# Controls for heavy-rain days that occur near high winds
daily_overlap_terms <- switch(
  daily_overlap_control,
  none = character(),
  rain100 = "i(agegroup, rain_days_100_wind_pm1day)",
  rain200 = "i(agegroup, rain_days_200_wind_pm1day)",
  both = c(
    "i(agegroup, rain_days_100_wind_pm1day)",
    "i(agegroup, rain_days_200_wind_pm1day)"
  )
)

daily_overlap_vars <- switch(
  daily_overlap_control,
  none = character(),
  rain100 = "rain_days_100_wind_pm1day",
  rain200 = "rain_days_200_wind_pm1day",
  both = c("rain_days_100_wind_pm1day", "rain_days_200_wind_pm1day")
)

daily_overlap_exclusion_var <- switch(
  daily_overlap_exclusion,
  none = character(),
  rain100 = "rain_days_100_wind_pm1day",
  rain200 = "rain_days_200_wind_pm1day"
)

daily_overlap_needed_vars <- unique(c(daily_overlap_vars, daily_overlap_exclusion_var))


# -----------------------------
# Regression sample
# -----------------------------

df <- load_new_panel(prcp_product = climate_product, temp_product = climate_product)

if (length(daily_overlap_needed_vars) > 0) {
  overlap_path <- file.path(
    DIR_REPO_RAINFALL_MORTALITY,
    "output/data/wind_precip_confounding/daily_precip_wind_overlap_panel_ready",
    "admin_year_daily_overlap_panel_ready.csv"
  )
  
  overlap <- read_csv(overlap_path, show_col_types = FALSE) %>%
    select(
      iso, admin_id, year,
      starts_with("rain_days_"), starts_with("share_rain_days_"),
      max_rain_event_mm, max_wind_on_rain_event_pm1day,
      wind_on_max_rain_day, wind_pm1day_on_max_rain_day
    )
  
  # Missing rows mean the admin-year had no daily rain event >= 100 mm
  # The rain-wind count variables are therefore zero
  df <- df %>%
    left_join(overlap, by = c("iso", "admin_id", "year")) %>%
    mutate(
      rain_days_100_wind_pm1day = coalesce(rain_days_100_wind_pm1day, 0),
      rain_days_200_wind_pm1day = coalesce(rain_days_200_wind_pm1day, 0)
    )
}

df <- df %>%
  filter_regression_sample(
    tavg_order = 2,
    prcp_order = prcp_order,
    extra_vars = c(wind_control_vars, daily_overlap_needed_vars)
  )

# Drop admin-years with the selected rain-wind overlap event
if (daily_overlap_exclusion != "none") {
  df <- df %>%
    filter(.data[[daily_overlap_exclusion_var]] == 0)
}

message(glue(
  "Main response sample: {nrow(df)} rows | ",
  "{n_distinct(df$iso)} countries | ",
  "{n_distinct(df$admin_code)} admin units | ",
  "wind_control = {wind_control} | ",
  "daily_overlap_control = {daily_overlap_control} | ",
  "daily_overlap_exclusion = {daily_overlap_exclusion}"
))


# -----------------------------
# Fixed effects
# -----------------------------

# Additional fixed-effect specifications for the four-spec comparison
four_specs <- tibble::tribble(
  ~spec_id, ~spec_short, ~spec_label, ~fe,
  "spec1",
  "Spec 1",
  "Spec 1: age x admin unit; country x year",
  list(c("admin_code^agegroup", "adm0_code^year")),
  
  "spec2",
  "Spec 2",
  "Spec 2: age x admin unit; age x country x year",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup")),
  
  "spec3",
  "Spec 3",
  "Spec 3: age x admin unit; age x country x year; ADM1-age linear trend",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup", "adm1_agegrp_code[year]")),
  
  "spec4",
  "Spec 4",
  "Spec 4: age x admin unit; age x country x year; age x ADM1 x year",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup", "adm1_code^year^agegroup"))
)

specs <- if (spec_set == "main_two") new_panel_specs else four_specs


# -----------------------------
# Estimate models
# -----------------------------

# Store the precipitation and/or temperature response for each specification
rf_main <- list()
result_i <- 1

for (spec_i in seq_len(nrow(specs))) {
  spec <- specs[spec_i, ]
  message("Running ", spec$spec_label)
  
  # `fit_response()` is defined in `0_utils/functions.R`. It builds the fixest
  # formula from the polynomial orders, controls, and fixed effects.
  fit <- fit_response(
    df,
    tavg_order = 2,
    prcp_order = prcp_order,
    fe = spec$fe[[1]],
    controls = c(wind_control_terms, daily_overlap_terms),
    weights = if (weighted) ~weight else NULL,
    cluster = ~adm1_code,
    log_mort = log_mort
  )
  
  # Precipitation response relative to 0 mm
  if (response %in% c("precip", "both")) {
    # `make_coef_names()` and `build_response()` are defined in
    # `0_utils/functions.R`.
    precip_key <- make_coef_names(prefix = "prcp_poly_", fit = fit)
    
    rf_main[[result_i]] <- build_response(
      fit,
      x = 0:300,
      x_ref = 0,
      poly_order = prcp_order,
      groups = tibble(agegroup = levels(df$agegroup)),
      key = precip_key,
      id = "Precipitation",
      vcov_cluster = ~adm1_code,
      vcov_fix = FALSE
    ) %>%
      mutate(
        spec_id = spec$spec_id,
        spec_short = spec$spec_short,
        spec_label = spec$spec_label,
        product = "ERA5-Land",
        outcome_model = outcome_model,
        weighted = weighted,
        wind_control = wind_control,
        daily_overlap_control = daily_overlap_control,
        daily_overlap_exclusion = daily_overlap_exclusion
      )
    
    result_i <- result_i + 1
  }
  
  # Temperature response relative to 27 C
  if (response %in% c("temp", "both")) {
    # `make_coef_names()` and `build_response()` are defined in
    # `0_utils/functions.R`.
    temp_key <- make_coef_names(prefix = "tavg_poly_", fit = fit)
    
    rf_main[[result_i]] <- build_response(
      fit,
      x = seq(-20, 45, by = 0.25),
      x_ref = 27,
      poly_order = 2,
      groups = tibble(agegroup = levels(df$agegroup)),
      key = temp_key,
      id = "Temperature",
      vcov_cluster = ~adm1_code,
      vcov_fix = FALSE
    ) %>%
      mutate(
        spec_id = spec$spec_id,
        spec_short = spec$spec_short,
        spec_label = spec$spec_label,
        product = "ERA5-Land",
        outcome_model = outcome_model,
        weighted = weighted,
        wind_control = wind_control,
        daily_overlap_control = daily_overlap_control,
        daily_overlap_exclusion = daily_overlap_exclusion
      )
    
    result_i <- result_i + 1
  }
}


# -----------------------------
# Write results
# -----------------------------

# One row per weather value, age group, and fixed-effect specification.
rf_main <- bind_rows(rf_main) %>%
  mutate(response_scale = if_else(log_mort, "poisson_delta_deathrate", "deathrate_levels"))

write_csv(rf_main, file.path(rf_dir, rf_file))

message("Wrote main response functions to: ", file.path(rf_dir, rf_file))
