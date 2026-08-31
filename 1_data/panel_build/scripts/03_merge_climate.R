# ============================================================
# 03_merge_climate.R
#
# Add ERA5-Land annual climate variables to the new-country mortality panel
#
# Climate is aggregated separately
# This script reads the annual country files and merges them to the mortality
# panel by `iso`, `admin_id`, and `year`
#
# Most countries use ADM2 climate files, the Philippines uses ADM3
# Climate IDs are stored differently across countries
# The ID column is set separately for each country
# Leading zeroes are added where needed before matching to `admin_id`
#
# Inputs:
#   panel_build/new_countries/new_countries_mortality.csv
#   country-level ERA5-Land annual files under climate_data/ERA5-LAND
#
# Outputs:
#   panel_build/new_countries/new_countries_climate.csv
#   panel_build/new_countries/new_countries_mortality_climate.csv
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

country_file <- file.path(build_dir, "country_files.csv")
mortality_file <- file.path(new_country_dir, "new_countries_mortality.csv")

climate_out <- file.path(new_country_dir, "new_countries_climate.csv")
panel_out <- file.path(new_country_dir, "new_countries_mortality_climate.csv")


# -----------------------------
# Country IDs
# -----------------------------

# Admin ID column in each country's climate files
climate_id_columns <- c(
  AUS = "adm2_id", COL = "adm2_code", ECU = "adm2_id",
  KOR = "adm2_n_", PER = "shp_adm2_code", PHL = "adm3_psgc"
)

# Admin level used in each country's climate file names
climate_level <- c(
  AUS = "adm2", COL = "adm2", ECU = "adm2",
  KOR = "adm2", PER = "adm2", PHL = "adm3"
)

# Add leading zeroes where needed so climate IDs match `admin_id`
climate_id_width <- c(
  AUS = 5, COL = 5, ECU = 4,
  KOR = 5, PER = 4, PHL = 10
)


# -----------------------------
# Climate variable names
# -----------------------------

# Variable names in the country climate files
climate_names <- unlist(lapply(1:5, function(power) {
  c(
    paste0("prcp_pop_p", power), paste0("tmean_pop_p", power),
    paste0("tmax_pop_p", power)
  )
}))

# Corresponding variable names used in the mortality panel
panel_names <- unlist(lapply(1:5, function(power) {
  c(
    paste0("prcp_poly_", power, "_ERA5LAND"), paste0("tavg_poly_", power, "_ERA5LAND"),
    paste0("tmax_poly_", power, "_ERA5LAND")
  )
}))


# -----------------------------------
# Read one country-year climate file
# -----------------------------------

read_climate_year <- function(iso, year) {
  
  # Get the ID column, admin level, and ID length for this country
  id_column <- climate_id_columns[[iso]]
  level <- climate_level[[iso]]
  id_width <- climate_id_width[[iso]]
  
  path <- file.path(
    era5land_dir,
    iso,
    "annual",
    paste0("era5land_", str_to_lower(iso), "_", level, "_annual_", year, ".csv")
  )
  
  if (!file.exists(path)) {
    return(tibble(
      iso = iso,
      year = as.integer(year),
      missing_file = path
    ))
  }
  
  climate <- read_csv(
    path,
    show_col_types = FALSE,
    col_types = cols(.default = col_character())
  )
  
  # Stop here if the climate file is missing the ID or climate variables
  missing_cols <- setdiff(c("year", id_column, climate_names), names(climate))
  if (length(missing_cols) > 0) {
    stop(
      "Climate file is missing expected columns: ",
      path,
      "\n",
      paste(missing_cols, collapse = ", "),
      call. = FALSE
    )
  }
  
  # Match the climate IDs to `admin_id` and rename the climate variables
  climate %>%
    transmute(
      iso = iso,
      admin_id = str_pad(as.character(.data[[id_column]]), id_width, pad = "0"),
      year = as.integer(year),
      across(all_of(climate_names), as.numeric)
    ) %>%
    rename(setNames(climate_names, panel_names))
}



# -----------------------------
# Read inputs
# -----------------------------

# Country list and year range for each country
countries <- read_csv(country_file, show_col_types = FALSE, col_types = cols(.default = col_character())) %>%
  mutate(
    start_year = as.integer(start_year),
    end_year = as.integer(end_year)
  )

# Mortality-only panel from step 02
mortality <- read_csv(mortality_file, show_col_types = FALSE, col_types = cols(.default = col_character())) %>%
  mutate(
    year = as.integer(year),
    agegroup = as.integer(agegroup),
    deaths = as.numeric(deaths),
    population = as.numeric(population),
    deathrate = as.numeric(deathrate),
    admin_id = as.character(admin_id)
  )

# Admin-years that need climate data
needed <- mortality %>%
  distinct(iso, admin_id, year)


# -----------------------------
# Read ERA5-Land annual files
# -----------------------------

# Stop here if a country in the panel has no climate ID column listed above
missing_id_country <- setdiff(unique(needed$iso), names(climate_id_columns))
if (length(missing_id_country) > 0) {
  stop(
    "Missing climate ID column for: ",
    paste(missing_id_country, collapse = ", "),
    call. = FALSE
  )
}

# Read all country-year climate files needed for the mortality panel
climate_parts <- list()

# Index for storing each country-year file in `climate_parts`
part <- 1

for (row in seq_len(nrow(countries))) {
  iso <- countries$iso[[row]]
  
  years <- needed %>%
    filter(iso == !!iso) %>%
    distinct(year) %>%
    arrange(year) %>%
    pull(year)
  
  for (year in years) {
    climate_parts[[part]] <- read_climate_year(iso, year)
    part <- part + 1
  }
}

climate <- bind_rows(climate_parts)

# If all climate files were found, add this column so the code below still works
if (!"missing_file" %in% names(climate)) {
  climate$missing_file <- NA_character_
}

missing_files <- climate %>%
  filter(!is.na(missing_file)) %>%
  select(iso, year, missing_file)

if (nrow(missing_files) > 0) {
  stop("Missing ERA5-Land climate files", call. = FALSE)
}

# Drop rows that only record missing files
climate <- climate %>%
  filter(is.na(missing_file)) %>%
  select(-missing_file)

# Duplicate climate rows would duplicate mortality rows after the merge
duplicate_climate <- climate %>%
  count(iso, admin_id, year, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_climate) > 0) {
  stop("Climate admin-year IDs are not unique", call. = FALSE)
}

# Keep only climate admin-years that appear in the mortality panel
climate <- climate %>%
  semi_join(needed, by = c("iso", "admin_id", "year")) %>%
  arrange(iso, admin_id, year)

# Mortality admin-years with no matching climate row
unmatched <- needed %>%
  anti_join(climate, by = c("iso", "admin_id", "year")) %>%
  arrange(iso, admin_id, year)

if (nrow(unmatched) > 0) {
  stop("Some mortality admin-years have no ERA5-Land climate row", call. = FALSE)
}

# -----------------------------
# Merge
# -----------------------------

# Merge climate onto the mortality panel
# The same admin-year climate values are repeated across age groups
panel <- mortality %>%
  left_join(climate, by = c("iso", "admin_id", "year"))

if (nrow(panel) != nrow(mortality)) {
  stop("Climate merge changed the row count.", call. = FALSE)
}


# -----------------------------
# Write outputs
# -----------------------------

dir.create(new_country_dir, recursive = TRUE, showWarnings = FALSE)

# Write the combined climate data
write_csv(climate, climate_out)

# Write the mortality panel with climate variables added
write_csv(panel, panel_out)

message("Wrote climate file: ", climate_out)
message("Wrote panel file: ", panel_out)
