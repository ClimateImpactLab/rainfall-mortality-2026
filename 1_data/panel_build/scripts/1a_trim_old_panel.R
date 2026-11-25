# ==============================================================================
# 1a_trim_old_panel.R
#
# Trim the old Carleton panel before adding the new countries
#
# Keep mortality, ADM0/ADM1 income and ERA5-Land climate. The original panel is
# left unchanged.
#
# The old panel uses ADM2 units. admin_id combines the ADM1 and ADM2 codes so it
# is unique within each country. Geography columns are renamed to match the new 
# country files before the panels are combined in 1c.
#
# Input:  old Carleton ERA5-Land panel (old_panel_file in paths.R)
# Output: old_panel/old_panel_era5_trimmed.csv
# ==============================================================================

# -----------------
# Packages
# -----------------

library(dplyr)
library(readr)
library(haven)


# ---------------
# Paths
# ---------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

out_file <- file.path(old_panel_dir, "old_panel_era5_trimmed.csv")


# ----------------------------------
# Variables kept from the old panel
# ----------------------------------

# Mortality, year, age group and admin units
core_vars <- c(
  "adm0", "iso", "adm1", "adm1_id", "adm2", "adm2_id", "year",
  "agegroup", "deaths", "population", "deathrate"
)

# ADM0 and ADM1 income (Kummu comes later, in 3b)
income_vars <- c(
  "gdppc_adm0", "gdppc_adm0_13br",
  "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg"
)

# ERA5-Land temp/precip polynomials and ADM1 climate
# The new countries get the same vars in 2a and 2c
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

old_panel <- read_dta(old_panel_file)

# revised mortality files replace their old-panel country, not just matching IDs
# for ex, Brazil now uses the stable municipality units
rebuilt_countries <- read_csv(file.path(build_dir, "country_files.csv"), show_col_types = FALSE)$iso

old_panel <- old_panel %>% filter(!iso %in% c(rebuilt_countries, excluded_countries))

# rename the admin columns to match the new country files
# admin_id combines ADM1 and ADM2 since ADM2 codes are not always unique
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

# -----------------------------
# Write
# -----------------------------

write_csv(panel, out_file, na = "")

message("Wrote trimmed old panel: ", out_file)
