# ============================================================
# 05_build_panel.R
#
# Combine the trimmed old panel with the new country panel
#
# The old panel is prepared in step 01. Steps 02-04 build the new country panel
# and add ERA5-Land climate and ADM1 income
# This script combines the two
#
# GHSL urban share, Kummu income, elevation, population density, and regression
# IDs are added later
#
# Inputs:
#   panel_build/old_panel/old_panel_era5_trimmed.csv
#   panel_build/new_countries/new_country_mortality_climate_income.csv
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.csv
# ============================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

old_file <- file.path(old_panel_dir, "old_panel_era5_trimmed.csv")
new_file <- file.path(new_country_dir, "new_country_mortality_climate_income.csv")

panel_out <- file.path(panel_dir, "new_mortality_panel.csv")


# -----------------------------
# Panel variables
# -----------------------------

# Mortality and geography variables kept in the combined panel
core_vars <- c(
  "adm0", "iso",
  "adm1_id", "adm1_name", "adm2_id", "adm2_name", "adm3_id", "adm3_name",
  "admin_level", "admin_id", "admin_name",
  "year", "agegroup", "deaths", "population", "deathrate"
  )

# Income variables already added to the old and new country panels
income_vars <- c(
  "gdppc_adm0", "gdppc_adm0_13br",
  "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg"
)

# ERA5-Land variables already added to both panels
climate_vars <- c(
  "prcp_poly_1_ERA5LAND", "tavg_poly_1_ERA5LAND", "tmax_poly_1_ERA5LAND",
  "prcp_poly_2_ERA5LAND", "tavg_poly_2_ERA5LAND", "tmax_poly_2_ERA5LAND",
  "prcp_poly_3_ERA5LAND", "tavg_poly_3_ERA5LAND", "tmax_poly_3_ERA5LAND",
  "prcp_poly_4_ERA5LAND", "tavg_poly_4_ERA5LAND", "tmax_poly_4_ERA5LAND",
  "prcp_poly_5_ERA5LAND", "tavg_poly_5_ERA5LAND", "tmax_poly_5_ERA5LAND",
  "tavg_ERA5LAND_adm1", "prcp_ERA5LAND_adm1",
  "tmax_cdd_20C_ERA5LAND_adm1", "tmax_hdd_20C_ERA5LAND_adm1",
  "lr_tavg_ERA5LAND_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg",
  "lr_cdd_20C_ERA5LAND_adm1_avg", "lr_hdd_20C_ERA5LAND_adm1_avg"
)

# Optional income source variables from the new-country income file
income_flags <- c("income_source_type", "income_basis")

panel_vars <- c(core_vars, income_vars, climate_vars, income_flags)

# Variables that should be numeric after the old and new panels are combined
numeric_vars <- c(
  "year", "agegroup", "deaths", "population", "deathrate",
  income_vars,
  climate_vars
)


# -----------------------------
# Helpers
# -----------------------------

# Add columns that are missing from either panel before combining rows
add_missing_cols <- function(data, vars) {
  missing <- setdiff(vars, names(data))
  
  for (var in missing) {
    data[[var]] <- NA
  }
  
  data
}

# Keep the same variables and types in the old and new panels
clean_panel <- function(data, source) {
  data %>%
    add_missing_cols(panel_vars) %>%
    select(all_of(panel_vars)) %>%
    mutate(
      source_panel = source,
      across(setdiff(panel_vars, numeric_vars), as.character),
      across(any_of(numeric_vars), as.numeric)
    )
}


# -----------------------------
# Read inputs
# -----------------------------


# Stop here if either input panel is missing
if (!file.exists(old_file)) {
  stop("Missing trimmed old panel. Run 01_trim_old_panel.R first: ", old_file, call. = FALSE)
}

if (!file.exists(new_file)) {
  stop("Missing new country panel. Run 04_merge_adm1_income.R first: ", new_file, call. = FALSE)
}

# Read the old and new country panels
old_panel <- read_csv(old_file, show_col_types = FALSE, col_types = cols(.default = col_character()))
new_panel <- read_csv(new_file, show_col_types = FALSE, col_types = cols(.default = col_character()))

# Put both panels in the same format before combining them
old_clean <- clean_panel(old_panel, "old")
new_clean <- clean_panel(new_panel, "new")

# -----------------------------
# Append
# -----------------------------

# Combine the old and new country panels and sort the rows
panel <- bind_rows(old_clean, new_clean) %>%
  arrange(iso, admin_id, year, agegroup)

# Each country-admin-year-age group should appear only once
duplicate_keys <- panel %>%
  count(iso, admin_id, year, agegroup, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_keys) > 0) {
  stop("Combined panel has duplicate iso-admin_id-year-agegroup keys.", call. = FALSE)
}

# -----------------------------
# Write outputs
# -----------------------------

dir.create(panel_dir, recursive = TRUE, showWarnings = FALSE)

# Write the combined mortality panel
write_csv(panel, panel_out, na = "")

message("Wrote panel: ", panel_out)
