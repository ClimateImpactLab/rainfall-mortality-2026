# ============================================================
# 01_rain_vs_flow_figures.R
#
# Compare monthly county rainfall with routed rainfall (rainfall_flow), USA
#
# Rainfall = prcp_pop_p1, the precipitation used in the mortality analysis:
#   ERA5-Land tp_total, population-weighted county mean of daily totals,
#   summed over the month (mm). Built by
#   era5land_admin/aggregation_scripts/02_aggregate_prcp_temp.py.
# Flow = flow_pop: ERA5-Land rainfall (tp_total minus the daily change in
#   snow water equivalent) summed over every upstream cell on the D8 river
#   network, each month routed on its own, then population-weighted county
#   mean. Units are mm summed over upstream cells, not discharge. Built by
#   ../01_aggregate_monthly_flow.py.
# Drought and flood = flowmean_pop_annual and flowmax_pop_annual, the annual
#   mean and max of flow, built by ../02_make_drought_flood.py.
#
# Inputs (DATA_DIR/climate_data/ERA5-LAND-GLOBAL/USA/):
#   monthly/era5land_usa_adm2_monthly_{1950..2025}.csv            rainfall
#   hydro/monthly/era5land_usa_adm2_flow_monthly_{1950..2025}.csv  flow
#   annual/era5land_usa_adm2_annual_{1950..2025}.csv              annual rainfall terms
#   hydro/annual/era5land_usa_adm2_flow_annual_{1950..2025}.csv    drought and flood
#
# Outputs:
#   output/figures/hydro/rain_vs_flow/  (each as .pdf and .png)
#     2_where_flow_differs    correlation and missed flow extremes vs upstream ratio
#     3_seasonal_correlation  correlation by calendar month and upstream-ratio group
#     4_seasonal_profile      share of the year's total in each month
#     7_case_timeseries       monthly values around four floods, relative to the mean month
#     8_event_record          flood-month totals in every year, example counties
#     9_drought_flood         variation in the drought and flood measures that rainfall does not explain
#     A1_levels               county mean flow vs mean rainfall
#     (figures 1, 5 and 6, the maps, come from 02_rain_vs_flow_maps.R)
#   output/data/hydro/rain_vs_flow/
#     county_summary.csv        one row per county
#     group_summary.csv         one row per upstream-ratio group, plus all counties
#     seasonal_correlation.csv  figure 3
#     seasonal_profile.csv      figure 4
#     annual_county.csv         drought and flood measures vs rainfall, one row per county
#     annual_correlation.csv    the same, summarised by upstream-ratio group
#     annual_variance_share.csv share of the pooled within-county variance in raw levels, by group
#     event_percentiles.csv     every county's rank in each flood window (for the maps)
#     event_ranks.csv           the same for the case-study counties
#     case_timeseries.csv       monthly values for the example counties
#   These tables are read by 02_rain_vs_flow_maps.R and rain_vs_flow_report.Rmd.
#
# All comparisons use the raw monthly series, within each county. Flow levels
# depend on how much land drains into a county, so counties are never pooled
# on levels.
#
# Dependencies: dplyr, readr, tidyr, tibble, ggplot2
#
# Run from this folder on Midway:
#   Rscript 01_rain_vs_flow_figures.R
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(tidyr)
library(ggplot2)

theme_set(theme_classic(base_size = 10))


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

climate_dir <- file.path(DATA_DIR, "climate_data", "ERA5-LAND-GLOBAL", "USA")
rain_dir <- file.path(climate_dir, "monthly")
flow_dir <- file.path(climate_dir, "hydro", "monthly")
rain_annual_dir <- file.path(climate_dir, "annual")
flow_annual_dir <- file.path(climate_dir, "hydro", "annual")

fig_dir <- file.path(DIR_FIGURE, "hydro", "rain_vs_flow")
table_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "hydro", "rain_vs_flow")

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Settings
# -----------------------------

# Years covered by both inputs (first_year and last_year in era5land_admin/settings.py)
years <- 1950:2025

# Territories are dropped, as in hydro/diagnostics/scripts/vis_flow_preview.py.
# None of the case studies is there. ID_1 is the state FIPS code.
territories <- c("60", "66", "69", "72", "78")

# Flood case studies. Years, months and counties come from the historical
# record (general knowledge, not from data in this repo), so edit or extend as
# needed. Months are the main flood months. Counties sit on the flooded river,
# listed upstream to downstream; for Harvey they are in the rain-flooded area.
# `expected` is the driver we expect from the record, not a result.
# County codes were checked against the county names in
# norgay/.../Countries/USA/Shapefile/USA_adm2.csv.
# `example` marks the one county per event shown in the time-series figure.
events <- tibble::tribble(
  ~event,                      ~year, ~first_month, ~last_month, ~expected,       ~region_id,       ~county,               ~example,
  "2011 Missouri River flood",  2011,  5,  8, "upstream flow", "USA_244_38_015", "Burleigh, ND",        FALSE,
  "2011 Missouri River flood",  2011,  5,  8, "upstream flow", "USA_244_19_193", "Woodbury, IA",        TRUE,
  "2011 Missouri River flood",  2011,  5,  8, "upstream flow", "USA_244_19_155", "Pottawattamie, IA",   FALSE,
  "2011 Missouri River flood",  2011,  5,  8, "upstream flow", "USA_244_29_021", "Buchanan, MO",        FALSE,
  "2019 Missouri River flood",  2019,  3,  6, "upstream flow", "USA_244_31_053", "Dodge, NE",           FALSE,
  "2019 Missouri River flood",  2019,  3,  6, "upstream flow", "USA_244_31_055", "Douglas, NE",         TRUE,
  "2019 Missouri River flood",  2019,  3,  6, "upstream flow", "USA_244_19_071", "Fremont, IA",         FALSE,
  "2019 Missouri River flood",  2019,  3,  6, "upstream flow", "USA_244_29_087", "Holt, MO",            FALSE,
  "1993 Great Flood",           1993,  6,  8, "rain and flow", "USA_244_19_153", "Polk, IA",            FALSE,
  "1993 Great Flood",           1993,  6,  8, "rain and flow", "USA_244_17_001", "Adams, IL",           FALSE,
  "1993 Great Flood",           1993,  6,  8, "rain and flow", "USA_244_29_183", "St. Charles, MO",     FALSE,
  "1993 Great Flood",           1993,  6,  8, "rain and flow", "USA_244_29_510", "St. Louis city, MO",  TRUE,
  "2017 Hurricane Harvey",      2017,  8,  8, "local rain",    "USA_244_48_157", "Fort Bend, TX",       FALSE,
  "2017 Hurricane Harvey",      2017,  8,  8, "local rain",    "USA_244_48_201", "Harris, TX",          TRUE,
  "2017 Hurricane Harvey",      2017,  8,  8, "local rain",    "USA_244_48_167", "Galveston, TX",       FALSE,
  "2017 Hurricane Harvey",      2017,  8,  8, "local rain",    "USA_244_48_245", "Jefferson, TX",       FALSE
)

