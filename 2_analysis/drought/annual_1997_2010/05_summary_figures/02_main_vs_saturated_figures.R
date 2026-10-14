# ============================================================
# 02_main_vs_saturated_figures.R
#
# The annual results with main and saturated FE (+ ADM1 x year x age) side
# by side: pooled, rainfall bins, Northeast only, robustness checks, and
# heterogeneity. Reads the per-run CSVs from 03_run_outputs/ 
#
#   fig_pooled_main_vs_saturated_<model>[_prcpoly]
#   fig_bins_fe_specs_<model>
#   fig_northeast_main_vs_saturated_<model>
#   fig_checks_main_vs_saturated_<model>
#   fig_het_<het>_main_vs_saturated_<model>[_prcpoly]
#   fig_het_dimensions_main_vs_saturated_levels
#
# Run from 05_summary_figures/ (sources 00_figure_setup.R).
# ============================================================

source("00_figure_setup.R")

# -----------------------------
# 3. Results, main vs saturated
# -----------------------------

# Pooled measures shown in the side-by-side figures: the yearly summaries,
# the annual rainfall deviation and SPI (one-term regs only)
pooled_sets <- c(
  "gs_neglog", "rs_months", "rs_worst_logdev", "low10_6m", "low05_6m",
  "worst_z_6m", "deficit_6m", "rain_dev", "spi12", "spi06_worst", "very_dry"
)

# One row per measure, main and saturated panels side by side within each age.
plot_main_vs_saturated <- function(data, title, subtitle, model) {
  plot_df <- data %>%
    mutate(measure_label = factor(measure_label, levels = rev(unique(measure_label))))

  ggplot(plot_df, aes(x = estimate_sd, y = measure_label, color = fe_label)) +
    geom_blank(data = shared_range_by_age(plot_df), aes(x = x), inherit.aes = FALSE) +
    geom_vline(xintercept = 0, color = "grey60") +
    geom_errorbarh(aes(xmin = ci_low_sd, xmax = ci_high_sd), height = 0.25) +
    geom_point(size = 1.8) +
    facet_nested(~ age_label + fe_label, scales = "free_x", independent = "x") +
    scale_x_continuous(n.breaks = 4) +
    scale_color_manual(values = fe_colors, guide = "none") +
    labs(x = x_label(model), y = NULL, title = title, subtitle = subtitle)
}

# The four pooled runs drawn, one figure each
pooled_runs <- tibble::tribble(
  ~run_suffix, ~model, ~file_tag, ~subtitle,
  "poisson_unweighted", "poisson", "poisson", "Poisson, unweighted, temperature controls",
  "levels_weighted", "levels", "levels", "Levels, population weighted, temperature controls",
  "poisson_unweighted_prcpoly", "poisson", "poisson_prcpoly", "Poisson, unweighted, temperature + precip polynomial",
  "levels_weighted_prcpoly", "levels", "levels_prcpoly", "Levels, population weighted, temperature + precip polynomial"
)

for (i in seq_len(nrow(pooled_runs))) {
  run <- pooled_runs[i, ]
  data <- read_main_saturated(run$run_suffix) %>%
    filter(set_id %in% pooled_sets) %>%
    mutate(measure_label = factor(measure_label, levels = unique(measure_label[order(match(set_id, pooled_sets))])))

  p <- plot_main_vs_saturated(data, "Brazil annual drought coefficients: main vs saturated FE", run$subtitle, run$model)
  save_fig(p, paste0("fig_pooled_main_vs_saturated_", run$file_tag), 12, 5.2)
}

# -------- Rainfall bins across FE specs --------

bin_order <- c(
  "<10\n(driest)" = "rain_bin_p00_10_pop",
  "10-25" = "rain_bin_p10_25_pop",
  "25-75\n(ref.)" = NA,
  "75-90" = "rain_bin_p75_90_pop",
  ">90\n(wettest)" = "rain_bin_p90_100_pop"
)

