# ==============================================================================
# 2a_add_new_country_climate.R
#
# Add current ERA5-Land precipitation and temperature to every panel country.
# Powers 1-5 are calculated at grid-cell level, averaged to admin units,
# and summed over the year by the climate aggregation scripts.
#
# Keep the full 1950-2025 climate series for last/next-year terms in 2g,
# even when mortality covers fewer years
#
# Input:  current country annual files, shapefiles_current.csv,
#         country_files.csv
#         combined_panel/01_panel_mortality.csv
# Output: climate_inputs/annual_climate.csv
#         combined_panel/02_panel_climate.csv (same mortality rows)
# ==============================================================================

# --------------------
# Packages and paths
# --------------------

library(dplyr)
library(readr)

build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "checks.R"))
source(file.path(build_dir, "climate_inputs.R"))
input_file <- mortality_panel_file
panel_file <- climate_panel_file

# -------------------
# Climate variables
# -------------------

# Population-weighted powers 1-5 of precip, mean temp and max temp
# They get the ERA5-Land names used in the old panel
climate_names <- unlist(lapply(1:5, function(power) {
  paste0(c("prcp_pop_p", "tmean_pop_p", "tmax_pop_p"), power)
}))
panel_names <- unlist(lapply(1:5, function(power) {
  paste0(c("prcp_poly_", "tavg_poly_", "tmax_poly_"), power, "_ERA5LAND")
}))

# ----------------------------------
# Annual climate for every country
# ----------------------------------

# Read the country-year files, not the older combined climate table
# Each source region is matched to the panel iso and admin_id
climate <- bind_rows(lapply(climate_maps$country, function(code) {
  message("Reading annual climate: ", code)
  panel_climate_ids(read_climate_source(code, "annual", climate_names), climate_names)
})) %>% rename(all_of(setNames(climate_names, panel_names))) %>%
  arrange(iso, admin_id, year)

# 3 old Chile units have no climate: Antartica, and the Juan Fernandez and Easter
# Island islands, which aren't in the current shapefile
# Their rows stay, with climate missing (not filled from the old panel)
omitted_units <- tibble(iso = "CHL", admin_id = c("12_601", "5_317", "5_330"))
climate <- bind_rows(climate, tidyr::crossing(omitted_units, year = 1950:2025))

# One climate row is used by every age group of the admin-year
if (anyDuplicated(climate[c("iso", "admin_id", "year")])) {
  stop("Repeated panel climate admin-years.", call. = FALSE)
}
write_csv(climate, annual_climate_file, na = "")

# --------------------------
# Add climate to the panel
# --------------------------

# Every mortality admin-year needs a climate row
# Unmatched ones are saved in the checks file and stop the script
panel <- read_csv(input_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character(), year = col_integer()))
needed <- panel %>% distinct(iso, admin_id, year)
unmatched <- anti_join(needed, climate, by = c("iso", "admin_id", "year"))
write_checks(list(unmatched_climate_rows = unmatched))
if (nrow(unmatched) > 0) stop("Some mortality admin-years have no climate row.", call. = FALSE)

# Replace all old annual climate cols, including those copied from the old panel
# A matched row with missing raw climate stays missing.
# It is not filled from old maps.
updated <- panel %>% select(-any_of(panel_names)) %>%
  left_join(climate, by = c("iso", "admin_id", "year"))
stopifnot(nrow(updated) == nrow(panel))
write_csv(updated, panel_file, na = "")
message("Updated panel: ", panel_file)
