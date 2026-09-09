# ==============================================================================
# Compare Young-Hsiang wind with ERA5-Land wind
#
# This script uses the Young-Hsiang state-month mortality panel after adding
# ERA5-Land wind. The comparison uses `windmax_area_month`, because Young and
# Hsiang spatially average storm exposure across state pixels (using area weifghts)xs

# It checks whether ERA5-Land wind moves with Young and Hsiang's
# tropical-cyclone wind variable, `maxs`.
#
# Unit: U.S. state-month, for the 36 states in the Young-Hsiang panel
# Unique IDs: `stfips`, `year`, `month`
# Years compared: 1950-2015
# Wind units: meters per second
#
# Input:
# `young_hsiang_state_month_era5land_wind_1950_2015.csv`
#
# Output:
# `era5land_vs_young_hsiang_wind_checks.xlsx`

# ==============================================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(writexl)
})


# -----------------------------
# Paths
# -----------------------------

# The panel location is resolved in _wind_common.R (env var, then the cluster
# path, then a local mirror), so this check and the regressions in 02-04 cannot
# end up reading different copies of the panel.
.adhoc <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a) == 1) dirname(normalizePath(sub("^--file=", "", a))) else normalizePath(getwd())
  while (!file.exists(file.path(d, "_common.R")) && dirname(d) != d) d <- dirname(d)
  d
})
source(file.path(.adhoc, "_common.R"))
source(file.path(.adhoc, "wind_tc_validation", "_wind_common.R"))

panel_file <- PANEL_CSV

# the checks workbook lives beside the panel it describes, wherever that is
workbook_file <- file.path(
  dirname(panel_file),
  "checks",
  "era5land_vs_young_hsiang_wind_checks.xlsx"
)

