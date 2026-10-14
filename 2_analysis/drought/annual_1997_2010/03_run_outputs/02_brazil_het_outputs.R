# ============================================================
# 02_brazil_het_outputs.R
#
# Figures for one run of 02_regressions/03_brazil_het_regs.R (same options).
# Reads that run's CSVs and the panel, reruns nothing.
#
#   - coefs scaled to a +1 SD change in the measure (in % for Poisson), so
#     the drought measures are on a comparable scale
#   - one coef plot per het grouping: measures x age group, one row per bin
#   - 2 x 2 heatmaps for urban x income and rainfall level x variability
#
# Output: output/data/drought/brazil-annual/heterogeneity/figures/, one
# folder per run
#
# Options:
#   --outcome_model=levels | poisson
#   --fe_spec=main | saturated | both
#   --weighted=true | false
#   --het_defs=main | climate | all | comma-separated names
#   --drought_vars=main | extended | all | comma-separated variable names
#   --prcp_poly=true | false
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)
library(tidyr)
library(grid)


# -----------------------------
# Options
# -----------------------------

# Same options as 03_brazil_het_regs.R, so the run name matches its CSVs
args <- commandArgs(FALSE)

# Read one option from the command line, for ex --fe_spec=saturated gives
# "saturated". If the option isn't given, use the default
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# Same defaults as 03_brazil_het_regs.R
outcome_model <- get_arg("outcome_model", "levels")
fe_spec <- get_arg("fe_spec", "main")
weighted_default <- if (outcome_model == "poisson") "false" else "true"
weighted_arg <- tolower(get_arg("weighted", weighted_default))
het_defs_arg <- get_arg("het_defs", "main")
drought_vars_arg <- get_arg("drought_vars", "main")
prcp_poly_arg <- tolower(get_arg("prcp_poly", "false"))

weighted <- weighted_arg %in% c("true", "t", "1", "yes")
use_prcp_poly <- prcp_poly_arg %in% c("true", "t", "1", "yes")
weight_label <- if (weighted) "weighted" else "unweighted"
# Parts of the run name, the same as in 03_brazil_het_regs.R
het_set <- if (het_defs_arg == "main") {
  "mainhet"
} else if (het_defs_arg == "climate") {
  "climatehet"
} else if (het_defs_arg == "all") {
  "allhet"
} else {
  "customhet"
}
drought_set <- if (drought_vars_arg == "main") {
  "maindrought"
} else if (drought_vars_arg == "extended") {
  "extendeddrought"
} else if (drought_vars_arg == "all") {
  "alldrought"
} else {
  "customdrought"
}
# Shown in the plot subtitles
control_label <- if (use_prcp_poly) "temp controls + precip poly" else "temp controls only"


# -----------------------------
# Paths
# -----------------------------

# paths.R gives DIR_REPO_RAINFALL_MORTALITY (the repo on RCC)
USER <- Sys.getenv("USER")
source("../../../../0_utils/paths.R")

# Panel from 01_build_brazil_panel.R. Figures go next to the het CSVs
PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds"
)

OUTPUT_DIR <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "drought",
  "brazil-annual", "heterogeneity"
)

# Run name, the same as in 03_brazil_het_regs.R
run_id <- paste(fe_spec, outcome_model, weight_label, het_set, drought_set, sep = "_")
if (use_prcp_poly) run_id <- paste(run_id, "prcpoly", sep = "_")

# CSVs written by 03_brazil_het_regs.R for this run (coefs, bin sizes)
coef_file <- file.path(OUTPUT_DIR, paste0("het_coefs_", run_id, ".csv"))
bin_file <- file.path(OUTPUT_DIR, paste0("het_bins_", run_id, ".csv"))

# One figure folder per run
figure_dir <- file.path(OUTPUT_DIR, "figures", run_id)
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Plot settings
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

# Short measure names for the plot rows
measure_short_labels <- c(
  "gs_neglog_annual_rain_pop" = "-log annual rainfall",
  "rs_drought_months_12m_pop" = "RS drought months",
  "rs_worst_logdev_severity_pop" = "RS worst log deviation",
  "rs_worst_pctdev_severity_pop" = "RS worst percent deviation",
  "drought_6m_low10_months_pop" = "6m below 10th pct",
  "drought_6m_low05_months_pop" = "6m below 5th pct",
  "drought_6m_worst_z_severity_pop" = "Worst 6m z-score",
  "deficit_mm_max_06m_pop" = "Largest 6m rainfall deficit",
  "rain_dry_logdev_pop" = "Annual rain log deviation",
  "spi06_worst_severity_pop" = "Worst 6m SPI"
)