# The event-window join below assumes each county appears in one event only
stopifnot(anyDuplicated(events$region_id) == 0)

events <- events %>%
  mutate(
    event_months = paste0(
      month.abb[first_month],
      ifelse(first_month == last_month, "", paste0("-", month.abb[last_month]))
    ),
    event_short = paste0(event, " (", event_months, ")"),
    event_label = paste0(event_short, ", expected driver: ", expected)
  )

# Extreme months are a county's top 5% of months by raw value. Alternative:
# top 1%, closer to flood-scale events but noisier.
extreme_share <- 0.05

# Drought years are a county's lowest 10% of years and flood years its highest
# 10%. Alternative: 5%, closer to rare events but only a handful of years per
# county.
extreme_year_share <- 0.10

# Series colors: blue and orange from the dataviz reference palette, checked
# with its color-blind validator (both pass as a two-series palette)
col_rain <- "#2a78d6"
col_flow <- "#eb6834"
series_colors <- c("Rainfall" = col_rain, "rainfall_flow" = col_flow)

ink <- "#0b0b0b"
ink_2 <- "#52514e"
muted <- "#898781"
rule <- "#c3c2b7"
shade <- "#e1e0d9"

theme_update(
  axis.line = element_line(colour = rule),
  axis.ticks = element_line(colour = rule),
  axis.text = element_text(colour = ink_2),
  axis.title = element_text(colour = ink_2),
  plot.title = element_text(colour = ink, face = "bold"),
  plot.title.position = "plot",
  plot.subtitle = element_text(colour = ink_2),
  plot.caption = element_text(colour = muted, hjust = 0),
  plot.caption.position = "plot",
  strip.background = element_blank(),
  strip.text = element_text(colour = ink, face = "bold", hjust = 0),
  legend.position = "top",
  legend.justification = "left",
  legend.title = element_blank()
)

# Format numbers for figure labels, one at a time so each keeps its own digits
fmt <- function(x, digits = 2) {
  vapply(x, function(v) format(signif(v, digits), big.mark = ",", scientific = FALSE, trim = TRUE), "")
}

# Save each figure as a PDF (for slides and papers) and a PNG (for the HTML report)
save_figure <- function(name, plot, width, height) {
  ggsave(file.path(fig_dir, paste0(name, ".pdf")), plot, width = width, height = height)
  ggsave(file.path(fig_dir, paste0(name, ".png")), plot, width = width, height = height, dpi = 200)
}

# First day of a month, rolling month 13 into January of the next year
month_start <- function(year, month) {
  as.Date(sprintf("%d-%02d-01", year + (month - 1) %/% 12, (month - 1) %% 12 + 1))
}


# -----------------------------
# Read rainfall and flow
# -----------------------------

read_rain_year <- function(year) {
  read_csv(
    file.path(rain_dir, paste0("era5land_usa_adm2_monthly_", year, ".csv")),
    col_types = cols_only(month = "c", region_id = "c", ID_1 = "c", prcp_pop_p1 = "d"),
    progress = FALSE
  )
}

read_flow_year <- function(year) {
  read_csv(
    file.path(flow_dir, paste0("era5land_usa_adm2_flow_monthly_", year, ".csv")),
    col_types = cols_only(month = "c", region_id = "c", flow_pop = "d"),
    progress = FALSE
  )
}

rain <- bind_rows(lapply(years, read_rain_year)) %>% rename(rain = prcp_pop_p1)
flow <- bind_rows(lapply(years, read_flow_year)) %>% rename(flow = flow_pop)

# Each file has one row per county and month, and together they cover every
# month from January of the first year to December of the last
all_months <- format(seq(month_start(min(years), 1), month_start(max(years), 12), by = "month"), "%Y-%m")

stopifnot(
  anyDuplicated(rain[c("month", "region_id")]) == 0,
  anyDuplicated(flow[c("month", "region_id")]) == 0,
  setequal(rain$month, all_months),
  setequal(flow$month, all_months)
)


# -----------------------------
# Merge
# -----------------------------

# Both come from the same weights and admin list, so every county-month in one
# file should be in the other
monthly <- inner_join(rain, flow, by = c("month", "region_id"), relationship = "one-to-one")
stopifnot(nrow(monthly) == nrow(rain), nrow(monthly) == nrow(flow))
cat("County-months after merge:", nrow(monthly), "(all rows matched)\n")

