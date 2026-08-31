# ============================================================
# 12_export_panel.R
#
# Export the combined mortality panels as RDS and Stata files
#
# The CSV files remain the main panel outputs. This script also writes RDS files
# for R and Stata files with variable labels
#
# Inputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.rds
#   panel_build/combined_panel/new_mortality_panel.dta
#   panel_build/combined_panel/new_mortality_panel_urban.rds
#   panel_build/combined_panel/new_mortality_panel_urban.dta
# ============================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(haven)
  library(readr)
})


# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
urban_file <- file.path(panel_dir, "new_mortality_panel_urban.csv")


# -----------------------------
# Variable labels
# -----------------------------

label_map <- c(
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
  gdppc_adm0 = "National GDP per capita, constant 2005 PPP dollars",
  gdppc_adm0_13br = "National GDP per capita, 13-bin regression version",
  loggdppc_adm0 = "Log national GDP per capita",
  loggdppc_adm0_13br = "Log national GDP per capita, 13-bin regression version",
  gdppc_adm1 = "ADM1 or income-region GDP per capita, constant 2005 PPP dollars",
  gdppc_adm1_13br = "ADM1 GDP per capita, 13-bin regression version",
  gdppc_adm1_avg = "ADM1 average GDP per capita used for heterogeneity",
  loggdppc_adm1 = "Log ADM1 or income-region GDP per capita",
  loggdppc_adm1_13br = "Log ADM1 GDP per capita, 13-bin regression version",
  loggdppc_adm1_avg = "Log ADM1 average GDP per capita used for heterogeneity",
  tavg_ERA5LAND_adm1 = "ADM1 annual average temperature, ERA5-Land",
  prcp_ERA5LAND_adm1 = "ADM1 annual total precipitation, ERA5-Land",
  tmax_cdd_20C_ERA5LAND_adm1 = "ADM1 annual cooling degree days above 20C, ERA5-Land",
  tmax_hdd_20C_ERA5LAND_adm1 = "ADM1 annual heating degree days below 20C, ERA5-Land",
  lr_tavg_ERA5LAND_adm1_avg = "ADM1 average annual temperature over available climate years, ERA5-Land",
  lr_prcp_ERA5LAND_adm1_avg = "ADM1 average annual precipitation over available climate years, ERA5-Land",
  lr_cdd_20C_ERA5LAND_adm1_avg = "ADM1 average annual CDDs over available climate years, ERA5-Land",
  lr_hdd_20C_ERA5LAND_adm1_avg = "ADM1 average annual HDDs over available climate years, ERA5-Land",
  prcp_pop_days_gt50_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 50mm, ERA5-Land",
  prcp_pop_days_gt100_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 100mm, ERA5-Land",
  prcp_pop_days_gt150_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 150mm, ERA5-Land",
  prcp_pop_days_gt200_ERA5LAND_admin_avg = "Average annual days with population-weighted daily precipitation above 200mm, ERA5-Land",
  prcp_pop_annual_max_ERA5LAND_admin_avg = "Average annual maximum population-weighted daily precipitation, ERA5-Land",
  prcp_pop_p99_ERA5LAND_admin_avg = "Average annual 99th percentile population-weighted daily precipitation, ERA5-Land",
  precip_exposure_years = "Years used for static ERA5-Land admin-unit precipitation exposure",
  precip_exposure_days_observed = "Daily observations used for static ERA5-Land admin-unit precipitation exposure",
  income_source_type = "Income source or extension type",
  income_basis = "Income geography basis",
  kummu_gdppc = "Kummu admin-unit GDP per capita, filled where needed",
  kummu_loggdppc = "Log Kummu admin-unit GDP per capita, filled where needed",
  kummu_lowinc_share = "Kummu admin-unit low-income population share",
  kummu_gdppc_avg_2010_2024 = "Kummu admin-unit average GDP per capita, 2010 to 2024",
  kummu_loggdppc_avg_2010_2024 = "Log Kummu admin-unit average GDP per capita, 2010 to 2024",
  kummu_lowinc_avg_2010_2024 = "Kummu average low-income population share, 2010 to 2024",
  kummu_years_observed_2010_2024 = "Years with original Kummu grid income, 2010 to 2024",
  kummu_years_filled_2010_2024 = "Years with Kummu income after parent ADM1 substitute, 2010 to 2024",
  kummu_income_pctile_country = "Within-country Kummu income percentile, 2010 to 2024",
  kummu_income_basis = "Kummu annual income basis",
  kummu_profile_income_basis = "Kummu profile income basis",
  elev_median_m = "Area-weighted median elevation, FABDEM, meters",
  share_area_elev_lt_10m = "Share of admin area below 10 meters elevation, FABDEM",
  elev_pop_median_m = "Population-weighted median elevation, FABDEM and LandScan 2011, meters",
  share_pop_elev_lt_5m = "Share of LandScan 2011 population below 5 meters elevation",
  share_pop_elev_lt_10m = "Share of LandScan 2011 population below 10 meters elevation",
  share_pop_elev_lt_20m = "Share of LandScan 2011 population below 20 meters elevation",
  panel_pop_density = "Average mortality-panel population divided by admin area, people per square kilometer",
  landscan2011_pop_density = "LandScan 2011 population divided by admin area, people per square kilometer",
  landscan2011_pop_pop_density = "Population-weighted LandScan 2011 population density, people per square kilometer",
  ghsl2010_pop_pop_density = "Population-weighted GHSL 2010 population density, people per square kilometer",
  source_panel = "Old Carleton panel or new country addition",
  year_5s = "Five-year GHSL reference year",
  settlement_type = "GHSL settlement model class",
  urban_share = "Share of GHSL population in urban settlement classes",
  ghsl_population = "GHSL population used for urban share"
)

