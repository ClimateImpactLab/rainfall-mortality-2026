# ============================================================
# 01_panel_diagnostics.R
#
# Quick checks on the rainfall-mortality panel
#
# The regression scripts assume that country-admin-year-age rows are unique and
# that the main climate, urban-share, income, and mortality variables are present
# This script writes small CSVs for checking the panel before running the
# regressions.
#
# Outputs:
#   output/data/diagnostics/new_panel_key_checks.csv
#   output/data/diagnostics/new_panel_country_checks.csv
#   output/data/diagnostics/new_panel_admin_level_checks.csv
#   output/data/diagnostics/new_panel_urban_checks.csv
#   output/data/diagnostics/new_panel_deathrate_extremes.csv
#
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

args <- commandArgs(FALSE)
file_arg <- args[grepl("^--file=", args)]

# Start from this folder so the relative source paths below work
# This matters when the script is run from sbatch
script_dir <- if (length(file_arg) > 0) {
  dirname(normalizePath(sub("^--file=", "", file_arg[[1]])))
} else {
  getwd()
}
setwd(script_dir)

USER <- Sys.getenv("USER")

# Load repo paths and the function that reads the analysis panel
source("../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY
source("../regressions/00_prep_analysis_panel.R") # load_new_panel()

# `load_new_panel()` is defined in 00_prep_analysis_panel.R
# Read the analysis panel:
df <- load_new_panel()

# Save all diagnostic outputs in the same folder
diagnostic_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "diagnostics")
dir.create(diagnostic_dir, recursive = TRUE, showWarnings = FALSE)

# -----------------------------
# Panel keys
# -----------------------------

# The main key should identify one row per country, admin unit, year, and age group
# The second check includes `admin_level` in case the same ID appears at more
# than one administrative level
key_checks <- tibble(
  key = c(
    "iso + admin_id + year + agegroup",
    "iso + admin_level + admin_id + year + agegroup"
  ),
  duplicate_rows = c(
    sum(duplicated(df[c("iso", "admin_id", "year", "agegroup")])),
    sum(duplicated(df[c("iso", "admin_level", "admin_id", "year", "agegroup")]))
  )
)

# Country-level coverage for the variables that most often cause dropped rows
country_checks <- df %>%
  group_by(iso) %>%
  summarize(
    rows = n(),
    admin_units = n_distinct(admin_id),
    first_year = min(year, na.rm = TRUE),
    last_year = max(year, na.rm = TRUE),
    missing_era5land_prcp = mean(is.na(prcp_poly_1_ERA5LAND)),
    missing_era5land_tavg = mean(is.na(tavg_poly_1_ERA5LAND)),
    missing_urban_share = mean(is.na(urban_share)),
    missing_income = mean(is.na(gdppc_adm1_avg)),
    .groups = "drop"
  ) %>%
  arrange(iso)

# Number of final admin units by country and admin level
admin_level_checks <- df %>%
  distinct(iso, admin_level, admin_id) %>%
  count(iso, admin_level, name = "admin_units") %>%
  arrange(iso, admin_level)

# -----------------------------
# Urban share and death rates
# -----------------------------

# Distribution of GHSL urban share in the analysis panel
urban_checks <- df %>%
  summarize(
    rows = n(),
    missing_urban_share = mean(is.na(urban_share)),
    zero_urban_share = mean(urban_share == 0, na.rm = TRUE),
    urban_p10 = quantile(urban_share, 0.10, na.rm = TRUE),
    urban_p25 = quantile(urban_share, 0.25, na.rm = TRUE),
    urban_p50 = quantile(urban_share, 0.50, na.rm = TRUE),
    urban_p75 = quantile(urban_share, 0.75, na.rm = TRUE),
    urban_p90 = quantile(urban_share, 0.90, na.rm = TRUE)
  )

# Highest raw death-rate rows
# Useful for quickly spotting weird units or years
deathrate_extremes <- df %>%
  arrange(desc(deathrate)) %>%
  select(
    iso, admin_level, admin_id, admin_name, year, agegroup,
    deaths, population, deathrate
  ) %>%
  slice_head(n = 100)

# -----------------------------
# Write outputs
# -----------------------------

write_csv(key_checks, file.path(diagnostic_dir, "new_panel_key_checks.csv"))
write_csv(country_checks, file.path(diagnostic_dir, "new_panel_country_checks.csv"))
write_csv(admin_level_checks, file.path(diagnostic_dir, "new_panel_admin_level_checks.csv"))
write_csv(urban_checks, file.path(diagnostic_dir, "new_panel_urban_checks.csv"))
write_csv(deathrate_extremes, file.path(diagnostic_dir, "new_panel_deathrate_extremes.csv"))

cat("\nKey checks:\n")
print(key_checks)
cat("\nUrban checks:\n")
print(urban_checks)
cat("\nWrote diagnostics to: ", diagnostic_dir, "\n", sep = "")
