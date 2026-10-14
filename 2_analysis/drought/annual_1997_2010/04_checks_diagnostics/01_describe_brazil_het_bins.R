# ============================================================
# 01_describe_brazil_het_bins.R
#
# How the heterogeneity bins used in 02_regressions/03_brazil_het_regs.R
# split Brazil's municipalities, before running those regs.
#
#   - urban share bins (as in the precip het work)
#   - Kummu income bins, compared with the older Carleton state income
#   - urban x income 2 x 2 cells
#   - 1981-2010 rainfall level and variability bins
#
# Output: histograms and scatter plots with the cutoffs marked, and CSVs of
# the variables and the number of municipalities in each bin.
# output/data/drought/brazil-annual/heterogeneity-diagnostics/
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)
library(tidyr)


# -----------------------------
# Paths
# -----------------------------

# paths.R gives DIR_REPO_RAINFALL_MORTALITY (the repo on RCC)
USER <- Sys.getenv("USER")
source("../../../../0_utils/paths.R")

PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds"
)

# Yearly drought file, for the 1981-2010 rainfall level and variability
DROUGHT_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/annual/era5land_admin_drought_annual_bra.rds"
)

OUTPUT_DIR <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "drought",
  "brazil-annual", "heterogeneity-diagnostics"
)

figure_dir <- file.path(OUTPUT_DIR, "figures")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Read Brazil panel
# -----------------------------

panel <- readRDS(PANEL_FILE)

# urban share and income are ADM2 characteristics
# use one row per ADM2 for histograms
adm2 <- panel %>%
  distinct(admin_code, .keep_all = TRUE) %>%
  select(
    adm1_code, adm1_name, admin_code, admin_name,
    urban_share,
    kummu_loggdppc_avg_2010_2024,
    kummu_gdppc_avg_2010_2024,
    loggdppc_adm1_avg,
    gdppc_adm1_avg
  )

# bin counts use adm2-years, not age rows
admin_year <- panel %>%
  distinct(admin_code, year, .keep_all = TRUE) %>%
  select(admin_code, year)

# Baseline climate uses the fixed 1981-2010 rainfall period, not the mortality years.
baseline_climate <- readRDS(DROUGHT_FILE) %>%
  filter(climate_country == "BRA", year >= 1981, year <= 2010) %>%
  mutate(admin_code = paste(climate_country, as.integer(ID_1), as.integer(ID_2), sep = "_")) %>%
  group_by(admin_code) %>%
  summarise(
    baseline_rain_years = sum(!is.na(annual_rain_mm_pop)),
    baseline_rain_mean_mm = mean(annual_rain_mm_pop, na.rm = TRUE),
    baseline_rain_sd_mm = sd(annual_rain_mm_pop, na.rm = TRUE),
    baseline_rain_cv = baseline_rain_sd_mm / baseline_rain_mean_mm,
    .groups = "drop"
  )

adm2 <- adm2 %>%
  left_join(baseline_climate, by = "admin_code")


# -----------------------------
# Bin definitions
# -----------------------------

# Cutoffs for income, urban-share, and baseline-climate bins
income_median <- median(adm2$kummu_loggdppc_avg_2010_2024, na.rm = TRUE)
income_tertiles <- quantile(adm2$kummu_loggdppc_avg_2010_2024, c(1 / 3, 2 / 3), na.rm = TRUE)
urban_tertiles <- quantile(adm2$urban_share, c(1 / 3, 2 / 3), na.rm = TRUE)
rain_mean_median <- median(adm2$baseline_rain_mean_mm, na.rm = TRUE)
rain_mean_tertiles <- quantile(adm2$baseline_rain_mean_mm, c(1 / 3, 2 / 3), na.rm = TRUE)
rain_cv_median <- median(adm2$baseline_rain_cv, na.rm = TRUE)
rain_cv_tertiles <- quantile(adm2$baseline_rain_cv, c(1 / 3, 2 / 3), na.rm = TRUE)

