# ==============================================================================
# 2e_add_wind.R
#
# Add current annual wind to the climate panel.
# Keep the population- and area-weighted maximum wind and days above 17.5 m/s.
#
# Wind comes from the current country files, not the older combined wind table.
# Admin units that merge two old climate regions use whichever values exist.
#
# Input:  current country wind files (via climate_inputs.R) and
#         02_panel_climate.csv
# Output: climate_inputs/annual_wind.csv, 02_panel_climate.csv (same rows)
# ==============================================================================

# ----------------------
# Packages and paths
# ----------------------

library(dplyr)
library(readr)

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "climate_inputs.R"))
panel_file <- climate_panel_file

# -------------------------------
# Read the current wind files
# -------------------------------

# Max wind and days above 17.5 m/s, weighted by population and by area
wind_vars <- c("windmax_pop_annual", "windmax_area_annual",
               "winddays_17p5_pop_annual", "winddays_17p5_area_annual")

# Read each country, then match the climate region IDs to panel admin IDs
wind <- bind_rows(lapply(climate_maps$country, function(code) {
  message("Reading annual wind: ", code)
  # As before, old units with two climate regions use the available values.
  panel_climate_ids(read_climate_source(code, "wind", wind_vars), wind_vars, ignore_missing = TRUE)
}))

# One row per admin unit and year, so the join below cannot add rows
if (anyDuplicated(wind[c("iso", "admin_id", "year")])) {
  stop("Repeated wind admin-years.", call. = FALSE)
}
write_csv(wind, annual_wind_file, na = "")

# --------------------------------------------
# Add wind without changing mortality rows
# --------------------------------------------

path <- panel_file
panel <- read_csv(path, show_col_types = FALSE,
                  col_types = cols(.default = col_character(), year = col_integer()))

# Drop old wind cols first so a rerun replaces them instead of duplicating
# Admin units and years with no wind value stay missing
updated <- panel %>% select(-any_of(wind_vars)) %>%
  left_join(wind, by = c("iso", "admin_id", "year"))
stopifnot(nrow(updated) == nrow(panel))
write_csv(updated, path, na = "")
message("Updated panel: ", path)
