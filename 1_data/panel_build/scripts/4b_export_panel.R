# ==============================================================================
# 4b_export_panel.R
#
# Export the three stage datasets to R and Stata
#
# Save RDS and labelled Stata copies of the three CSV datasets. The CSVs remain
# the main files.
#
# Variable labels come from label_map. Stata copies shorten the few names that
# pass Stata's 32 character limit (dta_name_map).
# The R copies keep the full names.
# With --full-only, only the full panel is exported.
#
# Input:  01_panel_mortality.csv, 02_panel_climate.csv, 03_panel_full.csv
# Output: RDS and Stata copies with the same names, CSVs are unchanged
#         panel_exports sheet in checks/panel_checks.xlsx
# ==============================================================================


# ---------------
# Packages
# ---------------

library(dplyr)
library(haven)
library(readr)


# ---------------
# Paths
# ---------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "checks.R"))

# Export the full panel first so it is available before the other Stata copies.
# The three stage CSVs, or only the full panel with --full-only
panel_files <- if ("--full-only" %in% commandArgs(trailingOnly = TRUE)) full_panel_file else
  c(full_panel_file, mortality_panel_file, climate_panel_file)


# ---------------------
# Variable labels
# ---------------------

# Label shown in R and Stata for each panel variable
label_map <- c(
  # Geography and mortality
  adm0 = "Country name",
  iso = "ISO alpha-3 country code",
  adm1_id = "ADM1 parent ID",
  adm1_name = "ADM1 parent name",
  adm2_id = "True ADM2 ID, if applicable",
  adm2_name = "True ADM2 name, if applicable",
  adm3_id = "True ADM3 ID, if applicable",
  adm3_name = "True ADM3 name, if applicable",
  admin_level = "Analysis admin-unit level",
  admin_id = "Analysis admin-unit ID",
  admin_name = "Analysis admin-unit name",
  year = "Calendar year",
  agegroup = "Age group code used by mortality regressions",
  deaths = "Deaths in admin-year-agegroup cell",
  population = "Population in admin-year-agegroup cell",
  deathrate = "Deaths per 100,000 population",
  # Carleton income
  gdppc_adm0 = "National GDP per capita, constant 2005 PPP dollars",
  gdppc_adm0_13br = "National GDP per capita, 13-year Bartlett average",
  loggdppc_adm0 = "Log national GDP per capita",
  loggdppc_adm0_13br = "Log national GDP per capita, 13-year Bartlett average",
  gdppc_adm1 = "ADM1 or income-region GDP per capita, constant 2005 PPP dollars",
  gdppc_adm1_13br = "ADM1 GDP per capita, 13-year Bartlett average",
  gdppc_adm1_avg = "Mean ADM1 GDP per capita over available mortality years",
  loggdppc_adm1 = "Log ADM1 or income-region GDP per capita",
  loggdppc_adm1_13br = "Log ADM1 GDP per capita, 13-year Bartlett average",
  loggdppc_adm1_avg = "Mean annual log ADM1 GDP per capita over available mortality years",
  # ERA5-Land ADM1 climate
  tavg_ERA5LAND_adm1 = "ADM1 annual average temperature, ERA5-Land",
  prcp_ERA5LAND_adm1 = "ADM1 annual total precipitation, ERA5-Land",
  tmax_cdd_20C_ERA5LAND_adm1 = "ADM1 annual cooling degree days above 20C, ERA5-Land",
  tmax_hdd_20C_ERA5LAND_adm1 = "ADM1 annual heating degree days below 20C, ERA5-Land",
  lr_tavg_ERA5LAND_adm1_avg = "ADM1 average annual temperature over available climate years, ERA5-Land",
  lr_prcp_ERA5LAND_adm1_avg = "ADM1 average annual precipitation over available climate years, ERA5-Land",
  lr_cdd_20C_ERA5LAND_adm1_avg = "ADM1 average annual CDDs over available climate years, ERA5-Land",
  lr_hdd_20C_ERA5LAND_adm1_avg = "ADM1 average annual HDDs over available climate years, ERA5-Land",
  # Static precipitation exposure by admin unit
  prcp_pop_days_gt50_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 50mm, ERA5-Land",
  prcp_pop_days_gt100_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 100mm, ERA5-Land",
  prcp_pop_days_gt150_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 150mm, ERA5-Land",
  prcp_pop_days_gt200_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 200mm, ERA5-Land",
  prcp_pop_annual_max_ERA5LAND_admin_avg = "Average annual maximum population-weighted daily precipitation, ERA5-Land",
  prcp_pop_p99_ERA5LAND_admin_avg = "Average annual 99th percentile population-weighted daily precipitation, ERA5-Land",
  precip_exposure_years = "Years used for static ERA5-Land admin-unit precipitation exposure",
  precip_exposure_days_observed = "Daily observations used for static ERA5-Land admin-unit precipitation exposure",
  # Income source and Kummu income
  income_source_type = "Income source or extension type",
  income_basis = "Income geography basis",
  kummu_gdppc = "Kummu GDP per capita, constant 2021 PPP, endpoints held outside 1990-2024",
  kummu_loggdppc = "Log Kummu GDP per capita, constant 2021 PPP",
  kummu_gdppc_avg_2010_2024 = "Kummu admin-unit average GDP per capita, 2010 to 2024",
  kummu_loggdppc_avg_2010_2024 = "Log Kummu admin-unit average GDP per capita, 2010 to 2024",
  kummu_years_observed_2010_2024 = "Years with original Kummu grid income, 2010 to 2024",
  kummu_years_filled_2010_2024 = "Years with Kummu income after parent ADM1 substitute, 2010 to 2024",
  kummu_gdppc_avg_2000_2010 = "Kummu admin-unit average GDP per capita, 2000 to 2010",
  kummu_loggdppc_avg_2000_2010 = "Log Kummu admin-unit average GDP per capita, 2000 to 2010",
  kummu_income_basis = "Kummu annual income basis",
  # Elevation
  elev_median_m = "Area-weighted median elevation, FABDEM, meters",
  share_area_elev_lt_10m = "Share of admin area below 10 meters elevation, FABDEM",
  elev_pop_median_m = "Population-weighted median elevation, FABDEM and LandScan 2011, meters",
  share_pop_elev_lt_5m = "Share of LandScan 2011 population below 5 meters elevation",
  share_pop_elev_lt_10m = "Share of LandScan 2011 population below 10 meters elevation",
  share_pop_elev_lt_20m = "Share of LandScan 2011 population below 20 meters elevation",
  # Population density
  panel_pop_density = "Average mortality-panel population divided by admin area, people per square kilometer",
  landscan2011_pop_density = "LandScan 2011 population divided by admin area, people per square kilometer",
  landscan2011_pop_pop_density = "Population-weighted LandScan 2011 population density, people per square kilometer",
  ghsl2010_pop_pop_density = "Population-weighted GHSL 2010 population density, people per square kilometer",
  # Cropland and irrigation
  cropland_share = "Cropland area / land area, EarthStat 2000",
  irrigated_share = "Area equipped for irrigation / cropland area, HID 2000",
  irrigated_share_spam = "Irrigated harvested area / all harvested area, SPAM 2005",
  rainfed_share_land = "Rainfed harvested area / land area, SPAM 2005",
  # Baseline rainfall
  baseline_prcp_mm = "Average annual precipitation 1981-2010, ERA5-Land, mm",
  baseline_prcp_cv = "Coefficient of variation of annual precipitation 1981-2010, ERA5-Land",
  # Source panel and GHSL urban vars
  source_panel = "Old Carleton panel or new country addition",
  year_5s = "Five-year GHSL reference year",
  settlement_type = "GHSL settlement model class",
  urban_share = "Share of GHSL population in urban settlement classes",
  city_population = "GHSL population in urban centres, SMOD class 30",
  city_share = "Percent of GHSL population in urban centres, SMOD class 30",
  town_population = "GHSL population in towns and peri-urban cells, SMOD classes 21-23",
  town_share = "Percent of GHSL population in towns and peri-urban cells, SMOD classes 21-23",
  built_share_pop = "Population-weighted building cover, GHSL 2000, percent",
  built_share_area = "Building area divided by admin area, GHSL 2000, percent",
  ghsl_population = "GHSL population used for urban share"
)