adm2_bins <- adm2 %>%
  mutate(
    # Any urban share is a diagnostic split because many Brazil ADM2s are at 0
    urban2_any = if_else(urban_share == 0, "0% urban", "above 0% urban"),
    # Main two-bin urban split, matching the precip heterogeneity setup.
    urban2_50 = if_else(urban_share <= 50, "0-50% urban", "above 50% urban"),
    # Diagnostic urban terciles based on the Brazil distribution
    urban3_distribution = case_when(
      urban_share == 0 ~ "0% urban",
      urban_share <= urban_tertiles[[2]] ~ "above 0%, below 67th pct",
      TRUE ~ "above 67th pct"),
    # Main 3-bin urban split, using simple equal-width urban-share ranges
    urban3_equal_width = case_when(
      urban_share < 34 ~ "0-33% urban",
      urban_share < 67 ~ "34-66% urban",
      TRUE ~ "67-100% urban"),
    # Kummu ADM2 income is the chosen main income var
    # median
    income2_kummu = if_else(
      kummu_loggdppc_avg_2010_2024 <= income_median,
      "low Kummu income",
      "high Kummu income"),
    # terciles
    income3_kummu = case_when(
      kummu_loggdppc_avg_2010_2024 <= income_tertiles[[1]] ~ "low Kummu income",
      kummu_loggdppc_avg_2010_2024 <= income_tertiles[[2]] ~ "middle Kummu income",
      TRUE ~ "high Kummu income"),
    # 2 x 2 cells use the main urban split crossed with the main income split
    urban_income_2x2 = paste(urban2_50, income2_kummu, sep = " + "),
    urban_income_2x2_short = case_when(
      urban2_50 == "0-50% urban" & income2_kummu == "low Kummu income" ~ "Low urban, low income",
      urban2_50 == "0-50% urban" & income2_kummu == "high Kummu income" ~ "Low urban, high income",
      urban2_50 == "above 50% urban" & income2_kummu == "low Kummu income" ~ "High urban, low income",
      TRUE ~ "High urban, high income"
    ),
    # Baseline rainfall level: 1981-2010 mean annual rainfall
    rain_level2 = if_else(
      baseline_rain_mean_mm <= rain_mean_median,
      "dry rainfall",
      "wet rainfall"),
    rain_level3 = case_when(
      baseline_rain_mean_mm <= rain_mean_tertiles[[1]] ~ "dry rainfall",
      baseline_rain_mean_mm <= rain_mean_tertiles[[2]] ~ "middle rainfall",
      TRUE ~ "wet rainfall"),
    # Rainfall variability: 1981-2010 CV of annual rainfall
    rain_cv2 = if_else(
      baseline_rain_cv <= rain_cv_median,
      "stable rainfall",
      "volatile rainfall"),
    rain_cv3 = case_when(
      baseline_rain_cv <= rain_cv_tertiles[[1]] ~ "stable rainfall",
      baseline_rain_cv <= rain_cv_tertiles[[2]] ~ "middle variability",
      TRUE ~ "volatile rainfall"),
    # 2 x 2 cells use the median split in level and variability
    rain_level_cv_2x2 = paste(rain_level2, rain_cv2, sep = " + "),
    rain_level_cv_2x2_short = case_when(
      rain_level2 == "dry rainfall" & rain_cv2 == "stable rainfall" ~ "Dry, stable",
      rain_level2 == "dry rainfall" & rain_cv2 == "volatile rainfall" ~ "Dry, volatile",
      rain_level2 == "wet rainfall" & rain_cv2 == "stable rainfall" ~ "Wet, stable",
      TRUE ~ "Wet, volatile"
    )
  )

# Attach ADM2 bin labels to ADM2-year rows so bin counts match the regression sample.
admin_year_bins <- admin_year %>%
  left_join(
    adm2_bins %>%
      select(admin_code, urban2_any, urban2_50, urban3_distribution, urban3_equal_width,
             income2_kummu, income3_kummu, urban_income_2x2,
             rain_level2, rain_level3, rain_cv2, rain_cv3, rain_level_cv_2x2),
    by = "admin_code"
  )


# -----------------------------
# CSV diagnostics
# -----------------------------

# Summary of the raw heterogeneity vars, mostly to compare Kummu ADM2 income
# with the older ADM1 income var.
summary_vars <- tibble::tribble(
  ~variable, ~label,
  "urban_share", "Urban share",
  "kummu_loggdppc_avg_2010_2024", "Kummu log GDP per capita",
  "kummu_gdppc_avg_2010_2024", "Kummu GDP per capita",
  "loggdppc_adm1_avg", "Legacy ADM1 log GDP per capita",
  "gdppc_adm1_avg", "Legacy ADM1 GDP per capita",
  "baseline_rain_mean_mm", "Baseline annual rainfall mean",
  "baseline_rain_sd_mm", "Baseline annual rainfall SD",
  "baseline_rain_cv", "Baseline annual rainfall CV"
)

