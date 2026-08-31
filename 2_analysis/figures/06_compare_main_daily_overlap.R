# ============================================================
# 06_compare_main_daily_overlap.R
#
# Compare the main rainfall response across daily rain-wind overlap checks
#
# This script reads saved response-function CSVs from
# `regressions/01_main_response.R`
#
# It compares the baseline main response with runs that either control for
# or exclude admin-years with very heavy rain near high winds
#
# These options must match the regression runs being compared
#   --outcome_model = levels | poisson
#   --spec_set = main_two | four_spec
#   --weighted = true | false
#   --prcp_order = 2 | 3 | 4 | 5
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(readr)
library(glue)
library(ggplot2)

theme_set(theme_classic())


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
outcome_model <- get_arg("outcome_model", "poisson") # levels or Poisson
spec_set <- get_arg("spec_set", "main_two")          # main specs or four-spec comparison
weighted_arg <- tolower(get_arg("weighted", "true")) # use population weights
prcp_order <- as.integer(get_arg("prcp_order", "3")) # rainfall polynomial order

weighted <- weighted_arg %in% c("true", "t", "1", "yes") # true/t/1/yes all mean weighted


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

outcome_folder <- outcome_model
weight_label <- if (weighted) "weighted" else "unweighted" # used in output file names

# Part of the RF filename shared by the baseline, control, and exclusion runs
base_run_id <- paste(
  spec_set, outcome_folder, paste0("p", prcp_order), weight_label,
  sep = "_"
)

rf_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "data", "rf", "analysis-panel", "main-response"
)

fig_dir <- file.path(
  DIR_FIGURE,
  "regs", "analysis-panel", "main-response", spec_set, outcome_folder,
  weight_label, "daily-overlap-comparison"
)

table_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "data", "rf", "analysis-panel", "main-response",
  "daily-overlap-comparison"
)

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

# File suffixes must match the run IDs written by `01_main_response.R`
overlap_options <- tibble::tribble(
  ~overlap_run, ~overlap_label, ~file_suffix,
  "baseline",        "Baseline",                              "",
  "control_rain100", "Control: rain >=100mm + high wind",    "_overlapctl_rain100",
  "control_rain200", "Control: rain >=200mm + high wind",    "_overlapctl_rain200",
  "exclude_rain100", "Exclude: rain >=100mm + high wind",    "_exclude_overlap_rain100",
  "exclude_rain200", "Exclude: rain >=200mm + high wind",    "_exclude_overlap_rain200"
)


# -----------------------------
# Plot settings
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

overlap_palette <- c(
  "Baseline" = "#222222",
  "Control: rain >=100mm + high wind" = "#0072B2",
  "Control: rain >=200mm + high wind" = "#56B4E9",
  "Exclude: rain >=100mm + high wind" = "#D55E00",
  "Exclude: rain >=200mm + high wind" = "#CC79A7"
)

y_axis_label <- if (outcome_model == "poisson") {
  expression(atop(Delta~deathrate, "relative to 0 mm"))
} else {
  "Change in annual deaths per 100,000\nrelative to 0 mm"
}


# -----------------------------
# Read response functions
# -----------------------------

# Read the precipitation response from one rain-wind overlap run
read_overlap_rf <- function(overlap_run, overlap_label, file_suffix) {
  rf_file <- file.path(
    rf_dir,
    paste0("main_response_", base_run_id, file_suffix, ".csv")
  )
  
  if (!file.exists(rf_file)) {
    stop("Missing RF file: ", rf_file)
  }
  
  # `dy` is the response estimate, `lo` and `hi` are the confidence interval
  read_csv(rf_file, show_col_types = FALSE) %>%
    filter(id == "Precipitation") %>%
    mutate(
      overlap_run = overlap_run,
      overlap_label = overlap_label
    )
}

# Combine the baseline, control, and exclusion runs
rf_list <- list()

for (row_i in seq_len(nrow(overlap_options))) {
  rf_list[[row_i]] <- read_overlap_rf(
    overlap_options$overlap_run[[row_i]],
    overlap_options$overlap_label[[row_i]],
    overlap_options$file_suffix[[row_i]]
  )
}

rf <- bind_rows(rf_list) %>%
  mutate(
    overlap_label = factor(overlap_label, levels = overlap_options$overlap_label),
    age_label = recode(as.character(agegroup), !!!age_labels)
  )

# Save estimates at the rainfall values used in the comparison figures
selected_effects <- rf %>%
  filter(x %in% c(100, 150, 200, 300)) %>%
  mutate(
    rainfall = factor(
      paste0(x, " mm"),
      levels = paste0(c(100, 150, 200, 300), " mm")
    )
  )

write_csv(
  selected_effects,
  file.path(table_dir, paste0("main_daily_overlap_selected_effects_", base_run_id, ".csv"))
)


# -----------------------------
# Figures
# -----------------------------

# Full rainfall response curve for one age group
plot_age_curve <- function(age) {
  plot_df <- rf %>% filter(as.character(agegroup) == age)
  
  age_stub <- paste0("age", age)
  age_title <- age_labels[[age]]
  
  # Compare the baseline response with the rain-wind control and exclusion runs
  p <- ggplot(plot_df, aes(x, dy, color = overlap_label, fill = overlap_label)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.06, color = NA) +
    geom_line(linewidth = 1.05) +
    facet_wrap(~spec_short, nrow = 1) +
    scale_color_manual(values = overlap_palette) +
    scale_fill_manual(values = overlap_palette) +
    labs(
      x = "Daily precipitation (mm)", y = y_axis_label,
      color = NULL, fill = NULL,
      title = glue("Main rainfall response with daily rain-wind checks, age {age_title}")
    ) +
    theme_classic(base_size = 13) +
    theme(
      legend.position = "bottom",
      legend.text = element_text(size = 9.5),
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      plot.title = element_text(face = "bold")
    ) +
    guides(fill = "none")
  
  ggsave(
    file.path(fig_dir, paste0("main_daily_overlap_curve_", base_run_id, "_", age_stub, ".pdf")),
    p, width = 12.5, height = 6.2
  )
}

# Point estimates at 100, 150, 200, and 300 mm for one age group
plot_age_selected <- function(age) {
  plot_df <- selected_effects %>% filter(as.character(agegroup) == age)
  
  age_stub <- paste0("age", age)
  age_title <- age_labels[[age]]
  
  # Same comparison at selected rainfall values
  p <- ggplot(plot_df, aes(rainfall, dy, ymin = lo, ymax = hi, color = overlap_label)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_pointrange(position = position_dodge(width = 0.62), linewidth = 0.5) +
    facet_wrap(~spec_short, nrow = 1) +
    scale_color_manual(values = overlap_palette) +
    labs(
      x = "Daily precipitation", y = y_axis_label,
      color = NULL,
      title = glue("Selected rainfall effects with daily rain-wind checks, age {age_title}")
    ) +
    theme_classic(base_size = 13) +
    theme(
      legend.position = "bottom",
      legend.text = element_text(size = 9.5),
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      plot.title = element_text(face = "bold")
    )
  
  ggsave(
    file.path(fig_dir, paste0("main_daily_overlap_selected_", base_run_id, "_", age_stub, ".pdf")),
    p, width = 12.5, height = 6.2
  )
}

for (age in names(age_labels)) {
  plot_age_curve(age)
  plot_age_selected(age)
}

message("Wrote daily-overlap comparison figures to: ", fig_dir)
message("Wrote daily-overlap selected-effects CSV to: ", table_dir)