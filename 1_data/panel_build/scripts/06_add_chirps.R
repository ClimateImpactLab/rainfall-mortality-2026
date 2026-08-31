# ============================================================
# 06_add_chirps.R
#
# Add CHIRPS precip to the combined mortality panel
#
# CHIRPS contains precip only
# This script reads the annual country files,
# matches them to `admin_id`, and adds the five CHIRPS precipitation polynomial
# variables to the panel
#
# CHIRPS admin IDs are stored differently across countries
# The code below handles the country cases directly
#
# The script overwrites `new_mortality_panel.csv` after checking that the merge
# does not change the number of mortality rows or remove existing variables
#
# Input:
#   panel_build/combined_panel/new_mortality_panel.csv
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.csv
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

panel_file <- file.path(panel_dir, "new_mortality_panel.csv")

# -----------------------------
# CHIRPS country IDs
# -----------------------------

# CHIRPS was aggregated at ADM2 for most countries, ADM3 for the Philippines,
# and ADM1 for Japan
chirps_country_ids <- tibble::tribble(
  ~iso,  ~level,
  "AUS", "adm2",
  "BRA", "adm2",
  "COL", "adm2",
  "ECU", "adm2",
  "IND", "adm2",
  "JPN", "adm1",
  "KOR", "adm2",
  "MEX", "adm2",
  "PER", "adm2",
  "PHL", "adm3"
)

# CHIRPS files use names like `prcp_pop_p1`
# The panel uses names like `prcp_poly_1_CHIRPS`
chirps_in <- paste0("prcp_pop_p", 1:5)
chirps_out <- paste0("prcp_poly_", 1:5, "_CHIRPS")

# -----------------------------
# Small ID edits
# -----------------------------

drop_leading_zeroes <- function(x) {
  out <- str_replace(as.character(x), "^0+", "")
  if_else(out == "", "0", out)
}

read_chirps_year <- function(iso, year, level) {
  path <- file.path(
    chirps_dir,
    iso,
    "annual",
    paste0("chirps_", str_to_lower(iso), "_", level, "_annual_", year, ".csv")
  )

  if (!file.exists(path)) {
    return(tibble(
      iso = iso,
      year = as.character(year),
      missing_file = path
    ))
  }

  climate <- read_csv(path, show_col_types = FALSE, col_types = cols(.default = col_character()))

  # Use the CHIRPS ID columns needed for each country
  if (iso == "AUS") {
    id_field <- "adm2_id"
    id_width <- 5
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "BRA") {
    id_field <- "ID_2"
    id_width <- 4
    required_cols <- c("year", "ID_1", id_field, chirps_in)
  } else if (iso == "COL") {
    id_field <- "adm2_code"
    id_width <- 5
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "ECU") {
    id_field <- "adm2_id"
    id_width <- 4
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "IND") {
    id_field <- "UNID"
    id_width <- 3
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "JPN") {
    id_field <- "ID_1"
    id_width <- 2
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "KOR") {
    id_field <- "adm2_n_"
    id_width <- 5
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "MEX") {
    id_field <- "GEOID"
    id_width <- 9
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "PER") {
    id_field <- "shp_adm2_code"
    id_width <- 4
    required_cols <- c("year", id_field, chirps_in)
  } else if (iso == "PHL") {
    id_field <- "adm3_psgc"
    id_width <- 10
    required_cols <- c("year", id_field, chirps_in)
  } else {
    stop("No CHIRPS ID code written for ", iso, call. = FALSE)
  }

  missing_cols <- setdiff(required_cols, names(climate))
  if (length(missing_cols) > 0) {
    stop("CHIRPS file is missing expected columns: ", path, call. = FALSE)
  }

  id <- str_pad(as.character(climate[[id_field]]), id_width, pad = "0")

  # AUS, COL, ECU, KOR, PER, and PHL use the CHIRPS admin code as `admin_id`
  # after restoring leading zeroes
  if (iso %in% c("AUS", "COL", "ECU", "KOR", "PER", "PHL")) {
    admin_id <- id
  } else if (iso == "BRA") {
    # Brazil's old-panel ID is ADM1_ADM2, without leading zeroes
    admin_id <- paste(
      drop_leading_zeroes(climate[["ID_1"]]),
      drop_leading_zeroes(id),
      sep = "_"
    )
  } else if (iso %in% c("IND", "MEX")) {
    # India and Mexico use old-panel admin IDs that are easiest to recover from
    # the existing panel
    admin_id <- old_admin_lookup$admin_id[
      match(paste(iso, drop_leading_zeroes(id)), paste(old_admin_lookup$iso, old_admin_lookup$adm2_id))
    ]
  } else if (iso == "JPN") {
    # Japan is ADM1 in the old panel
    admin_id <- paste0(drop_leading_zeroes(id), "_")
  } else {
    admin_id <- NA_character_
  }

  climate %>%
    transmute(
      iso = iso,
      admin_id = admin_id,
      year = as.character(year),
      across(all_of(chirps_in), as.numeric)
    ) %>%
    rename(setNames(chirps_in, chirps_out))
}

