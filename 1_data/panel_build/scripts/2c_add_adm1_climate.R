# ==============================================================================
# 2c_add_adm1_climate.R
#
# Add annual mean temperature and precipitation at ADM1 level.
# Rainfall profile selection uses lr_prcp_ERA5LAND_adm1_avg.
#
# For new or revised country panels, average current admin climate to ADM1
# with fixed LandScan 2011 population weights. Long-run means use the country's
# mortality years, as before. Keep the old Carleton ADM1 values unchanged.
# No additional raw raster extraction or degree-day calculation is needed.
# Admin units with no single ADM1 (Ecuador group 1503) get no ADM1 climate.
#
# Input:  combined_panel/02_panel_climate.csv, annual_climate.csv,
#         landscan_density.csv, old_panel/old_panel_era5_trimmed.csv
# Output: climate_inputs/adm1_climate.csv
#         combined_panel/02_panel_climate.csv (same rows, ADM1 climate added)
# ==============================================================================

# --------------------
# Packages and paths
# --------------------

library(dplyr)
library(readr)
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "checks.R"))
# The 4 ADM1 climate cols in the panel
adm1_vars <- c("tavg_ERA5LAND_adm1", "prcp_ERA5LAND_adm1",
               "lr_tavg_ERA5LAND_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg")

# --------------------------
# Admin unit to ADM1 links
# --------------------------

# New countries only, the old panel keeps its own ADM1 values (see the end)
mortality <- read_csv(mortality_panel_file, show_col_types = FALSE,
                      col_select = c(iso, admin_id, adm1_id, admin_level, year, source_panel),
                      col_types = cols(.default = col_character(), year = col_integer())) %>%
  filter(source_panel == "new")

# Link each admin unit to its ADM1
# Units that are themselves ADM1 are their own parent
links <- mortality %>% distinct(iso, admin_id, adm1_id, admin_level) %>%
  mutate(adm1_id = if_else((is.na(adm1_id) | adm1_id == "") & admin_level == "ADM1", admin_id, adm1_id)) %>%
  select(iso, admin_id, adm1_id) %>% distinct()
missing_links <- links %>% filter(is.na(adm1_id) | adm1_id == "")
write_checks(list(adm1_missing_parent_ids = missing_links))
if (anyDuplicated(links[c("iso", "admin_id")])) stop("An admin unit has multiple ADM1 links.", call. = FALSE)

# Ecuador's group 1503 combines cantons without a single province assignment
# Its own climate stays in the panel
# But we don't invent an ADM1 for this covariate
links <- links %>% filter(!is.na(adm1_id), adm1_id != "")
message("Admin units without a single ADM1: ", nrow(missing_links))

# Only the years each country has mortality data enter the ADM1 means
needed_years <- mortality %>% distinct(iso, year)


# --------------------------------
# Climate and population weights
# --------------------------------

# Fixed 2011 LandScan population of each admin unit, used as the weight
population <- read_csv(landscan_density_file, show_col_types = FALSE,
                        col_select = c(iso, admin_id, landscan2011_population),
                        col_types = cols(.default = col_double(), iso = col_character(), admin_id = col_character()))

# Admin-level annual precip and temperature (power 1) from 2a
annual <- read_csv(annual_climate_file, show_col_types = FALSE,
                    col_select = c(iso, admin_id, year, prcp_poly_1_ERA5LAND, tavg_poly_1_ERA5LAND),
                    col_types = cols(.default = col_double(), iso = col_character(), admin_id = col_character()))

# Attach each unit's ADM1 and weight, keeping the country's mortality years
climate <- annual %>% semi_join(needed_years, by = c("iso", "year")) %>%
  inner_join(links, by = c("iso", "admin_id")) %>% left_join(population, by = c("iso", "admin_id"))

# Kalayaan has neither LandScan coverage nor ERA5-Land climate
# It cannot contribute to an ADM1 climate mean
# It stays missing in the admin panel
# An observed climate value still needs its LandScan weight
has_climate <- is.finite(climate$prcp_poly_1_ERA5LAND) | is.finite(climate$tavg_poly_1_ERA5LAND)
if (any(has_climate & is.na(climate$landscan2011_population))) {
  stop("Missing current LandScan ADM1 weights for observed climate.", call. = FALSE)
}

