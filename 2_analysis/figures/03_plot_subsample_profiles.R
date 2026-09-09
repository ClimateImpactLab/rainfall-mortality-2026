# ============================================================
# 03_plot_subsample_profiles.R
#
# Plot the exploratory Mumbai-profile response functions
#
# This script reads the response-function CSV and retention table written by
# `regressions/03_subsample_profiles.R`
#
# It makes three sets of figures:
# 1. one profile at a time
# 2. two related profiles in the same panel
# 3. all four profiles in one larger panel
#
# These options must match the regression run being plotted
#   --low_income_cutoff = p25 | p50
#   --outcome_model = levels | poisson
#   --profile_scope = all | profile4
#   --age_filter = all | 1 | 2 | 3 | 1,2,3
#   --wind_control = none | windmax | winddays | both
#   --daily_overlap_control = none | rain100 | rain200 | both
#   --daily_overlap_exclusion = none | rain100 | rain200
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(readr)
library(glue)
library(ggplot2)
library(MetBrewer)
theme_set(theme_classic())


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

# These options are usually set in the sbatch files
low_income_cutoff <- get_arg("low_income_cutoff", "p25") # low-income cutoff for profiles
outcome_model <- get_arg("outcome_model", "levels")       # levels or Poisson
profile_scope <- get_arg("profile_scope", "all")          # all profiles or Profile 4 only
age_filter_arg <- get_arg("age_filter", "3")              # age groups to plot
wind_control <- get_arg("wind_control", "both")           # annual wind controls
daily_overlap_control <- get_arg("daily_overlap_control", "none")     # rain-wind overlap controls
daily_overlap_exclusion <- get_arg("daily_overlap_exclusion", "none") # drop rain-wind overlap years

# `all` means plot the three age-specific groups. Otherwise this can be one
# age group or a comma-separated list, such as 1,2,3.
age_filter <- if (age_filter_arg == "all") {
  c("1", "2", "3")
} else {
  trimws(strsplit(age_filter_arg, ",", fixed = TRUE)[[1]])
}

log_mort <- outcome_model == "poisson" # Poisson runs use the log-link model

# Keep this suffix in step with `regressions/03_subsample_profiles.R`.
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


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

rf_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf", "subsamples", out_suffix)
diag_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "diagnostics", "subsamples", out_suffix)
fig_dir <- file.path(DIR_FIGURE, "regs", "subsamples", out_suffix)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

rf_file <- paste0("subsample_profiles_", out_suffix, "_era5land.csv")

# In the RF file, `dy` is the estimate; `lo` and `hi` are low and high CI.
rf <- read_csv(file.path(rf_dir, rf_file), show_col_types = FALSE)

# The retention table has the criteria and sample size for each profile.
retention <- read_csv(file.path(diag_dir, "clean_subsample_contrast_retention.csv"),
                      show_col_types = FALSE)


# -----------------------------
# Plot settings
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")
pal <- c("Comparison units" = "#8A5A44", "Mumbai-profile units" = "#0072B2")
y_axis_label <- if (log_mort) {
  expression(atop(Delta~deathrate, "relative to 0 mm"))
} else {
  "Change in annual deaths per 100,000\nrelative to 0 mm"
}

profile_defs <- rf %>%
  distinct(profile_id, profile_label, profile_strip)

# Captions include the profile criteria and the selected/comparison sample size.
profile_note <- function(profile) {
  profile_retention <- retention %>%
    filter(profile_id == profile) %>%
    select(group, profile_label, rows, countries, admin_units, criteria)

  selected <- profile_retention %>% filter(group == "Mumbai-profile units")
  other <- profile_retention %>% filter(group == "Comparison units")

  glue(
    "{toupper(selected$profile_label[[1]])}: {selected$criteria[[1]]}\n",
    "Mumbai-profile: {format(selected$rows, big.mark = ',')} rows, ",
    "{format(selected$admin_units, big.mark = ',')} admin units, ",
    "{selected$countries} countries. ",
    "Comparison: {format(other$rows, big.mark = ',')} rows, ",
    "{format(other$admin_units, big.mark = ',')} admin units, ",
    "{other$countries} countries.\n",
    "Wind control: {wind_control}. ",
    "Daily overlap control: {daily_overlap_control}. ",
    "Daily overlap exclusion: {daily_overlap_exclusion}."
  )
}


