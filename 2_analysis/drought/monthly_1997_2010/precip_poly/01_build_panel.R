# ============================================================================
# 01_build_panel.R
#
# Brazil monthly mortality panel with precip only, 1997-2010.
# One row per municipality x age group x month.
#
# Rainfall terms, each with 12 lags and 6 leads (placebo):
#   rain_d1, rain_d2, rain_d3   daily rainfall, ^2 and ^3 summed over the
#                               month (the precip poly, d1 = monthly total)
#   rain_m2, rain_m3            monthly total ^2 and ^3
#   spi_dryside, spi_wetside    monthly SPI split at 0, to compare with the
#                               precip poly on the same lags and controls
# Plus temp and temp^2 summed over the month, with 12 lags.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# precip_monthly/brazil_precip_monthly_panel_1997_2010.rds
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(data.table)


# -----------------------------
# Paths and settings
# -----------------------------

# Monthly deaths, the monthly SPI from ../01_build_monthly_measures.R, and
# the ERA5-Land monthly rainfall and temp terms
MORTALITY_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/brazil_pilot/",
  "legacy_1997_2010/BRA_mortality_climate_monthly_1997_2010.csv"
)
SPI_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/",
  "brazil_monthly/brazil_monthly_drought_measures_stable.rds"
)
MONTHLY_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/BRA_STABLE/monthly"
OUTPUT_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/precip_monthly"
OUTPUT_FILE <- file.path(OUTPUT_DIR, "brazil_precip_monthly_panel_1997_2010.rds")

# 12 lags and 6 leads, for every rainfall term (lags only for temp)
N_LAGS <- 12
N_LEADS <- 6
RAIN_VARS <- c("rain_d1", "rain_d2", "rain_d3", "rain_m2", "rain_m3", "spi_dryside", "spi_wetside")
TEMP_VARS <- c("tavg_1", "tavg_2")


# -----------------------------
# Climate: monthly rainfall and temp terms, 1995-2011
# -----------------------------

# 1995-2011, so 1997 has its earlier months and 2010 its later ones. p1-p3
# are daily rainfall, rainfall^2, rainfall^3 summed over the month
files <- file.path(MONTHLY_DIR, paste0("era5land_bra_stable_adm2_monthly_", 1995:2011, ".csv"))
climate <- rbindlist(lapply(files, fread, select = c(
  "month", "stable_admin_id", "prcp_pop_p1", "prcp_pop_p2", "prcp_pop_p3",
  "tmean_pop_p1", "tmean_pop_p2"
)))

# Powers are taken on each ERA5-Land cell and day before averaging, so
# rain_d2 and rain_d3 are bigger when the month's rainfall falls on a few
# heavy days. Everything in cm (10 mm) so the cubic terms stay at a sane
# scale for the Poisson fit
climate[, `:=`(
  admin_id = as.character(stable_admin_id),
  year = as.integer(substr(month, 1, 4)),
  month = as.integer(substr(month, 6, 7)),
  rain_d1 = prcp_pop_p1 / 10,
  rain_d2 = prcp_pop_p2 / 10^2,
  rain_d3 = prcp_pop_p3 / 10^3,
  rain_m2 = (prcp_pop_p1 / 10)^2,
  rain_m3 = (prcp_pop_p1 / 10)^3,
  tavg_1 = tmean_pop_p1,
  tavg_2 = tmean_pop_p2
)]
# SPI from the drought measures, split into its dry and wet side
spi <- as.data.table(readRDS(SPI_FILE))[year %in% 1995:2011, .(
  admin_id, year, month,
  spi_dryside = pmax(0, -spi01),
  spi_wetside = pmax(0, spi01)
)]
climate <- merge(climate, spi, by = c("admin_id", "year", "month"), all.x = TRUE)

# Keep the rainfall and temp terms, in month order for the lags
climate <- climate[, c("admin_id", "year", "month", RAIN_VARS, TEMP_VARS), with = FALSE]
setorder(climate, admin_id, year, month)

# Every municipality must have every month, otherwise shift() would mix months
stopifnot(climate[, .N, by = admin_id][, all(N == 12 * length(files))])

# Lags (months before) for rainfall and temp, leads (months after) for rainfall only
for (k in 1:N_LAGS) {
  climate[, paste0(c(RAIN_VARS, TEMP_VARS), "_lag", k) := shift(.SD, k, type = "lag"),
          by = admin_id, .SDcols = c(RAIN_VARS, TEMP_VARS)]
}
for (k in 1:N_LEADS) {
  climate[, paste0(RAIN_VARS, "_lead", k) := shift(.SD, k, type = "lead"),
          by = admin_id, .SDcols = RAIN_VARS]
}


# -----------------------------
# Mortality, joined to climate
# -----------------------------

# Drop the all-age group. Population is annual, repeated across months.
mortality <- fread(MORTALITY_FILE, select = c(
  "admin_id", "year", "month", "adm1_id", "agegroup", "deaths", "population"
))
mortality <- mortality[agegroup != 0]
# FE and cluster IDs, as in the SPI panel
mortality[, `:=`(
  admin_id = as.character(admin_id),
  agegroup = factor(agegroup),
  admin_code = paste("BRA", admin_id, sep = "_"),
  adm1_code = paste("BRA", adm1_id, sep = "_"),
  year_month = year * 100 + month
)]

# Attach the rainfall and temp terms to every age group of a municipality-month
panel <- merge(mortality, climate, by = c("admin_id", "year", "month"), all.x = TRUE)


# -----------------------------
# Checks and output
# -----------------------------

# Sample size and missing lags/leads, printed to the log
print(panel[, .(
  rows = .N,
  years = paste(range(year), collapse = "-"),
  admin_units = uniqueN(admin_id),
  rows_no_climate = sum(is.na(rain_d1)),
  rows_missing_lag12 = sum(is.na(rain_d1_lag12)),
  rows_missing_lead6 = sum(is.na(rain_d1_lead6)),
  rows_missing_spi_lag12 = sum(is.na(spi_dryside_lag12))
)])

# Monthly totals (cm) and the daily-to-monthly link, as a sanity check
print(summary(panel$rain_d1))
message("corr(rain_d2, rain_m2) = ", round(cor(panel$rain_d2, panel$rain_m2, use = "complete.obs"), 3))

# Save the panel
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
saveRDS(panel, OUTPUT_FILE)
message("wrote: ", OUTPUT_FILE)
