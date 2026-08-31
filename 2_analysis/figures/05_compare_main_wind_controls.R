# ============================================================
# 05_compare_main_wind_controls.R
#
# Compare the main rainfall response across annual wind controls
#
# This script reads saved response-function CSVs from
# `regressions/01_main_response.R`
#
# It compares four runs:
# `--wind_control = none`, `windmax`, `winddays`, and `both`
#
# It writes one curve figure and one selected-effect figure per age group
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
outcome_model <- get_arg("outcome_model", "levels")  # levels or Poisson
spec_set <- get_arg("spec_set", "main_two")          # main specs or four-spec comparison
weighted_arg <- tolower(get_arg("weighted", "true")) # use population weights
prcp_order <- as.integer(get_arg("prcp_order", "3")) # rainfall polynomial order

weighted <- weighted_arg %in% c("true", "t", "1", "yes") # true/t/1/yes all mean weighted
weight_label <- if (weighted) "weighted" else "unweighted" # used in output file names


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

# Part of the RF filename shared across all four wind-control runs
base_run_id <- paste(
  spec_set, outcome_model, paste0("p", prcp_order), weight_label,
  sep = "_"
)

rf_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf",
  "analysis-panel", "main-response"
)

fig_dir <- file.path(
  DIR_FIGURE, "regs", "analysis-panel", "main-response",
  spec_set, outcome_model, weight_label, "wind-control-comparison"
)

table_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf",
  "analysis-panel", "main-response", "wind-control-comparison"
)

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

# Wind-control labels and the corresponding additions to the run ID
wind_options <- tibble::tribble(
  ~wind_control, ~wind_label, ~file_suffix,
  "none",     "No wind control",              "",
  "windmax",  "Annual max wind",              "_windmax",
  "winddays", "High-wind days",               "_winddays",
  "both",     "Max wind + high-wind days",    "_both"
)


# -----------------------------
# Plot settings
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

wind_palette <- c(
  "No wind control" = "#222222",
  "Annual max wind" = "#0072B2",
  "High-wind days" = "#D55E00",
  "Max wind + high-wind days" = "#009E73"
)

y_axis_label <- if (outcome_model == "poisson") {
  expression(atop(Delta~deathrate, "relative to 0 mm"))
} else {
  "Change in annual deaths per 100,000\nrelative to 0 mm"
}


# -----------------------------
# Read response functions
# -----------------------------

# Read the precipitation response from one wind-control run
read_wind_rf <- function(wind_control, wind_label, file_suffix) {
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
      wind_control = wind_control,
      wind_label = wind_label
    )
}

# Combine the four wind-control runs
rf_list <- list()

for (row_i in seq_len(nrow(wind_options))) {
  rf_list[[row_i]] <- read_wind_rf(
    wind_options$wind_control[[row_i]],
    wind_options$wind_label[[row_i]],
    wind_options$file_suffix[[row_i]]
  )
}

rf <- bind_rows(rf_list) %>%
  mutate(
    wind_label = factor(wind_label, levels = wind_options$wind_label),
    age_label = recode(as.character(agegroup), !!!age_labels)
  )

# Save the estimates at the rainfall values used in the comparison figures
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
  file.path(
    table_dir,
    paste0("main_wind_control_selected_effects_", base_run_id, ".csv")
  )
)


# -----------------------------
# Figures
# -----------------------------

# Full rainfall response curve for one age group
plot_age_curve <- function(age) {
  plot_df <- rf %>% filter(as.character(agegroup) == age)
  
  age_stub <- paste0("age", age)
  age_title <- age_labels[[age]]
  
  # Compare the baseline response with the three annual wind-control runs
  p <- ggplot(plot_df, aes(x, dy, color = wind_label, fill = wind_label)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.08, color = NA) +
    geom_line(linewidth = 1.05) +
    facet_wrap(~spec_short, nrow = 1) +
    scale_color_manual(values = wind_palette) +
    scale_fill_manual(values = wind_palette) +
    labs(
      x = "Daily precipitation (mm)", y = y_axis_label,
      color = NULL, fill = NULL,
      title = glue("Main rainfall response, age {age_title}")
    ) +
    theme_classic(base_size = 13) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      plot.title = element_text(face = "bold")
    ) +
    guides(fill = "none")
  
  ggsave(
    file.path(fig_dir, paste0("main_wind_control_curve_", base_run_id, "_", age_stub, ".pdf")),
    p, width = 11.5, height = 5.8
  )
}

# Point estimates at 100, 150, 200, and 300 mm for one age group
plot_age_selected <- function(age) {
  plot_df <- selected_effects %>% filter(as.character(agegroup) == age)
  
  age_stub <- paste0("age", age)
  age_title <- age_labels[[age]]
  
  # Same comparison at selected rainfall values
  p <- ggplot(plot_df, aes(rainfall, dy, ymin = lo, ymax = hi, color = wind_label)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_pointrange(position = position_dodge(width = 0.55), linewidth = 0.55) +
    facet_wrap(~spec_short, nrow = 1) +
    scale_color_manual(values = wind_palette) +
    labs(
      x = "Daily precipitation", y = y_axis_label,
      color = NULL,
      title = glue("Selected rainfall effects, age {age_title}")
    ) +
    theme_classic(base_size = 13) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      plot.title = element_text(face = "bold")
    )
  
  ggsave(
    file.path(fig_dir, paste0("main_wind_control_selected_", base_run_id, "_", age_stub, ".pdf")),
    p, width = 11.5, height = 5.8
  )
}

for (age in names(age_labels)) {
  plot_age_curve(age)
  plot_age_selected(age)
}

message("Wrote wind-control comparison figures to: ", fig_dir)
message("Wrote wind-control selected-effects CSV to: ", table_dir)
