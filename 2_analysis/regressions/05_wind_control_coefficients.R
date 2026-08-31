# ==============================================================================
# 05_wind_control_coefficients.R
#
# Save the coefficients on the wind controls
#
# The response-function scripts show whether the rainfall curve moves after
# adding wind controls. This script looks directly at the wind terms to check
# their sign, size, and uncertainty by age group
#
# The models match the main-response and Profile 4 regressions used in the
# wind checks. Wind controls enter as age-specific terms:
#
#   i(agegroup, windmax_pop_annual)
#   i(agegroup, winddays_17p5_pop_annual)
#   i(agegroup, rain_days_100_wind_pm1day)
#   i(agegroup, rain_days_200_wind_pm1day)
#
# `fit_response()` is defined in `0_utils/functions.R`.
# `load_new_panel()` and `filter_regression_sample()` are defined in
# `2_analysis/regressions/00_prep_analysis_panel.R`.
#
# Output:
#   output/data/diagnostics/wind_control_coefficients/
#
# Main options:
#   --scope = main | profile4 | both
#   --outcome_model = levels | poisson
#   --spec_set = main_two | four_spec
#   --weighted = true | false
#   --prcp_order = 2 | 3 | 4 | 5
#   --income_screen = p25 | p50
#   --control_set = all | tc_prone_minimal | tc_prone_four | tc_country_three
#   --country_group = none | tc_prone | tc_prone_country
# ==============================================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(glue)
  library(fixest)
})


# -----------------------------
# Options
# -----------------------------

args <- commandArgs(FALSE)

# Use the value passed by sbatch, or the default if nothing is passed
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# These options are usually set in the sbatch files
scope <- get_arg("scope", "both")                    # main sample, Profile 4 sample, or both
outcome_model <- get_arg("outcome_model", "poisson") # levels or Poisson
spec_set <- get_arg("spec_set", "main_two")          # main two FE specs or all four FE specs
weighted_arg <- tolower(get_arg("weighted", "true")) # use population weights
prcp_order <- as.integer(get_arg("prcp_order", "3")) # rainfall polynomial order
income_screen <- get_arg("income_screen", "p25")     # Profile 4 income cutoff: p25 or p50
control_set <- get_arg("control_set", "all")         # wind/overlap terms to estimate
country_group <- get_arg("country_group", "none")    # all countries, TC-prone split, or individual TC-prone countries


weighted <- weighted_arg %in% c("true", "t", "1", "yes")   # true/t/1/yes all mean weighted
log_mort <- outcome_model == "poisson"                     # Poisson runs use the log-link model
weight_label <- if (weighted) "weighted" else "unweighted" # used in the output file name

# Without a country split, coefficients vary by age group
# With a TC split, they vary by age group and country group
coef_group_var <- if (country_group == "none") "agegroup" else "age_country_group"


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")
source("../../0_utils/functions.R") # fit_response()
source("00_prep_analysis_panel.R")  # load_new_panel(), filter_regression_sample()


# -----------------------------
# Output path
# -----------------------------

# Record the main regression choices in the output file name
out_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "data", "diagnostics", "wind_control_coefficients"
)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

out_file <- paste(
  "wind_control_coefficients", scope, outcome_model, spec_set,
  paste0("p", prcp_order), weight_label, income_screen,
  sep = "_"
)

if (control_set != "all") {
  out_file <- paste(out_file, control_set, sep = "_")
}
if (country_group != "none") {
  out_file <- paste(out_file, paste0("by_", country_group), sep = "_")
}

out_file <- paste0(out_file, ".csv")


# -----------------------------
# Wind terms
# -----------------------------

# Define the wind-control regressions to run
# Each row is one regression
#
# `control_vars` lists the raw variables used in that run
# The script later turns each variable into an age-specific regression term:
# i(agegroup, variable)

control_runs <- tibble::tribble(
  ~control_run, ~control_label, ~control_vars,
  
  "windmax",
  "Annual max wind",
  list("windmax_pop_annual"),
  
  "winddays",
  "High-wind days",
  list("winddays_17p5_pop_annual"),
  
  "annual_both",
  "Annual max wind + high-wind days",
  list(c("windmax_pop_annual", "winddays_17p5_pop_annual")),
  
  "overlap_rain100",
  "Rain >=100mm + high wind",
  list("rain_days_100_wind_pm1day"),
  
  "overlap_rain200",
  "Rain >=200mm + high wind",
  list("rain_days_200_wind_pm1day")
)

