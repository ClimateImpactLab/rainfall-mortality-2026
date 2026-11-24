# ============================================================================
# 03_brazil_var_diagnostics.R
#
# Distributions of the annual drought measures, to help read the reg
# results:
#   - histograms: is a measure mostly zeros, skewed, or driven by a few years?
#   - drought measure vs annual rainfall: how close is it to plain annual rainfall?
#
# The panel has one row per age group, but drought is the same for all ages,
# so this uses one row per municipality-year.
#
# Output: output/data/drought/brazil-annual/variable-diagnostics/
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(ggplot2)
library(readr)
library(scales)


# -----------------------------
# Paths and settings
# -----------------------------

# Panel from 02_regressions/01_build_brazil_panel.R
PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds"
)

OUTPUT_DIR <- paste0(
  "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/",
  "output/data/drought/brazil-annual/variable-diagnostics"
)

figure_dir <- file.path(OUTPUT_DIR, "figures")


# -----------------------------
# Drought variables
# -----------------------------

# The measures from the first annual regs, with their plot labels
drought_vars <- tibble::tribble(
  ~variable, ~measure_label,
  "gs_neglog_annual_rain_pop", "-log annual rainfall",
  "rs_drought_months_12m_pop", "Rocha-Soares drought months",
  "rs_worst_logdev_severity_pop", "Worst Rocha-Soares log deviation",
  "rs_worst_pctdev_severity_pop", "Worst Rocha-Soares percent deviation",
  "drought_6m_low10_months_pop", "6-month months below 10th percentile",
  "drought_6m_low05_months_pop", "6-month months below 5th percentile",
  "drought_6m_worst_z_severity_pop", "Worst 6-month z-score severity",
  "deficit_mm_max_06m_pop", "Largest 6-month rainfall deficit"
)


# -----------------------------
# Read ADM2-year panel
# -----------------------------

adm_year <- readRDS(PANEL_FILE) %>%
  distinct(admin_code, year, .keep_all = TRUE) %>%
  select(admin_code, admin_name, adm1_code, adm1_name, year, annual_rain_mm_pop,
         all_of(drought_vars$variable))

# One row per municipality-year x measure, for the faceted plots
plot_data <- adm_year %>%
  pivot_longer(
    cols = all_of(drought_vars$variable),
    names_to = "variable",
    values_to = "value"
  ) %>%
  left_join(drought_vars, by = "variable") %>%
  mutate(measure_label = factor(measure_label, levels = drought_vars$measure_label))

# Plot only 8% of the points (readable scatter, small PDF), but draw the line
# through 40 bins of annual rainfall using all municipality-years
set.seed(1234)
scatter_points <- plot_data %>%
  filter(!is.na(value), !is.na(annual_rain_mm_pop)) %>%
  group_by(variable) %>%
  slice_sample(prop = 0.08) %>%
  ungroup()

scatter_bins <- plot_data %>%
  filter(!is.na(value), !is.na(annual_rain_mm_pop)) %>%
  group_by(variable, measure_label) %>%
  mutate(rain_bin = ntile(annual_rain_mm_pop, 40)) %>%
  group_by(variable, measure_label, rain_bin) %>%
  summarise(
    annual_rain_mm_pop = mean(annual_rain_mm_pop),
    value = mean(value),
    .groups = "drop"
  )


# -----------------------------
# Summary table
# -----------------------------

# Mean, SD and percentiles of each measure
summary_table <- plot_data %>%
  group_by(variable, measure_label) %>%
  summarise(
    adm2_years = sum(!is.na(value)),
    mean = mean(value, na.rm = TRUE),
    sd = sd(value, na.rm = TRUE),
    p10 = quantile(value, 0.10, na.rm = TRUE, names = FALSE),
    p50 = quantile(value, 0.50, na.rm = TRUE, names = FALSE),
    p90 = quantile(value, 0.90, na.rm = TRUE, names = FALSE),
    max = max(value, na.rm = TRUE),
    .groups = "drop"
  )


# -----------------------------
# Figures
# -----------------------------

theme_set(
  theme_bw(base_size = 11) +
    theme(
      panel.grid = element_blank(),
      strip.background = element_rect(fill = "grey92", color = NA),
      strip.text = element_text(face = "bold"),
      plot.title = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 9)
    )
)

# One histogram per measure
hist_plot <- ggplot(plot_data, aes(x = value)) +
  geom_histogram(bins = 35, fill = "#2F6B8F", alpha = 0.78, color = "white", linewidth = 0.2) +
  facet_wrap(~measure_label, scales = "free", ncol = 2) +
  labs(
    x = NULL,
    y = "ADM2-years",
    title = "Distribution of Brazil annual drought variables"
  )

# Each measure against annual rainfall: sampled points and the binned mean line
scatter_plot <- ggplot() +
  geom_point(
    data = scatter_points,
    aes(x = annual_rain_mm_pop, y = value),
    size = 0.35, color = "#A8C3D4"
  ) +
  geom_line(
    data = scatter_bins,
    aes(x = annual_rain_mm_pop, y = value),
    color = "#9F352D", linewidth = 0.75
  ) +
  facet_wrap(~measure_label, scales = "free_y", ncol = 2) +
  scale_x_continuous(labels = comma) +
  labs(
    x = "Annual rainfall, mm",
    y = NULL,
    title = "Drought variables against annual rainfall"
  )


# -----------------------------
# Write outputs
# -----------------------------

dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

write_csv(summary_table, file.path(OUTPUT_DIR, "drought_var_summary.csv"))

ggsave(file.path(figure_dir, "fig_drought_var_histograms.pdf"), hist_plot,
       width = 10, height = 11, bg = "white")

ggsave(file.path(figure_dir, "fig_drought_vs_annual_rain.pdf"), scatter_plot,
       width = 10, height = 11, bg = "white")

message("wrote: ", file.path(figure_dir, "fig_drought_var_histograms.pdf"))
message("wrote: ", file.path(figure_dir, "fig_drought_vs_annual_rain.pdf"))