# -----------------------------
# Single-profile figures
# -----------------------------

# Save a curve plot and selected-effect plot for one profile and age group.
plot_one_profile <- function(profile, age) {
  plot_df <- rf %>%
    filter(profile_id == profile, as.character(agegroup) == age) %>%
    mutate(age_label = recode(as.character(agegroup), !!!age_labels))

  note <- profile_note(profile)
  age_stub <- paste0("age", age)
  safe_profile <- gsub("[^A-Za-z0-9]+", "_", profile)

  # Full rainfall response from 0 to 300 mm, comparing profile units with the
  # rest of the panel.
  p_curve <- ggplot(plot_df, aes(x, dy, color = group, fill = group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.12, color = NA) +
    geom_line(linewidth = 1.15) +
    facet_grid(. ~ spec_short) +
    scale_color_manual(values = pal) +
    scale_fill_manual(values = pal) +
    labs(x = "Daily precipitation (mm)", y = y_axis_label,
         color = NULL, fill = NULL, caption = note) +
    theme_classic(base_size = 15) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold", size = 13),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 10.5, color = "grey35", hjust = 0)
    ) +
    guides(fill = "none")

  ggsave(file.path(fig_dir, paste0("curve_", safe_profile, "_", age_stub, ".pdf")),
         p_curve, width = 10.8, height = 5.8)

  # Same estimates read at the rainfall values used in the main checks.
  p_selected <- plot_df %>%
    filter(x %in% c(100, 150, 200, 300)) %>%
    mutate(precip = factor(paste0(x, " mm"),
                           levels = paste0(c(100, 150, 200, 300), " mm"))) %>%
    ggplot(aes(precip, dy, ymin = lo, ymax = hi, color = group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_pointrange(position = position_dodge(width = 0.55), linewidth = 0.8, fatten = 1.8) +
    facet_grid(. ~ spec_short) +
    scale_color_manual(values = pal) +
    labs(x = "Daily precipitation", y = y_axis_label,
         color = NULL, caption = note) +
    theme_classic(base_size = 15) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold", size = 13),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 10.5, color = "grey35", hjust = 0)
    )

  ggsave(file.path(fig_dir, paste0("selected_effects_", safe_profile, "_", age_stub, ".pdf")),
         p_selected, width = 10.8, height = 5.8)
}

for (profile in profile_defs$profile_id) {
  for (age in age_filter) {
    plot_one_profile(profile, age)
  }
}


# -----------------------------
# Two-profile figures
# -----------------------------

# Pair panels compare related profile definitions without putting all four
# profiles in one figure.
pair_defs <- tibble(
  pair_id = c("urban_vs_high_urban", "very_wet_vs_large_high_urban"),
  profile_ids = list(
    paste0(c("urban_wet_", "high_urban_wet_"), low_income_cutoff),
    paste0(c("very_wet_urban_", "large_high_urban_wet_"), low_income_cutoff)
  )
)

plot_pair <- function(pair_id, profile_ids, age) {
  pair_df <- rf %>%
    filter(profile_id %in% profile_ids, as.character(agegroup) == age) %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      profile_strip = factor(profile_strip, levels = profile_defs$profile_strip)
    )

  pair_note <- paste(vapply(profile_ids, profile_note, character(1)), collapse = "\n")
  age_stub <- paste0("age", age)

  # Full rainfall response for two related profile definitions.
  p_pair_curve <- ggplot(pair_df, aes(x, dy, color = group, fill = group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.11, color = NA) +
    geom_line(linewidth = 1.05) +
    facet_grid(profile_strip ~ spec_short) +
    scale_color_manual(values = pal) +
    scale_fill_manual(values = pal) +
    labs(x = "Daily precipitation (mm)", y = y_axis_label,
         color = NULL, fill = NULL, caption = pair_note) +
    theme_classic(base_size = 13) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold", size = 11),
      strip.text.y.right = element_text(angle = 0, lineheight = 0.95,
                                        margin = margin(2, 8, 2, 8)),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 8.5, color = "grey35", hjust = 0)
    ) +
    guides(fill = "none")

  ggsave(file.path(fig_dir, paste0("curve_pair_", pair_id, "_", age_stub, ".pdf")),
         p_pair_curve, width = 12.5, height = 8.4)

  # Selected rainfall values for the same two profile definitions.
  p_pair_selected <- pair_df %>%
    filter(x %in% c(100, 150, 200, 300)) %>%
    mutate(precip = factor(paste0(x, " mm"),
                           levels = paste0(c(100, 150, 200, 300), " mm"))) %>%
    ggplot(aes(precip, dy, ymin = lo, ymax = hi, color = group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_pointrange(position = position_dodge(width = 0.55), linewidth = 0.75, fatten = 1.7) +
    facet_grid(profile_strip ~ spec_short) +
    scale_color_manual(values = pal) +
    labs(x = "Daily precipitation", y = y_axis_label,
         color = NULL, caption = pair_note) +
    theme_classic(base_size = 13) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold", size = 11),
      strip.text.y.right = element_text(angle = 0, lineheight = 0.95,
                                        margin = margin(2, 8, 2, 8)),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 8.5, color = "grey35", hjust = 0)
    )

  ggsave(file.path(fig_dir, paste0("selected_effects_pair_", pair_id, "_", age_stub, ".pdf")),
         p_pair_selected, width = 12.5, height = 8.4)
}