# Labels for ERA5-Land and CHIRPS polynomial terms
for (power in 1:5) {
  label_map[paste0("prcp_poly_", power, "_ERA5LAND")] <-
    paste0("ERA5-Land annual precipitation polynomial term ", power)
  
  label_map[paste0("tavg_poly_", power, "_ERA5LAND")] <-
    paste0("ERA5-Land annual average temperature polynomial term ", power)
  
  label_map[paste0("tmax_poly_", power, "_ERA5LAND")] <-
    paste0("ERA5-Land annual maximum temperature polynomial term ", power)
  
  label_map[paste0("prcp_poly_", power, "_CHIRPS")] <-
    paste0("CHIRPS annual precipitation polynomial term ", power)
}

# Labels for current, lagged and lead drought terms
# Written for ERA5-Land, with the source name swapped in for CHIRPS below
drought_labels <- c(
  spi12_dry = "Dry side of the annual (January-December) SPI, ERA5-Land",
  dry_wsum = "Monthly SPI dry side summed over the year, weighted by usual monthly rainfall share, ERA5-Land",
  dry_sum = "Monthly SPI dry side summed over the year, ERA5-Land",
  mckee = "McKee drought magnitude over the year, ERA5-Land"
)

# Each precip and drought term gets an ERA5-Land and a CHIRPS version
# In the names the source comes before the lag1 or lead1 suffix
for (product in c("ERA5LAND", "CHIRPS")) {
  source_name <- if (product == "ERA5LAND") "ERA5-Land" else "CHIRPS"
  for (power in 1:5) {
    label_map[paste0("prcp_poly_", power, "_", product, "_lag1")] <-
      paste0(source_name, " annual precipitation polynomial term ", power, ", last year")
    label_map[paste0("prcp_poly_", power, "_", product, "_lead1")] <-
      paste0(source_name, " annual precipitation polynomial term ", power, ", next year")
  }
  for (var in names(drought_labels)) {
    label <- sub("ERA5-Land", source_name, drought_labels[[var]], fixed = TRUE)
    label_map[paste0(var, "_", product)] <- label
    label_map[paste0(var, "_", product, "_lag1")] <- paste0(label, ", last year")
    label_map[paste0(var, "_", product, "_lead1")] <- paste0(label, ", next year")
  }
}
# SPI-12 against the 30 years before, ERA5-Land only
# Same drought labels, with last year and next year versions
roll_label <- "Dry side of the annual SPI against the 30 years before, ERA5-Land"
label_map["spi12_dry_roll30_ERA5LAND"] <- roll_label
label_map["spi12_dry_roll30_ERA5LAND_lag1"] <- paste0(roll_label, ", last year")
label_map["spi12_dry_roll30_ERA5LAND_lead1"] <- paste0(roll_label, ", next year")
# Baseline rainfall for CHIRPS
label_map["baseline_prcp_mm_CHIRPS"] <- "Average annual precipitation 1981-2010, CHIRPS, mm"
label_map["baseline_prcp_cv_CHIRPS"] <- "Coefficient of variation of annual precipitation 1981-2010, CHIRPS"
label_map["baseline_prcp_n_CHIRPS"] <- "Observed annual precipitation values in 1981-2010, CHIRPS"


