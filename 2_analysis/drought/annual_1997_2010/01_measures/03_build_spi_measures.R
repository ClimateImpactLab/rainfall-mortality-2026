# ============================================================================
# 03_build_spi_measures.R
#
# SPI (Standardized Precipitation Index) for each Brazil municipality and
# year, from the rainfall totals built in 01 and 02. Population-weighted rainfall.
#
#   spi12_cal_pop     SPI of calendar-year rainfall (Jan-Dec), dry and wet years
#   spi06_worst_pop   driest 6-month SPI among the 12 windows ending in the
#                     year (like worst_z_06m_pop, but SPI instead of z)
#
# Baseline: 1981-2010, same municipality (and same ending month for SPI-6).
#
# Why SPI and not the z-score: rainfall can't go below zero, so in dry places
# with very variable rainfall (the semi-arid) even a total failure of the rains
# only gives z around -2. SPI fits a gamma distribution to the place's own
# 1981-2010 rainfall, turns rainfall into a probability, then puts it on the z scale.
# A 1-in-50-year drought gets the same SPI everywhere. The gamma is fitted
# from the mean and variance (method of moments), close to maximum
# likelihood with 30 years.
#
# Inputs (read only):
#   drought/monthly/era5land_admin_drought_monthly_bra.rds  6-month rainfall totals
#   drought/annual/era5land_admin_drought_annual_bra.rds  calendar-year rainfall
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/brazil_annual/era5land_admin_spi_annual_bra.rds
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)


# -----------------------------
# Paths and settings
# -----------------------------

DROUGHT_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought"

# Monthly drought file from 01_build_monthly_drought_measures.R. Rain totals
# do not depend on the baseline, so the rolling20 file is fine as the source
# of 6-month rainfall.
MONTHLY_FILE <- file.path(DROUGHT_DIR, "monthly", "era5land_admin_drought_monthly_bra.rds")
ANNUAL_FILE <- file.path(DROUGHT_DIR, "annual", "era5land_admin_drought_annual_bra.rds")

OUTPUT_DIR <- file.path(DROUGHT_DIR, "brazil_annual")
OUTPUT_FILE <- file.path(OUTPUT_DIR, "era5land_admin_spi_annual_bra.rds")

BASELINE_START <- 1981
BASELINE_END <- 2010

# SPI is capped at about +/-3.7 (probabilities 0.0001 and 0.9999) so a value
# far outside the 30 baseline years does not become infinite.
P_MIN <- 1e-4

write_output <- "--write" %in% commandArgs(trailingOnly = TRUE)


# -----------------------------
# SPI helper
# -----------------------------

# SPI for one rainfall value given the baseline gamma fit. Zeros get the baseline
# share of zeros as their probability (standard mixed gamma SPI).
spi_from_gamma <- function(rain, zero_share, shape, rate) {
  p <- ifelse(rain <= 0, zero_share, zero_share + (1 - zero_share) * pgamma(rain, shape = shape, rate = rate))
  qnorm(pmin(pmax(p, P_MIN), 1 - P_MIN))
}


# -----------------------------
# Calendar-year SPI
# -----------------------------

annual <- readRDS(ANNUAL_FILE) %>%
  filter(climate_country == "BRA") %>%
  select(climate_country, region_id, ID_1, ID_2, year, no_drought_baseline, annual_rain_mm_pop)

# One gamma fit per ADM2 on its 1981-2010 calendar-year totals.
annual_fit <- annual %>%
  filter(year >= BASELINE_START, year <= BASELINE_END, !is.na(annual_rain_mm_pop)) %>%
  group_by(region_id) %>%
  summarise(
    zero_share = mean(annual_rain_mm_pop <= 0),
    pos_mean = mean(annual_rain_mm_pop[annual_rain_mm_pop > 0]),
    pos_var = var(annual_rain_mm_pop[annual_rain_mm_pop > 0]),
    .groups = "drop"
  ) %>%
  mutate(shape = pos_mean^2 / pos_var, rate = pos_mean / pos_var)

annual_spi <- annual %>%
  left_join(annual_fit, by = "region_id") %>%
  mutate(spi12_cal_pop = spi_from_gamma(annual_rain_mm_pop, zero_share, shape, rate)) %>%
  select(climate_country, region_id, ID_1, ID_2, year, no_drought_baseline, spi12_cal_pop)


# -----------------------------
# 6-month SPI
# -----------------------------

# Only 6-month rainfall (pop-weighted) is needed. The monthly file has every
# measure for every window and weighting (~100 vars).
rain_6m <- readRDS(MONTHLY_FILE) %>%
  select(region_id, year, month_number, rain_mm_06m_pop)

# One gamma fit per ADM2 x ending month, for ex July-ending 6-month rainfall is
# compared with July-ending 6-month rainfall in 1981-2010.
rain_6m_fit <- rain_6m %>%
  filter(year >= BASELINE_START, year <= BASELINE_END, !is.na(rain_mm_06m_pop)) %>%
  group_by(region_id, month_number) %>%
  summarise(
    zero_share = mean(rain_mm_06m_pop <= 0),
    pos_mean = mean(rain_mm_06m_pop[rain_mm_06m_pop > 0]),
    pos_var = var(rain_mm_06m_pop[rain_mm_06m_pop > 0]),
    .groups = "drop"
  ) %>%
  mutate(shape = pos_mean^2 / pos_var, rate = pos_mean / pos_var)

spi_6m <- rain_6m %>%
  left_join(rain_6m_fit, by = c("region_id", "month_number")) %>%
  mutate(spi06 = spi_from_gamma(rain_mm_06m_pop, zero_share, shape, rate))

# Worst window in the year, by ending month, as in 02. Requires all 12 windows.
spi_6m_annual <- spi_6m %>%
  group_by(region_id, year) %>%
  summarise(
    spi06_worst_pop = if (sum(!is.na(spi06)) == 12) min(spi06) else NA_real_,
    .groups = "drop"
  )


# -----------------------------
# Final annual file
# -----------------------------

spi_annual <- annual_spi %>%
  left_join(spi_6m_annual, by = c("region_id", "year")) %>%
  arrange(region_id, year)

# Regions without a usable baseline stay in the file with missing SPI, as in 02.
spi_annual[spi_annual$no_drought_baseline, c("spi12_cal_pop", "spi06_worst_pop")] <- NA

# Quick check over 1981-2010: spi12 should be about mean 0, SD 1. The
# worst-in-year SPI-6 is lower by construction (it is the driest of 12).
print(
  spi_annual %>%
    filter(year >= BASELINE_START, year <= BASELINE_END) %>%
    summarise(
      across(c(spi12_cal_pop, spi06_worst_pop),
             list(mean = ~ mean(.x, na.rm = TRUE), sd = ~ sd(.x, na.rm = TRUE),
                  min = ~ min(.x, na.rm = TRUE), max = ~ max(.x, na.rm = TRUE)))
    )
)


# -----------------------------
# Write output
# -----------------------------

if (write_output) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(spi_annual, OUTPUT_FILE)
  message("wrote: ", OUTPUT_FILE)
}