if (profile_scope == "all") {
  for (pair_i in seq_len(nrow(pair_defs))) {
    for (age in age_filter) {
      plot_pair(pair_defs$pair_id[[pair_i]], pair_defs$profile_ids[[pair_i]], age)
    }
  }
}


# -----------------------------
# Four-profile figures
# -----------------------------

# The four-profile panel is useful for a compact overview, but it is dense.
# The single-profile and pair figures are easier to read.
plot_all_profiles <- function(age) {
  all_df <- rf %>%
    filter(as.character(agegroup) == age) %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      profile_strip = factor(profile_strip, levels = profile_defs$profile_strip)
    )

  all_note <- paste(vapply(profile_defs$profile_id, profile_note, character(1)), collapse = "\n")
  age_stub <- paste0("age", age)

  # Full rainfall response for all four profiles in one panel.
  p_all_curve <- ggplot(all_df, aes(x, dy, color = group, fill = group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.45) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.1, color = NA) +
    geom_line(linewidth = 0.95) +
    facet_grid(profile_strip ~ spec_short) +
    scale_color_manual(values = pal) +
    scale_fill_manual(values = pal) +
    labs(x = "Daily precipitation (mm)", y = y_axis_label,
         color = NULL, fill = NULL, caption = all_note) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold", size = 10.5),
      strip.text.y.right = element_text(angle = 0, lineheight = 0.95,
                                        margin = margin(2, 8, 2, 8)),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 7.6, color = "grey35", hjust = 0,
                                  lineheight = 0.98)
    ) +
    guides(fill = "none")

  ggsave(file.path(fig_dir, paste0("curve_all_four_profiles_", age_stub, ".pdf")),
         p_all_curve, width = 12.8, height = 11.2)

  # Selected rainfall values for all four profiles in one panel.
  p_all_selected <- all_df %>%
    filter(x %in% c(100, 150, 200, 300)) %>%
    mutate(precip = factor(paste0(x, " mm"),
                           levels = paste0(c(100, 150, 200, 300), " mm"))) %>%
    ggplot(aes(precip, dy, ymin = lo, ymax = hi, color = group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.45) +
    geom_pointrange(position = position_dodge(width = 0.55), linewidth = 0.7, fatten = 1.5) +
    facet_grid(profile_strip ~ spec_short) +
    scale_color_manual(values = pal) +
    labs(x = "Daily precipitation", y = y_axis_label,
         color = NULL, caption = all_note) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold", size = 10.5),
      strip.text.y.right = element_text(angle = 0, lineheight = 0.95,
                                        margin = margin(2, 8, 2, 8)),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 7.6, color = "grey35", hjust = 0,
                                  lineheight = 0.98)
    )

  ggsave(file.path(fig_dir, paste0("selected_effects_all_four_profiles_", age_stub, ".pdf")),
         p_all_selected, width = 12.8, height = 11.2)
}

if (profile_scope == "all") {
  for (age in age_filter) {
    plot_all_profiles(age)
  }
}

message("Wrote clean contrast figures to: ", fig_dir)
