# ============================================================
# 01_usa_flow_reg_outputs.R
#
# Figures for one run of 02_regressions/02_usa_flow_regs.R (same options).
# Reads that run's CSVs, reruns nothing. The text, equations and tables are
# written by 02_make_overleaf_doc.R, which puts these figures in the
# Overleaf document.
#
#   - response curves of the flow, upstream, precip and temp polys by age
#     group (as in figures/01_plot_main_response.R), one row per reg and
#     one column per FE spec, so the figures fit a portrait page
#   - the precip curve of every reg with the precip poly on one panel, against
#     the precip-only baseline and its CI
#   - coefficient plots by age group, with fixed and free y scales (as in
#     figures/07_plot_wind_control_coefficients.R): one for the z-scores and
#     SPI, one for the drought and flood bins
#
# Options (must match the regression run):
#   --outcome_model = levels | poisson
#   --weighted = true | false
#   --wind_control = none | windmax | winddays | both
#
# Inputs (output/data/flows/usa-annual/), from 02_usa_flow_regs.R:
#   usa_flow_response_<run_id>.csv, usa_flow_coefficients_<run_id>.csv,
#   usa_flow_models_<run_id>.csv
#
# Outputs (output/data/flows/usa-annual/figures/<run_id>/):
#   fig_usa_{flow,upstream,precip,temperature}_response_<run_id>.pdf
#   fig_usa_precip_overlay_<run_id>.pdf
#   fig_usa_flow_anomaly_coefs_<run_id>.pdf (and _free_y)
#   fig_usa_flow_bin_coefs_<run_id>.pdf (and _free_y)
#
# Dependencies: dplyr, readr, ggplot2, MetBrewer; ../../../0_utils/paths.R,
# so run this script from its own folder.
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)
library(MetBrewer)

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

# Same defaults as 02_usa_flow_regs.R, so the run name matches its CSVs
outcome_model <- get_arg("outcome_model", "levels")
weighted_arg <- tolower(get_arg("weighted", "true"))
wind_control <- get_arg("wind_control", "both")

weighted <- weighted_arg %in% c("true", "t", "1", "yes")
log_mort <- outcome_model == "poisson"
weight_label <- if (weighted) "weighted" else "unweighted"


# -----------------------------
# Project files and paths
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY

# Run name, the same as in 02_usa_flow_regs.R
run_id <- paste(outcome_model, weight_label, sep = "_")
if (wind_control != "none") {
  run_id <- paste(run_id, wind_control, sep = "_")
}

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual")
response_file <- file.path(OUTPUT_DIR, paste0("usa_flow_response_", run_id, ".csv"))
coef_file <- file.path(OUTPUT_DIR, paste0("usa_flow_coefficients_", run_id, ".csv"))
model_file <- file.path(OUTPUT_DIR, paste0("usa_flow_models_", run_id, ".csv"))

# One figure folder per run
figure_dir <- file.path(OUTPUT_DIR, "figures", run_id)
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Read inputs
# -----------------------------

# `dy` is the response estimate, `lo` and `hi` are the confidence interval
rf_flow <- read_csv(response_file, show_col_types = FALSE)
coef_flow <- read_csv(coef_file, show_col_types = FALSE)
model_flow <- read_csv(model_file, show_col_types = FALSE)

# Reg and FE order as run, for the figure panels
set_order <- unique(model_flow$set_label)
spec_order <- unique(model_flow$spec_short)


# -----------------------------
# Plot settings
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")
age_palette <- met.brewer("Hokusai3", n = length(age_labels))

# Same wind wording as figures/01_plot_main_response.R
wind_caption <- switch(
  wind_control,
  none = "No annual wind control.",
  windmax = "Controls for annual population-weighted extreme wind.",
  winddays = "Controls for annual population-weighted high-wind days.",
  both = "Controls for annual extreme wind and annual high-wind days."
)

# In a one-country sample, country x year is year
spec_caption <- paste0(
  "Main FE: age x county and age x year. ",
  "Saturated FE additionally includes age x state x year.\n",
  wind_caption, " USA 1970-2010, ", outcome_model, ", ", weight_label, "."
)

# Long reg names wrap in the row strips
set_labeller <- labeller(set_label = label_wrap_gen(width = 16))


# -----------------------------
# Response curves
# -----------------------------

