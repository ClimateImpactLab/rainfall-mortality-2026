# =============================================================================
# 01_profile_selection_diagnostics.R
#
# Check the first-pass Mumbai-like profile definitions
#
# These are the older profile checks based on urban share, population,
# long-run rainfall, and ADM1 income
# The newer profile work with additional covariates is in the nested folder
#
# This script does not run regressions
# It checks how much of the sample remains under each possible profile definition
#
# Main outputs:
#   hard_threshold_criteria_retention.csv
#   hard_threshold_waterfall.csv
#   admin_unit_profile_scores.csv
#   score_threshold_retention.csv
#   profile_country_composition.csv
# ==========================================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(readr)
library(glue)
library(ggplot2)
library(scales)

theme_set(theme_classic())

args <- commandArgs(FALSE)
file_arg <- args[grepl("^--file=", args)]

# Start from this folder so the relative source paths below work
# This matters when the script is run from sbatch
script_dir <- if (length(file_arg) > 0) {
  dirname(normalizePath(sub("^--file=", "", file_arg[[1]])))
} else {
  getwd()
}
setwd(script_dir)

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY, DIR_FIGURE
source("../../regressions/00_prep_analysis_panel.R") # load_new_panel(), filter_regression_sample()

# -----------------------------
# Output paths
# -----------------------------

# CSV outputs for the first-pass profile checks
diag_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "data", "diagnostics", "subsamples", "profile_selection"
)

# Figures showing how much of the sample each profile definition keeps
fig_dir <- file.path(
  DIR_FIGURE,
  "regs", "analysis-panel", "subsamples", "profile_selection"
)

