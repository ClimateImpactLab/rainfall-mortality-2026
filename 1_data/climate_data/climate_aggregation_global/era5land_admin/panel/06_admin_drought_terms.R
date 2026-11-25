# ==============================================================================
# 06_admin_drought_terms.R
#
# Annual drought terms for each admin region, from monthly pop-weighted
# precip. SPI fit on 1981-2010 (monthly SPI by calendar month, and SPI-12 on
# the year's total)
#
# The 4 drought terms:
#   - spi12_dry: dry side of SPI-12
#   - dry_wsum: dry side of each month's SPI, summed over the year, each month
#     weighted by its usual share of the year's rain
#   - dry_sum: same without the weights
#   - mckee: McKee drought magnitude. A drought event is a run of dry months
#     (SPI below 0) with at least one month at -1 or lower. Every month in
#     an event adds how dry it was (-SPI), summed over the year
# And spi12_dry_roll30: spi12_dry against the 30 years before (as long as
# 1981-2010) instead of 1981-2010. 1950-1979 use 1950-1979
#
# Also building here the drought x normal temp terms for
# 04_temp_interaction_regs.R:
# each month's SPI dry side x its normal temp (same month, 30 years before or
# 1981-2010), summed over the year, and the year's average normal
#
# Two ways this file is used, both use the same functions:
#  - run directly: writes the old-panel file below (old admin units), read by
#    the Brazil annual drought scripts
#  - loaded by the panel build (1_data/panel_build/scripts/2g_add_drought_terms.R),
#    which runs same functions on the new panel's adm units, for ERA5-Land and CHIRPS
# One row per country, admin region and year
#
# Input: climate_data/ERA5-LAND-GLOBAL/<COUNTRY>/monthly/ (COL, ECU, PER, PHL:
#   <COUNTRY>/<boundaries>/monthly/, see below)
# Output:
# climate_data/ERA5-LAND-GLOBAL/combined/era5land_admin_drought_annual.csv
# ==============================================================================


# --------
# Packages
# --------

# Using data.table instead of dplyr because it's faster on the big monthly files
# (Brazil is about 5M region-months)
# and data.table's own shift, frollmean and rleid do the lags, rolling means and 
# McKee runs in one line

library(data.table)



# -----------------
# Paths and choices
# -----------------

# Monthly climate by country, and the combined annual file this writes
climate_dir <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL"
output_file <- file.path(climate_dir, "combined", "era5land_admin_drought_annual.csv")

# Countries of the old panel, for the file this writes when run directly (EU =
# the European countries)
# The panel build has its own country list
countries <- c("AUS", "BRA", "CHL", "CHN", "COL", "ECU", "EU", "FRA", "IND",
               "JPN", "KOR", "MEX", "PER", "PHL", "USA")

# COL, ECU, PER and PHL have climate for two versions of their admin units:
#  - old_boundaries: before the boundary changes
#  - current_boundaries: units merged so they're stable over time
# Use the one the mortality panel uses
split_countries <- c("COL", "ECU", "PER", "PHL")
boundaries <- "old_boundaries"

# SPI baseline years
# p_min caps the SPI at about +/-3.7, as in the Brazil drought measures
baseline_years <- 1981:2010
p_min <- 1e-4

# Columns kept in the output
drought_vars <- c("spi12_dry", "dry_wsum", "dry_sum", "mckee", "spi12_dry_roll30")
normal_vars <- c("dry_x_normal_rolling", "dry_x_normal_fixed", "normal_rolling", "normal_fixed")

# Rolling normal temp: up to 30 earlier years, at least 15
rolling_years <- 30
min_years <- 15

# Rolling SPI-12 baseline: the 30 years before
rolling_spi_years <- 30


# ---
# SPI
# ---

# SPI: where this month's (or year's) rain falls in the place's usual
# distribution, as a standard normal value
# The distribution is the share of times with no rain, then a gamma for the rest
# p is the rain's percentile, capped so the SPI stays within about +/-3.7
spi_from_gamma <- function(rain, zero_share, shape, rate) {
  p <- ifelse(rain <= 0, zero_share, zero_share + (1 - zero_share) * pgamma(rain, shape = shape, rate = rate))
  qnorm(pmin(pmax(p, p_min), 1 - p_min))
}

