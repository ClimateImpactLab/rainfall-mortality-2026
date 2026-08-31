# ============================================================
# 10_add_elevation.R
#
# Add FABDEM elevation variables to the combined mortality panels
#
# Elevation is fixed over time, so the variables merge by country and admin unit
#
# The full elevation file contains additional percentiles and processing checks
# This script keeps only the elevation variables used in the mortality panel
#
# Inputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv
#   heterogeniety_data/elevation_data/output/
#     admin_elevation_exposure_fabdem_landscan2011.csv
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv
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

panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
urban_panel_file <- file.path(panel_dir, "new_mortality_panel_urban.csv")


# -----------------------------
# Variables
# -----------------------------

# Elevation variables kept in the mortality panel
elevation_vars <- c(
  "elev_median_m", "share_area_elev_lt_10m",
  "elev_pop_median_m", "share_pop_elev_lt_5m",
  "share_pop_elev_lt_10m", "share_pop_elev_lt_20m"
)

# Elevation variables kept by older versions of this script
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


# -----------------------------
# Read elevation
# -----------------------------

if (!file.exists(elevation_file)) {
  stop("Missing elevation file: ", elevation_file, call. = FALSE)
}

elevation_raw <- read_csv(
  elevation_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

# Check that all elevation variables needed for the panel are present
missing_elevation_cols <- setdiff(
  c("iso", "admin_id", elevation_vars),
  names(elevation_raw)
)

if (length(missing_elevation_cols) > 0) {
  stop(
    "Elevation file is missing required columns: ",
    paste(missing_elevation_cols, collapse = ", "),
    call. = FALSE
  )
}

# Keep only the elevation variables used in the mortality panel
elevation <- elevation_raw %>%
  transmute(
    iso, admin_id,
    across(all_of(elevation_vars), as.numeric)
  )

# Each admin unit should have only one elevation row
duplicate_elevation <- elevation %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_elevation) > 0) {
  stop("Elevation has duplicate country-admin rows", call. = FALSE)
}


# -----------------------------
# Add to panels
# -----------------------------

if (!file.exists(panel_file)) {
  stop("Missing panel file: ", panel_file, call. = FALSE)
}
if (!file.exists(urban_panel_file)) {
  stop("Missing panel file: ", urban_panel_file, call. = FALSE)
}

panel <- read_csv(panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character()))
urban_panel <- read_csv(urban_panel_file, show_col_types = FALSE,
                        col_types = cols(.default = col_character()))

# Drop old elevation variables first if the script is being rerun
panel <- panel %>%
  select(-any_of(c(elevation_vars, old_elevation_vars)))
urban_panel <- urban_panel %>%
  select(-any_of(c(elevation_vars, old_elevation_vars)))

panel_rows <- nrow(panel)
urban_panel_rows <- nrow(urban_panel)

panel <- panel %>%
  left_join(elevation, by = c("iso", "admin_id"))
urban_panel <- urban_panel %>%
  left_join(elevation, by = c("iso", "admin_id"))

if (nrow(panel) != panel_rows) {
  stop("Elevation merge changed the base panel row count.", call. = FALSE)
}
if (nrow(urban_panel) != urban_panel_rows) {
  stop("Elevation merge changed the urban panel row count.", call. = FALSE)
}

write_csv(panel, panel_file, na = "")
write_csv(urban_panel, urban_panel_file, na = "")

message("Updated panel: ", panel_file)
message("Updated urban panel: ", urban_panel_file)
