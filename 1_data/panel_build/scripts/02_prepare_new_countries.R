# ============================================================
# 02_prepare_new_countries.R
#
# Combine the cleaned mortality panels for the newly added countries
#
# Each country has already been cleaned in its own country folder
# The cleaned files should have the same mortality variables
# They use `admin_id` and `admin_name` for the final analysis unit
# ADM1, ADM2, and ADM3 variables are also kept where those levels are available
#
# This script only checks and combines the mortality data
# Climate, income, GHSL urban share, Kummu income, elevation, and population
# density are added later
#
# Inputs:
#   country_files.csv
#   cleaned country mortality files listed in country_files.csv
#
# Outputs:
#   panel_build/new_countries/new_countries_mortality.csv
#
# Usually run through:
#   1_data/panel_build/run_panel_build.sbatch
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)


# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

country_file <- file.path(build_dir, "country_files.csv")
out_file <- file.path(new_country_dir, "new_countries_mortality.csv")


# -----------------------------
# Country file list
# -----------------------------

# List of cleaned country files to include
country_files <- read_csv(
  country_file,
  col_types = cols(.default = col_character())
)

# Columns required in every cleaned country file
# Extra country-specific variables are dropped
required_cols <- c(
  "iso", "adm0", "admin_level", "admin_id", "admin_name",
  "adm1_id", "adm1_name", "adm2_id", "adm2_name", "adm3_id", "adm3_name",
  "year", "agegroup", "deaths", "population", "deathrate"
)

# Stop here if a country file listed in `country_files.csv` is missing
missing_files <- country_files %>%
  filter(!file.exists(panel_file))

if (nrow(missing_files) > 0) {
  stop(
    "Missing country panel file(s):\n",
    paste(missing_files$panel_file, collapse = "\n")
  )
}


# -----------------------------
# Read country panels
# -----------------------------

# Read one cleaned country panel and set column types explicitly
read_country_panel <- function(file) {
  panel <- read_csv(
    file,
    col_types = cols(
      iso = col_character(),
      adm0 = col_character(),
      admin_level = col_character(),
      admin_id = col_character(),
      admin_name = col_character(),
      adm1_id = col_character(),
      adm1_name = col_character(),
      adm2_id = col_character(),
      adm2_name = col_character(),
      adm3_id = col_character(),
      adm3_name = col_character(),
      year = col_integer(),
      agegroup = col_integer(),
      deaths = col_double(),
      population = col_double(),
      deathrate = col_double(),
      .default = col_guess()
    )
  )
  
  # Stop here if a cleaned country file is missing a variable used below
  missing_cols <- setdiff(required_cols, names(panel))
  if (length(missing_cols) > 0) {
    stop(
      "Missing required column(s) in ", file, ":\n",
      paste(missing_cols, collapse = ", ")
    )
  }
  
  # Keep the required columns and make the admin variables character
  panel %>%
    select(all_of(required_cols)) %>%
    mutate(
      across(
        c(
          iso, adm0, admin_level, admin_id, admin_name,
          adm1_id, adm1_name, adm2_id, adm2_name, adm3_id, adm3_name
        ),
        as.character
      )
    )
}

# Read country files one at a time so the Slurm log shows which file failed
country_panels <- list()

for (row in seq_len(nrow(country_files))) {
  file <- country_files$panel_file[[row]]
  iso <- country_files$iso[[row]]
  
  message("Reading ", iso, ": ", file)
  country_panels[[row]] <- read_country_panel(file)
}


# Combine all country panels and sort the final rows
panel <- bind_rows(country_panels) %>%
  arrange(iso, admin_id, year, agegroup)

# The combined panel should contain exactly the countries listed in `country_files.csv`
expected_countries <- sort(country_files$iso)
actual_countries <- sort(unique(panel$iso))
missing_countries <- setdiff(expected_countries, actual_countries)
extra_countries <- setdiff(actual_countries, expected_countries)

if (length(missing_countries) > 0 || length(extra_countries) > 0) {
  stop("Combined country list does not match country_files.csv", call. = FALSE)
}

# Each country-admin-year-age group should appear only once
duplicate_keys <- panel %>%
  count(iso, admin_id, year, agegroup, name = "rows") %>%
  filter(rows > 1) %>%
  arrange(iso, admin_id, year, agegroup)

if (nrow(duplicate_keys) > 0) {
  stop("New-country mortality panel has duplicate country-admin-year-age rows", call. = FALSE)
}

# -----------------------------
# Write outputs
# -----------------------------

dir.create(new_country_dir, recursive = TRUE, showWarnings = FALSE)

# Write the combined mortality panel
write_csv(panel, out_file, na = "")

message("Wrote new country mortality panel: ", out_file)
