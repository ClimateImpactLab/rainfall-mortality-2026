# ============================================================
# 00_figure_setup.R
#
# Shared setup for the summary figures in 05_summary_figures/: packages,
# paths, plot settings, and readers for the per-run coefficient CSVs.
# Sourced at the top of 01 and 02. Not run on its own.
#
# Output folder: output/data/drought/brazil-annual/summary/ (PDFs)
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(readr)
library(ggplot2)
library(ggh4x)
library(fixest)


# -----------------------------
# Paths
# -----------------------------

# paths.R gives DIR_REPO_RAINFALL_MORTALITY (the repo on RCC)
USER <- Sys.getenv("USER")
source("../../../../0_utils/paths.R")

# The panel (for 01). The reg results come from 03_run_outputs, under
# RESULTS_DIR
DROUGHT_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought"
PANEL_FILE <- file.path(DROUGHT_DIR, "brazil_annual", "brazil_annual_drought_regression_panel_urban.rds")

RESULTS_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "drought", "brazil-annual")
OUTPUT_DIR <- file.path(RESULTS_DIR, "summary")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Plot settings
# -----------------------------

age_levels <- c("0-4", "5-64", "65+")
# FE spec names and colours, the same in every figure
fe_labels <- c(
  main = "Main FE",
  saturated = "Saturated FE",
  statetrend = "State trends",
  region = "Region x year FE"
)
fe_colors <- c(
  "Main FE" = "#8C8C8C", "Saturated FE" = "#2F6B8F",
  "State trends" = "#6A9A4B", "Region x year FE" = "#D98C3A"
)

theme_set(
  theme_bw(base_size = 10) +
    theme(
      panel.grid.minor = element_blank(),
      strip.background = element_rect(fill = "grey92", color = NA),
      strip.text = element_text(face = "bold"),
      plot.title = element_text(face = "bold"),
      legend.position = "bottom"
    )
)

# x-axis label: Poisson effects in %, levels in deaths per 100,000
x_label <- function(model) {
  if (model == "poisson") {
    "% change in mortality, +1 SD drier (indicators: 0 to 1), 95% CI"
  } else {
    "Change in deaths per 100,000, +1 SD drier (indicators: 0 to 1), 95% CI"
  }
}

# Figures are saved as PDF (for Overleaf)
save_fig <- function(plot, name, width, height) {
  ggsave(file.path(OUTPUT_DIR, paste0(name, ".pdf")), plot, width = width, height = height, bg = "white")
}

# Significance stars for the TeX tables
stars <- function(p) ifelse(p < 0.01, "***", ifelse(p < 0.05, "**", ifelse(p < 0.1, "*", "")))


# -----------------------------
# Read regression outputs
# -----------------------------

# +1 SD coefs of one pooled run, from 03_run_outputs/01 (one folder per run)
read_pooled <- function(run_id) {
  path <- file.path(RESULTS_DIR, "tables", run_id, paste0("brazil_drought_coefficients_standardized_", run_id, ".csv"))
  read_csv(path, show_col_types = FALSE) %>%
    mutate(
      run_id = run_id,
      fe_label = factor(fe_labels[spec_id], levels = fe_labels),
      age_label = factor(age_label, levels = age_levels)
    )
}

# Main-FE and saturated-FE versions of one run (for ex "poisson_unweighted").
read_main_saturated <- function(run_suffix) {
  bind_rows(read_pooled(paste0("main_", run_suffix)), read_pooled(paste0("saturated_", run_suffix))) %>%
    mutate(fe_label = droplevels(fe_label))
}

# Same x-axis for the main and saturated FE panels of each age group, so they
# can be compared. Each panel would otherwise get its own x-axis. This adds
# invisible points at the widest range of the two panels
shared_range_by_age <- function(data) {
  data %>%
    group_by(age_label) %>%
    reframe(x = c(min(ci_low_sd, 0, na.rm = TRUE), max(ci_high_sd, 0, na.rm = TRUE))) %>%
    tidyr::crossing(fe_label = droplevels(unique(data$fe_label)))
}

# +1 SD coefs of one het run, from 03_run_outputs/02 (one folder per run)
read_het <- function(run_id) {
  path <- file.path(RESULTS_DIR, "heterogeneity", "figures", run_id, paste0("het_coefs_standardized_", run_id, ".csv"))
  read_csv(path, show_col_types = FALSE) %>%
    mutate(fe_label = factor(fe_labels[spec_id], levels = fe_labels),
           age_label = factor(age_label, levels = age_levels))
}