# Effect of each rainfall bin vs a normal year, across all FE specs
plot_bins <- function(model) {
  runs <- paste0(names(fe_labels), if (model == "poisson") "_poisson_unweighted" else "_levels_weighted")

  bins <- bind_rows(lapply(runs, read_pooled)) %>%
    filter(set_id == "rain_bins") %>%
    mutate(bin = names(bin_order)[match(variable, bin_order)])

  # Add the omitted normal-year bin at zero so the curve has its reference.
  reference <- bins %>%
    distinct(fe_label, age_label) %>%
    mutate(bin = names(bin_order)[3], estimate_sd = 0, ci_low_sd = 0, ci_high_sd = 0)

  bind_rows(bins, reference) %>%
    mutate(bin = factor(bin, levels = names(bin_order))) %>%
    ggplot(aes(x = bin, y = estimate_sd, group = fe_label, color = fe_label)) +
    geom_hline(yintercept = 0, color = "grey60") +
    geom_errorbar(aes(ymin = ci_low_sd, ymax = ci_high_sd), width = 0.15) +
    geom_line() +
    geom_point(size = 1.8) +
    facet_grid2(age_label ~ fe_label, scales = "free_y", independent = "none") +
    scale_color_manual(values = fe_colors, guide = "none") +
    labs(x = "Calendar-year rain, percentile of the ADM2's 1981-2010 distribution",
         y = if (model == "poisson") "% change in mortality vs a normal year" else "Deaths per 100,000 vs a normal year",
         title = "Mortality by rainfall bin, compared with a normal year",
         subtitle = ifelse(model == "poisson", "Poisson, unweighted", "Levels, population weighted")) +
    theme(axis.text.x = element_text(size = 7.5))
}

save_fig(plot_bins("poisson"), "fig_bins_fe_specs_poisson", 11, 6.5)
save_fig(plot_bins("levels"), "fig_bins_fe_specs_levels", 11, 6.5)

# -------- Northeast --------

# Same measures as the pooled figure, plus annual rainfall log deviation with its
# lag and lead (" + lag + lead" dropped from the label for display)
northeast_sets <- c(pooled_sets, "rain_dev_lag_lead")

for (model in c("poisson", "levels")) {
  suffix <- if (model == "poisson") "poisson_unweighted_northeast" else "levels_weighted_northeast"
  data <- read_main_saturated(suffix) %>%
    filter(set_id %in% northeast_sets) %>%
    mutate(measure_label = sub(" + lag + lead", "", measure_label, fixed = TRUE),
           measure_label = factor(measure_label, levels = unique(measure_label[order(match(set_id, northeast_sets))])))

  p <- plot_main_vs_saturated(
    data, "Northeast only: main vs saturated FE",
    paste(ifelse(model == "poisson", "Poisson, unweighted.", "Levels, population weighted."), "9 state clusters."),
    model
  )
  save_fig(p, paste0("fig_northeast_main_vs_saturated_", model), 12, 6.5)
}

# -------- Robustness checks, main vs saturated --------

# Four key measures, shown under each robustness check
check_sets <- c("rs_worst_logdev", "worst_z_6m", "rain_dev", "spi06_worst")

for (model in c("poisson", "levels")) {
  # Runs compared: the base run, + Tmax, + precip poly, and (levels only)
  # unweighted. Names are the legend labels
  base <- if (model == "poisson") "poisson_unweighted" else "levels_weighted"
  checks <- c("Base" = base, "+ Tmax (heat)" = paste0(base, "_tmax"), "+ precip poly" = paste0(base, "_prcpoly"))
  if (model == "levels") checks <- c(checks, "Unweighted" = "levels_unweighted")

  # Main and saturated FE results of each run, for the check measures only
  data <- bind_rows(lapply(names(checks), function(check) {
    read_main_saturated(checks[[check]]) %>% mutate(check = check)
  })) %>%
    filter(set_id %in% check_sets) %>%
    mutate(
      check = factor(check, levels = rev(names(checks))),
      measure_label = factor(measure_label, levels = unique(measure_label[order(match(set_id, check_sets))]))
    )

  # One row per measure, one colour per check. Main and saturated panels side
  # by side for each age, on the same x-axis
  p <- ggplot(data, aes(x = estimate_sd, y = measure_label, color = check)) +
    geom_blank(data = shared_range_by_age(data), aes(x = x), inherit.aes = FALSE) +
    geom_vline(xintercept = 0, color = "grey60") +
    geom_errorbarh(aes(xmin = ci_low_sd, xmax = ci_high_sd), height = 0, position = position_dodge(width = 0.7)) +
    geom_point(size = 1.5, position = position_dodge(width = 0.7)) +
    facet_nested(~ age_label + fe_label, scales = "free_x", independent = "x") +
    scale_x_continuous(n.breaks = 4) +
    guides(color = guide_legend(reverse = TRUE)) +
    labs(x = x_label(model), y = NULL, color = NULL,
         title = "Robustness checks: main vs saturated FE",
         subtitle = ifelse(model == "poisson", "Poisson", "Levels"))

  save_fig(p, paste0("fig_checks_main_vs_saturated_", model), 12, 4.8)
}


