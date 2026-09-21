# ============================================================
# 05_merge_young_hsiang_panel_climate.R
#
# Merge combined ERA5-Land state-month wind and precipitation onto the
# Young-Hsiang state-month mortality panel. The climate files are already
# aggregated to state x year x month. This step keeps all Young-Hsiang rows and
# writes CSV and Stata copies of the merged panel.
#
# Run locally or on a login node. This is a small table merge, not raster work.
# ============================================================


# -----------------------------
# Packages and paths
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(haven)
  library(readr)
})

# Young-Hsiang state-month mortality panel
yh_panel_file <- "/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/raw/data/DATA_hurricane_mortality_temp_month_state_19302015.dta"

# Combined ERA5-Land state-month climate files from 04_combine_state_month.py
climate_dir <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/USA/state_month"

# Merged Young-Hsiang panel with ERA5-Land climate added
output_dir <- "/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/processed"


# -----------------------------
# Settings
# -----------------------------

# ERA5-Land years used for the Young-Hsiang comparison.
first_year <- 1950
last_year <- 2015

# Command-line values can override the defaults above.
args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name, default) {
  found <- match(name, args)
  value <- args[found + 1]
  ifelse(is.na(value), default, value)
}

first_year <- as.integer(get_arg("--first-year", first_year))
last_year <- as.integer(get_arg("--last-year", last_year))

wind_file <- file.path(climate_dir, paste0("era5land_usa_state_month_wind_", first_year, "_", last_year, ".csv"))
precip_file <- file.path(climate_dir, paste0("era5land_usa_state_month_precip_", first_year, "_", last_year, ".csv"))
output_csv <- file.path(output_dir, paste0("young_hsiang_state_month_era5land_climate_", first_year, "_", last_year, ".csv"))
output_dta <- file.path(output_dir, paste0("young_hsiang_state_month_era5land_climate_", first_year, "_", last_year, ".dta"))


# -----------------------------
# Read Young-Hsiang panel
# -----------------------------

panel <- read_dta(yh_panel_file)

# The source panel has one blank non-state row, drop it before matching climate
panel <- panel %>%
  filter(trimws(as.character(state_abbrev)) != "") %>%
  mutate(
    stfips = as.integer(stfips),
    year = as.integer(year),
    month = as.integer(month)
  )


# -----------------------------
# Read ERA5-Land climate
# -----------------------------

# Wind file is already state-month. Monthly wind is grid-cell max first, then
# state weighted mean. Keep the two wind variables used in the comparison.
wind <- read_csv(wind_file, show_col_types = FALSE) %>%
  select(stfips, year, month, windmax_pop_month, windmax_area_month) %>%
  mutate(
    stfips = as.integer(stfips),
    year = as.integer(year),
    month = as.integer(month)
  )

# Precipitation powers were calculated at the ERA5-Land grid-cell level before
# state aggregation. Monthly values are sums of the daily state values.
precip_vars <- c(
  "prcp_pop_p1", "prcp_pop_p2", "prcp_pop_p3", "prcp_pop_p4", "prcp_pop_p5",
  "prcp_area_p1", "prcp_area_p2", "prcp_area_p3", "prcp_area_p4", "prcp_area_p5"
)

precip <- read_csv(precip_file, show_col_types = FALSE) %>%
  select(stfips, year, month, all_of(precip_vars)) %>%
  mutate(
    stfips = as.integer(stfips),
    year = as.integer(year),
    month = as.integer(month)
  )


# -----------------------------
# Merge
# -----------------------------

# Merge on the Young-Hsiang state-month id, left_join keeps every mortality row.
merged <- panel %>%
  left_join(wind, by = c("stfips", "year", "month")) %>%
  left_join(precip, by = c("stfips", "year", "month"))

# Any row-count increase would mean duplicate climate ids
if (nrow(merged) != nrow(panel)) {
  stop("Climate merge changed the number of Young-Hsiang rows")
}


# -----------------------------
# Checks
# -----------------------------

# The mortality panel starts earlier, only rows inside this climate year range
# are expected to have ERA5-Land climate.
in_climate_years <- merged$year >= first_year & merged$year <= last_year

# Missing climate inside the requested years is the main merge check to inspect.
cat("rows:", nrow(merged), "\n")
cat("states:", n_distinct(merged$stfips), "\n")
cat("panel years:", min(merged$year), "-", max(merged$year), "\n")
cat("climate years:", first_year, "-", last_year, "\n")
cat("rows in climate years:", sum(in_climate_years), "\n")
cat("missing wind in climate years:", sum(in_climate_years & is.na(merged$windmax_pop_month)), "\n")
cat("missing precip in climate years:", sum(in_climate_years & is.na(merged$prcp_pop_p1)), "\n")

# Basic range checks for the added climate variables.
cat("max windmax_pop_month:", round(max(merged$windmax_pop_month, na.rm = TRUE), 3), "\n")
cat("max windmax_area_month:", round(max(merged$windmax_area_month, na.rm = TRUE), 3), "\n")
cat("max prcp_pop_p1:", round(max(merged$prcp_pop_p1, na.rm = TRUE), 3), "\n")
cat("max prcp_area_p1:", round(max(merged$prcp_area_p1, na.rm = TRUE), 3), "\n")


# -----------------------------
# Write
# -----------------------------

# Save the same merged panel in CSV and Stata formats
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
write_csv(merged, output_csv, na = "")
write_dta(merged, output_dta, version = 15)

cat("created ", output_csv, "\n", sep = "")
cat("created ", output_dta, "\n", sep = "")