# Point colour, and the heatmap colours for negative / positive effects
coef_color <- "#2F6B8F"
heat_low <- "#3B6EA8"
heat_high <- "#B64A3A"

# Poisson effects are in % of the death rate, levels in deaths per 100,000
x_axis_label <- if (outcome_model == "poisson") {
  "Percent mortality-rate change for a +1 SD increase in the drought measure"
} else {
  "Change in winsorized death rate per 100,000 for a +1 SD increase in the drought measure"
}

theme_set(
  theme_bw(base_size = 11) +
    theme(
      panel.grid.minor = element_blank(),
      strip.background = element_rect(fill = "grey92", color = NA),
      strip.text = element_text(face = "bold"),
      plot.title = element_text(face = "bold")
    )
)


# -----------------------------
# Read inputs
# -----------------------------

# The panel is only used for the SD of each drought measure
panel <- readRDS(PANEL_FILE)
coef_results <- read_csv(coef_file, show_col_types = FALSE)
bin_counts <- read_csv(bin_file, show_col_types = FALSE)


# -----------------------------
# Standardize coefficients
# -----------------------------

# Drought variables are ADM2-year measures repeated across age groups.
# Use one row per ADM2-year when calculating the SD used for +1 SD effects.
panel_admin_year <- panel %>%
  distinct(admin_code, year, .keep_all = TRUE)

drought_vars <- coef_results %>%
  distinct(variable, measure_label) %>%
  arrange(match(variable, unique(coef_results$variable)))

drought_sds <- bind_rows(lapply(drought_vars$variable, function(variable) {
  tibble(variable = variable, drought_sd = sd(panel_admin_year[[variable]], na.rm = TRUE))
}))

# Add confidence intervals and multiply by each drought measure's ADM2-year SD.
coef_standardized <- coef_results %>%
  left_join(drought_sds, by = "variable") %>%
  left_join(
    bin_counts %>% select(het_def_id, het_group, adm2s, admin_years),
    by = c("het_def_id", "het_group")
  ) %>%
  mutate(
    age_label = recode(as.character(agegroup), !!!age_labels),
    measure_short = recode(variable, !!!measure_short_labels),
    ci_low = estimate - 1.96 * std_error,
    ci_high = estimate + 1.96 * std_error,
    estimate_sd_log = estimate * drought_sd,
    ci_low_sd_log = ci_low * drought_sd,
    ci_high_sd_log = ci_high * drought_sd,
    # Poisson coefficients are log rate ratios. Convert +1SD effects to percent.
    estimate_sd = if_else(outcome_model == "poisson", 100 * (exp(estimate_sd_log) - 1), estimate_sd_log),
    ci_low_sd = if_else(outcome_model == "poisson", 100 * (exp(ci_low_sd_log) - 1), ci_low_sd_log),
    ci_high_sd = if_else(outcome_model == "poisson", 100 * (exp(ci_high_sd_log) - 1), ci_high_sd_log),
    ci_clear = ci_low_sd > 0 | ci_high_sd < 0,
    het_group_with_n = paste0(het_group, "\n", format(adm2s, big.mark = ","), " ADM2s")
  )

write_csv(coef_standardized, file.path(figure_dir, paste0("het_coefs_standardized_", run_id, ".csv")))


# -----------------------------
# Coefficient plots
# -----------------------------

# Plot titles for each het grouping
het_plot_labels <- c(
  urban2_50 = "Urban share, 50% split",
  urban3_equal_width = "Urban share, equal-width thirds",
  income2_kummu = "Kummu income, median split",
  income3_kummu = "Kummu income, tertiles",
  urban_income_2x2 = "Urban x income, 2 x 2",
  rain_level2 = "Baseline rainfall level, median split",
  rain_level3 = "Baseline rainfall level, terciles",
  rain_cv2 = "Rainfall variability, median split",
  rain_cv3 = "Rainfall variability, terciles",
  rain_level_cv_2x2 = "Rainfall level x variability, 2 x 2",
  urban3_distribution = "Urban share, distribution thirds",
  urban2_any = "Urban share, zero vs above zero"
)

# PDF in this run's figure folder
save_plot <- function(plot, file_stub, width, height) {
  ggsave(file.path(figure_dir, paste0(file_stub, ".pdf")), plot, width = width, height = height, bg = "white")
}