n_territory <- n_distinct(monthly$region_id[monthly$ID_1 %in% territories])
monthly <- filter(monthly, !ID_1 %in% territories)
cat("Territory counties dropped:", n_territory, "\n")
cat("Counties kept:", n_distinct(monthly$region_id), "\n")

# Missing values are kept here and skipped in each statistic below. Flow can
# be negative, because its input is a residual (tp_total minus snow change).
cat("Missing rainfall county-months:", sum(is.na(monthly$rain)), "\n")
cat("Missing flow county-months:", sum(is.na(monthly$flow)), "\n")
cat("County-months with negative flow:", sum(monthly$flow < 0, na.rm = TRUE), "\n")

monthly <- monthly %>%
  mutate(
    year = as.integer(substr(month, 1, 4)),
    cal_month = as.integer(substr(month, 6, 7))
  )


# -----------------------------
# Extreme months
# -----------------------------

# Each county's top 5% of months by raw monthly value, separately for rainfall
# and flow. If the two were unrelated, about 95% of flow-extreme months would
# not be rainfall-extreme; if they always agreed, none would. Raw values keep
# the seasonal cycle, so extreme months fall mostly in each series' wet season.
monthly <- monthly %>%
  mutate(both_ok = !is.na(rain) & !is.na(flow)) %>%
  group_by(region_id) %>%
  mutate(
    rain_extreme = both_ok & rain >= quantile(rain[both_ok], 1 - extreme_share, names = FALSE),
    flow_extreme = both_ok & flow >= quantile(flow[both_ok], 1 - extreme_share, names = FALSE)
  ) %>%
  ungroup()

cat("County-months with both rainfall and flow:", sum(monthly$both_ok), "\n")


# -----------------------------
# Seasonal cycle
# -----------------------------

# Each county's mean for each calendar month over 1950-2025, and that month's
# share of the year's total. Flow shares can be negative in snowy months,
# because the flow input subtracts snow that builds up.
season_cycle <- monthly %>%
  filter(both_ok) %>%
  group_by(region_id, cal_month) %>%
  summarise(rain = mean(rain), flow = mean(flow), .groups = "drop") %>%
  group_by(region_id) %>%
  mutate(rain_share = rain / sum(rain), flow_share = flow / sum(flow)) %>%
  ungroup()

# Peak month = the calendar month with the highest mean. Alternative: the
# circular mean month, which is less sensitive to two near-equal months.
peaks <- season_cycle %>%
  group_by(region_id) %>%
  summarise(
    n_cal_months = n(),
    rain_peak_month = cal_month[which.max(rain)],
    flow_peak_month = cal_month[which.max(flow)],
    .groups = "drop"
  ) %>%
  # Shift from the rainfall peak to the flow peak, in months around the
  # calendar: -5 to 6, positive = flow peaks later
  mutate(
    peak_shift = (flow_peak_month - rain_peak_month) %% 12,
    peak_shift = ifelse(peak_shift > 6, peak_shift - 12, peak_shift)
  )


# -----------------------------
# County summary
# -----------------------------

# Upstream ratio = mean flow / mean rainfall. Over 1950-2025 the snow change
# in the flow input roughly nets out, so the ratio is mostly how much upstream
# rainfall is added to the county's own. A county with no upstream inflow
# has a ratio near 1.
county <- monthly %>%
  group_by(region_id) %>%
  summarise(
    rain_mean = mean(rain, na.rm = TRUE),
    flow_mean = mean(flow, na.rm = TRUE),
    n_months = sum(both_ok),
    # Correlation of the raw monthly series, seasonal cycle included
    corr = if (sum(both_ok) > 2) cor(rain[both_ok], flow[both_ok]) else NA_real_,
    n_flow_extreme = sum(flow_extreme),
    # Share of flow-extreme months that are not rainfall-extreme
    flow_extreme_missed = if (sum(flow_extreme) > 0) mean(!rain_extreme[flow_extreme]) else NA_real_,
    .groups = "drop"
  ) %>%
  mutate(upstream_ratio = flow_mean / rain_mean) %>%
  left_join(peaks, by = "region_id")

# Counties need a positive ratio (for the log scale), a correlation, at least
# one extreme month and all 12 calendar months
county_ok <- county %>%
  filter(
    is.finite(upstream_ratio), upstream_ratio > 0, is.finite(corr),
    is.finite(flow_extreme_missed), n_cal_months == 12
  )
cat("Counties in the comparison:", nrow(county_ok), "of", nrow(county), "\n")
cat("Dropped:", paste(setdiff(county$region_id, county_ok$region_id), collapse = ", "), "\n")

# Three equal-size groups by upstream ratio. Alternative: fixed cutoffs,
# e.g. ratio above 10.
county_ok <- county_ok %>% mutate(group = ntile(upstream_ratio, 3))

group_ranges <- county_ok %>%
  group_by(group) %>%
  summarise(ratio_min = min(upstream_ratio), ratio_max = max(upstream_ratio), .groups = "drop") %>%
  mutate(
    label_short = paste0(c("Low", "Middle", "High")[group], " (", fmt(ratio_min), " to ", fmt(ratio_max), ")")
  ) %>%
  # Keep groups in low-to-high order, not alphabetical
  mutate(label_short = factor(label_short, levels = label_short))

county_ok <- county_ok %>% left_join(select(group_ranges, group, label_short), by = "group")

write_csv(select(county_ok, -label_short), file.path(table_dir, "county_summary.csv"))

# Boundaries between the three groups, drawn in the figures against upstream ratio
group_cuts <- group_ranges$ratio_max[1:2]