# One summary row per ADM2-level heterogeneity var
variable_summary <- bind_rows(lapply(seq_len(nrow(summary_vars)), function(i) {
  variable <- summary_vars$variable[[i]]
  x <- adm2[[variable]]

  tibble(
    variable = variable,
    label = summary_vars$label[[i]],
    adm2s = sum(!is.na(x)),
    unique_values = n_distinct(x, na.rm = TRUE),
    mean = mean(x, na.rm = TRUE),
    sd = sd(x, na.rm = TRUE),
    min = min(x, na.rm = TRUE),
    p10 = quantile(x, 0.10, na.rm = TRUE, names = FALSE),
    p25 = quantile(x, 0.25, na.rm = TRUE, names = FALSE),
    p50 = quantile(x, 0.50, na.rm = TRUE, names = FALSE),
    p75 = quantile(x, 0.75, na.rm = TRUE, names = FALSE),
    p90 = quantile(x, 0.90, na.rm = TRUE, names = FALSE),
    max = max(x, na.rm = TRUE)
  )
}))

# Count how many ADM2s and ADM2-years fall into each bin. This is the quick
# check for whether any het cell is too thin for the regs
bin_variables <- c(
  "urban2_any", "urban2_50", "urban3_equal_width", "urban3_distribution",
  "income2_kummu", "income3_kummu", "urban_income_2x2",
  "rain_level2", "rain_level3", "rain_cv2", "rain_cv3", "rain_level_cv_2x2"
)

bin_counts <- bind_rows(lapply(bin_variables, function(variable) {
  admin_year_bins %>%
    group_by(bin = .data[[variable]]) %>%
    summarise(
      bin_variable = variable,
      adm2s = n_distinct(admin_code),
      admin_years = n(),
      .groups = "drop"
    ) %>%
    select(bin_variable, bin, adm2s, admin_years)
  }))

# `group_by()` sorts labels alphabetically. This order keeps the CSV readable:
# low to high urban share, low to high income, then the 2 x 2 cells.
bin_order <- tibble::tribble(
  ~bin_variable, ~bin, ~bin_order,
  "urban2_any", "0% urban", 1,
  "urban2_any", "above 0% urban", 2,
  "urban2_50", "0-50% urban", 1,
  "urban2_50", "above 50% urban", 2,
  "urban3_equal_width", "0-33% urban", 1,
  "urban3_equal_width", "34-66% urban", 2,
  "urban3_equal_width", "67-100% urban", 3,
  "urban3_distribution", "0% urban", 1,
  "urban3_distribution", "above 0%, below 67th pct", 2,
  "urban3_distribution", "above 67th pct", 3,
  "income2_kummu", "low Kummu income", 1,
  "income2_kummu", "high Kummu income", 2,
  "income3_kummu", "low Kummu income", 1,
  "income3_kummu", "middle Kummu income", 2,
  "income3_kummu", "high Kummu income", 3,
  "urban_income_2x2", "0-50% urban + low Kummu income", 1,
  "urban_income_2x2", "0-50% urban + high Kummu income", 2,
  "urban_income_2x2", "above 50% urban + low Kummu income", 3,
  "urban_income_2x2", "above 50% urban + high Kummu income", 4,
  "rain_level2", "dry rainfall", 1,
  "rain_level2", "wet rainfall", 2,
  "rain_level3", "dry rainfall", 1,
  "rain_level3", "middle rainfall", 2,
  "rain_level3", "wet rainfall", 3,
  "rain_cv2", "stable rainfall", 1,
  "rain_cv2", "volatile rainfall", 2,
  "rain_cv3", "stable rainfall", 1,
  "rain_cv3", "middle variability", 2,
  "rain_cv3", "volatile rainfall", 3,
  "rain_level_cv_2x2", "dry rainfall + stable rainfall", 1,
  "rain_level_cv_2x2", "dry rainfall + volatile rainfall", 2,
  "rain_level_cv_2x2", "wet rainfall + stable rainfall", 3,
  "rain_level_cv_2x2", "wet rainfall + volatile rainfall", 4
)

bin_counts <- bin_counts %>%
  left_join(bin_order, by = c("bin_variable", "bin")) %>%
  mutate(bin_variable_order = match(bin_variable, bin_variables)) %>%
  arrange(bin_variable_order, bin_order) %>%
  select(-bin_variable_order, -bin_order)

