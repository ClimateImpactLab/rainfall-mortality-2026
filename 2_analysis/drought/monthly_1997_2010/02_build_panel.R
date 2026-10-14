# ============================================================================
# 02_build_panel.R
#
# Brazil monthly mortality + drought panel for the regs. One row per
# municipality x age group x month.
#
# Mortality: monthly deaths and temp controls from the brazil_pilot panel
# (annual population repeated across months).
#
# Drought (from 01_build_monthly_measures.R, flipped so larger = drier):
#   - monthly SPI with 11 lags (this month + 11 = a year) and 6 leads
#     (placebo), also split into its dry side and wet side. The panel keeps
#     up to 23 lags for the 2-year check in 03
#   - 3/6/12-month SPI, with the next 3/6/12 months as placebo
#   - 6-month rainfall below p10 / p5, with the next 6 months as placebo
#
# Options:
#   --period = 1997_2010 | 2000_2024
#   --write
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/brazil_monthly/brazil_monthly_drought_regression_panel_<period>.rds
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(data.table)


# -----------------------------
# Options and paths
# -----------------------------

# Options: --period and --write (see header)
args <- commandArgs(trailingOnly = TRUE)
# Read one option from the command line, for ex --period=2000_2024 gives
# "2000_2024". If the option isn't given, use the default
get_arg <- function(name, default) {
  hit <- sub(paste0("^--", name, "="), "", args[grepl(paste0("^--", name, "="), args)])
  if (length(hit) == 0) default else hit[[1]]
}

period <- get_arg("period", "1997_2010")
write_output <- "--write" %in% args

# Mortality + climate panel for the period (monthly deaths, temp controls)
PILOT_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/brazil_pilot"
PANEL_FILE <- if (period == "1997_2010") {
  file.path(PILOT_DIR, "legacy_1997_2010/BRA_mortality_climate_monthly_1997_2010.csv")
} else {
  file.path(PILOT_DIR, "monthly/BRA_mortality_climate_covariates_monthly_2000_2024.csv")
}

# Drought measures from 01_build_monthly_measures.R, and where the panel goes
DROUGHT_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly"
MEASURES_FILE <- file.path(DROUGHT_DIR, "brazil_monthly_drought_measures_stable.rds")
OUTPUT_FILE <- file.path(DROUGHT_DIR, paste0("brazil_monthly_drought_regression_panel_", period, ".rds"))

N_LAGS <- 23 # last 23 months, plus this month = 24 terms (main regs use the first 12)
N_LEADS <- 6 # next 6 months, placebo


# -----------------------------
# Read mortality panel
# -----------------------------

# Only the columns used in the regs. Drop the all-age group. Monthly temp
# controls are the sums of daily temp (and temp^2) over the month.
panel <- fread(PANEL_FILE, select = c(
  "admin_id", "year", "month", "adm1_id", "adm1_name", "agegroup",
  "deaths", "population", "deathrate",
  "tavg_poly_1_ERA5LAND", "tavg_poly_2_ERA5LAND"
)) %>%
  as_tibble() %>%
  filter(agegroup != 0) %>%
  transmute(
    admin_id = as.character(admin_id),
    year, month, agegroup = factor(agegroup),
    adm1_id, adm1_name = tolower(adm1_name),
    deaths, population, deathrate,
    tavg_poly_1 = tavg_poly_1_ERA5LAND,
    tavg_poly_2 = tavg_poly_2_ERA5LAND,
    # FE and cluster IDs
    admin_code = paste("BRA", admin_id, sep = "_"),
    adm1_code = paste("BRA", adm1_id, sep = "_"),
    year_month = year * 100 + month,
    # Northeast: state codes 21-29
    northeast = adm1_id %in% 21:29
  )


# -----------------------------
# Drought measures, lags and leads
# -----------------------------

# Lags and leads are taken on the full 1950-2024 series, so January 1997
# still has its 11 earlier months. Signs flipped so larger = drier.
drought <- readRDS(MEASURES_FILE) %>%
  arrange(admin_id, year, month) %>%
  group_by(admin_id) %>%
  mutate(
    spi01_dry = -spi01,
    spi03_dry = -spi03,
    spi06_dry = -spi06,
    spi12_dry = -spi12,
    # Next 3/6/12 months, no overlap with the current window
    spi03_dry_lead = lead(spi03_dry, 3),
    spi06_dry_lead = lead(spi06_dry, 6),
    spi12_dry_lead = lead(spi12_dry, 12),
    dry10_6m_lead = lead(dry10_6m, 6),
    dry05_6m_lead = lead(dry05_6m, 6)
  )

# Monthly SPI of each of the 23 months before, and each of the 6 months after
for (k in 1:N_LAGS) drought <- drought %>% mutate("spi01_dry_lag{k}" := lag(spi01_dry, k))
for (k in 1:N_LEADS) drought <- drought %>% mutate("spi01_dry_lead{k}" := lead(spi01_dry, k))

# Dry and wet sides of the monthly SPI, each >= 0, so dry and wet months can
# have different effects: dryside = max(0, spi01_dry), wetside = max(0, -spi01_dry)
spi01_cols <- "^spi01_dry(_lag[0-9]+|_lead[0-9]+)?$"
drought <- drought %>%
  ungroup() %>%
  mutate(
    across(matches(spi01_cols), ~ pmax(0, .x), .names = "{sub('spi01_dry', 'spi01_dryside', .col)}"),
    across(matches(spi01_cols), ~ pmax(0, -.x), .names = "{sub('spi01_dry', 'spi01_wetside', .col)}")
  ) %>%
  select(admin_id, year, month, matches("^spi[0-9]{2}_dry"), matches("^spi01_wetside"),
         matches("^dry(10|05)_6m"))

# Attach the drought measures to every age group of a municipality-month
reg_panel <- panel %>%
  left_join(drought, by = c("admin_id", "year", "month"))


# -----------------------------
# Checks
# -----------------------------

# Sample size, municipalities with no climate, and missing values of each
# drought measure, printed to the log
drought_vars <- setdiff(names(drought), c("admin_id", "year", "month"))

print(
  reg_panel %>%
    summarise(
      rows = n(),
      first_year = min(year),
      last_year = max(year),
      admin_units = n_distinct(admin_id),
      admin_units_no_climate = n_distinct(admin_id[is.na(spi01_dry)]),
      zero_population_rows = sum(population == 0)
    )
)
print(reg_panel %>% summarise(across(all_of(drought_vars), ~ sum(is.na(.x)))) %>%
        tidyr::pivot_longer(everything(), names_to = "variable", values_to = "missing_rows"),
      n = Inf)

# Saved only with --write
if (write_output) {
  saveRDS(reg_panel, OUTPUT_FILE)
  message("wrote: ", OUTPUT_FILE)
}
