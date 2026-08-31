# ==============================================================================
# 04_profile4_leave_one_admin_unit_out.R
#
# Leave-one-admin-unit-out check for Profile 4
#
# Profile 4 is the first "Mumbai-like" profile:
# large population, high urban share, wet ADM1, and bottom-25% ADM1 income
#
# Each run drops one selected admin unit for all years and age groups, then
# re-estimates the Profile 4 rainfall response.
# The script saves the leave-one-out estimates, baseline estimates, and summary 
# tables used to check whether one city/adm unit is driving the result
#
# The sbatch files can split the job by outcome model and fixed-effect spec
# using environment variables. This script does not make figures
#
# `fit_response()`, `make_coef_names()`, and `build_response()` are defined in
# `0_utils/functions.R`.
#
# Sbatch settings:
#   outcome models (`loo_outcome_models`) = levels | poisson | levels,poisson
#   fixed-effect specs (`loo_spec_ids`) = main | saturated | main,saturated
#   output folder name (`loo_run_slug`) = short name for this array task
#   output root (`loo_output_root`) = where the diagnostic files are written
#   detailed tables (`skip_detailed_loo_tables`) = true | false
#   fixest threads (`fixest_nthreads`) = threads/CPUs used by fixest; should
#                                      match the CPUs requested in the sbatch file
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
  library(knitr)
  library(kableExtra)
  library(scales)
  library(stringr)
})


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")
source("../../0_utils/functions.R") # fit_response(), make_coef_names(), build_response()
source("00_prep_analysis_panel.R")  # load_new_panel(), filter_regression_sample()


# -----------------------------
# Output folders
# -----------------------------

loo_slug <- "profile4_p25"

# By default, write under the rainfall repo. `loo_output_root` can still be set
# manually if a large test run needs a different output location.
output_root <- Sys.getenv("loo_output_root", DIR_REPO_RAINFALL_MORTALITY)
run_slug <- Sys.getenv("loo_run_slug", "all_specs")

data_dir <- file.path(
  output_root, "output", "data", "diagnostics", "subsamples",
  "leave_one_out", loo_slug, run_slug
)

table_dir <- file.path(
  output_root, "output", "tables", "diagnostics", "subsamples",
  "leave_one_out", loo_slug, run_slug
)

dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Run choices
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")
rainfall_points <- c(50, 100, 150, 200, 250, 300)

fixest_nthreads <- as.integer(Sys.getenv("fixest_nthreads", "1")) # default to one CPU unless sbatch sets this
fixest::setFixest_nthreads(fixest_nthreads)

raw_outcome_models <- Sys.getenv("loo_outcome_models", "levels,poisson") # levels, Poisson, or both
default_spec_ids <- paste(new_panel_specs$spec_id, collapse = ",")
raw_spec_ids <- Sys.getenv("loo_spec_ids", default_spec_ids) # FE specs to run

# These values are usually set in the sbatch files
# Comma-separated values allow several models/specs in the same R session
requested_outcome_models <- unlist(
  strsplit(raw_outcome_models, ",", fixed = TRUE),
  use.names = FALSE
) %>%
  str_trim()

requested_outcome_models <- requested_outcome_models[requested_outcome_models != ""]

requested_spec_ids <- unlist(
  strsplit(raw_spec_ids, ",", fixed = TRUE),
  use.names = FALSE
) %>%
  str_trim()

requested_spec_ids <- requested_spec_ids[requested_spec_ids != ""]

message("Raw loo_outcome_models: ", raw_outcome_models)
message("Raw loo_spec_ids: ", raw_spec_ids)

if (!all(requested_outcome_models %in% c("levels", "poisson"))) {
  stop("loo_outcome_models must contain only: levels, poisson", call. = FALSE)
}

# Fixed-effect specifications from `00_prep_analysis_panel.R`
run_specs <- new_panel_specs %>%
  filter(spec_id %in% requested_spec_ids)

if (nrow(run_specs) == 0) {
  stop(
    "No FE specifications matched loo_spec_ids. Requested: ",
    paste(requested_spec_ids, collapse = ", "),
    ". Available: ",
    paste(new_panel_specs$spec_id, collapse = ", "),
    call. = FALSE
  )
}

