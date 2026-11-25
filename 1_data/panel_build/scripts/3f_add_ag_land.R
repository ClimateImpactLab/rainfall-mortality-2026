# ==============================================================================
# 3f_add_ag_land.R
#
# Add cropland and irrigation vars
#
# All are fixed over time and merge by country and admin unit:
#
#   - cropland_share: cropland / land area (EarthStat 2000)
#   - irrigated_share: area equipped for irrigation / cropland (HID 2000)
#   - irrigated_share_spam: irrigated harvested area / all harvested area
#       (SPAM 2005)
#   - rainfed_share_land: rainfed harvested area / land area (SPAM 2005)
#
# Built per country in 1_data/heterogeniety_data/1_data_cleaning/,
# cropland_irrigation/ and spam/.
# Old-panel countries use the climate crosswalk, other countries keep their 
# cleaned mortality IDs, including underscores.
# 
# Harvested area counts land cropped twice in a year twice, sorainfed_share_land 
# can exceed 1 where there is double cropping.
# Units missing from the source files stay missing.
#
# Input:  heterogeniety_data/cropland_irrigation/<COUNTRY>/current_boundaries/
#           cropland_irrigation_<country>.csv
#         heterogeniety_data/spam2005/<COUNTRY>/current_boundaries/
#           spam2005_<country>.csv
#         ERA5-LAND-GLOBAL/combined/era5land_to_global_panel_crosswalk.csv
#         combined_panel/03_panel_full.csv
#
# Output: combined_panel/03_panel_full.csv (same rows, farming vars added)
# ==============================================================================


# ---------------
# Packages
# ---------------

library(dplyr)
library(readr)
library(stringr)


# ---------------
# Paths
# ---------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_file <- full_panel_file

# Use the same current maps and panel IDs as precipitation, wind and drought.
source(file.path(build_dir, "climate_inputs.R"))

# Farming vars added to the panel
ag_land_vars <- c("cropland_share", "irrigated_share",
                  "irrigated_share_spam", "rainfed_share_land")

# Read the newly aggregated files. The older root-level files are unchanged.
# One file per country, stacked, with the climate country code added
# IDs stay text and the farming vars become numbers
read_ag_files <- function(folder, file_pattern, vars) {
  bind_rows(lapply(climate_maps$country, function(code) {
    path <- file.path(ag_land_dir, folder, code, "current_boundaries",
                       sprintf(file_pattern, tolower(code)))
    read_csv(path, show_col_types = FALSE,
             col_select = all_of(c("region_id", vars)),
             col_types = cols(.default = col_character())) %>%
      mutate(climate_country = code, across(all_of(vars), as.numeric))
  }))
}


# -----------------
# Read inputs
# -----------------

# Cropland and irrigation (EarthStat, HID), with land area for the rainfed share
cropland <- read_ag_files(
  "cropland_irrigation", "cropland_irrigation_%s.csv",
  c("cropland_share", "irrigated_share", "land_km2")
)

# Irrigated share and rainfed harvested area (SPAM)
spam <- read_ag_files(
  "spam2005", "spam2005_%s.csv",
  c("irrigated_share_spam", "rainfed_ha")
)

# Match the climate regions to panel country and admin_id
# Where two old climate regions fall in one panel unit, their mean is kept
# and a missing value is ignored if the other region has data
cropland_ready <- panel_climate_ids(cropland, c("cropland_share", "irrigated_share", "land_km2"), ignore_missing = TRUE)
spam_ready <- panel_climate_ids(spam, c("irrigated_share_spam", "rainfed_ha"), ignore_missing = TRUE)

# Rainfed farming = SPAM rainfed harvested area / land area
# Harvested area counts land cropped twice in a year twice, so the share
# can exceed 1 in places w/ double cropping
# Convert hectares to km2 (100 ha per km2), with no share where land area is 0
# The full join keeps units found in either source
ag_land <- cropland_ready %>%
  full_join(spam_ready, by = c("iso", "admin_id")) %>%
  mutate(rainfed_share_land = (rainfed_ha / 100) / if_else(land_km2 > 0, land_km2, NA_real_)) %>%
  select(iso, admin_id, all_of(ag_land_vars))


# ------------------
# Add to panel
# ------------------

# The full panel, IDs as text so they match the farming files
path <- panel_file
panel <- read_csv(
  path, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

# Drop the old farming vars first, so a rerun does not duplicate columns
panel <- panel %>%
  select(-any_of(ag_land_vars))

# Farming vars are fixed over time, so they repeat on every year and age group
# row
panel <- panel %>%
  left_join(ag_land, by = c("iso", "admin_id"))


write_csv(panel, path, na = "")
message("Updated panel: ", path)