# Smaller set used for quick TC checks
if (control_set == "tc_prone_minimal") {
  control_runs <- control_runs %>%
    filter(control_run %in% c("windmax", "overlap_rain100"))
}

# Both annual wind measures and both rain-wind overlap measures
if (control_set == "tc_prone_four") {
  control_runs <- control_runs %>%
    filter(control_run %in% c("windmax", "winddays", "overlap_rain100", "overlap_rain200"))
}

# Three terms used for separate TC-prone-country coefficients
if (control_set == "tc_country_three") {
  control_runs <- control_runs %>%
    filter(control_run %in% c("windmax", "overlap_rain100", "overlap_rain200"))
}

# Labels used by the plotting script
coef_labels <- tibble::tribble(
  ~control_var, ~control_var_label,
  "windmax_pop_annual", "Annual max wind",
  "winddays_17p5_pop_annual", "High-wind days",
  "rain_days_100_wind_pm1day", "Rain >=100mm + high wind",
  "rain_days_200_wind_pm1day", "Rain >=200mm + high wind"
)


# -----------------------------
# Fixed effects
# -----------------------------

# Additional FE specifications for the four-spec comparison
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
# Daily overlap controls
# -----------------------------

add_daily_overlap <- function(df) {
  overlap_path <- file.path(
    DIR_REPO_RAINFALL_MORTALITY,
    "output/data/wind_precip_confounding/daily_precip_wind_overlap_panel_ready",
    "admin_year_daily_overlap_panel_ready.csv"
  )
  
  overlap <- read_csv(overlap_path, show_col_types = FALSE) %>%
    select(iso, admin_id, year, starts_with("rain_days_"))
  
  # Missing rows mean the admin-year had no daily rain event >= 100 mm
  # The rain-wind count variables are therefore zero
  df %>%
    left_join(overlap, by = c("iso", "admin_id", "year")) %>%
    mutate(
      rain_days_100_wind_pm1day = coalesce(rain_days_100_wind_pm1day, 0),
      rain_days_200_wind_pm1day = coalesce(rain_days_200_wind_pm1day, 0)
    )
}


# -----------------------------
# Country groups
# -----------------------------

tc_prone_isos <- c("AUS", "CHN", "IND", "JPN", "KOR", "MEX", "PHL", "USA")

add_country_groups <- function(df) {
  if (country_group == "none") {
    return(df)
  }
  
  # Split countries to check whether wind coefficients differ where tropical
  # cyclones are a greater concern
  df %>%
    mutate(
      country_group_label = case_when(
        country_group == "tc_prone" & iso %in% tc_prone_isos ~ "TC-prone countries",
        country_group == "tc_prone" ~ "Other countries",
        country_group == "tc_prone_country" & iso %in% tc_prone_isos ~ iso,
        country_group == "tc_prone_country" ~ "Other countries"
      ),
      country_group_code = case_when(
        country_group_label == "TC-prone countries" ~ "tc_prone",
        country_group_label == "Other countries" ~ "other",
        TRUE ~ tolower(country_group_label)
      ),
      age_country_group = paste0("age", agegroup, "_", country_group_code),
      age_country_group = factor(
        age_country_group,
        levels = as.vector(outer(
          paste0("age", c("1", "2", "3"), "_"),
          c("other", "aus", "chn", "ind", "jpn", "kor", "mex", "phl", "usa", "tc_prone"),
          paste0
        ))
      )
    )
}

# Coefficient groups expected from the age-by-wind interactions
# Country splits add separate coefficients for each country group
coef_groups <- if (country_group == "tc_prone") {
  tibble::tribble(
    ~agegroup, ~age_label, ~country_group_label, ~coef_group_level,
    "1", "0-4", "Other countries", "age1_other",
    "2", "5-64", "Other countries", "age2_other",
    "3", "65+", "Other countries", "age3_other",
    "1", "0-4", "TC-prone countries", "age1_tc_prone",
    "2", "5-64", "TC-prone countries", "age2_tc_prone",
    "3", "65+", "TC-prone countries", "age3_tc_prone"
  )
  
} else if (country_group == "tc_prone_country") {
  tidyr::crossing(
    tibble::tribble(
      ~country_group_label, ~country_group_code,
      "Other countries", "other",
      "AUS", "aus",
      "CHN", "chn",
      "IND", "ind",
      "JPN", "jpn",
      "KOR", "kor",
      "MEX", "mex",
      "PHL", "phl",
      "USA", "usa"
    ),
    tibble::tribble(
      ~agegroup, ~age_label,
      "1", "0-4",
      "2", "5-64",
      "3", "65+"
    )
  ) %>%
    mutate(coef_group_level = paste0("age", agegroup, "_", country_group_code)) %>%
    select(agegroup, age_label, country_group_label, coef_group_level)
  
} else {
  tibble::tribble(
    ~agegroup, ~age_label, ~country_group_label, ~coef_group_level,
    "1", "0-4", "All countries", "1",
    "2", "5-64", "All countries", "2",
    "3", "65+", "All countries", "3"
  )
}