# -----------------------------
# Read panel
# -----------------------------

# CHIRPS is added after `05_build_panel.R` creates the combined panel
if (!file.exists(panel_file)) {
  stop("Missing panel file. Run 05_build_panel.R first: ", panel_file, call. = FALSE)
}

panel <- read_csv(panel_file, show_col_types = FALSE, col_types = cols(.default = col_character()))
old_names <- names(panel)
old_rows <- nrow(panel)

# Keep the old-panel ADM2-to-admin lookup for India and Mexico
# Their CHIRPS files use ADM2 codes, but the panel uses the old Carleton ID
old_admin_lookup <- panel %>%
  filter(!is.na(adm2_id), adm2_id != "") %>%
  distinct(iso, adm2_id, admin_id)

# Only read the country-years that are present in the combined panel
needed <- panel %>%
  distinct(iso, admin_id, year) %>%
  mutate(year = as.character(year))

# -----------------------------
# Read CHIRPS files
# -----------------------------

# Skip countries that are not present in this panel
available_chirps_countries <- chirps_country_ids %>%
  semi_join(needed, by = "iso")

# Read annual CHIRPS files country by country
chirps <- lapply(seq_len(nrow(available_chirps_countries)), function(i) {
  row <- available_chirps_countries[i, ]
  years <- needed %>%
    filter(iso == row$iso) %>%
    distinct(year) %>%
    arrange(year) %>%
    pull(year)

  bind_rows(lapply(years, function(year) {
    read_chirps_year(
      iso = row$iso,
      year = year,
      level = row$level
    )
  }))
}) %>%
  bind_rows()

if (!"missing_file" %in% names(chirps)) {
  chirps$missing_file <- NA_character_
}

# Files expected from the panel country-years but not found
missing_files <- chirps %>%
  filter(!is.na(missing_file)) %>%
  select(iso, year, missing_file)

if (nrow(missing_files) > 0) {
  stop("Missing CHIRPS files", call. = FALSE)
}

chirps <- chirps %>%
  filter(is.na(missing_file)) %>%
  select(-missing_file) %>%
  filter(!is.na(admin_id))

# CHIRPS should have at most one row per country-admin-year before merging
duplicate_chirps <- chirps %>%
  count(iso, admin_id, year, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_chirps) > 0) {
  # Duplicated CHIRPS keys would duplicate mortality rows
  stop("CHIRPS keys are not unique", call. = FALSE)
}

# Keep only CHIRPS rows that can merge to the combined panel
chirps <- chirps %>%
  semi_join(needed, by = c("iso", "admin_id", "year"))

# -----------------------------
# Merge
# -----------------------------

# Add CHIRPS variables to every mortality row
panel_chirps <- panel %>%
  select(-any_of(chirps_out)) %>%
  left_join(chirps, by = c("iso", "admin_id", "year"))

if (nrow(panel_chirps) != old_rows) {
  # CHIRPS should not add or remove mortality rows
  stop("CHIRPS merge changed row count", call. = FALSE)
}

# All variables already in the panel should still be present
missing_old_names <- setdiff(old_names, names(panel_chirps))
if (length(missing_old_names) > 0) {
  stop("CHIRPS merge dropped existing columns: ", paste(missing_old_names, collapse = ", "), call. = FALSE)
}

new_cols <- setdiff(names(panel_chirps), old_names)
expected_new <- setdiff(chirps_out, old_names)
if (!setequal(new_cols, expected_new)) {
  stop("Unexpected new columns after CHIRPS merge", call. = FALSE)
}

# -----------------------------
# Write outputs
# -----------------------------

# Write the panel with CHIRPS added
write_csv(panel_chirps, panel_file, na = "")

message("Overwrote panel with CHIRPS variables: ", panel_file)
message("Rows preserved: ", old_rows)
message("Added columns: ", paste(expected_new, collapse = ", "))