# Ordinal blues for the three groups, light = low upstream ratio (steps 250,
# 450 and 650 of the dataviz reference blue ramp)
group_colors <- setNames(c("#86b6ef", "#2a78d6", "#104281"), levels(group_ranges$label_short))


# -----------------------------
# Group summary
# -----------------------------

summarise_group <- function(rows) {
  tibble(
    n_counties = nrow(rows),
    ratio_min = min(rows$upstream_ratio),
    ratio_median = median(rows$upstream_ratio),
    ratio_max = max(rows$upstream_ratio),
    corr_p10 = unname(quantile(rows$corr, 0.10)),
    corr_median = median(rows$corr),
    corr_p90 = unname(quantile(rows$corr, 0.90)),
    missed_median = median(rows$flow_extreme_missed),
    share_peak_shifted = mean(rows$peak_shift != 0),
    peak_shift_median = median(rows$peak_shift)
  )
}

group_summary <- bind_rows(
  lapply(1:3, function(g) {
    summarise_group(filter(county_ok, group == g)) %>% mutate(group = as.character(g), .before = 1)
  }),
  summarise_group(county_ok) %>% mutate(group = "all", .before = 1)
)

write_csv(group_summary, file.path(table_dir, "group_summary.csv"))
cat("\nGroup summary (raw monthly correlation, flow extremes missed, peak-month shift):\n")
print(as.data.frame(group_summary))

examples <- events %>%
  filter(example) %>%
  inner_join(county_ok, by = "region_id")
stopifnot(nrow(examples) == sum(events$example))


# -----------------------------
# Figure 2: where flow differs from rainfall
# -----------------------------

# Two measures against the upstream ratio: how closely the raw monthly series
# move together, and how often a flow-extreme month is not rainfall-extreme
measure_labels <- c(
  corr = "Correlation of monthly rainfall and rainfall_flow",
  missed = "% of flow-extreme months that are not rainfall-extreme"
)

county_long <- county_ok %>%
  transmute(region_id, upstream_ratio, corr, missed = 100 * flow_extreme_missed) %>%
  pivot_longer(c(corr, missed), names_to = "measure", values_to = "value") %>%
  mutate(measure = factor(measure_labels[measure], levels = measure_labels))

# Binned medians: 20 equal-size bins of log upstream ratio
bins <- county_long %>%
  group_by(measure) %>%
  mutate(bin = ntile(log10(upstream_ratio), 20)) %>%
  group_by(measure, bin) %>%
  summarise(upstream_ratio = median(upstream_ratio), value = median(value), .groups = "drop")

examples_long <- inner_join(select(examples, region_id, county), county_long, by = "region_id")

# Reference lines: zero correlation, and the share unrelated series would give
reference_lines <- tibble(
  measure = factor(measure_labels, levels = measure_labels),
  value = c(0, 100 * (1 - extreme_share))
)

fig_where <- ggplot(county_long, aes(upstream_ratio, value)) +
  geom_hline(data = reference_lines, aes(yintercept = value), colour = rule) +
  geom_vline(xintercept = group_cuts, colour = shade) +
  geom_point(colour = col_rain, alpha = 0.3, size = 0.7, stroke = 0) +
  geom_line(data = bins, colour = ink, linewidth = 0.7) +
  geom_point(data = bins, colour = ink, size = 1.1) +
  geom_point(data = examples_long, colour = ink, shape = 21, fill = "white", size = 1.8) +
  geom_text(data = examples_long, aes(label = county), colour = ink, size = 2.6, hjust = 0, nudge_x = 0.05) +
  facet_wrap(~ measure, ncol = 1, scales = "free_y") +
  scale_x_log10(labels = scales::label_comma()) +
  labs(
    title = "Where rainfall_flow differs from local rainfall",
    x = "Upstream ratio: mean flow / mean rainfall (log scale)",
    y = NULL,
    caption = paste0(
      "One point per county, raw monthly values 1950-2025. Black line: median in 20 equal-size bins.\n",
      "Vertical lines: boundaries of the low / middle / high upstream-ratio groups.\n",
      "Bottom: extreme = a county's top ", 100 * extreme_share, "% of months; the gray line at ",
      100 * (1 - extreme_share), "% is what unrelated series would give."
    )
  )

save_figure("2_where_flow_differs", fig_where, width = 6.5, height = 7)


# -----------------------------
# Figure 3: correlation by calendar month
# -----------------------------

# One correlation per county and calendar month: that month's raw values
# across 1950-2025. In counties with little upstream water, a seasonal dip
# points to snow (flow counts snow when it melts, rainfall when it falls). A
# gap that holds in every month points to routing.
seasonal <- monthly %>%
  filter(both_ok) %>%
  inner_join(select(county_ok, region_id, label_short), by = "region_id") %>%
  group_by(region_id, label_short, cal_month) %>%
  summarise(
    corr = if (n() > 2 && sd(rain) > 0 && sd(flow) > 0) cor(rain, flow) else NA_real_,
    .groups = "drop"
  )

seasonal_summary <- seasonal %>%
  group_by(label_short, cal_month) %>%
  summarise(
    n_counties = sum(!is.na(corr)),
    corr_p25 = quantile(corr, 0.25, na.rm = TRUE, names = FALSE),
    corr_median = median(corr, na.rm = TRUE),
    corr_p75 = quantile(corr, 0.75, na.rm = TRUE, names = FALSE),
    .groups = "drop"
  )

write_csv(seasonal_summary, file.path(table_dir, "seasonal_correlation.csv"))