# Same style as plot_response_curves() in figures/01_plot_main_response.R,
# with one row per reg and one column per FE spec
plot_response_curves <- function(rf_data, xlab, ylab, file_stub) {
  plot_df <- rf_data %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      set_label = factor(set_label, levels = set_order),
      spec_short = factor(spec_short, levels = spec_order)
    )

  # Plot the response estimate and confidence interval
  p <- ggplot(plot_df, aes(x, dy, color = age_label, fill = age_label)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.16, color = NA) +
    geom_line(linewidth = 1) +
    facet_grid(set_label ~ spec_short, labeller = set_labeller) +
    scale_color_manual(values = age_palette) +
    scale_fill_manual(values = age_palette) +
    labs(
      x = xlab,
      y = ylab,
      color = "Age group",
      fill = "Age group",
      caption = spec_caption
    ) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "bottom",
      legend.title = element_text(face = "bold"),
      strip.text = element_text(face = "bold", size = 11),
      strip.text.y.right = element_text(angle = 0),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 9, color = "grey35", hjust = 0),
      plot.margin = margin(8, 12, 8, 12),
      panel.spacing = unit(1, "lines")
    ) +
    guides(fill = "none")

  ggsave(
    file.path(figure_dir, paste0(file_stub, ".pdf")),
    p,
    width = 9,
    height = 2.3 * n_distinct(plot_df$set_label) + 2
  )
}

# x units: flow and upstream are one month's value in a grid cell, in mm
# summed over cells (hydro/coarse/prepflow.py adds up mm without area weights)
curve_figures <- tibble::tribble(
  ~id, ~xlab, ~ref_label, ~file_stub,
  "Flow", "Monthly flow in a grid cell (mm, summed over the cell and every cell upstream of it)", "relative to 0", "flow",
  "Upstream", "Monthly upstream inflow to a grid cell (mm, summed over every cell upstream of it)", "relative to 0", "upstream",
  "Precipitation", "Daily precipitation (mm)", "relative to 0 mm", "precip",
  "Temperature", "Daily average temperature (C)", "relative to 27 C", "temperature"
)

for (curve_i in seq_len(nrow(curve_figures))) {
  curve <- curve_figures[curve_i, ]

  # Same y-axis wording as figures/01_plot_main_response.R
  ylab <- if (log_mort) {
    as.expression(bquote(atop(Delta ~ deathrate, .(curve$ref_label))))
  } else {
    paste0("Change in annual deaths per 100,000\n", curve$ref_label)
  }

  plot_response_curves(
    filter(rf_flow, id == curve$id),
    xlab = curve$xlab,
    ylab = ylab,
    file_stub = paste0("fig_usa_", curve$file_stub, "_response_", run_id)
  )
}


# -----------------------------
# Precip curves with and without flow terms
# -----------------------------

# Does adding flow, upstream or the anomaly terms move the precip curve?
# Every reg with the precip poly on one panel per age group and FE spec. The
# CI is drawn for precip only, the baseline, so the other curves can be read
# against it
precip_overlay <- rf_flow %>%
  filter(id == "Precipitation") %>%
  mutate(
    age_label = factor(recode(as.character(agegroup), !!!age_labels), levels = unname(age_labels)),
    set_label = factor(set_label, levels = intersect(set_order, set_label)),
    spec_short = factor(spec_short, levels = spec_order)
  )

overlay_palette <- setNames(
  c("grey15", met.brewer("Hokusai1", n = nlevels(precip_overlay$set_label) - 1)),
  levels(precip_overlay$set_label)
)

overlay_ylab <- if (log_mort) {
  expression(atop(Delta~deathrate, "relative to 0 mm"))
} else {
  "Change in annual deaths per 100,000\nrelative to 0 mm"
}

overlay_plot <- ggplot(precip_overlay, aes(x, dy, color = set_label)) +
  geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
  geom_ribbon(
    data = filter(precip_overlay, set_label == "Precip only"),
    aes(ymin = lo, ymax = hi), fill = "grey60", alpha = 0.25, color = NA
  ) +
  geom_line(linewidth = 0.8) +
  facet_grid(age_label ~ spec_short, scales = "free_y") +
  scale_color_manual(values = overlay_palette) +
  labs(
    x = "Daily precipitation (mm)",
    y = overlay_ylab,
    color = NULL,
    caption = paste0("Gray band: 95% CI of the precip-only regression.\n", spec_caption)
  ) +
  theme_classic(base_size = 12) +
  theme(
    legend.position = "bottom",
    strip.text = element_text(face = "bold", size = 11),
    strip.text.y.right = element_text(angle = 0),
    axis.title = element_text(face = "bold"),
    plot.caption = element_text(size = 9, color = "grey35", hjust = 0),
    plot.margin = margin(8, 12, 8, 12),
    panel.spacing = unit(1, "lines")
  ) +
  guides(color = guide_legend(nrow = 2))

