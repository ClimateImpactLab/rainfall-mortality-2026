# ============================================================================
# 01_build_monthly_measures.R
#
# Monthly drought measures for each Brazil municipality, from
# ERA5-Land monthly rainfall, 1950-2024:
#   - SPI over the last 1, 3, 6 and 12 months (spi01 ... spi12)
#   - 6-month rainfall at or below the 1981-2010 p10 / p5 (dry10_6m, dry05_6m)
#
# Every measure compares a month with the same calendar month in 1981-2010
# (for ex rainfall in Apr-Sep 2003 vs rainfall in Apr-Sep of each baseline year), so
# seasonality is taken out. SPI and percentiles are built as in
# annual_1997_2010/01_measures/02 and 03.
#
# The file covers all years so the same measures serve the 1997-2010 and
# 2000-2024 monthly panels, with enough earlier months for 11 lags.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/brazil_monthly/brazil_monthly_drought_measures_stable.rds
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(data.table)


# -----------------------------
# Paths and settings
# -----------------------------

# ERA5-Land monthly rainfall for each municipality (one CSV per year), and
# where the measures are saved
CLIMATE_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data"
MONTHLY_DIR <- file.path(CLIMATE_DIR, "ERA5-LAND-GLOBAL/BRA_STABLE/monthly")
OUTPUT_DIR <- file.path(CLIMATE_DIR, "ERA5-LAND/drought/brazil_monthly")
OUTPUT_FILE <- file.path(OUTPUT_DIR, "brazil_monthly_drought_measures_stable.rds")

# Baseline for SPI and the percentiles, and the rolling windows
BASELINE_START <- 1981
BASELINE_END <- 2010
WINDOWS <- c(1, 3, 6, 12) # months of rainfall in each measure
P_MIN <- 1e-4 # SPI capped at about +/-3.7, as in annual_1997_2010/01_measures/03

# The file is saved only with --write
write_output <- "--write" %in% commandArgs(trailingOnly = TRUE)


# -----------------------------
# Small functions
# -----------------------------

# SPI from a mixed gamma fit (same as annual_1997_2010/01_measures/03)
spi_from_gamma <- function(rain, zero_share, shape, rate) {
  p <- ifelse(rain <= 0, zero_share, zero_share + (1 - zero_share) * pgamma(rain, shape = shape, rate = rate))
  qnorm(pmin(pmax(p, P_MIN), 1 - P_MIN))
}

# Mid-rank percentile vs the baseline values (same as annual_1997_2010/01_measures/02)
midrank_percentile <- function(value, baseline_values) {
  if (is.na(value) || length(baseline_values) == 0) return(NA_real_)
  (sum(baseline_values < value) + 0.5 * sum(baseline_values == value)) / length(baseline_values)
}


# -----------------------------
# Read monthly rainfall
# -----------------------------

# One CSV per year. Keep the municipality, the month and the monthly
# rainfall total (population-weighted, in mm)
files <- list.files(MONTHLY_DIR, pattern = "_monthly_[0-9]{4}\\.csv$", full.names = TRUE)

monthly <- rbindlist(lapply(files, fread, select = c("month", "stable_admin_id", "prcp_pop_p1"))) %>%
  as_tibble() %>%
  transmute(
    admin_id = as.character(stable_admin_id),
    year = as.integer(substr(month, 1, 4)),
    month = as.integer(substr(month, 6, 7)),
    # Months counted in a row (year x 12 + month), to check that a rolling
    # window has no gap
    month_index = year * 12 + month,
    rain_mm = prcp_pop_p1
  ) %>%
  arrange(admin_id, month_index)

# Number of municipalities and years read, to the log
message(n_distinct(monthly$admin_id), " admin units, ", min(monthly$year), "-", max(monthly$year))


# ---------------------------------------
# Rain over the last 1, 3, 6, 12 months
# ---------------------------------------

# Rolling sums ending in the current month
# Missing if the months are not consecutive (a gap in the series)
for (window in WINDOWS) {
  monthly <- monthly %>%
    group_by(admin_id) %>%
    mutate("rain_{window}m" := if_else(
      month_index - lag(month_index, window - 1) == window - 1,
      as.numeric(stats::filter(rain_mm, rep(1, window), sides = 1)),
      NA_real_
    )) %>%
    ungroup()
}

# One row per admin x month x window
rain_long <- monthly %>%
  select(admin_id, year, month, matches("^rain_[0-9]+m$")) %>%
  pivot_longer(matches("^rain_[0-9]+m$"), names_to = "window", values_to = "rain") %>%
  mutate(window = as.integer(gsub("\\D", "", window)))


# -----------------------------
# Baseline: same calendar month, 1981-2010
# -----------------------------

# Gamma fit by method of moments, plus the baseline values for percentiles
# One baseline per admin x calendar month x window
baseline <- rain_long %>%
  filter(year >= BASELINE_START, year <= BASELINE_END, !is.na(rain)) %>%
  group_by(admin_id, month, window) %>%
  summarise(
    baseline_values = list(rain),
    zero_share = mean(rain <= 0),
    pos_mean = mean(rain[rain > 0]),
    pos_var = var(rain[rain > 0]),
    .groups = "drop"
  ) %>%
  mutate(shape = pos_mean^2 / pos_var, rate = pos_mean / pos_var)

# SPI for every municipality-month and window, from that baseline
rain_long <- rain_long %>%
  left_join(baseline, by = c("admin_id", "month", "window")) %>%
  mutate(spi = spi_from_gamma(rain, zero_share, shape, rate))


# -----------------------------
# Measures
# -----------------------------

# SPI for each window, wide
spi <- rain_long %>%
  select(admin_id, year, month, window, spi) %>%
  pivot_wider(names_from = window, values_from = spi, names_glue = "spi{sprintf('%02d', window)}")

# 6-month rainfall at or below the baseline p10 / p5 (0/1)
dry_6m <- rain_long %>%
  filter(window == 6) %>%
  mutate(
    percentile_6m = mapply(midrank_percentile, rain, baseline_values),
    dry10_6m = as.integer(percentile_6m <= 0.10),
    dry05_6m = as.integer(percentile_6m <= 0.05)
  ) %>%
  select(admin_id, year, month, percentile_6m, dry10_6m, dry05_6m)

# One row per municipality-month: monthly rainfall, SPI for each window, and
# the 6-month dry flags
measures <- monthly %>%
  select(admin_id, year, month, rain_mm) %>%
  left_join(spi, by = c("admin_id", "year", "month")) %>%
  left_join(dry_6m, by = c("admin_id", "year", "month")) %>%
  arrange(admin_id, year, month)


# -----------------------------
# Checks
# -----------------------------

# The joins above shouldn't duplicate months, but a duplicated month would be
# counted twice in the lags
if (measures %>% count(admin_id, year, month) %>% filter(n > 1) %>% nrow() > 0) {
  stop("Measures are not unique by admin-month", call. = FALSE)
}

# Over the baseline, SPI should be about mean 0 / sd 1, and the dry flags
# should be on about 10% / 5% of months
print(
  measures %>%
    filter(year >= BASELINE_START, year <= BASELINE_END) %>%
    summarise(across(c(spi01, spi03, spi06, spi12, dry10_6m, dry05_6m),
                     list(mean = ~ mean(.x, na.rm = TRUE), sd = ~ sd(.x, na.rm = TRUE)))) %>%
    pivot_longer(everything())
)

if (write_output) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(measures, OUTPUT_FILE)
  message("wrote: ", OUTPUT_FILE)
}
