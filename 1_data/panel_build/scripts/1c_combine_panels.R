# ==============================================================================
# 1c_combine_panels.R
#
# Combine the old panel and new country mortality files
#
# Keep mortality, population and geography only. Climate is added in stage 2,
# and income and other heterogeneity variables are added in stage 3.
# source_panel keeps track of whether each row came from the old or new file.
#
# Input:  old_panel/old_panel_era5_trimmed.csv
#         new_countries/new_countries_mortality.csv
# Output: combined_panel/01_panel_mortality.csv
# ==============================================================================


# -------------
# Packages
# -------------

library(dplyr)
library(readr)

# -------------
# Paths
# -------------

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

old_file <- file.path(old_panel_dir, "old_panel_era5_trimmed.csv")
new_file <- file.path(new_country_dir, "new_countries_mortality.csv")

panel_out <- mortality_panel_file


# -----------------
# Panel variables
# -----------------

# Mortality and geography cols kept for every country
core_vars <- c(
  "adm0", "iso",
  "adm1_id", "adm1_name", "adm2_id", "adm2_name", "adm3_id", "adm3_name",
  "admin_level", "admin_id", "admin_name",
  "year", "agegroup", "deaths", "population", "deathrate"
)

# The old panel also carries income and ERA5-Land climate from 1a
# They are dropped here, climate comes back in stage 2
panel_vars <- core_vars
numeric_vars <- c("year", "agegroup", "deaths", "population", "deathrate")


# -----------------------------
# Same columns in both panels
# -----------------------------

# Add any missing cols as NA before stacking the 2 files
add_missing_cols <- function(data, vars) {
  for (var in setdiff(vars, names(data))) {
    data[[var]] <- NA
  }
  data
}

# Put the cols in the same order and give them the same types
# IDs and names are text, deaths and population are numbers
# source_panel records which file the rows came from
clean_panel <- function(data, source) {
  data %>%
    add_missing_cols(panel_vars) %>%
    select(all_of(panel_vars)) %>%
    mutate(
      source_panel = source,
      across(setdiff(panel_vars, numeric_vars), as.character),
      across(any_of(numeric_vars), as.numeric)
    )
}


# -------------
# Read inputs
# -------------

# Read everything as text first so IDs keep their leading zeroes
old_panel <- read_csv(old_file, show_col_types = FALSE, col_types = cols(.default = col_character()))
new_panel <- read_csv(new_file, show_col_types = FALSE, col_types = cols(.default = col_character()))


# -------------
# Stack
# -------------

# Old rows first, then new, sorted by unit, year and age group
panel <- bind_rows(clean_panel(old_panel, "old"), clean_panel(new_panel, "new")) %>%
  arrange(iso, admin_id, year, agegroup)

# One row per admin unit x year x age group, so a country can't be in both
# the old panel and the new countries
duplicate_keys <- panel %>%
  count(iso, admin_id, year, agegroup, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_keys) > 0) {
  stop("Combined panel has duplicate iso-admin_id-year-agegroup keys.", call. = FALSE)
}

# -------------
# Write
# -------------

write_csv(panel, panel_out, na = "")

message("Wrote panel: ", panel_out)