# -----------------------------
# 4. Heterogeneity heatmaps, main vs saturated
# -----------------------------


# The het runs drawn, one heatmap figure each. Each figure spans 3 lines:
#   1. run name (without main_/saturated_), the 2 x 2 grouping, model, and
#      the tag in the file name
#   2. the bin labels as stored on the x and y axes, then shorter versions
#      for the heatmap
#   3. the figure title
het_runs <- tibble::tribble(
  ~run_suffix, ~het_def_id, ~model, ~file_tag, ~x_levels, ~y_levels, ~short_x, ~short_y, ~title,
  "levels_weighted_climatehet_extendeddrought", "rain_level_cv_2x2", "levels", "climate_2x2_levels",
  c("stable rainfall", "volatile rainfall"), c("wet rainfall", "dry rainfall"), c("stable", "volatile"), c("wet", "dry"),
  "Rainfall level x variability, levels",
  "poisson_unweighted_climatehet_extendeddrought", "rain_level_cv_2x2", "poisson", "climate_2x2_poisson",
  c("stable rainfall", "volatile rainfall"), c("wet rainfall", "dry rainfall"), c("stable", "volatile"), c("wet", "dry"),
  "Rainfall level x variability, Poisson",
  "levels_weighted_climatehet_extendeddrought_prcpoly", "rain_level_cv_2x2", "levels", "climate_2x2_levels_prcpoly",
  c("stable rainfall", "volatile rainfall"), c("wet rainfall", "dry rainfall"), c("stable", "volatile"), c("wet", "dry"),
  "Rainfall level x variability, levels, with precip polynomial",
  "poisson_unweighted_climatehet_extendeddrought_prcpoly", "rain_level_cv_2x2", "poisson", "climate_2x2_poisson_prcpoly",
  c("stable rainfall", "volatile rainfall"), c("wet rainfall", "dry rainfall"), c("stable", "volatile"), c("wet", "dry"),
  "Rainfall level x variability, Poisson, with precip polynomial",
  "levels_weighted_mainhet_extendeddrought", "urban_income_2x2", "levels", "urban_income_2x2_levels",
  c("low Kummu income", "high Kummu income"), c("above 50% urban", "0-50% urban"), c("low inc", "high inc"), c(">50% urban", "<=50% urban"),
  "Urban x income, levels",
  "levels_weighted_mainhet_extendeddrought_prcpoly", "urban_income_2x2", "levels", "urban_income_2x2_levels_prcpoly",
  c("low Kummu income", "high Kummu income"), c("above 50% urban", "0-50% urban"), c("low inc", "high inc"), c(">50% urban", "<=50% urban"),
  "Urban x income, levels, with precip polynomial"
)

for (i in seq_len(nrow(het_runs))) {
  run <- het_runs[i, ]

  # Main and saturated FE coefs of this run. Split each 2 x 2 bin ("wet
  # rainfall + stable rainfall") into its row and column, with short labels
  het_df <- bind_rows(read_het(paste0("main_", run$run_suffix)), read_het(paste0("saturated_", run$run_suffix))) %>%
    filter(het_def_id == run$het_def_id) %>%
    separate(het_group, into = c("y_group", "x_group"), sep = " \\+ ", remove = FALSE) %>%
    mutate(
      x_group = factor(run$short_x[[1]][match(x_group, run$x_levels[[1]])], levels = run$short_x[[1]]),
      y_group = factor(run$short_y[[1]][match(y_group, run$y_levels[[1]])], levels = run$short_y[[1]]),
      measure_short = factor(measure_short, levels = unique(measure_short))
    )

  # Colour scale is shared within each measure x age block, so main and
  # saturated cells for the same measure and age are comparable.
  het_df <- het_df %>%
    group_by(measure_short, age_label) %>%
    mutate(fill_scaled = estimate_sd / max(abs(estimate_sd), na.rm = TRUE)) %>%
    ungroup()

  p <- ggplot(het_df, aes(x = x_group, y = y_group, fill = fill_scaled)) +
    geom_tile(color = "white", linewidth = 0.8) +
    geom_tile(data = filter(het_df, ci_clear), fill = NA, color = "grey10", linewidth = 0.9) +
    geom_text(aes(label = sprintf("%.1f", estimate_sd)), size = 2.6) +
    facet_nested(measure_short ~ age_label + fe_label) +
    scale_fill_gradient2(low = "#3B6EA8", mid = "white", high = "#B64A3A", midpoint = 0,
                         limits = c(-1, 1), guide = "none") +
    labs(x = NULL, y = NULL,
         title = paste0("Heterogeneity: ", run$title, ", main vs saturated FE"),
         caption = paste("Numbers are +1 SD effects. Colour is scaled within each measure x age block.",
                         "Dark outlines mark 95% CIs excluding zero.")) +
    theme(axis.text.x = element_text(angle = 25, hjust = 1, size = 7.5),
          axis.text.y = element_text(size = 7.5),
          strip.text.y = element_text(size = 7.5, angle = 0),
          plot.caption = element_text(hjust = 0, color = "grey35"))

  save_fig(p, paste0("fig_het_", run$file_tag, "_main_vs_saturated"), 13, 10)
}