# ------------------------------------
# Export variables and functions
# ------------------------------------

# Kummu income windows, each with its average, log average and years of data
income_periods <- c("1990_2024", "1990_1999", "2000_2009", "2010_2024", "2000_2010")
income_window_vars <- unlist(lapply(income_periods, function(period) paste0(
  c("kummu_gdppc_avg_", "kummu_loggdppc_avg_", "kummu_years_observed_", "kummu_years_filled_"), period
)), use.names = FALSE)
for (period in income_periods) {
  years <- gsub("_", " to ", period)
  label_map[paste0("kummu_gdppc_avg_", period)] <- paste0("Kummu GDPpc, equal-year mean ", years, ", constant 2021 PPP")
  label_map[paste0("kummu_loggdppc_avg_", period)] <- paste0("Log of mean Kummu GDP per capita, ", years)
  label_map[paste0("kummu_years_observed_", period)] <- paste0("Years with direct Kummu grid values, ", years)
  label_map[paste0("kummu_years_filled_", period)] <- paste0("Usable years including parent substitutes, ", years)
}
# Population-weighted Kummu averages
label_map["kummu_gdppc_popwt_2010_2024"] <- "Kummu GDP per capita, population-weighted across 2010-2024 years"
label_map["kummu_loggdppc_popwt_2010_2024"] <- "Log of population-weighted mean Kummu GDP per capita, 2010-2024"