# -----------------------------
# Main response sample
# -----------------------------

make_main_sample <- function(extra_vars) {
  df <- load_new_panel(prcp_product = "ERA5LAND", temp_product = "ERA5LAND")
  
  # Rain-wind overlap variables are stored in a separate admin-year file
  if (any(startsWith(extra_vars, "rain_days_"))) {
    df <- add_daily_overlap(df)
  }
  
  df <- filter_regression_sample(
    df,
    tavg_order = 2,
    prcp_order = prcp_order,
    extra_vars = extra_vars
  )
  
  add_country_groups(df)
}


# -----------------------------
# Profile 4 sample
# -----------------------------

make_profile4_sample <- function(extra_vars) {
  # Fixed ADM1 income cutoffs used in the current Profile 4 runs
  income_cutoff <- if (income_screen == "p25") 7074.40 else 13270.86
  
  df <- load_new_panel(
    prcp_product = "ERA5LAND",
    temp_product = "ERA5LAND",
    require_urban = TRUE
  )
  
  # Rain-wind overlap variables are stored in a separate admin-year file
  if (any(startsWith(extra_vars, "rain_days_"))) {
    df <- add_daily_overlap(df)
  }
  
  # Use the Profile 4 regression sample plus the requested wind variables
  df <- df %>%
    filter_regression_sample(
      tavg_order = 2,
      prcp_order = prcp_order,
      require_urban = TRUE,
      extra_vars = c(
        "gdppc_adm1_avg",
        "lr_prcp_ERA5LAND_adm1_avg",
        "prcp_poly_1",
        extra_vars
      )
    )
  
  # Mortality population is age-specific, so first recover total admin-year population
  admin_year_pop <- df %>%
    group_by(admin_code, year) %>%
    summarize(admin_year_population = sum(population, na.rm = TRUE), .groups = "drop")
  
  # Average the profile variables over years to assign each admin unit once
  admin_static <- df %>%
    left_join(admin_year_pop, by = c("admin_code", "year")) %>%
    group_by(iso, admin_code) %>%
    summarize(
      urban_share = mean(urban_share, na.rm = TRUE),
      mortality_population = mean(admin_year_population, na.rm = TRUE),
      gdppc_adm1_avg = mean(gdppc_adm1_avg, na.rm = TRUE),
      lr_prcp_adm1 = mean(lr_prcp_ERA5LAND_adm1_avg, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    # Profile 4: urban share >= 70%, population >= 500k, low ADM1 income,
    # and long-run ADM1 rainfall >= 1500 mm/year
    mutate(
      analysis_population = mortality_population,
      selected =
        urban_share >= 70 &
        analysis_population >= 500000 &
        gdppc_adm1_avg <= income_cutoff &
        lr_prcp_adm1 >= 1500,
      group = if_else(selected, "Mumbai-profile units", "Comparison units")
    ) %>%
    select(iso, admin_code, group)
  
  df <- df %>%
    left_join(admin_static, by = c("iso", "admin_code")) %>%
    mutate(
      group = factor(
        group,
        levels = c("Comparison units", "Mumbai-profile units")
      )
    )
  
  add_country_groups(df)
}


# -----------------------------
# Coefficient extraction
# -----------------------------

extract_wind_coefs <- function(fit, control_vars) {
  b <- coef(fit)
  v <- vcov(fit, cluster = ~adm1_code, vcov_fix = FALSE)
  
  # Extract each expected age-by-wind coefficient
  # Missing terms remain in the output as missing estimates
  rows <- list()
  row_i <- 1
  
  for (control_var in control_vars) {
    for (group_i in seq_len(nrow(coef_groups))) {
      coef_group <- coef_groups[group_i, ]
      term_name <- paste0(
        coef_group_var, "::",
        coef_group$coef_group_level, ":",
        control_var
      )
      
      if (term_name %in% names(b)) {
        estimate <- unname(b[[term_name]])
        se <- sqrt(v[term_name, term_name])
      } else {
        estimate <- NA_real_
        se <- NA_real_
      }
      
      rows[[row_i]] <- tibble(
        agegroup = coef_group$agegroup,
        age_label = coef_group$age_label,
        country_group_label = coef_group$country_group_label,
        coef_group_level = coef_group$coef_group_level,
        control_var = control_var,
        term = term_name,
        estimate = estimate,
        se = se,
        lo = estimate - 1.96 * se,
        hi = estimate + 1.96 * se
      )
      
      row_i <- row_i + 1
    }
  }
  
  bind_rows(rows)
}


# -----------------------------
# Run models
# -----------------------------

# Estimate each requested wind-control regression for the main sample,
# Profile 4 sample, or both
results <- list()
result_i <- 1

for (run_i in seq_len(nrow(control_runs))) {
  control_run <- control_runs[run_i, ]
  control_run_id <- control_run$control_run[[1]]
  control_label <- control_run$control_label[[1]]
  
  # The same raw variables are used to filter the sample and build the
  # age-specific control terms in the regression
  extra_vars <- unlist(control_run$control_vars, use.names = FALSE)
  controls <- glue("i({coef_group_var}, {extra_vars})")
  
  if (scope %in% c("main", "both")) {
    # Main-sample regression
    main_df <- make_main_sample(extra_vars)
    
    for (spec_i in seq_len(nrow(specs))) {
      spec <- specs[spec_i, ]
      fe_terms <- unlist(spec$fe, use.names = FALSE)
      
      message(glue("Main | {control_label} | {spec$spec_short}"))
      
      # `fit_response()` is defined in `0_utils/functions.R`.
      fit <- fit_response(
        main_df,
        tavg_order = 2, prcp_order = prcp_order,
        fe = fe_terms,
        controls = controls,
        weights = if (weighted) ~weight else NULL,
        cluster = ~adm1_code,
        log_mort = log_mort
      )
      
      results[[result_i]] <- extract_wind_coefs(fit, extra_vars) %>%
        mutate(
          sample = "Main",
          control_run = control_run_id,
          control_label = control_label,
          spec_id = spec$spec_id,
          spec_short = spec$spec_short,
          spec_label = spec$spec_label,
          outcome_model = outcome_model,
          weighted = weighted
        )
      
      result_i <- result_i + 1
    }
  }
  
  if (scope %in% c("profile4", "both")) {
    # Profile 4 regression with the rainfall-by-profile interaction
    profile_df <- make_profile4_sample(extra_vars)
    
    for (spec_i in seq_len(nrow(specs))) {
      spec <- specs[spec_i, ]
      fe_terms <- unlist(spec$fe, use.names = FALSE)
      
      message(glue("Profile 4 | {control_label} | {spec$spec_short}"))
      
      # `fit_response()` is defined in `0_utils/functions.R`.
      fit <- fit_response(
        profile_df,
        tavg_order = 2, prcp_order = prcp_order,
        interact_var = "group",
        fe = fe_terms,
        controls = controls,
        weights = if (weighted) ~weight else NULL,
        cluster = ~adm1_code,
        log_mort = log_mort
      )
      
      results[[result_i]] <- extract_wind_coefs(fit, extra_vars) %>%
        mutate(
          sample = "Profile 4",
          control_run = control_run_id,
          control_label = control_label,
          spec_id = spec$spec_id,
          spec_short = spec$spec_short,
          spec_label = spec$spec_label,
          outcome_model = outcome_model,
          weighted = weighted
        )
      
      result_i <- result_i + 1
    }
  }
}


# -----------------------------
# Write results
# -----------------------------

# One row per wind coefficient, sample, model, FE spec, age group, and country split
coef_table <- bind_rows(results) %>%
  left_join(coef_labels, by = "control_var") %>%
  mutate(
    response_scale = if_else(log_mort, "poisson", "deathrate_levels")
  ) %>%
  # `lo` and `hi` are the lower and upper ends of the 95% confidence interval
  select(
    sample, outcome_model, response_scale, weighted,
    control_run, control_label, control_var, control_var_label,
    agegroup, age_label, country_group_label, coef_group_level,
    spec_id, spec_short, spec_label, term, estimate, se, lo, hi
  )

write_csv(coef_table, file.path(out_dir, out_file))

message("Wrote wind coefficient table to: ", file.path(out_dir, out_file))
