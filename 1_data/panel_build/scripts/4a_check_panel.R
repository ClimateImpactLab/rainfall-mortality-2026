# ==============================================================================
# 4a_check_panel.R
#
# Check the finished panel
#
# Write panel size, country coverage, duplicate rows and missing values
# to the check workbook. The panel is not changed.
#
# The script stops if a required column is missing, an excluded country is in
# the panel, or a country-admin-year-age row is repeated.
# The workbook is written before the repeated-row stop, so the rows can be read.
# Missing values are only counted, nothing is dropped or filled.
#
# Input:  combined_panel/03_panel_full.csv
# Output: checks/panel_checks.xlsx
# ==============================================================================


# ---------------
# Packages
# ---------------

library(dplyr)
library(readr)


# ---------------
# Paths
# ---------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "checks.R"))

panel_file <- full_panel_file
check_file <- file.path(check_dir, "panel_checks.xlsx")


# ---------------
# Variables
# ---------------

# 1 row should be unique on these vars
key_vars <- c("iso", "admin_id", "year", "agegroup")

# Core mortality and geography variables required in the final panel
core_vars <- c(
  "adm0", "iso", "adm1_id", "adm2_id", "admin_level", "admin_id",
  "year", "agegroup", "deaths", "population", "deathrate"
)

# ERA5-Land precip, avg temp and max temp powers 1-5
# Precip powers also come with last year (lag1) and next year (lead1)
era5_vars <- c(
  paste0("prcp_poly_", 1:5, "_ERA5LAND"),
  paste0("tavg_poly_", 1:5, "_ERA5LAND"),
  paste0("tmax_poly_", 1:5, "_ERA5LAND"),
  paste0("prcp_poly_", 1:5, "_ERA5LAND_lag1"),
  paste0("prcp_poly_", 1:5, "_ERA5LAND_lead1")
)

# ERA5-Land drought terms, each with last year (lag1) and next year (lead1)
# The last term is the dry side of SPI-12 against the 30 years before
drought_base <- paste0(c("spi12_dry", "dry_wsum", "dry_sum", "mckee",
                         "dry_x_normal_rolling", "dry_x_normal_fixed", "spi12_dry_roll30"), "_ERA5LAND")

# Rainfall normals and 1981-2010 baseline rainfall come with the drought terms
drought_vars <- c(drought_base, paste0(drought_base, "_lag1"), paste0(drought_base, "_lead1"),
                  "normal_rolling", "normal_fixed", "baseline_prcp_n", "baseline_prcp_mm", "baseline_prcp_cv")

# Annual maximum wind and days above 17.5, by population and by area
wind_vars <- c("windmax_pop_annual", "windmax_area_annual",
               "winddays_17p5_pop_annual", "winddays_17p5_area_annual")

# Heaviest rain event, wind on it, and rain days at the 100, 200 and 300
# thresholds, with wind within one day of them
overlap_vars <- c("max_rain_event_mm", "max_wind_on_rain_event_pm1day",
                  "wind_on_max_rain_day", "wind_pm1day_on_max_rain_day",
                  "rain_days_100", "rain_days_100_wind_pm1day",
                  "rain_days_200", "rain_days_200_wind_pm1day",
                  "rain_days_300", "rain_days_300_wind_pm1day",
                  "share_rain_days_100_wind_pm1day", "share_rain_days_200_wind_pm1day",
                  "share_rain_days_300_wind_pm1day")

# GHSL population, settlement type, urban shares and built-up shares
urban_vars <- c("year_5s", "ghsl_population", "settlement_type", "urban_share",
                "city_population", "city_share", "town_population", "town_share",
                "built_share_pop", "built_share_area")

# Cropland and irrigation shares
ag_vars <- c("cropland_share", "irrigated_share", "rainfed_share_land", "irrigated_share_spam")

# CHIRPS has precip powers 1-5 and six drought terms, each for this year,
# last year and next year
# The SPI-12 against the 30 years before is ERA5-Land only, so it is not here
chirps_base <- c(paste0("prcp_poly_", 1:5, "_CHIRPS"),
                 paste0(c("spi12_dry", "dry_wsum", "dry_sum", "mckee",
                          "dry_x_normal_rolling", "dry_x_normal_fixed"), "_CHIRPS"))

chirps_vars <- c(chirps_base, paste0(chirps_base, "_lag1"), paste0(chirps_base, "_lead1"),
                 "baseline_prcp_n_CHIRPS", "baseline_prcp_mm_CHIRPS", "baseline_prcp_cv_CHIRPS")

