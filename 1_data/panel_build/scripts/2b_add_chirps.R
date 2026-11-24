# ==============================================================================
# 2b_add_chirps.R
#
# Add CHIRPS precipitation powers 1-5 to the annual mortality panel.
#
# Read 1981-2025 on the current admin maps. The climate files already contain
# population-weighted daily grid-cell powers summed over each year.
# Keep the full climate history for the previous/following-year terms in 2g.
# Where CHIRPS has no value (before 1981, Canada, cells outside its latitude
# range) the panel stays missing, no ERA5-Land rainfall is copied in.
#
# Input:  CHIRPS annual files listed in shapefiles_chirps.csv
#         combined_panel/02_panel_climate.csv
# Output: climate_inputs/annual_chirps.csv
#         combined_panel/02_panel_climate.csv (same rows, CHIRPS added)
# ==============================================================================

# --------------------
# Packages and paths
# --------------------

library(dplyr)
library(readr)

build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "climate_inputs.R"))

# The same panel-ID matches are used for ERA5-Land and CHIRPS, including
# Brazil's stable municipalities and the merged COL, ECU, PER and PHL units.
# Source names are the population-weighted precip powers 1-5
climate_names <- paste0("prcp_pop_p", 1:5)
panel_names <- paste0("prcp_poly_", 1:5, "_CHIRPS")

# ----------------------
# Annual precipitation
# ----------------------

# Read each country's yearly CHIRPS files
# Match them to the panel iso and admin_id
chirps <- bind_rows(lapply(chirps_maps$country, function(code) {
  message("Reading annual CHIRPS: ", code)
  climate <- read_climate_source(code, "annual", climate_names, product = "CHIRPS")
  panel_climate_ids(climate, climate_names)
})) %>% rename(all_of(setNames(climate_names, panel_names))) %>%
  arrange(iso, admin_id, year)

# One CHIRPS row per admin-year, shared by all age groups
if (anyDuplicated(chirps[c("iso", "admin_id", "year")])) {
  stop("Repeated CHIRPS panel admin-years.", call. = FALSE)
}
write_csv(chirps, annual_chirps_file, na = "")

# --------------------------------------------
# Add CHIRPS without changing mortality rows
# --------------------------------------------

# No CHIRPS before 1981 or for Canada. Cells outside its latitude range and
# other missing raw values also stay missing, no ERA5-Land rainfall is copied.
panel <- read_csv(climate_panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character(), year = col_integer()))
updated <- panel %>% select(-any_of(panel_names)) %>%
  left_join(chirps, by = c("iso", "admin_id", "year"))
stopifnot(nrow(updated) == nrow(panel))
write_csv(updated, climate_panel_file, na = "")
message("Updated panel: ", climate_panel_file)