dir.create(dirname(workbook_file), recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Read inputs
# -----------------------------

# Read the merged Young-Hsiang and ERA5-Land state-month panel.
panel <- read_csv(panel_file, show_col_types = FALSE)


# -----------------------------
# Prepare comparison sample
# -----------------------------

# Compare only the years where ERA5-Land wind is available
wind_panel <- panel %>%
  filter(year >= 1950, year <= 2015) %>%
  mutate(
    maxs = as.numeric(maxs),
    pddi = as.numeric(pddi),
    windmax_pop_month = as.numeric(windmax_pop_month),
    windmax_area_month = as.numeric(windmax_area_month),
    yh_tc_month = !is.na(maxs) & maxs > 0
  )


# -----------------------------
# Coverage
# -----------------------------

# Check coverage of the ERA5-Land wind variables across the state-month panel.
coverage <- wind_panel %>%
  summarize(
    rows = n(),
    states = n_distinct(stfips),
    first_year = min(year),
    last_year = max(year),
    missing_windmax_pop_month = sum(is.na(windmax_pop_month)),
    missing_windmax_area_month = sum(is.na(windmax_area_month)),
    young_hsiang_tc_months = sum(yh_tc_month),
    share_young_hsiang_tc_months = mean(yh_tc_month)
  )


# -----------------------------
# Overall relationship
# -----------------------------

# Put the summary in four rows so `maxs` and ERA5-Land wind are easy to compare.
# The ERA5-Land row uses the area-weighted state-month wind variable.
summary_table <- bind_rows(
  wind_panel %>%
    filter(yh_tc_month) %>%
    summarize(
      sample = "Young-Hsiang TC months only",
      variable = "Young-Hsiang maxs",
      rows = n(),
      states = n_distinct(stfips),
      mean = mean(maxs, na.rm = TRUE),
      p50 = quantile(maxs, 0.50, na.rm = TRUE),
      p90 = quantile(maxs, 0.90, na.rm = TRUE),
      p99 = quantile(maxs, 0.99, na.rm = TRUE),
      max = max(maxs, na.rm = TRUE)
    ),
  wind_panel %>%
    filter(yh_tc_month) %>%
    summarize(
      sample = "Young-Hsiang TC months only",
      variable = "ERA5-Land wind, area-weighted",
      rows = n(),
      states = n_distinct(stfips),
      mean = mean(windmax_area_month, na.rm = TRUE),
      p50 = quantile(windmax_area_month, 0.50, na.rm = TRUE),
      p90 = quantile(windmax_area_month, 0.90, na.rm = TRUE),
      p99 = quantile(windmax_area_month, 0.99, na.rm = TRUE),
      max = max(windmax_area_month, na.rm = TRUE)
    ),
  wind_panel %>%
    summarize(
      sample = "all state-months",
      variable = "Young-Hsiang maxs",
      rows = n(),
      states = n_distinct(stfips),
      mean = mean(maxs, na.rm = TRUE),
      p50 = quantile(maxs, 0.50, na.rm = TRUE),
      p90 = quantile(maxs, 0.90, na.rm = TRUE),
      p99 = quantile(maxs, 0.99, na.rm = TRUE),
      max = max(maxs, na.rm = TRUE)
    ),
  wind_panel %>%
    summarize(
      sample = "all state-months",
      variable = "ERA5-Land wind, area-weighted",
      rows = n(),
      states = n_distinct(stfips),
      mean = mean(windmax_area_month, na.rm = TRUE),
      p50 = quantile(windmax_area_month, 0.50, na.rm = TRUE),
      p90 = quantile(windmax_area_month, 0.90, na.rm = TRUE),
      p99 = quantile(windmax_area_month, 0.99, na.rm = TRUE),
      max = max(windmax_area_month, na.rm = TRUE)
    )
  ) %>%
  mutate(
    corr_maxs_era5land_area = c(
      cor(
        wind_panel$maxs[wind_panel$yh_tc_month],
        wind_panel$windmax_area_month[wind_panel$yh_tc_month],
        use = "complete.obs"
      ),
      NA_real_,
      cor(wind_panel$maxs, wind_panel$windmax_area_month, use = "complete.obs"),
      NA_real_
    )
  )


# -----------------------------
# Young-Hsiang wind bins
# -----------------------------

# Group state-months by `maxs` to check whether ERA5-Land wind increases with
# stronger tropical-cyclone wind
maxs_bins <- wind_panel %>%
  mutate(
    maxs_bin = cut(
      coalesce(maxs, 0),
      breaks = c(-Inf, 0, 5, 10, 17.5, 25, 35, Inf),
      labels = c("0", "(0, 5]", "(5, 10]", "(10, 17.5]", "(17.5, 25]", "(25, 35]", ">35"),
      right = TRUE
    )
  ) %>%
  group_by(maxs_bin) %>%
  summarize(
    state_months = n(),
    mean_maxs = mean(maxs, na.rm = TRUE),
    max_maxs = max(maxs, na.rm = TRUE),
    mean_windmax_area_month = mean(windmax_area_month, na.rm = TRUE),
    p90_windmax_area_month = quantile(windmax_area_month, 0.90, na.rm = TRUE),
    max_windmax_area_month = max(windmax_area_month, na.rm = TRUE),
    .groups = "drop"
  )


# -----------------------------
# Top-month checks
# -----------------------------

# Check ERA5-Land wind in the months with the highest Young-Hsiang `maxs`
top_young_hsiang_maxs <- wind_panel %>%
  arrange(desc(maxs)) %>%
  select(
    state_abbrev, adm_name, year, month,
    maxs, pddi, windmax_area_month
  ) %>%
  slice_head(n = 50)


# Check whether the highest ERA5-Land wind months also have positive
# Young-Hsiang tropical-cyclone wind.
top_era5land_wind <- wind_panel %>%
  arrange(desc(windmax_area_month)) %>%
  select(
    state_abbrev, adm_name, year, month,
    maxs, pddi, windmax_area_month
  ) %>%
  slice_head(n = 50)


# -----------------------------
# Write workbook
# -----------------------------

# Keep the checks together in one file
write_xlsx(
  list(
    coverage = coverage,
    summary = summary_table,
    maxs_bins = maxs_bins,
    top_young_hsiang_maxs = top_young_hsiang_maxs,
    top_era5land_wind = top_era5land_wind
  ),
  workbook_file
)

message("created ", workbook_file)
