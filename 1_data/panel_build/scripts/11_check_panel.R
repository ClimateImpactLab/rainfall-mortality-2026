# ============================================================
# 11_check_panel.R
#
# Check the final combined mortality panel
#
# This script does not change the panel. It writes a workbook with checks on
# panel size, country coverage, duplicate rows, missing values, and mortality
# outliers before the RDS and Stata files are created
#
# Input:
#   panel_build/combined_panel/new_mortality_panel.csv
#
# Output:
#   checks/panel_checks.xlsx
# ============================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(writexl)
})


# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
check_file <- file.path(check_dir, "panel_checks.xlsx")


# -----------------------------
# Variables
# -----------------------------

# Variables that identify one panel observation
key_vars <- c("iso", "admin_id", "year", "agegroup")

# Core mortality and geography variables required in the final panel
core_vars <- c(
  "adm0", "iso", "adm1_id", "adm2_id", "admin_level", "admin_id",
  "year", "agegroup", "deaths", "population", "deathrate"
)

era5_vars <- c(
  "prcp_poly_1_ERA5LAND", "tavg_poly_1_ERA5LAND",
  "tmax_poly_1_ERA5LAND"
)

chirps_vars <- paste0("prcp_poly_", 1:5, "_CHIRPS")

elevation_vars <- c(
  "elev_median_m", "share_area_elev_lt_10m",
  "elev_pop_median_m", "share_pop_elev_lt_10m"
)

pop_density_vars <- c(
  "panel_pop_density", "landscan2011_pop_density",
  "landscan2011_pop_pop_density", "ghsl2010_pop_pop_density"
)

income_vars <- c(
  "gdppc_adm0", "gdppc_adm1", "loggdppc_adm0",
  "loggdppc_adm1", "gdppc_adm1_avg"
)

kummu_vars <- c(
  "kummu_gdppc", "kummu_loggdppc", "kummu_lowinc_share",
  "kummu_gdppc_avg_2010_2024", "kummu_loggdppc_avg_2010_2024"
)

# Variables checked for missing values by country
check_vars <- c(
  "deaths", "population", "deathrate",
  era5_vars, chirps_vars, income_vars, kummu_vars,
  elevation_vars, pop_density_vars
)

numeric_vars <- c(
  "year", "agegroup", "deaths", "population", "deathrate",
  era5_vars, chirps_vars, income_vars, kummu_vars,
  elevation_vars, pop_density_vars
)


# -----------------------------
# Read panel
# -----------------------------

if (!file.exists(panel_file)) {
  stop("Missing panel file: ", panel_file, call. = FALSE)
}

panel <- read_csv(
  panel_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  mutate(across(any_of(numeric_vars), as.numeric))

# Stop if any variables required for the main panel are missing
missing_required <- setdiff(c(core_vars, era5_vars, income_vars), names(panel))

if (length(missing_required) > 0) {
  stop(
    "Panel is missing required variables: ",
    paste(missing_required, collapse = ", "),
    call. = FALSE
  )
}


# -----------------------------
# Overall summary
# -----------------------------

# Check that each country-admin-year-age group appears only once
duplicate_rows <- panel %>%
  count(across(all_of(key_vars)), name = "rows") %>%
  filter(rows > 1) %>%
  arrange(iso, admin_id, year, agegroup)

summary <- tibble(
  rows = nrow(panel),
  cols = ncol(panel),
  countries = n_distinct(panel$iso),
  admin_units = n_distinct(paste(panel$iso, panel$admin_id)),
  year_min = min(panel$year, na.rm = TRUE),
  year_max = max(panel$year, na.rm = TRUE),
  duplicate_country_admin_year_age = nrow(duplicate_rows)
)


# -----------------------------
# Country and age coverage
# -----------------------------

# Panel size, years, and number of age groups by country
countries <- panel %>%
  group_by(source_panel, iso) %>%
  summarize(
    rows = n(),
    admin_units = n_distinct(admin_id),
    year_min = min(year, na.rm = TRUE),
    year_max = max(year, na.rm = TRUE),
    agegroups = n_distinct(agegroup),
    .groups = "drop"
  ) %>%
  arrange(source_panel, iso)

# Row counts by country and age group
rows_by_age <- panel %>%
  count(source_panel, iso, agegroup, name = "rows") %>%
  arrange(source_panel, iso, agegroup)

# Missing values in variables most likely to matter for analysis
missing_by_country <- panel %>%
  group_by(source_panel, iso) %>%
  summarize(
    rows = n(),
    across(any_of(check_vars), ~ sum(is.na(.x)), .names = "missing_{.col}"),
    .groups = "drop"
  ) %>%
  arrange(source_panel, iso)


# -----------------------------
# Mortality values
# -----------------------------

# Death-rate distribution by country and age group
deathrate_summary <- panel %>%
  group_by(source_panel, iso, agegroup) %>%
  summarize(
    rows = n(),
    min = min(deathrate, na.rm = TRUE),
    p01 = quantile(deathrate, 0.01, na.rm = TRUE),
    median = median(deathrate, na.rm = TRUE),
    p99 = quantile(deathrate, 0.99, na.rm = TRUE),
    max = max(deathrate, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(source_panel, iso, agegroup)

# Highest death rates for manual review
top_deathrates <- panel %>%
  arrange(desc(deathrate)) %>%
  select(
    source_panel, adm0, iso, admin_level, admin_id, admin_name,
    year, agegroup, deaths, population, deathrate
  ) %>%
  head(200)

# Smallest population cells for manual review
small_populations <- panel %>%
  filter(!is.na(population)) %>%
  arrange(population) %>%
  select(
    source_panel, adm0, iso, admin_level, admin_id, admin_name,
    year, agegroup, deaths, population, deathrate
  ) %>%
  head(200)


# -----------------------------
# Write checks
# -----------------------------

dir.create(check_dir, recursive = TRUE, showWarnings = FALSE)

write_xlsx(
  list(
    summary = summary,
    countries = countries,
    rows_by_age = rows_by_age,
    duplicate_rows = duplicate_rows,
    missing_by_country = missing_by_country,
    deathrate_summary = deathrate_summary,
    top_deathrates = top_deathrates,
    small_populations = small_populations
  ),
  check_file
)

print(summary)
message("Wrote checks: ", check_file)