# Fit that distribution to rain (x) over 1981-2010, separately for each group in
# by:
#  - region x calendar month for the monthly SPI (so March is compared with
#    other Marches)
#  - region for SPI-12. 
# The gamma shape and rate come from the mean and variance of the rainy values
fit_gamma <- function(d, by) {
  d[year %in% baseline_years, .(zero_share = mean(x <= 0), pos_mean = mean(x[x > 0]), pos_var = var(x[x > 0])), by = by][
    , `:=`(shape = pos_mean^2 / pos_var, rate = pos_mean / pos_var)]
}


# SPI-12 dry side against the n_years before, for every region-year
# Same fit as fit_gamma, but from rolling sums over the n_years before each year
# A year gets NA if those years have gaps
# The region's first n_years use those first n_years instead
spi12_rolling <- function(out, n_years) {
  d <- out[is.finite(total_mm), .(region_id, year, x = total_mm)]
  setorder(d, region_id, year)
  d[, `:=`(z = as.numeric(x <= 0), pos = as.numeric(x > 0))]
  d[, `:=`(xp = x * pos, xp2 = x^2 * pos)]

  # Sums over the n_years before, and whether they are exactly those years (no
  # gaps)
  d[, `:=`(
    z_n = shift(frollsum(z, n_years)), pos_n = shift(frollsum(pos, n_years)),
    xp_s = shift(frollsum(xp, n_years)), xp2_s = shift(frollsum(xp2, n_years)),
    full = year - shift(year, n_years) == n_years
  ), by = region_id]

  # Early years: the region's first n_years with data, if they're consecutive
  d[, first_year := min(year), by = region_id]
  early <- d[year < first_year + n_years, .(
    early_ok = .N == n_years, z_e = sum(z), pos_e = sum(pos), xp_e = sum(xp), xp2_e = sum(xp2)
  ), by = region_id]
  d <- merge(d, early, by = "region_id")
  d[year < first_year + n_years, `:=`(z_n = z_e, pos_n = pos_e, xp_s = xp_e, xp2_s = xp2_e, full = early_ok)]

  # Fit the gamma (shape and rate from the mean and variance of the rainy
  # years), then the SPI
  # NA if it can't be fit: fewer than 2 rainy years, or all of them equal
  d[, `:=`(zero_share = z_n / n_years, pos_mean = xp_s / pos_n)]
  d[, pos_var := (xp2_s - pos_n * pos_mean^2) / (pos_n - 1)]
  d[!(full %in% TRUE) | pos_n < 2 | !(pos_var > 0), pos_var := NA_real_]
  d[, `:=`(shape = pos_mean^2 / pos_var, rate = pos_mean / pos_var)]
  d[, spi12_dry_roll := pmax(0, -spi_from_gamma(x, zero_share, shape, rate))]
  d[, .(region_id, year, spi12_dry_roll)]
}


# -------------
# Drought terms
# -------------

# Monthly SPI, rainfall share and normal temps for every region-month, from
# monthly precip and temp