# These CSVs are just diagnostics: raw vars, bin sizes, and one row per ADM2
# with the bin labels used by the heterogeneity regs
write_csv(variable_summary, file.path(OUTPUT_DIRs, "het_vars.csv"))
write_csv(bin_counts, file.path(OUTPUT_DIR, "het_bins.csv"))
write_csv(adm2_bins, file.path(OUTPUT_DIR, "het_admin_bins.csv"))


# -----------------------------
# Figures
# -----------------------------

# ------------------------------------------------------------
# Common plot settings
# ------------------------------------------------------------

# Keep a common clean theme across the diagnostic figures
theme_set(
  theme_minimal(base_size = 12) +
    theme(
      plot.background = element_rect(fill = "white", color = NA),
      panel.background = element_rect(fill = "white", color = NA),
      legend.background = element_rect(fill = "white", color = NA)
    )
)

# Same colors for median, tercile, and 50% urban-share cutoffs across plots
cut_colors <- c(
  median = "#00876C",
  tertile = "#6A51A3",
  majority = "#C43B2F"
)


# ------------------------------------------------------------
# Figure 1. Urban-share histogram
# ------------------------------------------------------------

# Urban-share distribution with both possible binning ideas marked:
# main precip-style bins and distribution-based cutoffs:
urban_cut_33 <- quantile(adm2_bins$urban_share, 1 / 3, na.rm = TRUE, names = FALSE)
urban_cut_67 <- quantile(adm2_bins$urban_share, 2 / 3, na.rm = TRUE, names = FALSE)
urban_cut_median <- median(adm2_bins$urban_share, na.rm = TRUE)
urban_ymax <- max(hist(adm2_bins$urban_share, breaks = seq(0, 100, by = 5), plot = FALSE)$counts)

# labels for cutoff line: The 33rd percentile is zero in Brazil, so label moved slightly to the right
urban_lines <- tibble::tribble(
  ~x, ~x_label, ~label, ~line_type, ~y,
  urban_cut_33, 1.5, "33rd pct = 0%", "tertile", urban_ymax * 1.18,
  urban_cut_median, urban_cut_median, "median", "median", urban_ymax * 1.18,
  50, 50, "50% cutoff", "majority", urban_ymax * 1.05,
  urban_cut_67, urban_cut_67, "67th pct", "tertile", urban_ymax * 1.18
) %>%
  mutate(x_label = pmax(x_label, 1.5))


urban_hist <- ggplot(adm2_bins, aes(x = urban_share)) +
  geom_histogram(
    binwidth = 5, boundary = 0, fill = "#2F6B8F", alpha = 0.72,
    color = "white", linewidth = 0.2
  ) +
  geom_vline(
    data = urban_lines,
    aes(xintercept = x, color = line_type, linetype = line_type),
    linewidth = 0.75,
    show.legend = FALSE
  ) +
  geom_text(
    data = urban_lines,
    aes(x = x_label, y = y, label = label, color = line_type),
    angle = 90,
    hjust = 1,
    vjust = -0.45,
    size = 3.6,
    fontface = "bold",
    inherit.aes = FALSE,
    show.legend = FALSE
  ) +
  scale_color_manual(values = cut_colors) +
  scale_linetype_manual(values = c(median = "dotdash", tertile = "dashed", majority = "solid")) +
  scale_x_continuous(breaks = seq(0, 100, 10), labels = function(x) paste0(x, "%")) +
  coord_cartesian(xlim = c(-2, 100), ylim = c(0, urban_ymax * 1.22), clip = "off") +
  labs(
    x = "Urban share",
    y = "ADM2 count",
    title = "Brazil ADM2 urban share"
  ) +
  theme(plot.margin = margin(10, 12, 8, 8))

ggsave(file.path(figure_dir, "fig_urban_hist.pdf"), urban_hist, width = 8, height = 5, bg = "white")


# ------------------------------------------------------------
# Figure 2. Income histograms
# ------------------------------------------------------------

# Compare Kummu ADM2 income with the older ADM1 income var
# Kummu is the main version used in the regressions.
income_long <- adm2_bins %>%
  transmute(
    `Kummu ADM2 income` = kummu_loggdppc_avg_2010_2024,
    `Legacy ADM1 income` = loggdppc_adm1_avg
  ) %>%
  pivot_longer(everything(), names_to = "income_source", values_to = "log_income")