fig_seasonal <- ggplot(seasonal_summary, aes(cal_month, corr_median, colour = label_short, fill = label_short)) +
  geom_ribbon(aes(ymin = corr_p25, ymax = corr_p75), alpha = 0.12, colour = NA) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.4) +
  scale_x_continuous(breaks = 1:12, labels = month.abb) +
  scale_colour_manual(values = group_colors, name = "Upstream ratio") +
  scale_fill_manual(values = group_colors, guide = "none") +
  labs(
    title = "Correlation of rainfall and rainfall_flow, by calendar month",
    x = NULL,
    y = "Correlation across years",
    caption = paste0(
      "One correlation per county and calendar month: that month's values across 1950-2025.\n",
      "Line: median county in each upstream-ratio group. Band: 25th to 75th percentile of counties."
    )
  ) +
  theme(legend.title = element_text(colour = ink_2))

save_figure("3_seasonal_correlation", fig_seasonal, width = 6.5, height = 4.2)


# -----------------------------
# Figure 4: seasonal cycle
# -----------------------------

profile <- season_cycle %>%
  inner_join(select(county_ok, region_id, label_short), by = "region_id") %>%
  select(region_id, label_short, cal_month, Rainfall = rain_share, rainfall_flow = flow_share) %>%
  pivot_longer(c(Rainfall, rainfall_flow), names_to = "series", values_to = "share") %>%
  group_by(label_short, series, cal_month) %>%
  summarise(
    share_p25 = quantile(share, 0.25, names = FALSE),
    share_median = median(share),
    share_p75 = quantile(share, 0.75, names = FALSE),
    .groups = "drop"
  )

write_csv(profile, file.path(table_dir, "seasonal_profile.csv"))

fig_profile <- ggplot(profile, aes(cal_month, 100 * share_median, colour = series, fill = series)) +
  geom_hline(yintercept = 100 / 12, colour = rule) +
  geom_ribbon(aes(ymin = 100 * share_p25, ymax = 100 * share_p75), alpha = 0.12, colour = NA) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.2) +
  facet_wrap(~ label_short, nrow = 1) +
  scale_x_continuous(breaks = c(1, 4, 7, 10), labels = month.abb[c(1, 4, 7, 10)]) +
  scale_colour_manual(values = series_colors) +
  scale_fill_manual(values = series_colors, guide = "none") +
  labs(
    title = "Seasonal cycle of rainfall and rainfall_flow",
    x = NULL,
    y = "% of the year's total",
    caption = paste0(
      "Each county's mean for each calendar month over 1950-2025, as a share of its year.\n",
      "Line: median county in each upstream-ratio group. Band: 25th to 75th percentile of counties.\n",
      "Gray line: an even year (", sprintf("%.1f", 100 / 12), "% per month)."
    )
  )

save_figure("4_seasonal_profile", fig_profile, width = 6.5, height = 3.6)


# -----------------------------
# Drought and flood measures (annual)
# -----------------------------

# The mortality regressions are annual, and the flow enters them as the
# drought and flood measures from ../02_make_drought_flood.py:
#   flowmean_pop_annual  annual mean of the 12 monthly county values (drought)
#   flowmax_pop_annual   each cell's highest month, then the county mean (flood)
# Each is compared with the rainfall the regressions already have: the annual
# total (prcp_pop_p1, sum of daily rainfall), prcp_pop_p2 (sum of squared
# daily rainfall), and each year's wettest month of county rainfall. There is
# no rainfall version of the cell-level max, so the wettest county month
# stands in for it. All statistics are within one county across its years.

read_rain_annual <- function(year) {
  read_csv(
    file.path(rain_annual_dir, paste0("era5land_usa_adm2_annual_", year, ".csv")),
    col_types = cols_only(year = "i", region_id = "c", prcp_pop_p1 = "d", prcp_pop_p2 = "d"),
    progress = FALSE
  )
}

read_flow_annual <- function(year) {
  read_csv(
    file.path(flow_annual_dir, paste0("era5land_usa_adm2_flow_annual_", year, ".csv")),
    col_types = cols_only(year = "i", region_id = "c", flowmean_pop_annual = "d", flowmax_pop_annual = "d"),
    progress = FALSE
  )
}

rain_annual <- bind_rows(lapply(years, read_rain_annual))
flow_annual <- bind_rows(lapply(years, read_flow_annual))

stopifnot(
  anyDuplicated(rain_annual[c("year", "region_id")]) == 0,
  anyDuplicated(flow_annual[c("year", "region_id")]) == 0
)

# Complete years only, the same rule as 02_make_drought_flood.py. The monthly
# flow mean and max are kept only to check the annual files against.
annual <- monthly %>%
  group_by(region_id, year) %>%
  summarise(
    n_months = sum(both_ok),
    rain_total = sum(rain),
    rain_max = max(rain),
    flow_month_mean = mean(flow),
    flow_month_max = max(flow),
    # Calendar month of each year's biggest month. flowmax_pop_annual takes
    # each cell's max, so it has no single month; the county's biggest month
    # stands in for it. Ties go to the earlier month. [1] gives NA when every
    # month is missing; those years are dropped by the complete-year filter.
    rain_max_month = cal_month[which.max(rain)][1],
    flow_max_month = cal_month[which.max(flow)][1],
    .groups = "drop"
  ) %>%
  filter(n_months == 12) %>%
  inner_join(rain_annual, by = c("region_id", "year"), relationship = "one-to-one") %>%
  inner_join(flow_annual, by = c("region_id", "year"), relationship = "one-to-one") %>%
  inner_join(select(county_ok, region_id, group, upstream_ratio), by = "region_id")