# 04_temp_interaction_regs.R calls function too (the drought x temp interaction
# reg script)
monthly_drought <- function(m) {
  # Work on a copy so the monthly data passed in stays as it was (data.table
  # edits in place)
  # Split "YYYY-MM" into year and month, x = the month's pop-weighted precip in
  # mm
  m <- copy(as.data.table(m))
  m[, `:=`(year = as.integer(substr(month, 1, 4)), month = as.integer(substr(month, 6, 7)), x = prcp_pop_p1)]

  # Monthly SPI (spi01), and each calendar month's usual share of the year's
  # rain over 1981-2010 (rainfall_share)
  # For ex 0.15 in a rainy-season month, 0.01 in a dry-season month, the 12
  # shares add up to 1
  base <- fit_gamma(m, c("region_id", "month"))
  shares <- m[year %in% baseline_years, .(normal_mm = mean(x)), by = .(region_id, month)][
    , rainfall_share := normal_mm / sum(normal_mm), by = region_id]
  m <- merge(m, base, by = c("region_id", "month"))
  m <- merge(m, shares[, .(region_id, month, rainfall_share)], by = c("region_id", "month"))
  m[, spi01 := spi_from_gamma(x, zero_share, shape, rate)]
  setorder(m, region_id, year, month)

  # Monthly mean temp: the file has daily mean temp summed over the month, so
  # divide by the number of days
  leap <- (m$year %% 4 == 0 & m$year %% 100 != 0) | m$year %% 400 == 0
  m[, temp_mean := tmean_pop_p1 / (c(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[month] + (month == 2 & leap))]

  # Normal temp of each month, same calendar month in the same region:
  #  - rolling: average of the up to 30 years before (NA with fewer than 15)
  #  - fixed: average over 1981-2010
  # Sorted by month then year so shift and frollmean look back over earlier
  # years of the same month
  setorder(m, region_id, month, year)
  m[, prev := shift(temp_mean, 1), by = .(region_id, month)]
  m[, n_prev := pmin(rowid(region_id, month) - 1L, rolling_years)]
  m[, normal_rolling := frollmean(prev, n_prev, adaptive = TRUE), by = .(region_id, month)]
  m[n_prev < min_years, normal_rolling := NA_real_]
  m[, normal_fixed := mean(temp_mean[year %in% baseline_years]), by = .(region_id, month)]
  setorder(m, region_id, year, month)
  m
}

# All the terms for one country, one row per region x year
drought_country <- function(country, monthly = NULL) {
  # Monthly precip and temp, read from the country folder unless the panel build
  # passes its own
  if (is.null(monthly)) {
    folder <- if (country %in% split_countries) file.path(country, boundaries, "monthly") else file.path(country, "monthly")
    files <- list.files(file.path(climate_dir, folder), pattern = "_monthly_[0-9]{4}\\.csv$", full.names = TRUE)
    monthly <- rbindlist(lapply(files, fread, select = c("month", "region_id", "prcp_pop_p1", "tmean_pop_p1")))
  }
  # Monthly SPI, shares and normals
  # When the panel build passes rain already matched to its admin units, the SPI
  # is fit on that rain
  m <- monthly_drought(monthly)

  # McKee drought events: run_neg numbers each run of months below 0 (or at or
  # above 0)
  # A month is in an event if it's below 0 and its run has at least one month at
  # -1 or lower
  m[, run_neg := rleid(spi01 < 0), by = region_id]
  m[, in_mckee := spi01 < 0 & min(spi01) <= -1, by = .(region_id, run_neg)]

  # Sum each month's dry side over the year, one row per region x year
  # x 12 in the weighted sum so a dry month with a typical share (1/12) counts 1
  # Years without all 12 months are dropped, their sums would be too small (only
  # the last year if the data stops mid-year)
  out <- m[, .(
    dry_wsum = 12 * sum(rainfall_share * pmax(0, -spi01)),
    dry_sum = sum(pmax(0, -spi01)),
    mckee = sum(-spi01 * in_mckee),
    dry_x_normal_rolling = sum(pmax(0, -spi01) * normal_rolling),
    dry_x_normal_fixed = sum(pmax(0, -spi01) * normal_fixed),
    normal_rolling = mean(normal_rolling),
    normal_fixed = mean(normal_fixed),
    total_mm = sum(x),
    n_months = .N
  ), by = .(region_id, year)][n_months == 12][, n_months := NULL]

  # SPI-12: SPI of the year's total, fit on 1981-2010 for each region, dry side
  # only
  base12 <- fit_gamma(out[, .(region_id, year, x = total_mm)], "region_id")
  out <- merge(out, base12, by = "region_id")
  out[, spi12_dry := pmax(0, -spi_from_gamma(total_mm, zero_share, shape, rate))]

  # SPI-12 against the 30 years before
  roll <- spi12_rolling(out, rolling_spi_years)
  setnames(roll, "spi12_dry_roll", "spi12_dry_roll30")
  out <- merge(out, roll, by = c("region_id", "year"), all.x = TRUE)
  # Log line, then only the output columns
  message(country, ": ", uniqueN(out$region_id), " regions, ", min(out$year), "-", max(out$year))
  out[, c("region_id", "year", drought_vars, normal_vars), with = FALSE][, climate_country := country]
}

# Only when the script is run directly (see header): build the old-panel file
# sys.nframe() is 0 when the script is run directly, and 1 or more when the
# panel build loads it with source(), so the panel build only gets the functions
# This has to come last, after the functions are defined
if (sys.nframe() == 0L) {
  # Drought terms for each old-panel country, stacked into one table
  drought <- rbindlist(lapply(countries, drought_country))
  # IDs first, then write the file
  setcolorder(drought, c("climate_country", "region_id", "year"))
  fwrite(drought, output_file)
  message("Wrote: ", output_file)
}
