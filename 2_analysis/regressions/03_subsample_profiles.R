# ============================================================
# 03_subsample_profiles.R
#
# Estimate rainfall response contrasts for exploratory Mumbai-profile subsamples
#
# Each profile is estimated as one interacted regression:
# rainfall response x selected-profile indicator.
#
# This script writes the retention table and the response-function CSV. 
# Figures are made separately by
# `2_analysis/figures/03_plot_subsample_profiles.R`.
#
# `fit_response()`, `make_coef_names()`, and `build_response()` are defined in
# `0_utils/functions.R`.
#
# Main options:
#   --low_income_cutoff = p25 | p50
#   --outcome_model = levels | poisson
#   --profile_scope = all | profile4
#   --age_filter = all | 1 | 2 | 3 | 1,2,3
#   --wind_control = none | windmax | winddays | both
#   --daily_overlap_control = none | rain100 | rain200 | both
#   --daily_overlap_exclusion = none | rain100 | rain200
#
# Notes:
#   - The profile indicators are based on static admin-unit averages.
#   - p25 is the current preferred income screen for reporting.
#   - The model is one interacted regression per profile/specification, not
#     separate selected-vs-comparison regressions.
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(readr)
library(glue)
library(purrr)
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

# These options are usually set in the sbatch files
low_income_cutoff <- get_arg("low_income_cutoff", "p25") # low-income cutoff for profiles
outcome_model <- get_arg("outcome_model", "levels") # levels or Poisson
profile_scope <- get_arg("profile_scope", "all") # all profiles or Profile 4 only
age_filter_arg <- get_arg("age_filter", "3")     # age groups to keep
wind_control <- get_arg("wind_control", "both")  # annual wind controls
daily_overlap_control <- get_arg("daily_overlap_control", "none")     # rain-wind overlap controls
daily_overlap_exclusion <- get_arg("daily_overlap_exclusion", "none") # drop rain-wind overlap years

age_filter <- strsplit(age_filter_arg, ",", fixed = TRUE)[[1]] # age groups passed by sbatch
age_filter <- trimws(age_filter)

# Income cutoffs used in the earlier simple profile outputs
income_cutoff <- if (low_income_cutoff == "p25") 7074.40 else 13270.86
income_label <- if (low_income_cutoff == "p25") "bottom 25% of sample" else "bottom 50% of sample"

log_mort <- outcome_model == "poisson" # Poisson runs use the log-link model
model_label <- outcome_model           # used in output file names

# Build the folder/file suffix for this run. The suffix records the mortality
# model, low-income cutoff, optional Profile 4 restriction, and any storm checks.
out_suffix <- paste(outcome_model, "income", low_income_cutoff, sep = "_")
if (profile_scope == "profile4") {
  out_suffix <- paste(out_suffix, "profile4", sep = "_")
}
if (age_filter_arg != "3") {
  out_suffix <- paste(out_suffix, paste0("age", gsub(",", "_", age_filter_arg)), sep = "_")
}
if (wind_control != "none") {
  out_suffix <- paste(out_suffix, wind_control, sep = "_")
}
if (daily_overlap_control != "none") {
  out_suffix <- paste(out_suffix, paste0("overlapctl_", daily_overlap_control), sep = "_")
}
if (daily_overlap_exclusion != "none") {
  out_suffix <- paste(out_suffix, paste0("exclude_overlap_", daily_overlap_exclusion), sep = "_")
}

# Annual wind controls, estimated separately by age group
wind_control_terms <- switch(
  wind_control,
  none = character(),
  windmax = "i(agegroup, windmax_pop_annual)",
  winddays = "i(agegroup, winddays_17p5_pop_annual)",
  both = c("i(agegroup, windmax_pop_annual)", "i(agegroup, winddays_17p5_pop_annual)")
)
wind_control_vars <- switch(
  wind_control,
  none = character(),
  windmax = "windmax_pop_annual",
  winddays = "winddays_17p5_pop_annual",
  both = c("windmax_pop_annual", "winddays_17p5_pop_annual")
)