plot_het_coefs <- function(het_def_id) {
  plot_df <- coef_standardized %>%
    filter(het_def_id == !!het_def_id) %>%
    mutate(
      age_label = factor(age_label, levels = c("0-4", "5-64", "65+")),
      measure_short = factor(measure_short, levels = unique(measure_short)),
      het_group_with_n = factor(het_group_with_n, levels = rev(unique(het_group_with_n)))
    )

  # One panel per drought measure and age group. Each point is one bin-specific
  # drought slope, scaled to a +1 SD increase in that drought measure.
  p <- ggplot(plot_df, aes(x = estimate_sd, y = het_group_with_n)) +
    geom_vline(xintercept = 0, color = "grey65", linewidth = 0.4) +
    geom_errorbarh(aes(xmin = ci_low_sd, xmax = ci_high_sd),
                   height = 0.16, linewidth = 0.5, color = coef_color) +
    geom_point(aes(shape = ci_clear), size = 2.0, color = coef_color) +
    facet_grid(measure_short ~ age_label, scales = "free_x") +
    scale_shape_manual(values = c(`FALSE` = 16, `TRUE` = 18), guide = "none") +
    labs(
      x = x_axis_label,
      y = NULL,
      title = paste0("Brazil drought heterogeneity: ", het_plot_labels[[het_def_id]]),
      subtitle = control_label
    ) +
    theme(
      axis.text.y = element_text(size = 8.8),
      panel.spacing = unit(0.85, "lines")
    )

  p
}

# One figure per het grouping in this run. The 2 x 2 ones have more rows
for (het_def_id in unique(coef_standardized$het_def_id)) {
  p <- plot_het_coefs(het_def_id)

  height <- if (grepl("_2x2$", het_def_id)) 9.2 else 8.2
  save_plot(p, paste0("fig_het_coefs_", het_def_id), width = 13.5, height = height)
}


# -----------------------------
# 2 x 2 heatmaps
# -----------------------------

# Same estimates as the 2 x 2 coefficient plots, but arranged as cells.
# Dark outlines mark coefficients whose 95% CI does not cross zero.
plot_2x2_heatmap <- function(het_def_id, x_levels, y_levels, title, file_stub) {
  heatmap_df <- coef_standardized %>%
    filter(het_def_id == !!het_def_id) %>%
    separate(het_group, into = c("y_group", "x_group"), sep = " \\+ ", remove = FALSE) %>%
    mutate(
      age_label = factor(age_label, levels = c("0-4", "5-64", "65+")),
      measure_short = factor(measure_short, levels = unique(measure_short)),
      y_group = factor(y_group, levels = y_levels),
      x_group = factor(x_group, levels = x_levels),
      label = sprintf("%.1f", estimate_sd)
    )

  if (nrow(heatmap_df) == 0) return(invisible(NULL))

  heat_lim <- max(abs(heatmap_df$estimate_sd), na.rm = TRUE)

  heatmap_df <- heatmap_df %>%
    mutate(label_color = if_else(abs(estimate_sd) > 0.55 * heat_lim, "white", "black"))

  heatmap_2x2 <- ggplot(heatmap_df, aes(x = x_group, y = y_group, fill = estimate_sd)) +
    geom_tile(color = "white", linewidth = 0.8) +
    geom_tile(data = filter(heatmap_df, ci_clear), fill = NA, color = "grey10", linewidth = 0.9) +
    geom_text(aes(label = label, color = label_color), size = 3.0) +
    facet_grid(measure_short ~ age_label) +
    scale_fill_gradient2(
      low = heat_low, mid = "white", high = heat_high,
      midpoint = 0, limits = c(-heat_lim, heat_lim),
      name = "+1 SD effect"
    ) +
    scale_color_manual(values = c(black = "black", white = "white"), guide = "none") +
    labs(
      x = NULL,
      y = NULL,
      title = title,
      subtitle = control_label,
      caption = "Numbers are effects for a +1 SD increase in the drought measure. Dark outlines mark 95% CI excluding zero."
    ) +
    theme(
      axis.text.x = element_text(angle = 20, hjust = 1),
      plot.caption = element_text(size = 9, color = "grey35", hjust = 0),
      panel.spacing = unit(0.75, "lines")
    )

  save_plot(heatmap_2x2, file_stub, width = 11.5, height = 9.0)
}

# Drawn only if the run has these groupings (the function skips them otherwise)
plot_2x2_heatmap(
  "urban_income_2x2",
  x_levels = c("low Kummu income", "high Kummu income"),
  y_levels = c("above 50% urban", "0-50% urban"),
  title = "Brazil drought heterogeneity: urban x income cells",
  file_stub = "fig_het_heatmap_urban_income_2x2"
)

plot_2x2_heatmap(
  "rain_level_cv_2x2",
  x_levels = c("stable rainfall", "volatile rainfall"),
  y_levels = c("wet rainfall", "dry rainfall"),
  title = "Brazil drought heterogeneity: rainfall level x variability cells",
  file_stub = "fig_het_heatmap_rain_level_cv_2x2"
)

message("Wrote heterogeneity figures to: ", figure_dir)