# Temperature is a sum of daily means in the annual file
# So divide by the days in the year
climate <- climate %>% mutate(
  leap = year %% 4 == 0 & (year %% 100 != 0 | year %% 400 == 0),
  tavg_admin = tavg_poly_1_ERA5LAND / if_else(leap, 366, 365)
)

# -------------------------------
# Average admin climate to ADM1
# -------------------------------

# Population-weighted mean over the units that have a value and a weight
weighted_mean_or_na <- function(values, population) {
  observed <- is.finite(values) & is.finite(population) & population > 0
  if (!any(observed)) return(NA_real_)
  sum(values[observed] * population[observed]) / sum(population[observed])
}
# Plain mean over the years that have a value
mean_or_na <- function(values) {
  if (!any(is.finite(values))) return(NA_real_)
  mean(values[is.finite(values)])
}

# Annual ADM1 climate, plus the population and unit counts behind each mean
adm1_annual <- climate %>% group_by(iso, adm1_id, year) %>% summarize(
  tavg_ERA5LAND_adm1 = weighted_mean_or_na(tavg_admin, landscan2011_population),
  prcp_ERA5LAND_adm1 = weighted_mean_or_na(prcp_poly_1_ERA5LAND, landscan2011_population),
  population_total = sum(landscan2011_population),
  population_with_precip = sum(landscan2011_population[is.finite(prcp_poly_1_ERA5LAND)]),
  admin_units = n(), .groups = "drop"
)

# Long-run ADM1 means over the country's mortality years
# first_year, last_year and precip_years_observed show how many years went in
long_run <- adm1_annual %>% group_by(iso, adm1_id) %>% summarize(
  lr_tavg_ERA5LAND_adm1_avg = mean_or_na(tavg_ERA5LAND_adm1),
  lr_prcp_ERA5LAND_adm1_avg = mean_or_na(prcp_ERA5LAND_adm1),
  first_year = min(year), last_year = max(year),
  precip_years_observed = sum(is.finite(prcp_ERA5LAND_adm1)), .groups = "drop"
)
current <- adm1_annual %>% left_join(long_run, by = c("iso", "adm1_id"))
write_csv(current, file.path(climate_input_dir, "adm1_climate.csv"), na = "")

# -----------------------------------------
# Old country values and saving the panel
# -----------------------------------------

# ADM1 climate of the old panel, one row per old admin unit and year
old <- read_csv(file.path(old_panel_dir, "old_panel_era5_trimmed.csv"), show_col_types = FALSE,
                 col_select = all_of(c("iso", "admin_id", "year", adm1_vars)),
                 col_types = cols(.default = col_character(), year = col_integer())) %>%
  mutate(across(all_of(adm1_vars), as.numeric)) %>% distinct()
stopifnot(!anyDuplicated(old[c("iso", "admin_id", "year")]))

# Old rows get their old ADM1 values, new rows get the ones built above
# row keeps the original row order, so the mortality rows don't move
panel <- read_csv(climate_panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character(), year = col_integer())) %>%
  mutate(row = row_number()) %>% select(-any_of(adm1_vars))
old_rows <- panel %>% filter(source_panel == "old") %>%
  left_join(old, by = c("iso", "admin_id", "year"))
new_rows <- panel %>% filter(source_panel == "new") %>%
  left_join(current %>% select(iso, adm1_id, year, all_of(adm1_vars)), by = c("iso", "adm1_id", "year"))
updated <- bind_rows(old_rows, new_rows) %>% arrange(row) %>% select(-row)
stopifnot(nrow(updated) == nrow(panel))

# Write to a temp file first so the panel is never left half written
temporary <- paste0(climate_panel_file, ".tmp")
write_csv(updated, temporary, na = "")
if (!file.rename(temporary, climate_panel_file)) stop("Could not save ADM1 climate.", call. = FALSE)
message("Updated ADM1 rainfall and temperature: ", climate_panel_file)