# Rain-wind overlap controls, also estimated separately by age group
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

# Exclusion runs drop admin-years with the selected rain-wind overlap measure
daily_overlap_exclusion_var <- switch(
  daily_overlap_exclusion,
  none = character(),
  rain100 = "rain_days_100_wind_pm1day",
  rain200 = "rain_days_200_wind_pm1day"
)

# Variables needed either as controls or for the rain-wind overlap exclusion
daily_overlap_needed_vars <- unique(c(daily_overlap_vars, daily_overlap_exclusion_var))


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")
source("../../0_utils/functions.R") # fit_response(), make_coef_names(), build_response()
source("00_prep_analysis_panel.R")  # load_new_panel(), filter_regression_sample()


# -----------------------------
# Output paths
# -----------------------------

rf_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf", "subsamples", out_suffix)
diag_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "diagnostics", "subsamples", out_suffix)
dir.create(rf_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(diag_dir, recursive = TRUE, showWarnings = FALSE)

# -----------------------------
# Regression sample
# -----------------------------

add_daily_overlap <- function(df) {
  overlap_path <- file.path(
    DIR_REPO_RAINFALL_MORTALITY,
    "output/data/wind_precip_confounding/daily_precip_wind_overlap_panel_ready",
    "admin_year_daily_overlap_panel_ready.csv"
  )

  overlap <- read_csv(overlap_path, show_col_types = FALSE) %>%
    select(
      iso,
      admin_id,
      year,
      starts_with("rain_days_"),
      starts_with("share_rain_days_"),
      max_rain_event_mm,
      max_wind_on_rain_event_pm1day,
      wind_on_max_rain_day,
      wind_pm1day_on_max_rain_day
    )

  # Missing rows mean the admin-year had no daily rain event >= 100 mm
  # The rain-wind count variables are therefore zero
  df %>%
    left_join(overlap, by = c("iso", "admin_id", "year")) %>%
    mutate(
      rain_days_100_wind_pm1day = coalesce(rain_days_100_wind_pm1day, 0),
      rain_days_200_wind_pm1day = coalesce(rain_days_200_wind_pm1day, 0)
    )
}

df <- load_new_panel(prcp_product = "ERA5LAND", temp_product = "ERA5LAND", require_urban = TRUE)

if (length(daily_overlap_needed_vars) > 0) {
  df <- df %>%
    add_daily_overlap()
}

# These regressions use the main rainfall sample, plus the variables needed to
# define the Mumbai-profile groups
df <- df %>%
  filter_regression_sample(
    tavg_order = 2,
    prcp_order = 3,
    require_urban = TRUE,
    extra_vars = c(
      "gdppc_adm1_avg",
      "lr_prcp_ERA5LAND_adm1_avg",
      "prcp_poly_1",
      wind_control_vars,
      daily_overlap_needed_vars
    )
  )

if (!"all" %in% age_filter) {
  df <- df %>%
    filter(as.character(agegroup) %in% age_filter)
}

if (daily_overlap_exclusion != "none") {
  df <- df %>%
    filter(.data[[daily_overlap_exclusion_var]] == 0)
}

message(glue(
  "Subsample sample: {nrow(df)} rows | ",
  "{n_distinct(df$iso)} countries | ",
  "{n_distinct(df$admin_code)} admin units | ",
  "profile_scope = {profile_scope} | ",
  "wind_control = {wind_control} | ",
  "daily_overlap_control = {daily_overlap_control} | ",
  "daily_overlap_exclusion = {daily_overlap_exclusion}"
))

# -----------------------------
# Profile definitions
# -----------------------------


# Four exploratory profiles defined by urban share, population, income, and rainfall
# The income cutoff is common across profiles and set by --low_income_cutoff

clean_defs <- tibble::tribble(
  ~profile_id, ~profile_label, ~profile_strip, ~urban_cutoff, ~pop_cutoff, ~income_cutoff, ~prcp_cutoff,
  paste0("urban_wet_", low_income_cutoff), "Urban Wet", "Urban Wet", 50, 100000, income_cutoff, 1000,
  paste0("high_urban_wet_", low_income_cutoff), "High-Urban Wet", "High-Urban Wet", 70, 250000, income_cutoff, 1000,
  paste0("very_wet_urban_", low_income_cutoff), "Large-Pop Very-Wet", "Large-Pop\nVery-Wet", 50, 250000, income_cutoff, 1500,
  paste0("large_high_urban_wet_", low_income_cutoff), "Large-Pop High-Urban Very-Wet", "Large-Pop High-Urban\nVery-Wet", 70, 500000, income_cutoff, 1500
)

if (profile_scope == "profile4") {
  clean_defs <- clean_defs %>%
    filter(profile_id == paste0("large_high_urban_wet_", low_income_cutoff))
}

# -----------------------------
# Profile indicators
# -----------------------------

# Mortality population is age-specific, so first recover total admin-year population
admin_year_pop <- df %>%
  group_by(admin_code, year) %>%
  summarize(admin_year_population = sum(population, na.rm = TRUE), .groups = "drop")

# Profile assignment is fixed at the admin-unit level
# Use GHSL population when available, otherwise mortality-panel population
admin_static <- df %>%
  left_join(admin_year_pop, by = c("admin_code", "year")) %>%
  group_by(iso, adm0, adm1_code, adm1_name, admin_code, admin_name, admin_level) %>%
  summarize(
    urban_share = mean(urban_share, na.rm = TRUE),
    mortality_population = mean(admin_year_population, na.rm = TRUE),
    gdppc_adm1_avg = mean(gdppc_adm1_avg, na.rm = TRUE),
    lr_prcp_adm1 = mean(lr_prcp_ERA5LAND_adm1_avg, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(analysis_population = mortality_population)

# Apply each profile's urban, population, income, and rainfall cutoffs
# to every admin unit
admin_profiles <- pmap_dfr(clean_defs, function(profile_id, profile_label, profile_strip, urban_cutoff,
                                                pop_cutoff, income_cutoff, prcp_cutoff) {
  admin_static %>%
    transmute(
      iso, admin_code,
      profile_id = profile_id,
      profile_label = profile_label,
      profile_strip = profile_strip,
      selected = urban_share >= urban_cutoff &
        analysis_population >= pop_cutoff &
        gdppc_adm1_avg <= income_cutoff &
        lr_prcp_adm1 >= prcp_cutoff,
      group = if_else(selected, "Mumbai-profile units", "Comparison units")
    )
})

# Join the profile indicators to the regression panel
# Each panel row appears once for each profile being estimated
contrast_df <- df %>%
  left_join(admin_profiles, by = c("iso", "admin_code"), relationship = "many-to-many") %>%
  mutate(group = factor(group, levels = c("Comparison units", "Mumbai-profile units")))

# Profile criteria used in the retention table
criteria_table <- clean_defs %>%
  mutate(
    criteria = glue(
      "urban_share > {urban_cutoff} | population > {format(pop_cutoff, big.mark = ',')} | ",
      "ADM1 GDP pc < ${format(round(income_cutoff), big.mark = ',')} ",
      "({income_label}) | ",
      "long-run precip > {format(prcp_cutoff, big.mark = ',')} mm/year"
    )
  )

# Number of rows, countries, and admin units in each selected/comparison group
retention <- contrast_df %>%
  group_by(profile_id, profile_label, profile_strip, group) %>%
  summarize(
    rows = n(),
    countries = n_distinct(iso),
    admin_units = n_distinct(admin_code),
    .groups = "drop"
  ) %>%
  left_join(criteria_table, by = c("profile_id", "profile_label", "profile_strip"))

write_csv(retention, file.path(diag_dir, "clean_subsample_contrast_retention.csv"))
print(retention)

# -----------------------------
# Estimate models
# -----------------------------

# Estimate one response function for each profile and FE specification
# Each regression uses the full sample, with the precipitation response
# interacted with group: "Mumbai-profile units" vs "Comparison units"

run_rf <- function(data, profile_id, profile_label, spec_id, spec_short, spec_label, fe) {
  
  # Keep the full regression sample for this profile definition
  reg_df <- data %>% 
    filter(.data$profile_id == !!profile_id)
  
  message(glue("Running {profile_label} | {spec_short}: {nrow(reg_df)} rows"))
  
  # `fit_response()` is defined in `0_utils/functions.R`. Here it estimates the
  # rainfall response separately for selected and comparison units.
  fit <- fit_response(
    reg_df,
    tavg_order = 2,
    prcp_order = 3,
    interact_var = "group",
    fe = fe,
    controls = c(wind_control_terms, daily_overlap_terms),
    weights = ~weight,
    cluster = ~adm1_code,
    log_mort = log_mort
  )
  
  # `make_coef_names()` and `build_response()` are defined in
  # `0_utils/functions.R`.
  # Identify the precipitation coefficients for each age and profile group.
  key <- make_coef_names(
    prefix = "prcp_poly_",
    interact_var = "group",
    fit = fit
  )
  
  # Build precipitation responses from 0 to 300 mm, relative to 0 mm
  rf <- build_response(
    fit,
    x = 0:300,
    x_ref = 0,
    poly_order = 3,
    groups = crossing(
      agegroup = levels(reg_df$agegroup),
      group = levels(reg_df$group)
    ),
    key = key,
    id = "Precipitation",
    vcov_cluster = ~adm1_code,
    vcov_fix = FALSE
  ) %>%
    mutate(
      profile_id = profile_id,
      profile_label = profile_label,
      spec_id = spec_id,
      spec_short = spec_short,
      spec_label = spec_label,
      wind_control = wind_control,
      daily_overlap_control = daily_overlap_control,
      daily_overlap_exclusion = daily_overlap_exclusion,
      profile_scope = profile_scope
    )
  
  # Record whether the response comes from the levels or Poisson model
  rf <- rf %>%
    mutate(
      response_scale = if_else(
        log_mort,
        "poisson_delta_deathrate",
        "deathrate_levels"
      )
    )
  
  rf
}

# Run each profile under both preferred FE specifications from
# `00_prep_analysis_panel.R`
rf_list <- list()
result_i <- 1

for (profile_i in seq_len(nrow(clean_defs))) {
  profile <- clean_defs[profile_i, ]
  
  for (spec_i in seq_len(nrow(new_panel_specs))) {
    spec <- new_panel_specs[spec_i, ]
    
    rf_list[[result_i]] <- run_rf(
      contrast_df,              # full sample with selected/comparison labels
      profile$profile_id,       # profile to estimate
      profile$profile_label,    # readable profile name
      spec$spec_id,             # fixed-effect spec ID
      spec$spec_short,          # short fixed-effect label
      spec$spec_label,          # full fixed-effect label
      spec$fe[[1]]              # fixed effects passed to fixest
    ) %>%
      mutate(profile_strip = profile$profile_strip)
    
    result_i <- result_i + 1
  }
}

# Combine results across all profiles and FE specifications
rf <- bind_rows(rf_list)


# -----------------------------
# Write outputs
# -----------------------------

rf_file <- paste0("subsample_profiles_", out_suffix, "_era5land.csv")

# This file has one row per rainfall value, age group, profile group, and
# fixed-effect specification
write_csv(rf, file.path(rf_dir, rf_file))

message("Wrote clean contrast diagnostics to: ", diag_dir)
message("Wrote clean contrast RFs to: ", rf_dir)
