# ============================================================
# 07_add_adm1_climate.R
#
# Add ADM1 ERA5-Land climate variables for the new countries
#
# ERA5-Land is available at ADM2 for AUS, COL, ECU, KOR, and PER, and at ADM3
# for PHL. This script averages those values to ADM1 using LandScan 2011
# population weights
#
# The long-run ADM1 variables are averages over the years available for each
# country, matching the approach used for the old panel
#
# Inputs:
#   panel_build/new_countries/new_countries_mortality.csv
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv, if present
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv, if present
#
# Usually run through:
#   1_data/panel_build/run_panel_build.sbatch
# ============================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})


# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

mortality_file <- file.path(new_country_dir, "new_countries_mortality.csv")
panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
urban_panel_file <- file.path(panel_dir, "new_mortality_panel_urban.csv")


# -----------------------------
# Country IDs and ADM1 variables
# -----------------------------

# Admin level and ID variable used in each country's ERA5-Land files
country_ids <- tibble::tribble(
  ~iso,  ~level, ~id_column,       ~id_length,
  "AUS", "adm2", "adm2_id",                 5,
  "COL", "adm2", "adm2_code",               5,
  "ECU", "adm2", "adm2_id",                 4,
  "KOR", "adm2", "adm2_n_",                 5,
  "PER", "adm2", "shp_adm2_code",           4,
  "PHL", "adm3", "adm3_psgc",              10
)

new_countries <- country_ids$iso

# Annual ADM1 climate variables
annual_vars <- c(
  "tavg_ERA5LAND_adm1", "prcp_ERA5LAND_adm1",
  "tmax_cdd_20C_ERA5LAND_adm1", "tmax_hdd_20C_ERA5LAND_adm1"
)

# Long-run ADM1 climate averages
lr_vars <- c(
  "lr_tavg_ERA5LAND_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg",
  "lr_cdd_20C_ERA5LAND_adm1_avg", "lr_hdd_20C_ERA5LAND_adm1_avg"
)

adm1_vars <- c(annual_vars, lr_vars)


# -----------------------------
# Functions
# -----------------------------

# Number of days in each year
days_in_year <- function(year) {
  leap_year <- (year %% 4 == 0 & year %% 100 != 0) | year %% 400 == 0
  ifelse(leap_year, 366, 365)
}

# Population-weighted mean using non-missing values with positive weights
weighted_mean_or_na <- function(value, weight) {
  keep <- !is.na(value) & !is.na(weight) & weight > 0
  
  if (!any(keep)) {
    return(NA_real_)
  }
  
  weighted.mean(value[keep], weight[keep])
}


# -----------------------------
# Read mortality panel
# -----------------------------

# The mortality file provides the admin-to-ADM1 links and country-year coverage
if (!file.exists(mortality_file)) {
  stop(
    "Missing new-country mortality file. Run 02_prepare_new_countries.R first: ",
    mortality_file, call. = FALSE
  )
}