# The annual files should agree with the monthly ones: the same rainfall total
# and flow mean, and a cell-level max at least as high as the wettest county
# month (a mean of each cell's max cannot be below the max of the means)
stopifnot(
  !anyNA(annual[c("prcp_pop_p1", "prcp_pop_p2", "flowmean_pop_annual", "flowmax_pop_annual")]),
  isTRUE(all.equal(annual$prcp_pop_p1, annual$rain_total)),
  isTRUE(all.equal(annual$flowmean_pop_annual, annual$flow_month_mean)),
  all(annual$flowmax_pop_annual >= annual$flow_month_max - 1e-9 * abs(annual$flow_month_max))
)

cat("\nCounty-years in the drought and flood comparison:", nrow(annual), "\n")
cat(
  "Median flowmax_pop_annual / wettest county month of flow:",
  median(annual$flowmax_pop_annual / annual$flow_month_max), "\n"
)

# If flow and rainfall were unrelated, about 90% of a county's flow drought
# (or flood) years would not be rainfall drought (or wettest-month) years
annual_county <- annual %>%
  group_by(region_id, group, upstream_ratio) %>%
  mutate(
    flow_drought = flowmean_pop_annual <= quantile(flowmean_pop_annual, extreme_year_share, names = FALSE),
    rain_drought = prcp_pop_p1 <= quantile(prcp_pop_p1, extreme_year_share, names = FALSE),
    flow_flood = flowmax_pop_annual >= quantile(flowmax_pop_annual, 1 - extreme_year_share, names = FALSE),
    rain_flood = rain_max >= quantile(rain_max, 1 - extreme_year_share, names = FALSE)
  ) %>%
  summarise(
    n_years = n(),
    corr_drought = cor(flowmean_pop_annual, prcp_pop_p1),
    # Flood correlation with both measures built the same way: the biggest
    # month of the county's monthly series, as the drought correlation uses
    # the mean of the same series. flowmax_pop_annual takes each cell's max
    # first and has no rainfall version; for flow the two are close (median
    # ratio printed above). The other flood statistics below use
    # flowmax_pop_annual, the variable that enters the regressions.
    corr_flood = cor(flow_month_max, rain_max),
    # Share of years in which flow's biggest month is rainfall's biggest month
    peak_month_match = mean(flow_max_month == rain_max_month),
    # Whether the drought and flood measures move separately, in flow and,
    # for reference, in rainfall
    corr_flow_mean_max = cor(flowmean_pop_annual, flowmax_pop_annual),
    corr_rain_total_max = cor(prcp_pop_p1, rain_max),
    # Share of each flow measure's year-to-year variance that local rainfall
    # does not explain: 1 - R^2 of a regression, in this county, on the annual
    # total, the squared-daily term and the wettest month. This is what flow
    # adds to a regression that already has rainfall. R^2 rises by chance
    # with three regressors, so this slightly understates what flow adds.
    unexplained_drought = 1 - summary(lm(flowmean_pop_annual ~ prcp_pop_p1 + prcp_pop_p2 + rain_max))$r.squared,
    unexplained_flood = 1 - summary(lm(flowmax_pop_annual ~ prcp_pop_p1 + prcp_pop_p2 + rain_max))$r.squared,
    drought_missed = mean(!rain_drought[flow_drought]),
    flood_missed = mean(!rain_flood[flow_flood]),
    # Within-county sums of squares of the raw levels, for the variance shares below
    ss_rain = sum((prcp_pop_p1 - mean(prcp_pop_p1))^2),
    ss_flowmean = sum((flowmean_pop_annual - mean(flowmean_pop_annual))^2),
    ss_flowmax = sum((flowmax_pop_annual - mean(flowmax_pop_annual))^2),
    .groups = "drop"
  )

write_csv(annual_county, file.path(table_dir, "annual_county.csv"))

annual_measures <- c(
  "corr_drought", "corr_flood", "peak_month_match", "corr_flow_mean_max", "corr_rain_total_max",
  "unexplained_drought", "unexplained_flood", "drought_missed", "flood_missed"
)

summarise_annual <- function(rows, g) {
  bind_rows(lapply(annual_measures, function(m) {
    tibble(
      group = g,
      measure = m,
      n_counties = sum(!is.na(rows[[m]])),
      p10 = quantile(rows[[m]], 0.10, na.rm = TRUE, names = FALSE),
      median = median(rows[[m]], na.rm = TRUE),
      p90 = quantile(rows[[m]], 0.90, na.rm = TRUE, names = FALSE)
    )
  }))
}

annual_corr <- bind_rows(
  lapply(1:3, function(g) summarise_annual(filter(annual_county, group == g), as.character(g))),
  summarise_annual(annual_county, "all")
)

write_csv(annual_corr, file.path(table_dir, "annual_correlation.csv"))
cat("\nDrought and flood measures vs rainfall (one value per county, then across counties):\n")
print(as.data.frame(annual_corr))

# Share of the pooled within-county variance of raw levels that each set of
# counties contributes. With county fixed effects and flow in raw levels, a
# regression is identified from the counties with a large share.
share_of_total <- function(rows, g) {
  tibble(
    group = g,
    n_counties = nrow(rows),
    rain = sum(rows$ss_rain) / sum(annual_county$ss_rain),
    flowmean = sum(rows$ss_flowmean) / sum(annual_county$ss_flowmean),
    flowmax = sum(rows$ss_flowmax) / sum(annual_county$ss_flowmax)
  )
}

variance_share <- bind_rows(
  lapply(1:3, function(g) share_of_total(filter(annual_county, group == g), as.character(g))),
  share_of_total(filter(annual_county, upstream_ratio >= quantile(upstream_ratio, 0.99)), "top 1%")
)

