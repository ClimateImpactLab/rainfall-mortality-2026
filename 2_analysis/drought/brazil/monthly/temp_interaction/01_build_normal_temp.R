# ============================================================================
# 01_build_normal_temp.R
#
# Normal temperature of each municipality x month, for the drought x normal
# temp regs (02_regs.R). The normal of a month is the average temp of that
# calendar month in that municipality, in C (not relative to the place):
#   normal_rolling: over the previous 30 years, for ex July 1967-1996 for
#                   July 1997 (the first version)
#   normal_fixed:   over 1981-2010, the same years as the SPI baseline
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/
# brazil_monthly/brazil_monthly_normal_temp.rds
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(data.table)


# -----------------------------
# Paths and settings
# -----------------------------

# ERA5-Land monthly temp (pop-weighted), one file per year, and where the normals go
MONTHLY_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/BRA_STABLE/monthly"
OUTPUT_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/",
  "brazil_monthly/brazil_monthly_normal_temp.rds"
)

# Rolling window (years) and the fixed baseline
ROLLING_YEARS <- 30
BASELINE <- 1981:2010


# -----------------------------
# Monthly mean temp
# -----------------------------

# All years, 1950-2024. tmean_pop_p1 is the daily mean temp summed over the
# month, so divided by the days in the month it's the month's mean temp in C
files <- list.files(MONTHLY_DIR, pattern = "_monthly_[0-9]{4}\\.csv$", full.names = TRUE)
temp <- rbindlist(lapply(files, fread, select = c("month", "stable_admin_id", "tmean_pop_p1")))
temp[, `:=`(
  admin_id = as.character(stable_admin_id),
  year = as.integer(substr(month, 1, 4)),
  month = as.integer(substr(month, 6, 7))
)]
# Days in the month, with 29 in February of leap years
leap <- function(y) (y %% 4 == 0 & y %% 100 != 0) | y %% 400 == 0
temp[, days := c(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[month] + (month == 2 & leap(year))]
temp[, temp_mean := tmean_pop_p1 / days]
temp <- temp[, .(admin_id, year, month, temp_mean)]


# -----------------------------
# Normal temp
# -----------------------------

# Rolling: same calendar month, the 30 years before. NA until a municipality
# has 30 earlier years of that month (so from 1980)
setorder(temp, admin_id, month, year)
temp[, normal_rolling := frollmean(shift(temp_mean, 1), ROLLING_YEARS), by = .(admin_id, month)]

# Fixed: same calendar month, 1981-2010
fixed <- temp[year %in% BASELINE, .(normal_fixed = mean(temp_mean)), by = .(admin_id, month)]
temp <- merge(temp, fixed, by = c("admin_id", "month"), all.x = TRUE)

# Years the monthly panel uses (1997-2010, with 12 months of lags and 6 of leads)
normal <- temp[year >= 1980][order(admin_id, year, month)]


# -----------------------------
# Checks and output
# -----------------------------

# Spread of the normals over the panel months, and how close the two are
panel_months <- normal[year %in% 1996:2011]
print(panel_months[, lapply(.SD, function(x) round(quantile(x, c(0.05, 0.1, 0.5, 0.9, 0.95), na.rm = TRUE), 1)),
                   .SDcols = c("temp_mean", "normal_rolling", "normal_fixed")][, pct := c("p5", "p10", "p50", "p90", "p95")])
message("municipalities: ", uniqueN(normal$admin_id),
        " | missing rolling normal in 1996-2011: ", sum(is.na(panel_months$normal_rolling)),
        " | corr(rolling, fixed): ", round(cor(panel_months$normal_rolling, panel_months$normal_fixed, use = "complete.obs"), 3))

dir.create(dirname(OUTPUT_FILE), recursive = TRUE, showWarnings = FALSE)
saveRDS(normal, OUTPUT_FILE)
message("wrote: ", OUTPUT_FILE)