mortality <- read_csv(
  mortality_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

# Check that the all-age group exists before using it for population weights
missing_all_age <- mortality %>%
  group_by(iso, admin_id, year) %>%
  summarize(has_all_age = any(agegroup == "0"), .groups = "drop") %>%
  filter(!has_all_age)

if (nrow(missing_all_age) > 0) {
  stop("Some new-country admin-years do not have agegroup 0", call. = FALSE)
}

# Match each lower-level admin unit to its ADM1
admin_to_adm1 <- mortality %>%
  distinct(iso, admin_id, adm1_id) %>%
  filter(!is.na(admin_id), admin_id != "",
         !is.na(adm1_id), adm1_id != "")

# Each admin unit should belong to only one ADM1
duplicate_admin_to_adm1 <- admin_to_adm1 %>%
  count(iso, admin_id, name = "adm1_rows") %>%
  filter(adm1_rows > 1)

if (nrow(duplicate_admin_to_adm1) > 0) {
  stop("Some new-country admin IDs match more than one ADM1", call. = FALSE)
}

# Country-years that need ADM1 climate
needed_years <- mortality %>%
  distinct(iso, year) %>%
  mutate(year = as.integer(year)) %>%
  arrange(iso, year)


# -----------------------------
# ERA5-Land files
# -----------------------------

# Annual and degree-day files needed for each country-year
source_files <- needed_years %>%
  inner_join(country_ids, by = "iso") %>%
  mutate(
    annual_file = file.path(
      era5land_dir, iso, "annual",
      paste0("era5land_", str_to_lower(iso), "_", level, "_annual_", year, ".csv")
    ),
    degree_day_file = file.path(
      era5land_dir, iso, "degree_days",
      paste0("era5land_", str_to_lower(iso), "_", level, "_degree_days_", year, ".csv")
    )
  )

# Stop before reading climate if any required file is missing
missing_files <- source_files %>%
  filter(!file.exists(annual_file) | !file.exists(degree_day_file)) %>%
  transmute(
    iso, year,
    missing_annual_file = if_else(file.exists(annual_file), NA, annual_file),
    missing_degree_day_file = if_else(file.exists(degree_day_file), NA, degree_day_file)
  )

if (nrow(missing_files) > 0) {
  stop("Some ERA5-Land annual or degree-day files are missing", call. = FALSE)
}


# -----------------------------
# LandScan population
# -----------------------------

# Read LandScan 2011 population totals used to weight each lower-level admin unit
population <- lapply(seq_len(nrow(country_ids)), function(i) {
  info <- country_ids[i, ]
  
  # LandScan totals are stored in the ERA5-Land admin summary files
  path <- file.path(
    climate_root, "weights", "landscan2011", "ERA5-LAND", info$iso,
    paste0("era5land_", str_to_lower(info$iso), "_", info$level, "_admin_summary.csv")
  )
  
  if (!file.exists(path)) {
    stop("Missing ERA5-Land admin summary file: ", path, call. = FALSE)
  }
  
  pop <- read_csv(path, show_col_types = FALSE,
                  col_types = cols(.default = col_character()))
  
  # Check that the country ID and LandScan population are available
  required_cols <- c("region_id", info$id_column, "population_total_landscan2011")
  missing_cols <- setdiff(required_cols, names(pop))
  
  if (length(missing_cols) > 0) {
    stop(
      "Admin summary file is missing expected columns: ", path,
      "\n", paste(missing_cols, collapse = ", "),
      call. = FALSE
    )
  }
  
  # Format the country ID to match `admin_id` in the mortality panel
  pop %>%
    transmute(
      iso = info$iso,
      admin_id = str_pad(as.character(.data[[info$id_column]]),
                         info$id_length, pad = "0"),
      population_total_landscan2011 = as.numeric(population_total_landscan2011)
    )
}) %>%
  bind_rows()

# Each admin unit should have only one LandScan population value
duplicate_population <- population %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_population) > 0) {
  stop("LandScan population has duplicate country-admin rows", call. = FALSE)
}


# -----------------------------
# Read annual climate
# -----------------------------

# Read annual precipitation/temperature and degree days for each country-year
climate <- lapply(seq_len(nrow(source_files)), function(i) {
  info <- source_files[i, ]
  
  annual <- read_csv(info$annual_file, show_col_types = FALSE,
                     col_types = cols(.default = col_character()))
  
  degree_days <- read_csv(info$degree_day_file, show_col_types = FALSE,
                          col_types = cols(.default = col_character()))
  
  # Variables required from the two ERA5-Land files
  annual_needed <- c(info$id_column, "prcp_pop_p1", "tmean_pop_p1")
  degree_day_needed <- c(info$id_column, "tmax_cdd_20C_pop", "tmax_hdd_20C_pop")
  
  missing_annual_cols <- setdiff(annual_needed, names(annual))
  missing_degree_day_cols <- setdiff(degree_day_needed, names(degree_days))
  
  if (length(missing_annual_cols) > 0) {
    stop(
      "Annual climate file is missing expected columns: ", info$annual_file,
      "\n", paste(missing_annual_cols, collapse = ", "),
      call. = FALSE
    )
  }
  
  if (length(missing_degree_day_cols) > 0) {
    stop(
      "Degree-day file is missing expected columns: ", info$degree_day_file,
      "\n", paste(missing_degree_day_cols, collapse = ", "),
      call. = FALSE
    )
  }
  
  # `tmean_pop_p1` is the sum of daily mean temperature, so divide by the
  # number of days in the year. Precip is already an annual total
  annual <- annual %>%
    transmute(
      iso = info$iso,
      admin_id = str_pad(as.character(.data[[info$id_column]]),
                         info$id_length, pad = "0"),
      year = as.integer(info$year),
      tavg_admin = as.numeric(tmean_pop_p1) / days_in_year(as.integer(info$year)),
      prcp_admin = as.numeric(prcp_pop_p1)
    )
  
  # Cooling and heating degree days are already annual totals
  degree_days <- degree_days %>%
    transmute(
      iso = info$iso,
      admin_id = str_pad(as.character(.data[[info$id_column]]),
                         info$id_length, pad = "0"),
      year = as.integer(info$year),
      cdd_admin = as.numeric(tmax_cdd_20C_pop),
      hdd_admin = as.numeric(tmax_hdd_20C_pop)
    )
  
  annual %>%
    left_join(degree_days, by = c("iso", "admin_id", "year"))
}) %>%
  bind_rows()

# Each admin-year should appear only once in the climate data
duplicate_climate <- climate %>%
  count(iso, admin_id, year, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_climate) > 0) {
  stop("ERA5-Land climate has duplicate country-admin-year rows.", call. = FALSE)
}

