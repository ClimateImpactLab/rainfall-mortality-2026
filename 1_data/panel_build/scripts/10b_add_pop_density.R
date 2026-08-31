# ============================================================
# 10b_add_pop_density.R
#
# Add population density variables to the combined mortality panels
#
# Population density is fixed over time, so the variables merge by country and
# admin unit
#
# This script keeps the density variables used in the mortality panel:
#
#   panel_pop_density
#   landscan2011_pop_density
#   landscan2011_pop_pop_density
#   ghsl2010_pop_pop_density
#
# Inputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv
#   heterogeniety_data/pop_density/admin_density.csv
#   heterogeniety_data/pop_density/landscan_density.csv
#   heterogeniety_data/pop_density/ghsl_density.csv
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

pop_density_vars <- c(
  "panel_pop_density", "landscan2011_pop_density",
  "landscan2011_pop_pop_density", "ghsl2010_pop_pop_density"
)


# -----------------------------
# Read density files
# -----------------------------

# Stop if any density input is missing
for (path in c(admin_density_file, landscan_density_file, ghsl_density_file)) {
  if (!file.exists(path)) {
    stop("Missing population density input: ", path, call. = FALSE)
  }
}

# Panel-population density
panel_density <- read_csv(
  admin_density_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    iso, admin_id,
    panel_pop_density = as.numeric(panel_pop_density)
  )

# LandScan 2011 density
landscan_density <- read_csv(
  landscan_density_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    iso, admin_id,
    landscan2011_pop_density = as.numeric(landscan2011_pop_density),
    landscan2011_pop_pop_density = as.numeric(landscan2011_pop_pop_density)
  )

# GHSL 2010 population-weighted density
ghsl_density <- read_csv(
  ghsl_density_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    iso, admin_id,
    ghsl2010_pop_pop_density = as.numeric(ghsl2010_pop_pop_density)
  )

# Combine the three density sources by country and admin unit
pop_density <- panel_density %>%
  left_join(landscan_density, by = c("iso", "admin_id")) %>%
  left_join(ghsl_density, by = c("iso", "admin_id"))

# Check that each admin unit has one density row
duplicate_density <- pop_density %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_density) > 0) {
  stop("Population density has duplicate country-admin rows", call. = FALSE)
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

panel <- read_csv(
  panel_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

urban_panel <- read_csv(
  urban_panel_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

# Drop old density variables first if the script is being rerun
panel <- panel %>%
  select(-any_of(pop_density_vars))

urban_panel <- urban_panel %>%
  select(-any_of(pop_density_vars))

panel_rows <- nrow(panel)
urban_panel_rows <- nrow(urban_panel)

# Add population density by country and admin unit
panel <- panel %>%
  left_join(pop_density, by = c("iso", "admin_id"))

urban_panel <- urban_panel %>%
  left_join(pop_density, by = c("iso", "admin_id"))

if (nrow(panel) != panel_rows) {
  stop("Population density merge changed the base panel row count", call. = FALSE)
}

if (nrow(urban_panel) != urban_panel_rows) {
  stop("Population density merge changed the urban panel row count", call. = FALSE)
}

write_csv(panel, panel_file, na = "")
write_csv(urban_panel, urban_panel_file, na = "")

message("Updated panel: ", panel_file)
message("Updated urban panel: ", urban_panel_file)
