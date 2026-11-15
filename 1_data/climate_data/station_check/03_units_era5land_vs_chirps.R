# ============================================================================
# 03_units_era5land_vs_chirps.R
#
# ERA5-Land vs CHIRPS yearly precip for each panel admin unit: mean yearly
# total over 1981-2010 (pop-weighted, prcp_pop_p1) from each product's admin
# files, same boundaries and IDs.
# Every panel country with CHIRPS (not Canada, mostly north of 50N).
# Units partly outside 50S-50N have no CHIRPS value and are dropped. 
# Deaths and unit-years from the het panel, to say how much of the panel each 
# unit is.
#
# Output:
#   /project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check/
#     units_era5land_vs_chirps_1981_2010.csv
# ============================================================================


# ---------------
# Packages
# ---------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
})


# -------------
# Paths
# -------------

# Panel build helpers: climate_maps (each country's ERA5-Land folder),
# panel_climate_ids() (climate region -> panel admin unit)

build_dir <- "../../panel_build"
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "climate_inputs.R"))

# Het panel, for deaths and unit-years
het_panel_file <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/precip_heterogeneity/precip_het_panel.rds"

# Where the comparison is saved
OUT_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check"

YEARS <- 1981:2010


# --------------------
# Yearly totals
# --------------------

# One country and product: yearly total per climate region, 1981-2010.
# CHIRPS files sit in the same folders as ERA5-Land, under CHIRPS/
country_years <- function(code, product) {
  folder <- climate_maps$climate_folder[climate_maps$country == code]
  if (product == "chirps") folder <- sub("/ERA5-LAND-GLOBAL/", "/CHIRPS/", folder, fixed = TRUE)
  files <- list.files(file.path(folder, "annual"), pattern = paste0("_annual_(", paste(YEARS, collapse = "|"), ")\\.csv$"), full.names = TRUE)
  if (length(files) != length(YEARS)) stop(code, " ", product, ": ", length(files), " yearly files", call. = FALSE)
  bind_rows(lapply(files, function(f) {
    read_csv(f, col_select = c(year, region_id, prcp_pop_p1), col_types = cols(region_id = "c", .default = "d"))
  })) %>%
    transmute(climate_country = code, region_id, year, product, mm = prcp_pop_p1)
}


# -----------------------------------
# Mean over 1981-2010 per panel unit
# -----------------------------------

# Yearly totals of both products for every country with CHIRPS. Canada is
# left out, almost all of it is north of 50N where CHIRPS stops
countries <- setdiff(climate_maps$country, "CAN")
yearly <- bind_rows(lapply(countries, function(code) {
  message("Reading: ", code)
  bind_rows(country_years(code, "era5l"), country_years(code, "chirps"))
}))

# For each product: match climate regions to panel units (same IDs once the
# country prefix is dropped), then the mean over the 30 years, missing unless
# all 30 are there
units <- bind_rows(lapply(c("era5l", "chirps"), function(p) {
  yearly %>%
    filter(product == p) %>%
    select(-product) %>%
    panel_climate_ids("mm") %>%
    group_by(iso, admin_id) %>%
    summarize(mm = if (sum(is.finite(mm)) == length(YEARS)) mean(mm) else NA_real_, .groups = "drop") %>%
    mutate(product = p)
})) %>%
  # One row per unit with both products side by side, then the ratio. Units
  # with no CHIRPS value (partly outside 50S-50N) drop
  pivot_wider(names_from = product, values_from = mm, names_glue = "{product}_mm") %>%
  filter(is.finite(era5l_mm), is.finite(chirps_mm), chirps_mm > 0) %>%
  mutate(ratio = era5l_mm / chirps_mm)

# Deaths (all ages and years) and unit-years from the het panel, to say how
# much of the panel each unit is. Units not in the panel drop
panel <- readRDS(het_panel_file) %>%
  group_by(iso, admin_id) %>%
  summarize(deaths = sum(deaths), unit_years = n_distinct(year), .groups = "drop")
units <- inner_join(units, panel, by = c("iso", "admin_id"))

# Save, and print how many units each country has
write_csv(units, file.path(OUT_DIR, "units_era5land_vs_chirps_1981_2010.csv"))
message("wrote ", nrow(units), " units")
print(count(units, iso), n = 30)