# Add the ADM1 ID and LandScan population needed for the ADM1 averages
climate <- climate %>%
  left_join(admin_to_adm1, by = c("iso", "admin_id")) %>%
  left_join(population, by = c("iso", "admin_id"))

# Every climate row needs an ADM1 and a pop weight
missing_adm1_or_population <- climate %>%
  filter(is.na(adm1_id) | is.na(population_total_landscan2011))

if (nrow(missing_adm1_or_population) > 0) {
  stop("Some climate rows are missing ADM1 IDs or LandScan population", call. = FALSE)
}


# -----------------------------
# Average to ADM1
# -----------------------------

# Population-weighted ADM1 climate for each year
adm1_annual <- climate %>%
  group_by(iso, adm1_id, year) %>%
  summarize(
    tavg_ERA5LAND_adm1 = weighted_mean_or_na(tavg_admin, population_total_landscan2011),
    prcp_ERA5LAND_adm1 = weighted_mean_or_na(prcp_admin, population_total_landscan2011),
    tmax_cdd_20C_ERA5LAND_adm1 = weighted_mean_or_na(cdd_admin, population_total_landscan2011),
    tmax_hdd_20C_ERA5LAND_adm1 = weighted_mean_or_na(hdd_admin, population_total_landscan2011),
    admin_units = n_distinct(admin_id),
    admin_units_with_population = n_distinct(admin_id[population_total_landscan2011 > 0]),
    .groups = "drop"
  )

# Long-run averages over the years available for each country
adm1_lr <- adm1_annual %>%
  group_by(iso, adm1_id) %>%
  summarize(
    adm1_climate_years = n_distinct(year),
    lr_tavg_ERA5LAND_adm1_avg = mean(tavg_ERA5LAND_adm1, na.rm = TRUE),
    lr_prcp_ERA5LAND_adm1_avg = mean(prcp_ERA5LAND_adm1, na.rm = TRUE),
    lr_cdd_20C_ERA5LAND_adm1_avg = mean(tmax_cdd_20C_ERA5LAND_adm1, na.rm = TRUE),
    lr_hdd_20C_ERA5LAND_adm1_avg = mean(tmax_hdd_20C_ERA5LAND_adm1, na.rm = TRUE),
    .groups = "drop"
  )

# Add the long-run averages to the annual ADM1 data
adm1_climate <- adm1_annual %>%
  left_join(adm1_lr, by = c("iso", "adm1_id")) %>%
  select(iso, adm1_id, year, all_of(adm1_vars))

# Each ADM1-year should appear only once
duplicate_adm1 <- adm1_climate %>%
  count(iso, adm1_id, year, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_adm1) > 0) {
  stop("ADM1 climate has duplicate country-ADM1-year rows.", call. = FALSE)
}


# -----------------------------
# Add to panels
# -----------------------------

# Add ADM1 climate for the new countries while leaving old-country values unchanged
add_adm1_climate <- function(path) {
  if (!file.exists(path)) {
    stop("Missing panel file: ", path, call. = FALSE)
  }
  
  panel <- read_csv(path, show_col_types = FALSE,
                    col_types = cols(.default = col_character())) %>%
    mutate(year = as.integer(year), adm1_id = as.character(adm1_id))
  
  old_rows <- nrow(panel)
  old_names <- names(panel)
  
  old_country_rows <- panel %>%
    filter(!iso %in% new_countries)
  
  # Replace the ADM1 climate variables for the new countries
  new_country_rows <- panel %>%
    filter(iso %in% new_countries) %>%
    select(-any_of(adm1_vars)) %>%
    left_join(adm1_climate, by = c("iso", "adm1_id", "year"))
  
  out <- bind_rows(old_country_rows, new_country_rows) %>%
    arrange(iso, admin_id, year, agegroup)
  
  # The merge should not add or remove panel rows
  if (nrow(out) != old_rows) {
    stop("ADM1 climate merge changed the row count for ", path, call. = FALSE)
  }
  
  # All variables already in the panel should still be present
  missing_old_names <- setdiff(old_names, names(out))
  
  if (length(missing_old_names) > 0) {
    stop(
      "ADM1 climate merge dropped existing columns: ",
      paste(missing_old_names, collapse = ", "),
      call. = FALSE
    )
  }
  
  write_csv(out, path, na = "")
  out
}

# Update the main combined panel
panel_out <- add_adm1_climate(panel_file)

# Update the urban panel too if it has already been created
urban_out <- NULL
if (file.exists(urban_panel_file)) {
  urban_out <- add_adm1_climate(urban_panel_file)
}


message("Updated panel: ", panel_file)

if (!is.null(urban_out)) {
  message("Updated urban panel: ", urban_panel_file)
}