ggsave(
  file.path(figure_dir, paste0("fig_usa_precip_overlay_", run_id, ".pdf")),
  overlay_plot,
  width = 9,
  height = 9
)


# -----------------------------
# z-score, SPI and bin coefficients
# -----------------------------

coef_df <- coef_flow %>%
  mutate(
    age_label = factor(recode(as.character(agegroup), !!!age_labels), levels = unname(age_labels)),
    spec_short = factor(spec_short, levels = spec_order)
  )

y_axis_label <- if (log_mort) "Coefficient (log death rate)" else "Deaths per 100,000"

# Two figures: the z-scores and SPI (per SD), and the bins (a year in the bin
# vs the reference year). Colors from figures/07_plot_wind_control_coefficients.R
coef_figures <- list(
  anomaly = list(
    labels = c("Annual mean flow z-score", "Annual max flow z-score", "Flow SPI"),
    colors = c("#0072B2", "#D55E00", "#009E73"),
    title = "USA flow z-score and SPI coefficients",
    caption = paste(
      "Coefficient for a 1-unit change. z-scores are in SDs of the county's previous 20 years;",
      "SPI is on the standard normal scale. Both positive = wetter. 95% CIs."
    ),
    file_stub = "fig_usa_flow_anomaly_coefs_"
  ),
  bins = list(
    labels = c("Driest 10% (mean flow)", "10th-25th pct (mean flow)", "75th-90th pct (max flow)", "Wettest 10% (max flow)"),
    colors = c("#D55E00", "#E69F00", "#56B4E9", "#0072B2"),
    title = "USA flow drought and flood bin coefficients",
    caption = paste(
      "Bins vs the county's 20 previous years. Drought: annual mean flow at or below p10, or p10-25.",
      "Flood: annual max flow p75-90, or at or above p90.\nCompared with a year whose mean flow is above p25",
      "and max flow below p75. 95% CIs."
    ),
    file_stub = "fig_usa_flow_bin_coefs_"
  )
)

# Same layout as make_plot() in figures/07_plot_wind_control_coefficients.R,
# with one row per reg and one column per FE spec
make_coef_plot <- function(plot_df, figure, free_y = FALSE) {
  facet_scales <- if (free_y) "free_y" else "fixed"

  p <- ggplot(plot_df, aes(age_label, estimate, ymin = lo, ymax = hi, color = coef_label)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_pointrange(position = position_dodge(width = 0.65), linewidth = 0.55) +
    facet_grid(set_label ~ spec_short, scales = facet_scales, labeller = set_labeller) +
    scale_color_manual(values = setNames(figure$colors, figure$labels)) +
    labs(
      x = "Age group",
      y = y_axis_label,
      color = NULL,
      title = figure$title,
      caption = paste0(figure$caption, "\n", spec_caption)
    ) +
    theme_classic(base_size = 13) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold"),
      strip.text.y.right = element_text(angle = 0, lineheight = 0.95),
      axis.title = element_text(face = "bold"),
      plot.title = element_text(face = "bold"),
      plot.caption = element_text(hjust = 0, color = "grey25")
    )

  # Symmetric y-axis around 0 for the fixed-scale version
  if (!free_y) {
    y_max <- max(abs(c(plot_df$lo, plot_df$hi)), na.rm = TRUE)
    p <- p + coord_cartesian(ylim = c(-y_max, y_max))
  }

  p
}

for (figure in coef_figures) {
  plot_df <- coef_df %>%
    filter(coef_label %in% figure$labels) %>%
    mutate(
      set_label = factor(set_label, levels = intersect(set_order, set_label)),
      coef_label = factor(coef_label, levels = figure$labels)
    )

  coef_fig_file <- paste0(figure$file_stub, run_id, ".pdf")

  ggsave(file.path(figure_dir, coef_fig_file), make_coef_plot(plot_df, figure, free_y = FALSE), width = 12, height = 9)
  ggsave(
    file.path(figure_dir, sub("\\.pdf$", "_free_y.pdf", coef_fig_file)),
    make_coef_plot(plot_df, figure, free_y = TRUE),
    width = 12,
    height = 9
  )
}

message("Wrote figures to: ", figure_dir)