# Variables converted back to numeric after reading the CSV files
# Anything not listed stays text, such as IDs and names
numeric_vars <- c(
  # Rain and wind overlap
  "max_rain_event_mm", "max_wind_on_rain_event_pm1day", "wind_on_max_rain_day",
  "wind_pm1day_on_max_rain_day", "rain_days_100", "rain_days_100_wind_pm1day",
  "rain_days_200", "rain_days_200_wind_pm1day", "rain_days_300", "rain_days_300_wind_pm1day",
  "share_rain_days_100_wind_pm1day", "share_rain_days_200_wind_pm1day", "share_rain_days_300_wind_pm1day",
  # Kummu income windows
  income_window_vars, "kummu_gdppc_popwt_2010_2024", "kummu_loggdppc_popwt_2010_2024",
  # Mortality and Carleton income
  "year", "agegroup", "deaths", "population", "deathrate",
  "gdppc_adm0", "gdppc_adm0_13br", "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg",
  # ERA5-Land climate
  paste0("prcp_poly_", 1:5, "_ERA5LAND"),
  paste0("tavg_poly_", 1:5, "_ERA5LAND"),
  paste0("tmax_poly_", 1:5, "_ERA5LAND"),
  "tavg_ERA5LAND_adm1", "prcp_ERA5LAND_adm1",
  "tmax_cdd_20C_ERA5LAND_adm1", "tmax_hdd_20C_ERA5LAND_adm1",
  "lr_tavg_ERA5LAND_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg",
  "lr_cdd_20C_ERA5LAND_adm1_avg", "lr_hdd_20C_ERA5LAND_adm1_avg",
  # Static precipitation exposure
  "prcp_pop_days_gt50_ERA5LAND_admin_avg", "prcp_pop_days_gt100_ERA5LAND_admin_avg",
  "prcp_pop_days_gt150_ERA5LAND_admin_avg", "prcp_pop_days_gt200_ERA5LAND_admin_avg",
  "prcp_pop_annual_max_ERA5LAND_admin_avg", "prcp_pop_p99_ERA5LAND_admin_avg",
  "precip_exposure_years", "precip_exposure_days_observed",
  # Kummu income
  "kummu_gdppc", "kummu_loggdppc",
  "kummu_gdppc_avg_2010_2024", "kummu_loggdppc_avg_2010_2024",
  "kummu_years_observed_2010_2024", "kummu_years_filled_2010_2024",
  "kummu_gdppc_avg_2000_2010", "kummu_loggdppc_avg_2000_2010",
  # Elevation, population density and farming
  "elev_median_m", "share_area_elev_lt_10m", "elev_pop_median_m",
  "share_pop_elev_lt_5m", "share_pop_elev_lt_10m", "share_pop_elev_lt_20m",
  "panel_pop_density", "landscan2011_pop_density",
  "landscan2011_pop_pop_density", "ghsl2010_pop_pop_density",
  "cropland_share", "irrigated_share", "irrigated_share_spam", "rainfed_share_land",
  # Baseline rainfall, wind and rainfall normals
  "baseline_prcp_mm", "baseline_prcp_cv", "baseline_prcp_n",
  "windmax_pop_annual", "windmax_area_annual",
  "winddays_17p5_pop_annual", "winddays_17p5_area_annual",
  "normal_rolling", "normal_fixed",
  # ERA5-Land drought terms and precip powers, with last and next year
  paste0(rep(paste0(c("spi12_dry", "dry_wsum", "dry_sum", "mckee",
                       "dry_x_normal_rolling", "dry_x_normal_fixed", "spi12_dry_roll30"), "_ERA5LAND"), each = 3),
         c("", "_lag1", "_lead1")),
  paste0(rep(paste0("prcp_poly_", 1:5, "_ERA5LAND"), each = 2), c("_lag1", "_lead1")),
  # CHIRPS precip powers, drought terms and baseline rainfall
  paste0("prcp_poly_", 1:5, "_CHIRPS"),
  paste0(rep(paste0("prcp_poly_", 1:5, "_CHIRPS"), each = 2), c("_lag1", "_lead1")),
  paste0(rep(paste0(c("spi12_dry", "dry_wsum", "dry_sum", "mckee",
                       "dry_x_normal_rolling", "dry_x_normal_fixed"), "_CHIRPS"), each = 3),
         c("", "_lag1", "_lead1")),
  "baseline_prcp_mm_CHIRPS", "baseline_prcp_cv_CHIRPS", "baseline_prcp_n_CHIRPS",
  # GHSL urban and built-up vars
  "year_5s", "ghsl_population", "settlement_type", "urban_share",
  "city_population", "city_share", "town_population", "town_share",
  "built_share_pop", "built_share_area"
)

