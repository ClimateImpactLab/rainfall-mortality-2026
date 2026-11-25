# ==============================================================================
# 2d_add_precip_extremes.R
#
# Add long-run extreme precip measures
#
# For each admin unit, take the average annual number of days above 50,
# 100, 150 and 200 mm, plus the average annual max and 99th percentile.
# These vars are fixed over time.
#
# Built from daily ERA5-Land precip in
# 1_data/climate_data/climate_aggregation_global/era5land_admin/panel/
# 03_admin_precip_exposure.py.
#
# Old-panel countries are matched through the ERA5-Land panel crosswalk.
# The new countries' admin ID is the end of region_id.
# Since the measures are fixed over time, every year of a unit gets the same
# values. If a unit has several source rows, they are averaged.
#
# Input:  ERA5-LAND/combined/era5land_admin_precip_exposure_static.csv
#         ERA5-LAND-GLOBAL/combined/era5land_to_global_panel_crosswalk.csv
#         combined_panel/02_panel_climate.csv
# Output: combined_panel/02_panel_climate.csv (same rows, extremes added)
# ==============================================================================


# -------------
# Packages
# -------------

library(dplyr)
library(readr)
library(stringr)


# -------------
# Paths
# -------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_file <- climate_panel_file

precip_file <- file.path(
  era5land_dir, "combined",
  "era5land_admin_precip_exposure_static.csv"
)

crosswalk_file <- file.path(
  era5land_global_dir, "combined",
  "era5land_to_global_panel_crosswalk.csv"
)


# -------------
# Variables
# -------------

# Countries whose admin_id comes from region_id, not from the crosswalk
new_countries <- c("AUS", "COL", "ECU", "KOR", "PER", "PHL")

# Extreme precip vars added to the panel
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


# -------------
# Admin IDs
# -------------

# Old-panel admin_id combines ADM1 and ADM2 IDs
panel_admin_id_from_adm <- function(adm1_id, adm2_id) {
  paste(coalesce(adm1_id, ""), coalesce(adm2_id, ""), sep = "_")
}

# New-country admin_id is stored at the end of the ERA5-Land region_id
# PHL IDs are padded to 10 digits to keep their leading zeroes
admin_id_from_region <- function(climate_country, region_id) {
  admin_id <- str_extract(region_id, "[^_]+$")
  
  if_else(
    climate_country == "PHL",
    str_pad(admin_id, width = 10, side = "left", pad = "0"),
    admin_id
  )
}

# Convert ERA5-Land IDs to the admin_id used in the mortality panel
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
  
  # New countries use the admin ID at the end of region_id
  # This preserves leading zeroes that may be lost in source_admin_id
  new_ready <- precip %>%
    filter(climate_country %in% new_countries) %>%
    transmute(
      iso = climate_country,
      admin_id = admin_id_from_region(climate_country, region_id),
      across(all_of(precip_vars), as.numeric)
    )
  
  # Average to 1 extreme precip row per country-admin unit
# Units with no value in any source row stay missing
  bind_rows(old_ready, new_ready) %>%
    group_by(iso, admin_id) %>%
    summarize(across(all_of(precip_vars), ~ mean(.x, na.rm = TRUE)),
              .groups = "drop") %>%
    mutate(across(all_of(precip_vars), ~ if_else(is.nan(.x), NA_real_, .x)))
}

# Add extreme precip w/out changing the panel rows
add_precip_exposure <- function(panel, exposure) {
  # Drop old versions first if the script is being rerun
  existing <- intersect(precip_vars, names(panel))
  if (length(existing) > 0) {
    panel <- panel %>%
      select(-all_of(existing))
  }
  
  panel %>%
    left_join(exposure, by = c("iso", "admin_id"))
}

# -------------
# Read inputs
# -------------

# Extreme precip table, one row per ERA5-Land region
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
# Otherwise the left join would add rows to the panel
duplicate_exposure <- exposure %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_exposure) > 0) {
  stop("Precipitation exposure has duplicate country-admin rows", call. = FALSE)
}


# --------------
# Add to panel
# --------------

# The measures are the same for every year and age group of a unit
panel <- read_csv(
  panel_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

panel_out <- add_precip_exposure(panel, exposure)
write_csv(panel_out, panel_file, na = "")

message("Updated panel: ", panel_file)
