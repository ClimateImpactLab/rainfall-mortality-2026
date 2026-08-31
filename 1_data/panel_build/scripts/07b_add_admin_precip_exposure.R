# ============================================================
# 07b_add_admin_precip_exposure.R
#
# Add admin-level extreme precipitation variables to the mortality panel
#
# The exposure file is built separately from daily ERA5-Land precipitation in:
#
#   1_data/climate_data/climate_aggregation/scripts/era5land_admin/panel/
#   04_build_admin_precip_exposure.py
#
# Old-panel countries are matched through the ERA5-Land panel crosswalk
# New countries use the admin ID stored in `region_id`
#
# Inputs:
#   climate_data/ERA5-LAND/combined/era5land_admin_precip_exposure_static.csv
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

precip_file <- file.path(
  era5land_dir, "combined",
  "era5land_admin_precip_exposure_static.csv"
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

# Admin-level precipitation exposure variables added to the panel
precip_vars <- c(
  "prcp_pop_days_gt50_ERA5LAND_admin_avg",
  "prcp_pop_days_gt100_ERA5LAND_admin_avg",
  "prcp_pop_days_gt150_ERA5LAND_admin_avg",
  "prcp_pop_days_gt200_ERA5LAND_admin_avg",
  "prcp_pop_annual_max_ERA5LAND_admin_avg",
  "prcp_pop_p99_ERA5LAND_admin_avg",
  "precip_exposure_years",
  "precip_exposure_days_observed"
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

# Convert ERA5-Land IDs to the `admin_id` used in the mortality panel
make_precip_panel_ids <- function(precip, crosswalk) {
  
  # Old-panel countries use the ERA5-Land crosswalk
  old_ready <- precip %>%
    semi_join(crosswalk, by = c("climate_country", "region_id")) %>%
    left_join(crosswalk, by = c("climate_country", "region_id")) %>%
    transmute(
      iso = panel_iso,
      admin_id = panel_admin_id_from_adm(panel_adm1_id, panel_adm2_id),
      across(all_of(precip_vars), as.numeric)
    )
  
  # New countries use the admin ID at the end of `region_id`
  # This preserves leading zeroes that may be lost in `source_admin_id`
  new_ready <- precip %>%
    filter(climate_country %in% new_countries) %>%
    transmute(
      iso = climate_country,
      admin_id = admin_id_from_region(climate_country, region_id),
      across(all_of(precip_vars), as.numeric)
    )
  
  # Keep one precipitation exposure row per country-admin unit
  bind_rows(old_ready, new_ready) %>%
    group_by(iso, admin_id) %>%
    summarize(across(all_of(precip_vars), ~ mean(.x, na.rm = TRUE)),
              .groups = "drop") %>%
    mutate(across(all_of(precip_vars), ~ if_else(is.nan(.x), NA_real_, .x)))
}

# Add precipitation exposure without changing the number of panel rows
add_precip_exposure <- function(panel, exposure) {
  start_rows <- nrow(panel)
  
  # Drop old versions first if the script is being rerun
  existing <- intersect(precip_vars, names(panel))
  if (length(existing) > 0) {
    panel <- panel %>%
      select(-all_of(existing))
  }
  
  out <- panel %>%
    left_join(exposure, by = c("iso", "admin_id"))
  
  if (nrow(out) != start_rows) {
    stop("Admin precipitation exposure merge changed the row count", call. = FALSE)
  }
  
  out
}

# -----------------------------
# Read inputs
# -----------------------------

if (!file.exists(precip_file)) {
  stop(
    "Missing precipitation exposure file. Run 04_build_admin_precip_exposure.py first: ",
    precip_file, call. = FALSE
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

precip <- read_csv(
  precip_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  mutate(across(all_of(precip_vars), as.numeric))

# Keep only matched old-panel admin units from the crosswalk
crosswalk <- read_csv(
  crosswalk_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  filter(match_status == "matched") %>%
  select(climate_country, region_id, panel_iso, panel_adm1_id, panel_adm2_id)

exposure <- make_precip_panel_ids(precip, crosswalk)

# Each country-admin unit should have only one exposure row
duplicate_exposure <- exposure %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_exposure) > 0) {
  stop("Precipitation exposure has duplicate country-admin rows", call. = FALSE)
}


# -----------------------------
# Add to panels
# -----------------------------

# Update the main combined panel
panel <- read_csv(
  panel_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

panel_out <- add_precip_exposure(panel, exposure)
write_csv(panel_out, panel_file, na = "")

# Update the urban panel too if it has already been created
urban_out <- NULL

if (file.exists(urban_panel_file)) {
  urban <- read_csv(
    urban_panel_file, show_col_types = FALSE,
    col_types = cols(.default = col_character())
  )
  
  urban_out <- add_precip_exposure(urban, exposure)
  write_csv(urban_out, urban_panel_file, na = "")
}

message("Updated panel: ", panel_file)

if (!is.null(urban_out)) {
  message("Updated urban panel: ", urban_panel_file)
}