write_csv(variance_share, file.path(table_dir, "annual_variance_share.csv"))
cat("\nShare of pooled within-county variance of raw annual levels:\n")
print(as.data.frame(variance_share))


# -----------------------------
# Figure 9: what the drought and flood measures add to rainfall
# -----------------------------

unexplained_labels <- c(
  unexplained_drought = "Drought measure: annual mean of rainfall_flow",
  unexplained_flood = "Flood measure: annual max of rainfall_flow"
)

unexplained_long <- annual_county %>%
  select(region_id, upstream_ratio, all_of(names(unexplained_labels))) %>%
  pivot_longer(all_of(names(unexplained_labels)), names_to = "measure", values_to = "value") %>%
  mutate(value = 100 * value, measure = factor(unexplained_labels[measure], levels = unexplained_labels))

# Binned medians: 20 equal-size bins of log upstream ratio, as in figure 2
unexplained_bins <- unexplained_long %>%
  group_by(measure) %>%
  mutate(bin = ntile(log10(upstream_ratio), 20)) %>%
  group_by(measure, bin) %>%
  summarise(upstream_ratio = median(upstream_ratio), value = median(value), .groups = "drop")

fig_unexplained <- ggplot(unexplained_long, aes(upstream_ratio, value)) +
  geom_vline(xintercept = group_cuts, colour = shade) +
  geom_point(colour = col_rain, alpha = 0.3, size = 0.7, stroke = 0) +
  geom_line(data = unexplained_bins, colour = ink, linewidth = 0.7) +
  geom_point(data = unexplained_bins, colour = ink, size = 1.1) +
  facet_wrap(~ measure, ncol = 1) +
  scale_x_log10(labels = scales::label_comma()) +
  labs(
    title = "What the flow drought and flood measures add to local rainfall",
    x = "Upstream ratio: mean flow / mean rainfall (log scale)",
    y = "% of year-to-year variation not explained by rainfall",
    caption = paste0(
      "One point per county, 1950-2025: 1 - R-squared of the flow measure regressed on the county's annual\n",
      "rainfall total, sum of squared daily rainfall and wettest month. Black line: median in 20 equal-size bins.\n",
      "Vertical lines: boundaries of the low / middle / high upstream-ratio groups."
    )
  )

save_figure("9_drought_flood", fig_unexplained, width = 6.5, height = 6)


# -----------------------------
# Flood windows, all counties
# -----------------------------

event_windows <- events %>%
  distinct(event, event_short, event_label, year, first_month, last_month) %>%
  rename(event_year = year)

# Flood-month totals in every year and county, one block per event. A year
# with any missing month in the window is left out.
window_totals <- bind_rows(lapply(seq_len(nrow(event_windows)), function(i) {
  e <- event_windows[i, ]
  monthly %>%
    filter(cal_month >= e$first_month, cal_month <= e$last_month) %>%
    group_by(region_id, year) %>%
    summarise(Rainfall = sum(rain), rainfall_flow = sum(flow), .groups = "drop") %>%
    pivot_longer(c(Rainfall, rainfall_flow), names_to = "series", values_to = "total") %>%
    filter(!is.na(total)) %>%
    mutate(event = e$event, event_year = e$event_year)
}))

# For the event year: rank among 1950-2025 (1 = highest), percentile
# (100 = highest), and total relative to the county's median year
event_years <- window_totals %>%
  group_by(event, region_id, series) %>%
  mutate(n_years = n(), median_total = median(total), rank = rank(-total, ties.method = "min")) %>%
  ungroup() %>%
  filter(year == event_year) %>%
  mutate(
    percentile = 100 * (n_years - rank) / (n_years - 1),
    ratio_to_median = total / median_total
  ) %>%
  left_join(select(event_windows, event, event_short, event_label), by = "event")

# Every county, for the event maps in 02_rain_vs_flow_maps.R
write_csv(
  select(event_years, event, event_short, region_id, series, total, median_total, ratio_to_median, rank, n_years, percentile),
  file.path(table_dir, "event_percentiles.csv")
)

# Case-study counties only, in the order of the events table (upstream to downstream)
event_ranks <- event_years %>%
  inner_join(select(events, event, region_id, county), by = c("event", "region_id")) %>%
  select(event, event_label, county, region_id, year, series, total, median_total, ratio_to_median, rank, n_years, percentile) %>%
  arrange(match(region_id, events$region_id), series)

# Every case-study county should have both a rainfall and a flow rank
stopifnot(nrow(event_ranks) == 2 * nrow(events))

write_csv(event_ranks, file.path(table_dir, "event_ranks.csv"))
cat("\nFlood-window ranks (1 = highest of 1950-2025):\n")
print(as.data.frame(select(event_ranks, event, county, series, rank, n_years, ratio_to_median)))


# -----------------------------
# Figure 7: case-study time series
# -----------------------------

# One example county per event: the year before to the year after the event
example_events <- events %>%
  filter(example) %>%
  mutate(panel = factor(paste0(event, ": ", county), levels = paste0(event, ": ", county)))

# Each series is divided by the county's mean month over 1950-2025, so
# rainfall (mm) and flow (mm summed over upstream cells) share one axis.
# 1 = an average month; the seasonal cycle stays in.
case_ts <- monthly %>%
  inner_join(
    select(example_events, event, panel, event_year = year, region_id, county),
    by = "region_id"
  ) %>%
  group_by(region_id) %>%
  mutate(rain_rel = rain / mean(rain, na.rm = TRUE), flow_rel = flow / mean(flow, na.rm = TRUE)) %>%
  ungroup() %>%
  filter(year >= event_year - 1, year <= event_year + 1)

write_csv(
  select(case_ts, event, county, region_id, month, rain, flow, rain_rel, flow_rel),
  file.path(table_dir, "case_timeseries.csv")
)