# -------- Four heterogeneity dimensions in one figure --------

# Three-bin splits for urban, income, rainfall level and variability, main vs
# saturated FE, for two measures: the whole-year shortfall and the worst
# 6-month dry spell (SPI, not the z-score, whose -1/CV floor squashes droughts
# in volatile places). Levels, since all four dimensions were run in the
# levels model.
dim_labels <- c(
  urban3_equal_width = "Urban share", income3_kummu = "Income (Kummu)",
  rain_level3 = "Baseline rainfall level", rain_cv3 = "Rainfall variability"
)
dim_measures <- c("rain_dry_logdev_pop", "spi06_worst_severity_pop")

# Main and saturated FE results of the two het runs (urban/income and climate
# groupings), kept for the 4 three-bin splits and the 2 measures
het_dims <- bind_rows(
  read_het("main_levels_weighted_mainhet_extendeddrought"),
  read_het("saturated_levels_weighted_mainhet_extendeddrought"),
  read_het("main_levels_weighted_climatehet_extendeddrought"),
  read_het("saturated_levels_weighted_climatehet_extendeddrought")
) %>%
  filter(het_def_id %in% names(dim_labels), variable %in% dim_measures) %>%
  mutate(
    fe_label = droplevels(fe_label),
    dimension = factor(dim_labels[het_def_id], levels = dim_labels),
    # Short display names for the bins (the reg outputs keep the long ones)
    het_group = recode(het_group,
      "low Kummu income" = "Low income", "middle Kummu income" = "Middle income",
      "high Kummu income" = "High income",
      "dry rainfall" = "Dry", "middle rainfall" = "Medium", "wet rainfall" = "Wet",
      "stable rainfall" = "Stable", "middle variability" = "Moderate",
      "volatile rainfall" = "Volatile"),
    # Bins from low to high, top to bottom within each dimension
    het_group = factor(het_group, levels = rev(c(
      "0-33% urban", "34-66% urban", "67-100% urban",
      "Low income", "Middle income", "High income",
      "Dry", "Medium", "Wet",
      "Stable", "Moderate", "Volatile"
    ))),
    measure_short = factor(measure_short, levels = c("Annual rain log deviation", "Worst 6m SPI"))
  )

# One row per bin, rows grouped by dimension, one colour per measure. Main
# and saturated panels side by side for each age, on the same x-axis
het_dims_plot <- ggplot(het_dims, aes(x = estimate_sd, y = het_group, color = measure_short)) +
  geom_blank(data = shared_range_by_age(het_dims), aes(x = x), inherit.aes = FALSE) +
  geom_vline(xintercept = 0, color = "grey60") +
  geom_errorbarh(aes(xmin = ci_low_sd, xmax = ci_high_sd), height = 0,
                 position = position_dodge(width = 0.6)) +
  geom_point(size = 1.7, position = position_dodge(width = 0.6)) +
  facet_nested(dimension ~ age_label + fe_label, scales = "free", independent = "x", space = "free_y") +
  scale_x_continuous(n.breaks = 4) +
  scale_color_manual(values = c("Annual rain log deviation" = "#2F6B8F", "Worst 6m SPI" = "#B5452B")) +
  labs(x = x_label("levels"), y = NULL, color = NULL,
       title = "Heterogeneity: where the drought effect differs, main vs saturated FE",
       subtitle = "Levels, population weighted. Three-bin splits (terciles for income, rainfall level and variability, equal-width thirds for urban share).") +
  theme(strip.text.y = element_text(angle = 0))

save_fig(het_dims_plot, "fig_het_dimensions_main_vs_saturated_levels", 12, 8)

message("wrote: ", OUTPUT_DIR)