dir.create(diag_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

# -----------------------------
# Regression sample
# -----------------------------

# Use the same basic sample restrictions as the regressions
# The extra variables are needed to define the first-pass profiles
df <- load_new_panel(
  prcp_product = "ERA5LAND",
  temp_product = "ERA5LAND",
  require_urban = TRUE
) %>%
  filter_regression_sample(
    tavg_order = 2,
    prcp_order = 3,
    require_urban = TRUE,
    extra_vars = c("gdppc_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg", "prcp_poly_1")
  )

# -----------------------------
# Admin-unit measures
# -----------------------------

# Population is age-specific in the regression panel
# Sum across age groups before using it as an admin-year population measure
admin_year_pop <- df %>%
  group_by(admin_code, year) %>%
  summarize(admin_year_population = sum(population, na.rm = TRUE), .groups = "drop")

# Profile membership is fixed within each admin unit
# Collapse the year-age panel to one row per admin unit
admin_static <- df %>%
  left_join(admin_year_pop, by = c("admin_code", "year")) %>%
  group_by(iso, adm0, adm1_code, adm1_name, admin_code, admin_name, admin_level) %>%
  summarize(
    urban_share = mean(urban_share, na.rm = TRUE),
    ghsl_population = mean(ghsl_population, na.rm = TRUE),
    mortality_population = mean(admin_year_population, na.rm = TRUE),
    gdppc_adm1_avg = mean(gdppc_adm1_avg, na.rm = TRUE),
    lr_prcp_adm1 = mean(lr_prcp_ERA5LAND_adm1_avg, na.rm = TRUE),
    rows = n(),
    years = n_distinct(year),
    agegroups = n_distinct(agegroup),
    .groups = "drop"
  ) %>%
  mutate(
    analysis_population = coalesce(ghsl_population, mortality_population)
  ) %>%
  # Keep only admin units with all variables needed for the profile checks
  filter(
    !is.na(urban_share),
    !is.na(analysis_population),
    !is.na(gdppc_adm1_avg),
    !is.na(lr_prcp_adm1)
  )

# -----------------------------
# Hard-cutoff profiles
# -----------------------------

# ADM1 income is the weakest part of these first-pass profiles
# Use p25 and p50 of the regression sample instead of fixed dollar cutoffs
income_cutoffs <- quantile(
  df$gdppc_adm1_avg,
  probs = c(0.25, 0.50),
  na.rm = TRUE,
  type = 7
)

# Each row defines one possible Mumbai-like profile
# Profiles combine urban share, population, ADM1 income, and long-run rainfall
profile_defs <- tibble::tribble(
  ~profile_id, ~profile_label, ~urban_cutoff, ~pop_cutoff, ~income_type, ~income_cutoff, ~prcp_cutoff,
  "urban_wet_p50", "Urban Wet, Bottom-50 Income", 50, 100000, "bottom_50", unname(income_cutoffs[["50%"]]), 1000,
  "high_urban_wet_p50", "High-Urban Wet, Bottom-50 Income", 70, 250000, "bottom_50", unname(income_cutoffs[["50%"]]), 1000,
  "very_wet_urban_p50", "Very-Wet Urban, Bottom-50 Income", 50, 250000, "bottom_50", unname(income_cutoffs[["50%"]]), 1500,
  "large_high_urban_wet_p50", "Large High-Urban Wet, Bottom-50 Income", 70, 500000, "bottom_50", unname(income_cutoffs[["50%"]]), 1500,
  "urban_wet_p25", "Urban Wet, Bottom-25 Income", 50, 100000, "bottom_25", unname(income_cutoffs[["25%"]]), 1000,
  "high_urban_wet_p25", "High-Urban Wet, Bottom-25 Income", 70, 250000, "bottom_25", unname(income_cutoffs[["25%"]]), 1000,
  "very_wet_urban_p25", "Very-Wet Urban, Bottom-25 Income", 50, 250000, "bottom_25", unname(income_cutoffs[["25%"]]), 1500,
  "large_high_urban_wet_p25", "Large High-Urban Wet, Bottom-25 Income", 70, 500000, "bottom_25", unname(income_cutoffs[["25%"]]), 1500
) %>%
  mutate(
    criteria = glue(
      "urban_share >= {urban_cutoff}; population >= {format(pop_cutoff, big.mark = ',')}; ",
      "ADM1 GDPpc <= ${format(round(income_cutoff), big.mark = ',')} ({income_type}); ",
      "long-run precip >= {format(prcp_cutoff, big.mark = ',')} mm/year"
    )
  )

# Count how much of the sample remains after applying a TRUE/FALSE profile flag
summarize_support <- function(data, selected) {
  selected <- selected %in% TRUE
  data %>%
    filter(selected) %>%
    summarize(
      rows = sum(rows),
      admin_units = n_distinct(admin_code),
      countries = n_distinct(iso),
      adm1_units = n_distinct(adm1_code),
      mean_urban_share = mean(urban_share, na.rm = TRUE),
      mean_population = mean(analysis_population, na.rm = TRUE),
      mean_gdppc_adm1 = mean(gdppc_adm1_avg, na.rm = TRUE),
      mean_lr_prcp_adm1 = mean(lr_prcp_adm1, na.rm = TRUE),
      .groups = "drop"
    )
}

# Check each criterion on its own and in a few useful combinations
# This shows which criteria are driving the sample loss
criteria_retention <- profile_defs %>%
  rowwise() %>%
  mutate(
    urban_only = list(admin_static$urban_share >= urban_cutoff),
    population_only = list(admin_static$analysis_population >= pop_cutoff),
    income_only = list(admin_static$gdppc_adm1_avg <= income_cutoff),
    rainfall_only = list(admin_static$lr_prcp_adm1 >= prcp_cutoff),
    urban_population = list(unlist(urban_only) & unlist(population_only)),
    urban_rainfall = list(unlist(urban_only) & unlist(rainfall_only)),
    urban_population_rainfall = list(unlist(urban_only) & unlist(population_only) & unlist(rainfall_only)),
    all_criteria = list(unlist(urban_only) & unlist(population_only) & unlist(income_only) & unlist(rainfall_only))
  ) %>%
  ungroup() %>%
  select(profile_id, profile_label, criteria, urban_only:all_criteria) %>%
  pivot_longer(
    cols = urban_only:all_criteria,
    names_to = "criteria_set",
    values_to = "selected"
  ) %>%
  rowwise() %>%
  mutate(summary = list(summarize_support(admin_static, unlist(selected)))) %>%
  unnest(summary) %>%
  ungroup() %>%
  mutate(
    criteria_set = factor(
      criteria_set,
      levels = c(
        "urban_only", "population_only", "income_only", "rainfall_only",
        "urban_population", "urban_rainfall", "urban_population_rainfall",
        "all_criteria"
      )
    )
  )

write_csv(
  criteria_retention,
  file.path(diag_dir, "hard_threshold_criteria_retention.csv")
)

# -----------------------------
# Waterfall checks
# -----------------------------

# Apply the four criteria one at a time
# This shows which criterion removes the most admin units
waterfall_order <- c("urban", "population", "rainfall", "income")

# Build one waterfall table for each profile definition
waterfall <- profile_defs %>%
  rowwise() %>%
  mutate(
    steps = list({
      selected <- rep(TRUE, nrow(admin_static))
      out <- tibble(
        step = "Full sample",
        rows = sum(admin_static$rows),
        admin_units = n_distinct(admin_static$admin_code),
        countries = n_distinct(admin_static$iso)
      )
      
      for (criterion in waterfall_order) {
        criterion_keep <- switch(
          criterion,
          urban = admin_static$urban_share >= urban_cutoff,
          population = admin_static$analysis_population >= pop_cutoff,
          rainfall = admin_static$lr_prcp_adm1 >= prcp_cutoff,
          income = admin_static$gdppc_adm1_avg <= income_cutoff
        )
        
        selected <- selected & criterion_keep
        out <- bind_rows(
          out,
          summarize_support(admin_static, selected) %>%
            transmute(
              step = paste("After", criterion),
              rows = rows,
              admin_units = admin_units,
              countries = countries
            )
        )
      }
      
      out
    })
  ) %>%
  select(profile_id, profile_label, criteria, steps) %>%
  unnest(steps) %>%
  group_by(profile_id) %>%
  mutate(
    step = factor(step, levels = c("Full sample", paste("After", waterfall_order))),
    retained_admin_share = admin_units / first(admin_units),
    retained_row_share = rows / first(rows)
  ) %>%
  ungroup()

write_csv(
  waterfall,
  file.path(diag_dir, "hard_threshold_waterfall.csv")
)

# -----------------------------
# Profile score
# -----------------------------

# Continuous version of the first-pass profile definition
# Higher scores mean more urban, more populous, wetter, and lower-income
admin_scores <- admin_static %>%
  mutate(
    urban_pct = percent_rank(urban_share),
    population_pct = percent_rank(log1p(analysis_population)),
    rainfall_pct = percent_rank(lr_prcp_adm1),
    inverse_income_pct = percent_rank(-gdppc_adm1_avg),
    urban_wet_income_score = rowMeans(
      as.data.frame(across(c(urban_pct, population_pct, rainfall_pct, inverse_income_pct))),
      na.rm = TRUE
    )
  )

# Define score cutoffs for the top 30%, 20%, 10%, and 5% of admin units
score_thresholds <- tibble(
  score_group = c("Top 30%", "Top 20%", "Top 10%", "Top 5%"),
  min_score = quantile(
    admin_scores$urban_wet_income_score,
    probs = c(0.70, 0.80, 0.90, 0.95),
    na.rm = TRUE,
    type = 7
  )
)

# Count how much of the sample remains at each score cutoff
score_retention <- score_thresholds %>%
  rowwise() %>%
  mutate(
    summary = list(summarize_support(
      admin_scores,
      admin_scores$urban_wet_income_score >= min_score
    ))
  ) %>%
  unnest(summary) %>%
  ungroup()

write_csv(
  admin_scores,
  file.path(diag_dir, "admin_unit_profile_scores.csv")
)

write_csv(
  score_retention,
  file.path(diag_dir, "score_threshold_retention.csv")
)

# -----------------------------
# Country composition
# -----------------------------

# A profile can retain many observations while drawing them from only a few countries
# Check country shares for both the hard-cutoff profiles and score cutoffs
country_composition <- bind_rows(
  profile_defs %>%
    rowwise() %>%
    mutate(
      selected = list(
        admin_static$urban_share >= urban_cutoff &
          admin_static$analysis_population >= pop_cutoff &
          admin_static$gdppc_adm1_avg <= income_cutoff &
          admin_static$lr_prcp_adm1 >= prcp_cutoff
      )
    ) %>%
    ungroup() %>%
    select(profile_id, profile_label, selected) %>%
    rowwise() %>%
    mutate(
      composition = list(
        admin_static %>%
          filter(unlist(selected)) %>%
          count(iso, adm0, wt = rows, name = "rows") %>%
          mutate(
            profile_id = profile_id,
            profile_label = profile_label,
            share_rows = rows / sum(rows)
          )
      )
    ) %>%
    select(composition) %>%
    unnest(composition),
  
  score_thresholds %>%
    rowwise() %>%
    mutate(
      composition = list(
        admin_scores %>%
          filter(urban_wet_income_score >= min_score) %>%
          count(iso, adm0, wt = rows, name = "rows") %>%
          mutate(
            profile_id = paste0("score_", gsub("[^0-9]", "", score_group)),
            profile_label = paste0("Score ", score_group),
            share_rows = rows / sum(rows)
          )
      )
    ) %>%
    select(composition) %>%
    unnest(composition)
)

write_csv(
  country_composition,
  file.path(diag_dir, "profile_country_composition.csv")
)

# -----------------------------
# Figures
# -----------------------------

# Plot the number of admin units kept by each hard-cutoff criterion
p_retention <- criteria_retention %>%
  filter(criteria_set %in% c(
    "urban_only", "population_only", "income_only", "rainfall_only",
    "urban_population_rainfall", "all_criteria"
  )) %>%
  mutate(
    criteria_set = recode(
      as.character(criteria_set),
      urban_only = "Urban only",
      population_only = "Population only",
      income_only = "Income only",
      rainfall_only = "Rainfall only",
      urban_population_rainfall = "Urban + population + rainfall",
      all_criteria = "All criteria"
    ),
    profile_label = factor(profile_label, levels = unique(profile_label))
  ) %>%
  ggplot(aes(criteria_set, admin_units, fill = criteria_set)) +
  geom_col(width = 0.72) +
  facet_wrap(~ profile_label, scales = "free_y", ncol = 2) +
  scale_y_continuous(labels = comma) +
  labs(
    x = NULL,
    y = "Admin units retained",
    fill = NULL
  ) +
  theme_classic(base_size = 12) +
  theme(
    legend.position = "none",
    strip.text = element_text(face = "bold"),
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

ggsave(
  file.path(fig_dir, "hard_threshold_criteria_retention_admin_units.pdf"),
  p_retention,
  width = 13,
  height = 8.5
)

# Plot how the sample shrinks as criteria are added one at a time
p_waterfall <- waterfall %>%
  ggplot(aes(step, admin_units, group = profile_label, color = profile_label)) +
  geom_line(linewidth = 1) +
  geom_point(size = 2.2) +
  scale_y_continuous(labels = comma) +
  labs(
    x = NULL,
    y = "Admin units retained",
    color = NULL
  ) +
  theme_classic(base_size = 13) +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 25, hjust = 1)
  )

ggsave(
  file.path(fig_dir, "hard_threshold_waterfall_admin_units.pdf"),
  p_waterfall,
  width = 12,
  height = 6.8
)

# Plot how many admin units are kept by each score cutoff
p_score <- score_retention %>%
  mutate(score_group = factor(score_group, levels = c("Top 30%", "Top 20%", "Top 10%", "Top 5%"))) %>%
  ggplot(aes(score_group, admin_units, fill = score_group)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = comma(admin_units)), vjust = -0.25, size = 4) +
  scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.12))) +
  labs(
    x = "Score threshold",
    y = "Admin units retained",
    fill = NULL
  ) +
  theme_classic(base_size = 14) +
  theme(legend.position = "none")

ggsave(
  file.path(fig_dir, "score_threshold_retention_admin_units.pdf"),
  p_score,
  width = 8,
  height = 5.5
)

message("Wrote profile-selection diagnostics to: ", diag_dir)
message("Wrote profile-selection figures to: ", fig_dir)