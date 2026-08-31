# ============================================================
# 01_trim_old_panel.R
#
# Prepare the old Carleton mortality panel for the new panel
#
# The old panel already contains mortality, income, and ERA5-Land climate
# variables
# This script keeps the variables needed for the new panel and
# puts the geography variables in the same format used for the newly added
# countries
#
# This script does not edit the old source panel
# It writes a trimmed copy under:
#
#   /project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build
#
# Main input:
#   Old Carleton ERA5-Land panel specified in paths.R
#
# Main outputs:
#   panel_build/old_panel/old_panel_era5_trimmed.csv
#
# Geographic level:
#   For countries in the old panel, ADM2 is the final analysis unit:
#     - ADM1: adm1_id / adm1_name
#     - ADM2: adm2_id / adm2_name
#     - admin_id / admin_name also identify the ADM2 unit used in regressions
#
# Usually run through:
#   1_data/panel_build/run_panel_build.sbatch
#
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(haven)


# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

out_file <- file.path(old_panel_dir, "old_panel_era5_trimmed.csv")


# ----------------------------------
# Variables kept from the old panel
# ----------------------------------

# Mortality, year, age group, and geography variables
core_vars <- c(
  "adm0", "iso", "adm1", "adm1_id", "adm2", "adm2_id", "year",
  "agegroup", "deaths", "population", "deathrate"
)

# Keep the income variables already included in the old panel
# Kummu income is added separately later in the panel build
income_vars <- c(
  "gdppc_adm0", "gdppc_adm0_13br",
  "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg"
)

# Keep the ERA5-Land polynomial and ADM1 climate variables already in the old panel
# The same variables are added for the new countries later
era5_vars <- c(
  "prcp_poly_1_ERA5LAND", "tavg_poly_1_ERA5LAND", "tmax_poly_1_ERA5LAND",
  "prcp_poly_2_ERA5LAND", "tavg_poly_2_ERA5LAND", "tmax_poly_2_ERA5LAND",
  "prcp_poly_3_ERA5LAND", "tavg_poly_3_ERA5LAND", "tmax_poly_3_ERA5LAND",
  "prcp_poly_4_ERA5LAND", "tavg_poly_4_ERA5LAND", "tmax_poly_4_ERA5LAND",
  "prcp_poly_5_ERA5LAND", "tavg_poly_5_ERA5LAND", "tmax_poly_5_ERA5LAND",
  "tavg_ERA5LAND_adm1", "prcp_ERA5LAND_adm1",
  "tmax_cdd_20C_ERA5LAND_adm1", "tmax_hdd_20C_ERA5LAND_adm1",
  "lr_tavg_ERA5LAND_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg",
  "lr_cdd_20C_ERA5LAND_adm1_avg", "lr_hdd_20C_ERA5LAND_adm1_avg"
)

keep_vars <- c(core_vars, income_vars, era5_vars)

# -----------------------------
# Read and trim
# -----------------------------

# Stop here if the old panel path is wrong
if (!file.exists(old_panel_file)) {
  stop("Missing old panel: ", old_panel_file)
}

old_panel <- read_dta(old_panel_file)

# Stop here if the old panel is missing a variable used below
missing_vars <- setdiff(keep_vars, names(old_panel))
if (length(missing_vars) > 0) {
  stop("Old panel is missing expected variables: ", paste(missing_vars, collapse = ", "))
}

# Keep the variables needed for the new panel
# Create the geography variables used for the new countries
# For countries in the old panel, ADM2 is the final analysis unit, so `admin_id`
# combines the ADM1 and ADM2 IDs

panel <- old_panel %>%
  select(all_of(keep_vars)) %>%
  mutate(
    across(c(iso, adm0, adm1, adm1_id, adm2, adm2_id), as.character),
    adm1_name = adm1,
    adm2_name = adm2,
    adm3_id = NA_character_,
    adm3_name = NA_character_,
    admin_level = "ADM2",
    admin_id = paste(adm1_id, adm2_id, sep = "_"),
    admin_name = if_else(!is.na(adm2) & adm2 != "", adm2, adm2_id),
    .after = adm2_id
  )


# Check that each country-admin-year-age group appears only once before the old
# and new country panels are combined
duplicate_keys <- panel %>%
  count(iso, admin_id, year, agegroup, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_keys) > 0) {
  stop("Trimmed old panel has duplicate country-admin-year-age rows", call. = FALSE)
}

# -----------------------------
# Write outputs
# -----------------------------

dir.create(old_panel_dir, recursive = TRUE, showWarnings = FALSE)

write_csv(panel, out_file, na = "")

message("Wrote trimmed old panel: ", out_file)