# Median and tercile cutoffs for each income source
income_cuts <- income_long %>%
  group_by(income_source) %>%
  summarise(
    median = median(log_income, na.rm = TRUE),
    p33 = quantile(log_income, 1 / 3, na.rm = TRUE, names = FALSE),
    p67 = quantile(log_income, 2 / 3, na.rm = TRUE, names = FALSE),
    ymax = max(hist(log_income, breaks = 40, plot = FALSE)$counts),
    .groups = "drop"
  ) %>%
  pivot_longer(c(median, p33, p67), names_to = "cut", values_to = "x") %>%
  mutate(
    line_type = if_else(cut == "median", "median", "tertile"),
    label = recode(cut, median = "median", p33 = "33rd pct", p67 = "67th pct"),
    y = ymax * 1.35
  )

income_hist <- ggplot(income_long, aes(x = log_income)) +
  geom_histogram(bins = 40, fill = "#2F6B8F", alpha = 0.72, color = "white", linewidth = 0.2) +
  geom_vline(
    data = income_cuts,
    aes(xintercept = x, color = line_type, linetype = line_type),
    linewidth = 0.75,
    show.legend = FALSE
  ) +
  geom_text(
    data = income_cuts,
    aes(x = x, y = y, label = label, color = line_type),
    angle = 90,
    hjust = 1,
    vjust = -0.45,
    size = 3.4,
    fontface = "bold",
    inherit.aes = FALSE,
    show.legend = FALSE
  ) +
  scale_color_manual(values = cut_colors) +
  scale_linetype_manual(values = c(median = "dotdash", tertile = "dashed")) +
  scale_y_continuous(expand = expansion(mult = c(0.02, 0.36))) +
  facet_wrap(~income_source, scales = "free_y", ncol = 1) +
  coord_cartesian(clip = "off") +
  labs(
    x = "Log GDP per capita",
    y = "ADM2 count",
    title = "Brazil income variables"
  ) +
  theme(plot.margin = margin(10, 12, 8, 8))

ggsave(file.path(figure_dir, "fig_income_hist.pdf"), income_hist, width = 8, height = 6, bg = "white")


# ------------------------------------------------------------
# Figure 3. Kummu vs legacy income
# ------------------------------------------------------------

# This shows why Kummu is preferred: it keeps much more ADM2 variation than the
# legacy ADM1 income measure
income_compare <- ggplot(adm2_bins, aes(x = loggdppc_adm1_avg, y = kummu_loggdppc_avg_2010_2024)) +
  geom_point(alpha = 0.35, size = 0.9, color = "#2F6B8F") +
  labs(
    x = "Legacy ADM1 log GDP per capita",
    y = "Kummu ADM2 log GDP per capita",
    title = "Kummu income has more within-Brazil variation"
  )

ggsave(file.path(figure_dir, "fig_income_compare.pdf"), income_compare, width = 6.5, height = 5, bg = "white")


# ------------------------------------------------------------
# Figure 4. Urban x income bins
# ------------------------------------------------------------

# Check the joint bins used in the urban x income 2 x 2 regs 
urban_income <- ggplot(adm2_bins, aes(x = urban_share, y = kummu_loggdppc_avg_2010_2024)) +
  geom_point(aes(color = urban_income_2x2_short), alpha = 0.55, size = 0.9) +
  geom_vline(xintercept = 50, color = "grey35", linewidth = 0.5) +
  geom_hline(yintercept = income_median, color = "grey35", linewidth = 0.5) +
  scale_x_continuous(labels = function(x) paste0(x, "%")) +
  labs(
    x = "Urban share",
    y = "Kummu log GDP per capita",
    color = "2x2 bin",
    title = "Urban share and income bins"
  ) +
  guides(color = guide_legend(nrow = 2, byrow = TRUE)) +
  theme(legend.position = "bottom")

ggsave(file.path(figure_dir, "fig_urban_income_2x2.pdf"), urban_income, width = 9, height = 5.8, bg = "white")


# ------------------------------------------------------------
# Figure 5. Baseline rainfall level
# ------------------------------------------------------------

# Baseline rainfall level is long-run mean annual rainfall over 1981-2010
rain_level_lines <- tibble::tribble(
  ~x, ~label, ~line_type,
  rain_mean_tertiles[[1]], "33rd pct", "tertile",
  rain_mean_median, "median", "median",
  rain_mean_tertiles[[2]], "67th pct", "tertile"
)

rain_level_ymax <- max(hist(adm2_bins$baseline_rain_mean_mm, breaks = 40, plot = FALSE)$counts)