case_ts_long <- case_ts %>%
  mutate(date = as.Date(paste0(month, "-15"))) %>%
  select(panel, date, Rainfall = rain_rel, rainfall_flow = flow_rel) %>%
  pivot_longer(c(Rainfall, rainfall_flow), names_to = "series", values_to = "relative")

# Shade the flood months, from the first day of the first month to the first
# day of the month after the last
case_windows <- example_events %>%
  mutate(
    start = month_start(year, first_month),
    end = month_start(year, last_month + 1)
  )

fig_ts <- ggplot(case_ts_long, aes(date, relative, colour = series)) +
  geom_rect(
    data = case_windows, aes(xmin = start, xmax = end, ymin = -Inf, ymax = Inf),
    fill = shade, alpha = 0.6, inherit.aes = FALSE
  ) +
  geom_hline(yintercept = 1, colour = rule) +
  geom_line(linewidth = 0.6) +
  geom_point(size = 0.9) +
  facet_wrap(~ panel, ncol = 1, scales = "free") +
  scale_colour_manual(values = series_colors) +
  # Breaks every January and July. Breaks near the right edge are dropped so
  # the last label is not clipped.
  scale_x_date(
    breaks = function(lims) {
      candidates <- seq(
        as.Date(paste0(format(lims[1], "%Y"), "-01-01")),
        as.Date(paste0(format(lims[2], "%Y"), "-07-01")),
        by = "6 months"
      )
      candidates[candidates >= lims[1] & candidates <= lims[2] - 45]
    },
    date_labels = "%b %Y"
  ) +
  labs(
    title = "Monthly rainfall and rainfall_flow around four floods",
    x = NULL,
    y = "Monthly value / county's mean month",
    caption = paste0(
      "Each series divided by its own 1950-2025 mean month, so both share one axis (1 = an average month).\n",
      "Shaded: main flood months (from the historical record, not from data). One example county per event."
    )
  )

save_figure("7_case_timeseries", fig_ts, width = 6.5, height = 8)


# -----------------------------
# Figure 8: flood-month totals in every year
# -----------------------------

# The full record for the example counties: each year's flood-month total
# relative to the county's median year, so the event year can be seen against
# every other year
example_history <- window_totals %>%
  semi_join(example_events, by = c("event", "region_id")) %>%
  group_by(region_id, series) %>%
  mutate(ratio_to_median = total / median(total)) %>%
  ungroup()

# Panel titles carry the ranks, so they need no labels inside the plot
example_titles <- event_ranks %>%
  semi_join(example_events, by = "region_id") %>%
  select(region_id, series, rank, n_years) %>%
  pivot_wider(names_from = series, values_from = c(rank, n_years)) %>%
  left_join(select(example_events, region_id, panel, event_year = year), by = "region_id") %>%
  arrange(match(region_id, example_events$region_id)) %>%
  mutate(title = paste0(
    panel, "\n", event_year, " ranks ", rank_Rainfall, " of ", n_years_Rainfall,
    " in rainfall and ", rank_rainfall_flow, " of ", n_years_rainfall_flow, " in flow"
  )) %>%
  mutate(title = factor(title, levels = title))

example_history <- example_history %>%
  left_join(select(example_titles, region_id, title), by = "region_id")
event_points <- filter(example_history, year == event_year)

fig_record <- ggplot(example_history, aes(year, ratio_to_median, colour = series)) +
  geom_vline(data = example_titles, aes(xintercept = event_year), colour = shade, linewidth = 2.5) +
  geom_hline(yintercept = 1, colour = rule) +
  geom_line(linewidth = 0.5) +
  geom_point(data = event_points, size = 2) +
  facet_wrap(~ title, ncol = 1, scales = "free_y") +
  scale_colour_manual(values = series_colors) +
  scale_x_continuous(breaks = seq(1950, 2020, by = 10)) +
  labs(
    title = "Flood-month totals in every year, 1950-2025",
    x = NULL,
    y = "Total over the flood months / median year",
    caption = paste0(
      "Flood-month total in each year divided by the county's median year (1 = a typical year).\n",
      "Shaded line and dots: the event year. Rank 1 = highest of 1950-2025.\n",
      "One example county per event; the ranks for all case-study counties are in the report table."
    )
  )

save_figure("8_event_record", fig_record, width = 6.5, height = 8)


# -----------------------------
# Appendix figure A1: levels
# -----------------------------

fig_levels <- ggplot(county_ok, aes(rain_mean, flow_mean)) +
  geom_abline(slope = 1, intercept = 0, colour = rule) +
  geom_point(colour = col_rain, alpha = 0.35, size = 0.8, stroke = 0) +
  geom_point(data = examples, colour = ink, size = 1.6) +
  geom_text(data = examples, aes(label = county), colour = ink, size = 2.8, hjust = 0, nudge_x = 0.03) +
  scale_x_log10(labels = scales::label_comma()) +
  scale_y_log10(labels = scales::label_comma()) +
  labs(
    title = "County mean monthly rainfall and rainfall_flow, 1950-2025",
    x = "Mean monthly rainfall (mm, log scale)",
    y = "Mean monthly rainfall_flow\n(mm summed over upstream cells, log scale)",
    caption = paste0(
      "One point per county (", nrow(county_ok), "). Gray line: flow equals local rainfall, ",
      "i.e. no water from upstream.\nLabelled: example counties from the case studies. ",
      "Both series population-weighted."
    )
  )

save_figure("A1_levels", fig_levels, width = 6.5, height = 4.5)

cat("\nFigures written to:", fig_dir, "\n")
cat("Tables written to:", table_dir, "\n")