# Shorter names used only in the Stata files, new name = full name
dta_name_map <- c(
  prcp_d50_ERA5LAND_admin_avg = "prcp_pop_days_gt50_ERA5LAND_admin_avg",
  prcp_d100_ERA5LAND_admin_avg = "prcp_pop_days_gt100_ERA5LAND_admin_avg",
  prcp_d150_ERA5LAND_admin_avg = "prcp_pop_days_gt150_ERA5LAND_admin_avg",
  prcp_d200_ERA5LAND_admin_avg = "prcp_pop_days_gt200_ERA5LAND_admin_avg",
  prcp_max_ERA5LAND_admin_avg = "prcp_pop_annual_max_ERA5LAND_admin_avg",
  prcp_p99_ERA5LAND_admin_avg = "prcp_pop_p99_ERA5LAND_admin_avg",
  # Only these interaction names exceed Stata's 32-character limit.
  dry_x_roll_ERA5LAND_lag1 = "dry_x_normal_rolling_ERA5LAND_lag1",
  dry_x_roll_ERA5LAND_lead1 = "dry_x_normal_rolling_ERA5LAND_lead1",
  dry_x_fixed_ERA5LAND_lead1 = "dry_x_normal_fixed_ERA5LAND_lead1",
  dry_x_roll_CHIRPS_lead1 = "dry_x_normal_rolling_CHIRPS_lead1"
)

# Add variable labels where a label has been defined
apply_labels <- function(data) {
  for (var in intersect(names(label_map), names(data))) {
    attr(data[[var]], "label") <- unname(label_map[[var]])
  }
  
  data
}

# Shorten long variable names before writing the Stata files
make_stata_names <- function(data) {
  rename_pairs <- dta_name_map[dta_name_map %in% names(data)]
  
  for (new_name in names(rename_pairs)) {
    old_name <- unname(rename_pairs[[new_name]])
    names(data)[names(data) == old_name] <- new_name
  }
  
  apply_labels(data)
}

# Read a CSV panel and restore numeric variable types
read_panel <- function(path) {
  read_csv(path, show_col_types = FALSE,
           col_types = cols(.default = col_character())) %>%
    mutate(across(any_of(numeric_vars), as.numeric))
}


# ---------------
# Export
# ---------------

# Export each saved stage separately, without changing its CSV
# Each gets an RDS copy with full names and a Stata copy with shortened names
exports <- list()
for (path in panel_files) {
  panel <- read_panel(path) %>% apply_labels()
  rds_file <- sub("\\.csv$", ".rds", path)
  dta_file <- sub("\\.csv$", ".dta", path)
  # A failed export must not leave a half-written file at the final path.
  saveRDS(panel, paste0(rds_file, ".tmp"))
  if (!file.rename(paste0(rds_file, ".tmp"), rds_file)) stop("Could not save: ", rds_file)

  # Stata's name limit applies only to the Stata copy.
  write_dta(make_stata_names(panel), paste0(dta_file, ".tmp"), version = 15)
  if (!file.rename(paste0(dta_file, ".tmp"), dta_file)) stop("Could not save: ", dta_file)
  exports[[path]] <- tibble(csv = path, rds = rds_file, dta = dta_file,
                            rows = nrow(panel), cols = ncol(panel))
}
# Record the exported files in the check workbook
print(bind_rows(exports))
export_table <- bind_rows(exports)
check_file <- file.path(check_dir, "panel_checks.xlsx")
# With --full-only, keep the rows of the other stages from the earlier export
if ("--full-only" %in% commandArgs(trailingOnly = TRUE) && file.exists(check_file) &&
    "panel_exports" %in% readxl::excel_sheets(check_file)) {
  previous_exports <- readxl::read_excel(check_file, sheet = "panel_exports")
  export_table <- bind_rows(previous_exports %>% filter(!csv %in% export_table$csv), export_table)
}
write_checks(list(panel_exports = export_table))
