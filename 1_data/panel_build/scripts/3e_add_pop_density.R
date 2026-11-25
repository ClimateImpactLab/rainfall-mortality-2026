# ==============================================================================
# 3e_add_pop_density.R
#
# Add population density
#
# These vars are fixed over time and merge by country and admin unit:
#
#   panel_pop_density: average panel population / admin area
#   landscan2011_pop_density: LandScan 2011 people / admin area
#   landscan2011_pop_pop_density: LandScan 2011 density where people live
#     (density of each person's cell, averaged over people)
#   ghsl2010_pop_pop_density: same with GHSL 2010
#
# The admin density file sets the list of units, the other two are joined to it.
# A unit can have a missing density value.
# A panel unit with no row in the admin density file stops the script.
#
# Input:  heterogeniety_data/pop_density/current_boundaries/admin_density.csv,
#           landscan_density.csv, ghsl_density.csv
#         combined_panel/03_panel_full.csv
# Output: combined_panel/03_panel_full.csv (same rows, density added)
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

# Density vars added to the panel
pop_density_vars <- c(
  "panel_pop_density", "landscan2011_pop_density",
  "landscan2011_pop_pop_density", "ghsl2010_pop_pop_density"
)


# ------------------------
# Read density files
# ------------------------

# Read the 3 density files, IDs as text and density as numbers
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
# The panel-population file sets the list of units
pop_density <- panel_density %>%
  left_join(landscan_density, by = c("iso", "admin_id")) %>%
  left_join(ghsl_density, by = c("iso", "admin_id"))

# Each admin unit needs exactly one density row, or the join would add rows
duplicate_density <- pop_density %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_density) > 0) {
  stop("Population density has duplicate country-admin rows", call. = FALSE)
}


# ------------------
# Add to panel
# ------------------

# The full panel, IDs as text so they match the density files
path <- panel_file
panel <- read_csv(path, show_col_types = FALSE,
                  col_types = cols(.default = col_character()))

# A unit can have a missing density value, but a unit with no row at all
# needs checking.
# Save the unmatched IDs in the check workbook and stop if there are any.
unmatched <- anti_join(panel %>% distinct(iso, admin_id), pop_density,
                       by = c("iso", "admin_id"))
write_checks(list(unmatched_density_ids = unmatched))
if (nrow(unmatched) > 0) stop("Some panel units have no current density row.", call. = FALSE)

# Drop old density vars first so a rerun does not duplicate columns
# Density repeats on every year and age group row
updated <- panel %>% select(-any_of(pop_density_vars)) %>%
  left_join(pop_density, by = c("iso", "admin_id"))
# Check that the join added no rows
stopifnot(nrow(updated) == nrow(panel))
write_csv(updated, path, na = "")
message("Updated panel: ", path)