rain_level_hist <- ggplot(adm2_bins, aes(x = baseline_rain_mean_mm)) +
  geom_histogram(bins = 40, fill = "#2F6B8F", alpha = 0.72, color = "white", linewidth = 0.2) +
  geom_vline(
    data = rain_level_lines,
    aes(xintercept = x, color = line_type, linetype = line_type),
    linewidth = 0.75,
    show.legend = FALSE
  ) +
  geom_text(
    data = rain_level_lines,
    aes(x = x, y = rain_level_ymax * 1.18, label = label, color = line_type),
    angle = 90,
    hjust = 1,
    vjust = -0.45,
    size = 3.5,
    fontface = "bold",
    inherit.aes = FALSE,
    show.legend = FALSE
  ) +
  scale_color_manual(values = cut_colors) +
  scale_linetype_manual(values = c(median = "dotdash", tertile = "dashed")) +
  coord_cartesian(ylim = c(0, rain_level_ymax * 1.25), clip = "off") +
  labs(
    x = "1981-2010 mean annual rainfall, mm",
    y = "ADM2 count",
    title = "Brazil baseline rainfall level"
  ) +
  theme(plot.margin = margin(10, 12, 8, 8))

ggsave(file.path(figure_dir, "fig_rain_level_hist.pdf"), rain_level_hist, width = 8, height = 5, bg = "white")


# ------------------------------------------------------------
# Figure 6. Baseline rainfall variability
# ------------------------------------------------------------

# Rainfall variability is the CV of annual rainfall over 1981-2010
rain_cv_lines <- tibble::tribble(
  ~x, ~label, ~line_type,
  rain_cv_tertiles[[1]], "33rd pct", "tertile",
  rain_cv_median, "median", "median",
  rain_cv_tertiles[[2]], "67th pct", "tertile"
)

rain_cv_ymax <- max(hist(adm2_bins$baseline_rain_cv, breaks = 40, plot = FALSE)$counts)

rain_cv_hist <- ggplot(adm2_bins, aes(x = baseline_rain_cv)) +
  geom_histogram(bins = 40, fill = "#2F6B8F", alpha = 0.72, color = "white", linewidth = 0.2) +
  geom_vline(
    data = rain_cv_lines,
    aes(xintercept = x, color = line_type, linetype = line_type),
    linewidth = 0.75,
    show.legend = FALSE
  ) +
  geom_text(
    data = rain_cv_lines,
    aes(x = x, y = rain_cv_ymax * 1.18, label = label, color = line_type),
    angle = 90,
    hjust = 1,
    vjust = -0.45,
    size = 3.5,
    fontface = "bold",
    inherit.aes = FALSE,
    show.legend = FALSE
  ) +
  scale_color_manual(values = cut_colors) +
  scale_linetype_manual(values = c(median = "dotdash", tertile = "dashed")) +
  scale_x_continuous(labels = function(x) paste0(round(100 * x), "%")) +
  coord_cartesian(ylim = c(0, rain_cv_ymax * 1.25), clip = "off") +
  labs(
    x = "1981-2010 annual rainfall CV",
    y = "ADM2 count",
    title = "Brazil baseline rainfall variability"
  ) +
  theme(plot.margin = margin(10, 12, 8, 8))

ggsave(file.path(figure_dir, "fig_rain_cv_hist.pdf"), rain_cv_hist, width = 8, height = 5, bg = "white")


# ------------------------------------------------------------
# Figure 7. Rainfall level x variability bins
# ------------------------------------------------------------

# Check whether the climate 2 x 2 cells are reasonably populated
rain_level_cv <- ggplot(adm2_bins, aes(x = baseline_rain_mean_mm, y = baseline_rain_cv)) +
  geom_point(aes(color = rain_level_cv_2x2_short), alpha = 0.55, size = 0.9) +
  geom_vline(xintercept = rain_mean_median, color = "grey35", linewidth = 0.5) +
  geom_hline(yintercept = rain_cv_median, color = "grey35", linewidth = 0.5) +
  scale_y_continuous(labels = function(x) paste0(round(100 * x), "%")) +
  labs(
    x = "1981-2010 mean annual rainfall, mm",
    y = "1981-2010 annual rainfall CV",
    color = "2x2 bin",
    title = "Baseline rainfall level and variability bins"
  ) +
  guides(color = guide_legend(nrow = 2, byrow = TRUE)) +
  theme(legend.position = "bottom")

ggsave(file.path(figure_dir, "fig_rain_level_cv_2x2.pdf"), rain_level_cv, width = 9, height = 5.8, bg = "white")

message("Wrote heterogeneity diagnostics to: ", OUTPUT_DIR)