# Print the run choices at the top of the Slurm log
message("Leave-one-out run slug: ", run_slug)
message("Outcome models: ", paste(requested_outcome_models, collapse = ", "))
message("FE specs: ", paste(run_specs$spec_id, collapse = ", "))
message("fixest threads: ", fixest_nthreads)


# -----------------------------
# Table formatting
# -----------------------------

# Leave missing estimates blank in the LaTeX tables
fmt_num <- function(x) {
  ifelse(
    is.na(x),
    "",
    formatC(x, digits = 4, format = "fg", big.mark = ",")
  )
}

# Show estimate [low CI, high CI], with significant cells bold and shaded
fmt_estimate <- function(estimate, lo, hi) {
  if (is.na(estimate) || is.na(lo) || is.na(hi)) {
    return("")
  }
  
  cell <- paste0(
    fmt_num(estimate), " [",
    fmt_num(lo), ", ",
    fmt_num(hi), "]"
  )
  
  if ((lo > 0 && hi > 0) || (lo < 0 && hi < 0)) {
    cell <- cell_spec(
      cell, format = "latex",
      bold = TRUE, background = "#eeeeee"
    )
  }
  
  cell
}

# Return the first available value, or missing if the run failed
first_nonmissing <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) NA_real_ else x[[1]]
}

# Name the dropped unit that changes the estimate the most
largest_change_unit <- function(unit, diff) {
  if (all(is.na(diff))) {
    return(NA_character_)
  }
  
  unit[which.max(abs(diff))][[1]]
}


# -----------------------------
# Estimate one response function
# -----------------------------

run_profile_rf <- function(data, outcome_model, spec_row,
                           dropped_admin_code, dropped_admin_name) {
  log_mort <- outcome_model == "poisson"
  fe_terms <- spec_row$fe[[1]]
  
  # `fit_response()` is defined in `0_utils/functions.R`.
  # `group` separates Profile 4 units from the rest of the panel
  # The interaction estimates the rainfall response separately by age and group
  fit <- fit_response(
    data,
    tavg_order = 2, prcp_order = 3,
    interact_var = "group",
    fe = fe_terms,
    weights = ~weight,
    cluster = ~adm1_code,
    log_mort = log_mort,
    mem.clean = TRUE,
    nthreads = fixest_nthreads
  )
  
  # `make_coef_names()` and `build_response()` are defined in
  # `0_utils/functions.R`.
  # Identify the rainfall coefficients for each age and profile group.
  key <- make_coef_names(
    prefix = "prcp_poly_",
    interact_var = "group",
    fit = fit
  )
  
  # Build both group responses, then keep Profile 4 at the rainfall values
  # used in the leave-one-out tables
  response_groups <- crossing(
    agegroup = levels(data$agegroup),
    group = levels(data$group)
  )
  
  build_response(
    fit,
    x = 0:300, x_ref = 0, poly_order = 3,
    groups = response_groups,
    key = key, id = "Precipitation",
    vcov_cluster = ~adm1_code, vcov_fix = FALSE
  ) %>%
    filter(group == "Mumbai-profile units", x %in% rainfall_points) %>%
    transmute(
      dropped_admin_code = dropped_admin_code,
      dropped_admin_unit = dropped_admin_name,
      outcome_model = outcome_model,
      spec_id = spec_row$spec_id,
      spec_short = spec_row$spec_short,
      agegroup = as.character(agegroup),
      age_group = recode(as.character(agegroup), !!!age_labels),
      rainfall_mm = x,
      estimate = dy,
      se = se,
      ci_lower = lo,
      ci_upper = hi
    )
}

# If one dropped-unit regression fails, record it and continue with the other runs
run_profile_rf_or_record_error <- function(data, outcome_model, spec_row,
                                           dropped_admin_code, dropped_admin_name) {
  out <- tryCatch(
    run_profile_rf(
      data, outcome_model, spec_row,
      dropped_admin_code, dropped_admin_name
    ),
    error = function(e) {
      failure_rows <- expand.grid(
        agegroup = levels(data$agegroup),
        rainfall_mm = rainfall_points,
        stringsAsFactors = FALSE
      )
      
      # Keep the expected age/rainfall rows but leave the failed estimates missing
      failure_rows %>%
        transmute(
          dropped_admin_code = dropped_admin_code,
          dropped_admin_unit = dropped_admin_name,
          outcome_model = outcome_model,
          spec_id = spec_row$spec_id,
          spec_short = spec_row$spec_short,
          agegroup = as.character(agegroup),
          age_group = recode(as.character(agegroup), !!!age_labels),
          rainfall_mm = rainfall_mm,
          estimate = NA_real_,
          se = NA_real_,
          ci_lower = NA_real_,
          ci_upper = NA_real_,
          error = conditionMessage(e)
        )
    }
  )
  
  # Successful runs have no error message
  if (!"error" %in% names(out)) {
    out <- out %>%
      mutate(error = NA_character_)
  }
  
  out
}


