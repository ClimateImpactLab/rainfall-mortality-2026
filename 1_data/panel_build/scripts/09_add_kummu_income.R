# ============================================================
# 09_add_kummu_income.R
#
# Add Kummu income to the combined mortality panels
#
# Kummu is the gridded income dataset we aggregated to the mortality admin
# units
# These variables are separate from the older ADM1 income variables
#
# Annual Kummu values merge by country, admin unit, and year
# The profile variables are 2010-2024 averages and merge by country and admin unit
#
# Inputs:
#   income_data/kummu/output/kummu_admin_year_income.csv
#   income_data/kummu/output/kummu_admin_profile_income.csv
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv
# ============================================================

# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
urban_panel_file <- file.path(panel_dir, "new_mortality_panel_urban.csv")

kummu_root <- "/project/cil/gcp/estimation/rainfall-mortality/income_data/kummu"
kummu_annual_file <- file.path(kummu_root, "output/kummu_admin_year_income.csv")
kummu_profile_file <- file.path(kummu_root, "output/kummu_admin_profile_income.csv")

# -----------------------------
# Variables
# -----------------------------

kummu_numeric_vars <- c(
  "kummu_gdppc", "kummu_loggdppc", "kummu_lowinc_share",
  "kummu_gdppc_avg_2010_2024",
  "kummu_loggdppc_avg_2010_2024",
  "kummu_lowinc_avg_2010_2024",
  "kummu_years_observed_2010_2024",
  "kummu_years_filled_2010_2024",
  "kummu_income_pctile_country"
)

kummu_vars <- c(
  kummu_numeric_vars,
  "kummu_income_basis", "kummu_admin_fallback",
  "kummu_fallback_level", "kummu_profile_income_basis"
)
old_kummu_vars <- c(
  "kummu_low_income_pop_share",
  "kummu_low_income_pop_share_avg_2010_2024"
)

# -----------------------------
# Read Kummu income
# -----------------------------

if (!file.exists(kummu_annual_file)) {
  stop("Missing Kummu annual income file: ", kummu_annual_file, call. = FALSE)
}
if (!file.exists(kummu_profile_file)) {
  stop("Missing Kummu profile income file: ", kummu_profile_file, call. = FALSE)
}

kummu_annual <- read_csv(
  kummu_annual_file,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    iso,
    admin_id,
    year = as.integer(year),
    kummu_gdppc = as.numeric(kummu_gdppc_ppp_filled),
    kummu_loggdppc = as.numeric(kummu_log_gdppc_ppp_filled),
    kummu_lowinc_share = as.numeric(kummu_low_income_pop_share_filled),
    kummu_income_basis,
    kummu_admin_fallback = as.logical(kummu_admin_fallback),
    kummu_fallback_level
  )

kummu_profile <- read_csv(
  kummu_profile_file,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    iso,
    admin_id,
    kummu_gdppc_avg_2010_2024 = as.numeric(kummu_gdppc_ppp_avg_2010_2024),
    kummu_loggdppc_avg_2010_2024 = as.numeric(kummu_log_gdppc_ppp_avg_2010_2024),
    kummu_lowinc_avg_2010_2024 = as.numeric(
      kummu_low_income_pop_share_avg_2010_2024
    ),
    kummu_years_observed_2010_2024 = as.numeric(kummu_years_observed_2010_2024),
    kummu_years_filled_2010_2024 = as.numeric(kummu_years_filled_2010_2024),
    kummu_income_pctile_country = as.numeric(kummu_income_percentile_2010_2024),
    kummu_profile_income_basis
  )

# Check that each Kummu annual row has one country-admin-year
duplicate_annual <- kummu_annual %>%
  count(iso, admin_id, year, name = "rows") %>%
  filter(rows > 1)
if (nrow(duplicate_annual) > 0) {
  stop("Kummu annual keys are not unique", call. = FALSE)
}

# Profile rows are fixed admin-unit values
# Each admin unit should appear once
duplicate_profile <- kummu_profile %>%
  count(iso, admin_id, name = "rows") %>%
  filter(rows > 1)
if (nrow(duplicate_profile) > 0) {
  stop("Kummu profile keys are not unique", call. = FALSE)
}

# Add the 2010-2024 profile columns to each annual Kummu row
kummu <- kummu_annual %>%
  left_join(kummu_profile, by = c("iso", "admin_id"))

# -----------------------------
# Merge Kummu income
# -----------------------------

if (!file.exists(panel_file)) {
  stop("Missing panel file: ", panel_file, call. = FALSE)
}
if (!file.exists(urban_panel_file)) {
  stop("Missing panel file: ", urban_panel_file, call. = FALSE)
}

panel <- read_csv(panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character())) %>%
  mutate(year = as.integer(year))
urban_panel <- read_csv(urban_panel_file, show_col_types = FALSE,
                        col_types = cols(.default = col_character())) %>%
  mutate(year = as.integer(year))

# Drop old Kummu variables first if the script is being rerun
panel <- panel %>%
  select(-any_of(c(kummu_vars, old_kummu_vars)))
urban_panel <- urban_panel %>%
  select(-any_of(c(kummu_vars, old_kummu_vars)))

panel_rows <- nrow(panel)
urban_panel_rows <- nrow(urban_panel)

panel <- panel %>%
  left_join(kummu, by = c("iso", "admin_id", "year"))
urban_panel <- urban_panel %>%
  left_join(kummu, by = c("iso", "admin_id", "year"))

if (nrow(panel) != panel_rows) {
  stop("Kummu merge changed the base panel row count", call. = FALSE)
}
if (nrow(urban_panel) != urban_panel_rows) {
  stop("Kummu merge changed the urban panel row count", call. = FALSE)
}

write_csv(panel, panel_file, na = "")
write_csv(urban_panel, urban_panel_file, na = "")

message("Updated panel: ", panel_file)
message("Updated urban panel: ", urban_panel_file)