# Add labels for the ERA5-Land and CHIRPS polynomial terms
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


# -----------------------------
# Export variables and functions
# -----------------------------

# Variables converted back to numeric after reading the CSV files
numeric_vars <- c(
  "year", "agegroup", "deaths", "population", "deathrate",
  "gdppc_adm0", "gdppc_adm0_13br", "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg",
  paste0("prcp_poly_", 1:5, "_ERA5LAND"),
  paste0("tavg_poly_", 1:5, "_ERA5LAND"),
  paste0("tmax_poly_", 1:5, "_ERA5LAND"),
  "tavg_ERA5LAND_adm1", "prcp_ERA5LAND_adm1",
  "tmax_cdd_20C_ERA5LAND_adm1", "tmax_hdd_20C_ERA5LAND_adm1",
  "lr_tavg_ERA5LAND_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg",
  "lr_cdd_20C_ERA5LAND_adm1_avg", "lr_hdd_20C_ERA5LAND_adm1_avg",
  "prcp_pop_days_gt50_ERA5LAND_admin_avg", "prcp_pop_days_gt100_ERA5LAND_admin_avg",
  "prcp_pop_days_gt150_ERA5LAND_admin_avg", "prcp_pop_days_gt200_ERA5LAND_admin_avg",
  "prcp_pop_annual_max_ERA5LAND_admin_avg", "prcp_pop_p99_ERA5LAND_admin_avg",
  "precip_exposure_years", "precip_exposure_days_observed",
  "kummu_gdppc", "kummu_loggdppc", "kummu_lowinc_share",
  "kummu_gdppc_avg_2010_2024", "kummu_loggdppc_avg_2010_2024",
  "kummu_lowinc_avg_2010_2024", "kummu_years_observed_2010_2024",
  "kummu_years_filled_2010_2024", "kummu_income_pctile_country",
  "elev_median_m", "share_area_elev_lt_10m", "elev_pop_median_m",
  "share_pop_elev_lt_5m", "share_pop_elev_lt_10m", "share_pop_elev_lt_20m",
  "panel_pop_density", "landscan2011_pop_density",
  "landscan2011_pop_pop_density", "ghsl2010_pop_pop_density",
  paste0("prcp_poly_", 1:5, "_CHIRPS"),
  "year_5s", "ghsl_population", "settlement_type", "urban_share"
)

# Shorter names used only in the Stata files
dta_name_map <- c(
  prcp_d50_ERA5LAND_admin_avg = "prcp_pop_days_gt50_ERA5LAND_admin_avg",
  prcp_d100_ERA5LAND_admin_avg = "prcp_pop_days_gt100_ERA5LAND_admin_avg",
  prcp_d150_ERA5LAND_admin_avg = "prcp_pop_days_gt150_ERA5LAND_admin_avg",
  prcp_d200_ERA5LAND_admin_avg = "prcp_pop_days_gt200_ERA5LAND_admin_avg",
  prcp_max_ERA5LAND_admin_avg = "prcp_pop_annual_max_ERA5LAND_admin_avg",
  prcp_p99_ERA5LAND_admin_avg = "prcp_pop_p99_ERA5LAND_admin_avg"
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


# -----------------------------
# Export
# -----------------------------

if (!file.exists(panel_file)) {
  stop("Missing panel file: ", panel_file, call. = FALSE)
}

if (!file.exists(urban_file)) {
  stop("Missing panel file: ", urban_file, call. = FALSE)
}

# Read both final CSV panels and add variable labels
panel <- read_panel(panel_file) %>%
  apply_labels()

urban_panel <- read_panel(urban_file) %>%
  apply_labels()

# Use the same filenames with RDS and Stata extensions
panel_rds <- sub("\\.csv$", ".rds", panel_file)
panel_dta <- sub("\\.csv$", ".dta", panel_file)
urban_rds <- sub("\\.csv$", ".rds", urban_file)
urban_dta <- sub("\\.csv$", ".dta", urban_file)

# Write RDS files
saveRDS(panel, panel_rds)
saveRDS(urban_panel, urban_rds)

# Stata has a shorter variable-name limit, so shorten only the affected variables
write_dta(make_stata_names(panel), panel_dta, version = 15)
write_dta(make_stata_names(urban_panel), urban_dta, version = 15)

# Print the exported file paths and panel dimensions
summary <- tibble(
  panel = c("new_mortality_panel", "new_mortality_panel_urban"),
  csv = c(panel_file, urban_file),
  rds = c(panel_rds, urban_rds),
  dta = c(panel_dta, urban_dta),
  rows = c(nrow(panel), nrow(urban_panel)),
  cols = c(ncol(panel), ncol(urban_panel))
)

print(summary)
