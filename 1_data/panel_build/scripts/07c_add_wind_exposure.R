# ============================================================
# 07c_add_wind_exposure.R
#
# Add annual ERA5-Land wind exposure variables to the mortality panel
#
# The annual wind file is built separately in:
#
#   1_data/climate_data/climate_aggregation/scripts/era5land_admin/
#   aggregation_scripts/07_combine_wind_exposure.py
#
# Old-panel countries are matched through the ERA5-Land panel crosswalk
# New countries use the admin ID stored in `region_id`
#
# Inputs:
#   climate_data/ERA5-LAND/combined/era5land_admin_wind_annual.csv
#   climate_data/ERA5-LAND/combined/era5land_to_global_panel_crosswalk.csv
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv, if present
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv, if present
# ============================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})


# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
urban_panel_file <- file.path(panel_dir, "new_mortality_panel_urban.csv")

wind_file <- file.path(
  era5land_dir, "combined",
  "era5land_admin_wind_annual.csv"
)

crosswalk_file <- file.path(
  era5land_dir, "combined",
  "era5land_to_global_panel_crosswalk.csv"
)

crosswalk_fallback_file <- file.path(
  repo_dir, "1_data/climate_data/climate_aggregation/outputs/ERA5-LAND/combined",
  "era5land_to_global_panel_crosswalk.csv"
)


# -----------------------------
# Variables
# -----------------------------

new_countries <- c("AUS", "COL", "ECU", "KOR", "PER", "PHL")

# Annual wind exposure variables added to the panel
wind_vars <- c(
  "windmax_pop_annual", "windmax_area_annual",
  "winddays_17p5_pop_annual", "winddays_17p5_area_annual"
)


# -----------------------------
# Admin IDs
# -----------------------------

# Old-panel `admin_id` combines ADM1 and ADM2 IDs
panel_admin_id_from_adm <- function(adm1_id, adm2_id) {
  paste(coalesce(adm1_id, ""), coalesce(adm2_id, ""), sep = "_")
}

# New-country `admin_id` is stored at the end of the ERA5-Land `region_id`
admin_id_from_region <- function(climate_country, region_id) {
  admin_id <- str_extract(region_id, "[^_]+$")
  
  if_else(
    climate_country == "PHL",
    str_pad(admin_id, width = 10, side = "left", pad = "0"),
    admin_id
  )
}

# Mean of available values, or missing if all values are missing
mean_or_na <- function(x) {
  x <- x[!is.na(x)]
  
  if (length(x) == 0) {
    return(NA_real_)
  }
  
  mean(x)
}

# Convert ERA5-Land IDs to the `admin_id` used in the mortality panel
make_wind_panel_ids <- function(wind, crosswalk) {
  
  # Old-panel countries use the ERA5-Land crosswalk
  old_ready <- wind %>%
    semi_join(crosswalk, by = c("climate_country", "region_id")) %>%
    left_join(crosswalk, by = c("climate_country", "region_id")) %>%
    transmute(
      iso = panel_iso,
      admin_id = panel_admin_id_from_adm(panel_adm1_id, panel_adm2_id),
      year,
      across(all_of(wind_vars), as.numeric)
    )
  
  # New countries use the admin ID at the end of `region_id`
  # This preserves leading zeroes that may be lost in the source admin ID
  new_ready <- wind %>%
    filter(climate_country %in% new_countries) %>%
    transmute(
      iso = climate_country,
      admin_id = admin_id_from_region(climate_country, region_id),
      year,
      across(all_of(wind_vars), as.numeric)
    )
  
  ready <- bind_rows(old_ready, new_ready)
  
  # Some source rows match the same panel admin-year, so average them before merging
  ready %>%
    group_by(iso, admin_id, year) %>%
    summarize(across(all_of(wind_vars), mean_or_na), .groups = "drop")
}


# -----------------------------
# Add wind to panel
# -----------------------------

# Add wind variables without changing the number of panel rows
add_wind <- function(path, wind) {
  if (!file.exists(path)) {
    stop("Missing panel file: ", path, call. = FALSE)
  }
  
  panel <- read_csv(path, show_col_types = FALSE,
                    col_types = cols(.default = col_character()))
  
  # Drop existing wind variables first if the script is being rerun
  existing_wind <- intersect(wind_vars, names(panel))
  if (length(existing_wind) > 0) {
    panel <- panel %>%
      select(-all_of(existing_wind))
  }
  
  rows_before <- nrow(panel)
  
  panel_wind <- panel %>%
    left_join(wind, by = c("iso", "admin_id", "year"))
  
  if (nrow(panel_wind) != rows_before) {
    stop("Wind exposure merge changed the row count for ", path, call. = FALSE)
  }
  
  write_csv(panel_wind, path, na = "")
  panel_wind
}


# -----------------------------
# Read inputs
# -----------------------------

if (!file.exists(wind_file)) {
  stop(
    "Missing wind exposure file. Run 07_combine_wind_exposure.py first: ",
    wind_file, call. = FALSE
  )
}

# Use the main crosswalk location, with the climate aggregation output as fallback
if (!file.exists(crosswalk_file)) {
  if (file.exists(crosswalk_fallback_file)) {
    crosswalk_file <- crosswalk_fallback_file
  } else {
    stop(
      "Missing ERA5-Land panel crosswalk. Run build_climate_panel_crosswalk.py first: ",
      crosswalk_file, call. = FALSE
    )
  }
}

if (!file.exists(panel_file)) {
  stop("Missing combined panel: ", panel_file, call. = FALSE)
}

wind <- read_csv(
  wind_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  mutate(
    year = as.character(year),
    across(all_of(wind_vars), as.numeric)
  )

# Keep only matched old-panel admin units from the crosswalk
crosswalk <- read_csv(
  crosswalk_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  filter(match_status == "matched") %>%
  select(climate_country, region_id, panel_iso, panel_adm1_id, panel_adm2_id)

# Check that all wind variables needed below are present
required_wind_cols <- c("climate_country", "region_id", "year", wind_vars)
missing_wind_cols <- setdiff(required_wind_cols, names(wind))

if (length(missing_wind_cols) > 0) {
  stop(
    "Wind file is missing required columns: ",
    paste(missing_wind_cols, collapse = ", "),
    call. = FALSE
  )
}

# Convert source IDs to panel IDs
wind_ready <- make_wind_panel_ids(wind, crosswalk)

# Each country-admin-year should appear only once after averaging duplicate source rows
duplicate_wind <- wind_ready %>%
  count(iso, admin_id, year, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_wind) > 0) {
  stop("Wind exposure has duplicate country-admin-year rows", call. = FALSE)
}


# -----------------------------
# Add to panels
# -----------------------------

# Update the main combined panel
panel_out <- add_wind(panel_file, wind_ready)

# Update the urban panel too if it has already been created
urban_out <- NULL

if (file.exists(urban_panel_file)) {
  urban_out <- add_wind(urban_panel_file, wind_ready)
}

message("Updated panel: ", panel_file)

if (!is.null(urban_out)) {
  message("Updated urban panel: ", urban_panel_file)
}