# FABDEM elevation, fixed over time
elevation_vars <- c(
  "elev_median_m", "share_area_elev_lt_10m",
  "elev_pop_median_m", "share_pop_elev_lt_5m", "share_pop_elev_lt_10m", "share_pop_elev_lt_20m"
)

# Population density, fixed over time
pop_density_vars <- c(
  "panel_pop_density", "landscan2011_pop_density",
  "landscan2011_pop_pop_density", "ghsl2010_pop_pop_density"
)

# Carleton income, national and ADM1
income_vars <- c(
  "gdppc_adm0", "gdppc_adm0_13br", "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg"
)

# Kummu income, with averages over five year windows and the years observed or
# filled in each window
kummu_vars <- c(
  "kummu_gdppc", "kummu_loggdppc",
  unlist(lapply(c("1990_2024", "1990_1999", "2000_2009", "2010_2024", "2000_2010"),
    function(period) paste0(c("kummu_gdppc_avg_", "kummu_loggdppc_avg_",
                              "kummu_years_observed_", "kummu_years_filled_"), period)), use.names = FALSE)
)

# Check missing values in these vars by country
check_vars <- c(
  "deaths", "population", "deathrate",
  era5_vars, chirps_vars, income_vars, kummu_vars,
  elevation_vars, pop_density_vars, drought_vars, wind_vars, overlap_vars, urban_vars, ag_vars
)

# Vars to read as numbers, since the CSV is read as text
numeric_vars <- c(
  "year", "agegroup", "deaths", "population", "deathrate",
  era5_vars, chirps_vars, income_vars, kummu_vars,
  elevation_vars, pop_density_vars, drought_vars, wind_vars, overlap_vars, urban_vars, ag_vars
)


# ----------------
# Read panel
# ----------------

# Read everything as text, then set the numeric vars
panel <- read_csv(
  panel_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  mutate(across(any_of(numeric_vars), as.numeric))

# Stop if any of the core, climate, income or other vars is missing
missing_required <- setdiff(c(core_vars, era5_vars, chirps_vars, income_vars, kummu_vars, elevation_vars,
                              pop_density_vars, drought_vars, wind_vars, overlap_vars, urban_vars, ag_vars), names(panel))

if (length(missing_required) > 0) {
  stop(
    "Panel is missing required variables: ",
    paste(missing_required, collapse = ", "),
    call. = FALSE
  )
}


# ---------------------
# Overall summary
# ---------------------

# Do not export countries whose mortality data are not ready.
if (any(panel$iso %in% excluded_countries)) {
  stop("Panel includes an excluded country. Check excluded_countries in paths.R.", call. = FALSE)
}

# Check that each country-admin-year-age group appears only once
duplicate_rows <- panel %>%
  count(across(all_of(key_vars)), name = "rows") %>%
  filter(rows > 1) %>%
  arrange(iso, admin_id, year, agegroup)

# One row with panel size, years and the number of repeated rows
summary <- tibble(
  rows = nrow(panel),
  cols = ncol(panel),
  countries = n_distinct(panel$iso),
  admin_units = n_distinct(paste(panel$iso, panel$admin_id)),
  year_min = min(panel$year, na.rm = TRUE),
  year_max = max(panel$year, na.rm = TRUE),
  duplicate_country_admin_year_age = nrow(duplicate_rows)
)


# ----------------------
# Country coverage
# ----------------------

# Panel size, years, and number of age groups by country
countries <- panel %>%
  group_by(source_panel, iso) %>%
  summarize(
    rows = n(),
    admin_units = n_distinct(admin_id),
    year_min = min(year, na.rm = TRUE),
    year_max = max(year, na.rm = TRUE),
    agegroups = n_distinct(agegroup),
    .groups = "drop"
  ) %>%
  arrange(source_panel, iso)

# Count missing values by country in the vars most likely to matter
missing_by_country <- panel %>%
  group_by(source_panel, iso) %>%
  summarize(
    rows = n(),
    across(any_of(check_vars), ~ sum(is.na(.x)), .names = "missing_{.col}"),
    .groups = "drop"
  ) %>%
  arrange(source_panel, iso)


# ------------------
# Write checks
# ------------------

dir.create(check_dir, recursive = TRUE, showWarnings = FALSE)

# Keep the input checks from earlier steps when updating the panel-wide sheets.
write_checks(
  list(
    summary = summary,
    countries = countries,
    duplicate_rows = duplicate_rows,
    missing_by_country = missing_by_country
  )
)

print(summary)
message("Wrote checks: ", check_file)

# Stop on repeated rows, but only after the workbook is written
# The repeated rows are in the duplicate_rows sheet
if (nrow(duplicate_rows) > 0) stop("Repeated country-admin-year-age rows in the panel.", call. = FALSE)
