# ==============================================================================
# 3d_add_elevation.R
#
# Add FABDEM elevation
#
# Keep median elevation by area and by population, land below 10 m,
# and people below 5, 10 and 20 m. These vars are fixed over time,
# so they merge by country and admin unit.
# The source file has more measures, but they are not needed here.
#
# Input:  heterogeniety_data/elevation_data/output/new_boundary/
#           admin_elevation_exposure_fabdem_landscan2011.csv
#         combined_panel/03_panel_full.csv
# Output: combined_panel/03_panel_full.csv (same rows, elevation added)
# ==============================================================================


# ---------------
# Packages
# ---------------

library(dplyr)
library(readr)


# ---------------
# Paths
# ---------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "checks.R"))

panel_file <- full_panel_file


# ---------------
# Variables
# ---------------

# Elevation variables kept in the mortality panel
elevation_vars <- c(
  "elev_median_m", "share_area_elev_lt_10m",
  "elev_pop_median_m", "share_pop_elev_lt_5m",
  "share_pop_elev_lt_10m", "share_pop_elev_lt_20m"
)

# Old elevation vars removed when this script is rerun
old_elevation_vars <- c(
  "elev_mean_m", "elev_min_m", "elev_p05_m", "elev_p25_m",
  "elev_p75_m", "elev_p95_m",
  "share_area_elev_lt_5m", "share_area_elev_lt_20m",
  "elev_cells", "elev_valid_cells",
  "landscan2011_pop_sum", "landscan2011_pop_positive_pixels",
  "landscan2011_pop_with_valid_elevation",
  "elev_pop_mean_m", "elev_pop_min_m", "elev_pop_p05_m",
  "elev_pop_p25_m", "elev_pop_p75_m", "elev_pop_p95_m"
)


# --------------------
# Read elevation
# --------------------

# Read everything as text, then set the elevation vars to numbers below
elevation_raw <- read_csv(
  elevation_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

# Keep only the elevation variables used in the mortality panel
elevation <- elevation_raw %>%
  transmute(
    iso, admin_id,
    across(all_of(elevation_vars), as.numeric)
  )

# Each admin unit needs exactly one elevation row, or the join would add rows
duplicate_elevation <- elevation %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_elevation) > 0) {
  stop("Elevation has duplicate country-admin rows", call. = FALSE)
}


# ------------------
# Add to panel
# ------------------

# The full panel, IDs as text so they match the elevation file
panel <- read_csv(panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character()))

# Every panel unit needs an elevation row, except three Chile units with no
# source polygon.
# Save the unmatched IDs in the check workbook and stop on any other unit.
unmatched <- panel %>% distinct(iso, admin_id) %>%
  anti_join(elevation, by = c("iso", "admin_id"))
write_checks(list(unmatched_elevation_ids = unmatched))
if (any(!paste(unmatched$iso, unmatched$admin_id, sep = "_") %in%
        c("CHL_12_601", "CHL_5_317", "CHL_5_330"))) {
  stop("Some panel units have no current elevation row.", call. = FALSE)
}

# Row count before the join, to check that the join adds no rows
rows_before <- nrow(panel)

# Drop the old elevation vars first, so a rerun does not duplicate columns
panel <- panel %>%
  select(-any_of(c(elevation_vars, old_elevation_vars)))

# Elevation is fixed over time, so it repeats on every year and age group row
panel <- panel %>%
  left_join(elevation, by = c("iso", "admin_id"))

# Write to a temp file and rename it, so a failed write cannot leave a half
# written panel
stopifnot(nrow(panel) == rows_before)
temporary <- paste0(panel_file, ".tmp")
write_csv(panel, temporary, na = "")
if (!file.rename(temporary, panel_file)) stop("Could not save the elevation merge.", call. = FALSE)

message("Updated panel: ", panel_file)