# -----------------------------
# Regression sample
# -----------------------------

# Use the same rainfall, temperature, urban-share, and income variables as the
# Profile 4 subsample regressions
df <- load_new_panel(
  prcp_product = "ERA5LAND",
  temp_product = "ERA5LAND",
  require_urban = TRUE
) %>%
  filter_regression_sample(
    tavg_order = 2,
    prcp_order = 3,
    require_urban = TRUE,
    extra_vars = c(
      "gdppc_adm1_avg",
      "lr_prcp_ERA5LAND_adm1_avg",
      "prcp_poly_1"
    )
  )


# -----------------------------
# Profile 4 units
# -----------------------------

# Bottom-quartile ADM1 income cutoff in this regression sample
income_cutoff <- quantile(
  df$gdppc_adm1_avg,
  probs = 0.25,
  na.rm = TRUE,
  type = 7
)

# Mortality population is age-specific, so first recover total admin-year population
admin_year_pop <- df %>%
  group_by(admin_code, year) %>%
  summarize(
    admin_year_population = sum(population, na.rm = TRUE),
    .groups = "drop"
  )

# Average the profile variables over years to assign each admin unit once
admin_static <- df %>%
  left_join(admin_year_pop, by = c("admin_code", "year")) %>%
  group_by(
    iso, adm0,
    adm1_code, adm1_name,
    adm2_id, adm2_name,
    admin_code, admin_name, admin_level
  ) %>%
  summarize(
    urban_share = mean(urban_share, na.rm = TRUE),
    mortality_population = mean(admin_year_population, na.rm = TRUE),
    gdppc_adm1_avg = mean(gdppc_adm1_avg, na.rm = TRUE),
    lr_prcp_adm1 = mean(lr_prcp_ERA5LAND_adm1_avg, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  # Profile 4: urban share >= 70%, population >= 500k, bottom-quartile ADM1
  # income, and long-run ADM1 rainfall >= 1500 mm/year
  mutate(
    analysis_population = mortality_population,
    selected =
      urban_share >= 70 &
      analysis_population >= 500000 &
      gdppc_adm1_avg <= income_cutoff &
      lr_prcp_adm1 >= 1500
  )

# Keep the full sample and mark selected Profile 4 versus comparison units
profile_panel <- df %>%
  left_join(
    admin_static %>% select(iso, admin_code, selected),
    by = c("iso", "admin_code")
  ) %>%
  mutate(
    selected = coalesce(selected, FALSE),
    group = factor(
      if_else(selected, "Mumbai-profile units", "Comparison units"),
      levels = c("Comparison units", "Mumbai-profile units")
    )
  )

selected_units <- admin_static %>%
  filter(selected) %>%
  arrange(iso, adm1_name, admin_name, admin_code)

if (nrow(selected_units) == 0) {
  stop("No selected Profile 4 p25 admin units found.", call. = FALSE)
}


# -----------------------------
# Units dropped one at a time
# -----------------------------

selected_panel <- profile_panel %>%
  filter(selected)

# Record how much of the selected Profile 4 sample is removed with each unit
sample_changes <- selected_units %>%
  select(
    dropped_admin_code = admin_code,
    dropped_admin_unit = admin_name,
    country = adm0, iso, adm1_name, adm2_name, admin_level
  ) %>%
  rowwise() %>%
  # Each dropped unit is removed for all years and age groups
  mutate(
    years_dropped = n_distinct(
      selected_panel$year[selected_panel$admin_code == dropped_admin_code]
    ),
    age_groups_dropped = n_distinct(
      selected_panel$agegroup[selected_panel$admin_code == dropped_admin_code]
    ),
    regression_rows_dropped = sum(
      selected_panel$admin_code == dropped_admin_code
    ),
    selected_admin_units_remaining = n_distinct(
      selected_panel$admin_code[selected_panel$admin_code != dropped_admin_code]
    ),
    selected_rows_remaining = sum(
      selected_panel$admin_code != dropped_admin_code
    ),
    total_regression_rows_remaining = sum(
      profile_panel$admin_code != dropped_admin_code
    ),
    share_selected_rows_dropped = regression_rows_dropped / nrow(selected_panel)
  ) %>%
  ungroup() %>%
  arrange(desc(regression_rows_dropped), country, dropped_admin_unit)

write_csv(
  sample_changes,
  file.path(data_dir, "leave_one_admin_unit_sample_changes.csv")
)

# LaTeX version of the dropped-unit sample-size table
sample_table <- sample_changes %>%
  transmute(
    `Dropped\\ Admin\\ Unit` = str_to_title(dropped_admin_unit),
    `Country` = str_to_title(country),
    `ADM1` = str_to_title(adm1_name),
    `ADM2` = str_to_title(adm2_name),
    `Admin\\ Level` = admin_level,
    `Years\\ Dropped` = years_dropped,
    `Age\\ Groups\\ Dropped` = age_groups_dropped,
    `Rows\\ Dropped` = regression_rows_dropped,
    `Selected\\ Rows\\ Remaining` = selected_rows_remaining,
    `Selected\\ Admin\\ Units\\ Remaining` = selected_admin_units_remaining
  )

sample_table_tex <- kbl(
  sample_table,
  format = "latex",
  booktabs = TRUE,
  escape = FALSE,
  align = c("l", "l", "l", "l", "l", rep("r", 5)),
  caption = "Leave-one-admin-unit-out sample changes"
) %>%
  kable_styling(
    latex_options = c("hold_position", "scale_down"),
    font_size = 7
  )

writeLines(
  sample_table_tex,
  file.path(table_dir, "leave_one_admin_unit_sample_changes.tex")
)


# -----------------------------
# Baseline regressions
# -----------------------------

# Estimate the Profile 4 response before dropping any selected unit
baseline_list <- list()
result_i <- 1

for (outcome_model in requested_outcome_models) {
  for (spec_i in seq_len(nrow(run_specs))) {
    spec_row <- run_specs[spec_i, ]
    
    message(glue(
      "Running baseline | {outcome_model} | {spec_row$spec_short}"
    ))
    
    baseline_list[[result_i]] <- run_profile_rf_or_record_error(
      data = profile_panel,
      outcome_model = outcome_model,
      spec_row = spec_row,
      dropped_admin_code = "baseline",
      dropped_admin_name = "Baseline"
    )
    
    result_i <- result_i + 1
  }
}

# Rename the full-sample estimates before comparing them with each dropped-unit run
baseline_runs <- bind_rows(baseline_list) %>%
  rename(
    baseline_estimate = estimate,
    baseline_se = se,
    baseline_ci_lower = ci_lower,
    baseline_ci_upper = ci_upper,
    baseline_error = error
  )


# -----------------------------
# Leave-one-out regressions
# -----------------------------

# Drop each selected admin unit once and re-run the same model/spec combinations
leave_one_out_list <- list()
result_i <- 1

for (drop_i in seq_len(nrow(sample_changes))) {
  dropped_admin_code <- sample_changes$dropped_admin_code[[drop_i]]
  dropped_admin_unit <- sample_changes$dropped_admin_unit[[drop_i]]
  
  # Drop this unit for all years and age groups
  loo_panel <- profile_panel %>%
    filter(admin_code != dropped_admin_code)
  
  for (outcome_model in requested_outcome_models) {
    for (spec_i in seq_len(nrow(run_specs))) {
      spec_row <- run_specs[spec_i, ]
      
      message(glue(
        "Dropping {dropped_admin_code} | {outcome_model} | {spec_row$spec_short}"
      ))
      
      leave_one_out_list[[result_i]] <- run_profile_rf_or_record_error(
        data = loo_panel,
        outcome_model = outcome_model,
        spec_row = spec_row,
        dropped_admin_code = dropped_admin_code,
        dropped_admin_name = dropped_admin_unit
      )
      
      result_i <- result_i + 1
    }
  }
}

leave_one_out_runs <- bind_rows(leave_one_out_list)

# Match each dropped-unit estimate to its full-sample estimate
loo_estimates <- leave_one_out_runs %>%
  left_join(
    sample_changes %>%
      select(
        dropped_admin_code, country, iso, adm1_name, adm2_name,
        regression_rows_dropped
      ),
    by = "dropped_admin_code"
  ) %>%
  left_join(
    baseline_runs %>%
      select(
        outcome_model, spec_id, spec_short, agegroup, age_group, rainfall_mm,
        baseline_estimate, baseline_se,
        baseline_ci_lower, baseline_ci_upper, baseline_error
      ),
    by = c(
      "outcome_model", "spec_id", "spec_short",
      "agegroup", "age_group", "rainfall_mm"
    )
  ) %>%
  # Compare each leave-one-out estimate with the full-sample estimate
  mutate(
    diff_from_baseline = estimate - baseline_estimate,
    pct_change_from_baseline = diff_from_baseline / abs(baseline_estimate),
    sign_flipped =
      !is.na(estimate) &
      !is.na(baseline_estimate) &
      sign(estimate) != sign(baseline_estimate)
  ) %>%
  arrange(
    outcome_model, spec_id, agegroup, rainfall_mm,
    country, dropped_admin_unit
  )

# One row per dropped unit, model, FE spec, age group, and rainfall value
write_csv(
  loo_estimates,
  file.path(data_dir, "leave_one_admin_unit_estimates.csv")
)

# Full-sample estimates used as the comparison point
write_csv(
  baseline_runs,
  file.path(data_dir, "leave_one_admin_unit_baseline_estimates.csv")
)


# -----------------------------
# Detailed estimate tables
# -----------------------------

make_estimate_table <- function(outcome, spec, age) {
  # One row per dropped unit and one column per rainfall value
  table_data <- loo_estimates %>%
    filter(
      outcome_model == outcome,
      spec_id == spec,
      agegroup == age
    ) %>%
    # Bold/shaded cells have confidence intervals that do not cross zero
    mutate(
      cell = mapply(
        fmt_estimate, estimate, ci_lower, ci_upper,
        USE.NAMES = FALSE
      ),
      rainfall_label = paste0("\\makecell{", rainfall_mm, "\\\\mm}")
    ) %>%
    select(
      dropped_admin_unit, country, regression_rows_dropped,
      rainfall_label, cell
    ) %>%
    distinct() %>%
    mutate(
      dropped_admin_unit = str_to_title(dropped_admin_unit),
      country = str_to_title(country)
    ) %>%
    pivot_wider(names_from = rainfall_label, values_from = cell) %>%
    arrange(country, dropped_admin_unit) %>%
    rename(
      `Dropped\\ Admin\\ Unit` = dropped_admin_unit,
      `Country` = country,
      `Rows\\ Dropped` = regression_rows_dropped
    )
  
  caption <- glue(
    "Leave-one-admin-unit-out estimates: {str_to_title(outcome)}, ",
    "{unique(loo_estimates$spec_short[loo_estimates$spec_id == spec])}, ",
    "age {age_labels[[age]]}"
  )
  
  kbl(
    table_data,
    format = "latex",
    booktabs = TRUE,
    escape = FALSE,
    align = c("l", "l", "r", rep("r", length(rainfall_points))),
    caption = caption
  ) %>%
    kable_styling(
      latex_options = c("hold_position", "scale_down"),
      font_size = 6
    ) %>%
    footnote(
      general = paste(
        "Cells report estimate [95\\% CI].",
        "Bold shaded cells have confidence intervals that do not cross zero."
      ),
      general_title = "",
      threeparttable = TRUE,
      escape = FALSE
    )
}

# List the detailed tables that can be written
detailed_table_rows <- list()
row_i <- 1

for (outcome_model in requested_outcome_models) {
  for (spec_id in run_specs$spec_id) {
    for (agegroup in names(age_labels)) {
      detailed_table_rows[[row_i]] <- tibble(
        outcome_model = outcome_model,
        spec_id = spec_id,
        agegroup = agegroup,
        file_name = paste0(
          "leave_one_admin_unit_estimates_",
          outcome_model, "_", spec_id, "_age", agegroup, ".tex"
        )
      )
      
      row_i <- row_i + 1
    }
  }
}

detailed_table_index <- bind_rows(detailed_table_rows)

if (tolower(Sys.getenv("skip_detailed_loo_tables", "false")) != "true") {
  # These tables are large, so the sbatch file usually skips them
  for (row_i in seq_len(nrow(detailed_table_index))) {
    writeLines(
      make_estimate_table(
        detailed_table_index$outcome_model[[row_i]],
        detailed_table_index$spec_id[[row_i]],
        detailed_table_index$agegroup[[row_i]]
      ),
      file.path(
        table_dir,
        detailed_table_index$file_name[[row_i]]
      )
    )
  }
} else {
  message(
    "Skipping detailed leave-one-out LaTeX tables because ",
    "skip_detailed_loo_tables=true"
  )
}


# -----------------------------
# Stability summary
# -----------------------------

# Use the 300 mm response to compare sensitivity across dropped units
stability_summary <- loo_estimates %>%
  filter(rainfall_mm == 300) %>%
  group_by(outcome_model, spec_id, spec_short, agegroup, age_group) %>%
  # Compare the baseline with the range of estimates after dropping one unit
  summarize(
    baseline_estimate_300mm = first_nonmissing(baseline_estimate),
    min_loo_estimate_300mm = if_else(
      all(is.na(estimate)),
      NA_real_,
      min(estimate, na.rm = TRUE)
    ),
    max_loo_estimate_300mm = if_else(
      all(is.na(estimate)),
      NA_real_,
      max(estimate, na.rm = TRUE)
    ),
    largest_abs_change_300mm = if_else(
      all(is.na(diff_from_baseline)),
      NA_real_,
      max(abs(diff_from_baseline), na.rm = TRUE)
    ),
    dropped_unit_largest_change = largest_change_unit(
      dropped_admin_unit,
      diff_from_baseline
    ),
    sign_flips = sum(sign_flipped, na.rm = TRUE),
    loo_runs_ci_excludes_zero = sum(
      (ci_lower > 0 & ci_upper > 0) |
        (ci_lower < 0 & ci_upper < 0),
      na.rm = TRUE
    ),
    failed_runs = sum(!is.na(error)),
    .groups = "drop"
  ) %>%
  mutate(
    dropped_unit_largest_change = if_else(
      is.na(largest_abs_change_300mm),
      NA_character_,
      str_to_title(dropped_unit_largest_change)
    )
  ) %>%
  arrange(outcome_model, spec_id, agegroup)

# Compact summary of sensitivity in the 300 mm estimate
write_csv(
  stability_summary,
  file.path(data_dir, "leave_one_admin_unit_stability_summary.csv")
)

# LaTeX summary of the leave-one-out range at 300 mm
stability_table <- stability_summary %>%
  transmute(
    `Model` = str_to_title(outcome_model),
    `FE\\ Spec.` = spec_short,
    `Age\\ Group` = age_group,
    `Baseline\\ at\\ 300\\ mm` = fmt_num(baseline_estimate_300mm),
    `Min\\ LOO\\ at\\ 300\\ mm` = fmt_num(min_loo_estimate_300mm),
    `Max\\ LOO\\ at\\ 300\\ mm` = fmt_num(max_loo_estimate_300mm),
    `Largest\\ Abs.\\ Change` = fmt_num(largest_abs_change_300mm),
    `Dropped\\ Unit\\ Largest\\ Change` = dropped_unit_largest_change,
    `Sign\\ Flips` = sign_flips,
    `LOO\\ CI\\ Excludes\\ Zero` = loo_runs_ci_excludes_zero,
    `Failed\\ Runs` = failed_runs
  )

stability_table_tex <- kbl(
  stability_table,
  format = "latex",
  booktabs = TRUE,
  escape = FALSE,
  align = c("l", "l", "l", rep("r", 4), "l", rep("r", 3)),
  caption = "Leave-one-admin-unit-out stability summary at 300 mm"
) %>%
  kable_styling(
    latex_options = c("hold_position", "scale_down"),
    font_size = 7
  )

writeLines(
  stability_table_tex,
  file.path(table_dir, "leave_one_admin_unit_stability_summary.tex")
)

# Keep an index of the optional detailed tables even when they are skipped
write_csv(
  detailed_table_index,
  file.path(data_dir, "leave_one_admin_unit_table_index.csv")
)

message("Wrote leave-one-out data to: ", data_dir)
message("Wrote leave-one-out tables to: ", table_dir)
