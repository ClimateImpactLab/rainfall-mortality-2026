# ==============================================================================
# 01_daily_overlap_tables.R
#
# Summarize overlap between extreme daily rain and nearby high wind
#
# The input has one row per admin-day with daily precipitation >= 100 mm.
# For each rain event, it includes ERA5-Land wind on the same day and the
# maximum wind observed within one day of the event.
#
# This script summarizes the overlap at several rainfall thresholds, builds
# admin-year overlap measures, and writes the main diagnostic tables to Excel.
#
# Outputs:
#   output/data/wind_precip_confounding/daily_precip_wind_overlap_report/
# =============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(tidyr)
library(writexl)

# -----------------------------
# Paths
# -----------------------------

# Repo and project data paths
USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R")

# Main daily rain-wind output from the climate aggregation scripts
climate_input_dir <- file.path(
  DATA_DIR, "climate_data", "ERA5-LAND", "combined",
  "daily_rain_event_wind_overlap"
)

# Older repo output used for local tests
repo_input_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "wind_precip_confounding",
  "daily_precip_wind_overlap"
)

input_dir <- if (dir.exists(climate_input_dir)) climate_input_dir else repo_input_dir

# Tables written by this script
output_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "wind_precip_confounding",
  "daily_precip_wind_overlap_report"
)
table_dir <- file.path(output_dir, "tables")

# Daily rain-event file and country-year summary
event_file <- file.path(input_dir, "daily_extreme_rain_wind_events_ge100mm.csv")
country_year_file <- file.path(input_dir, "daily_precip_wind_country_year_summary.csv")
table_file <- file.path(table_dir, "daily_rain_wind_overlap_tables.xlsx")

dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

# -----------------------------
# Choices
# -----------------------------

rain_thresholds <- c(100, 200, 300) # daily rain cutoffs in mm
high_wind_ms <- 17.5                # high wind cutoff in m/s

# -----------------------------
# Read inputs
# -----------------------------

# Read the daily event file and fix the column types used in the tables
events <- read_csv(event_file, show_col_types = FALSE) %>%
  mutate(
    date = as.Date(date),
    year = as.integer(year),
    prcp_pop_p1 = as.numeric(prcp_pop_p1),
    windmax_pop_day = as.numeric(windmax_pop_day),
    windmax_pop_pm1day = as.numeric(windmax_pop_pm1day),
    windshare_17p5_pop_pm1day = as.numeric(windshare_17p5_pop_pm1day),
    any_pop_above_17p5_pm1day = as.logical(any_pop_above_17p5_pm1day),
    windmean_ge_17p5_pop_pm1day = as.logical(windmean_ge_17p5_pop_pm1day))

country_year <- read_csv(country_year_file, show_col_types = FALSE)

# -----------------------------
# Global threshold summary
# -----------------------------

# One summary row for each daily rain cutoff
# Each row counts admin-day rain events above the cutoff and how often those
# events also have high wind within one day
global_summary <- bind_rows(lapply(rain_thresholds, function(threshold) {
  
  # Admin-days with population-weighted rain above this cutoff
  sample <- events %>%
    filter(prcp_pop_p1 >= threshold)
  
  tibble(
    rain_threshold = paste0(">= ", threshold, " mm"),
    rain_event_admin_days = nrow(sample),
    countries = n_distinct(sample$climate_country),
    country_years = n_distinct(paste(sample$climate_country, sample$year)),
    admin_units = n_distinct(sample$region_id),
    
    # Rainfall intensity among events above the cutoff
    median_rain_mm = median(sample$prcp_pop_p1, na.rm = TRUE),
    p90_rain_mm = quantile(sample$prcp_pop_p1, 0.90, na.rm = TRUE),
    max_rain_mm = max(sample$prcp_pop_p1, na.rm = TRUE),
    
    # Maximum nearby wind within one day
    median_wind_pm1day_ms = median(sample$windmax_pop_pm1day, na.rm = TRUE),
    p90_wind_pm1day_ms = quantile(sample$windmax_pop_pm1day, 0.90, na.rm = TRUE),
    
    # Share of rain events where at least one populated grid cell has wind >= 17.5 m/s
    any_exposed_pop_high_wind_share = mean(
      sample$any_pop_above_17p5_pm1day[!is.na(sample$windmax_pop_pm1day)],
      na.rm = TRUE),
    
    # Share of rain events where the admin-level mean wind is >= 17.5 m/s
    admin_mean_high_wind_share = mean(
      sample$windmean_ge_17p5_pop_pm1day[!is.na(sample$windmax_pop_pm1day)],
      na.rm = TRUE)
  )
}))

# -----------------------------
# Country threshold summary
# -----------------------------

# Denominators used to compare event frequency across countries
# admin_unit_years is the number of admin-year observations in the daily
# climate data, which accounts for differences in country panel size
country_denominators <- country_year %>%
  group_by(climate_country) %>%
  summarize(
    observed_years = n_distinct(year),
    admin_unit_years = sum(admin_units, na.rm = TRUE),
    .groups = "drop")

# Same threshold summaries as above, calculated separately by country
country_summary <- bind_rows(lapply(split(events, events$climate_country), function(country_events) {
  country <- unique(country_events$climate_country)
  denom <- country_denominators %>%
    filter(climate_country == country)
  
  bind_rows(lapply(rain_thresholds, function(threshold) {
    
    # Rain events in this country above the current cutoff
    sample <- country_events %>%
      filter(prcp_pop_p1 >= threshold)
    
    # Number of admin-years with at least one event above this cutoff
    affected_admin_years <- n_distinct(paste(sample$climate_country, sample$region_id, sample$year))
    
    tibble(
      country = country,
      rain_threshold = paste0(">= ", threshold, " mm"),
      rain_event_admin_days = nrow(sample),
      observed_years = denom$observed_years,
      years_with_any_rain_event = n_distinct(paste(sample$climate_country, sample$year)),
      affected_admin_units = n_distinct(sample$region_id),
      rain_event_admin_days_per_year = nrow(sample) / denom$observed_years,
      rain_event_days_per_1000_admin_unit_years = nrow(sample) / denom$admin_unit_years * 1000,
      
      # Average number of event days among admin-years with at least one event
      rain_event_days_per_affected_admin_year = if_else(
        affected_admin_years > 0,
        nrow(sample) / affected_admin_years,
        NA),
      
      # Rainfall and nearby-wind intensity among selected events
      median_event_rain_mm = median(sample$prcp_pop_p1, na.rm = TRUE),
      p90_wind_pm1day_ms = quantile(sample$windmax_pop_pm1day, 0.90, na.rm = TRUE),
      
      # High-wind overlap when any populated grid cell crosses 17.5 m/s
      any_exposed_pop_high_wind_share = mean(
        sample$any_pop_above_17p5_pm1day[!is.na(sample$windmax_pop_pm1day)],
        na.rm = TRUE),
      
      # High-wind overlap when the admin-level population-weighted mean crosses 17.5 m/s
      admin_mean_high_wind_share = mean(
        sample$windmean_ge_17p5_pop_pm1day[!is.na(sample$windmax_pop_pm1day)],
        na.rm = TRUE)
    )
  }))
}))

# -----------------------------
# Admin-year overlap variables
# -----------------------------

# Keep the rainiest event in each admin-year
# This gives the wind values associated with that admin-year's largest rain day
max_rain_event <- events %>%
  group_by(climate_country, region_id, year) %>%
  arrange(desc(prcp_pop_p1), desc(windmax_pop_pm1day), .by_group = TRUE) %>%
  slice_head(n = 1) %>%
  ungroup() %>%
  transmute(
    climate_country, region_id, year,
    max_rain_event_mm = prcp_pop_p1,
    wind_on_max_rain_day = windmax_pop_day,
    wind_pm1day_on_max_rain_day = windmax_pop_pm1day
  )

# Collapse the daily events to annual overlap measures for each admin unit
# These variables are used later in the wind-confounding regression checks
admin_year <- events %>%
  group_by(climate_country, region_id, year) %>%
  summarize(
    # Number of extreme-rain days at each cutoff
    rain_days_100 = sum(prcp_pop_p1 >= 100, na.rm = TRUE),
    rain_days_200 = sum(prcp_pop_p1 >= 200, na.rm = TRUE),
    rain_days_300 = sum(prcp_pop_p1 >= 300, na.rm = TRUE),
    
    # Same counts, restricted to events with high wind within one day
    rain_days_100_wind_pm1day = sum(prcp_pop_p1 >= 100 & any_pop_above_17p5_pm1day, na.rm = TRUE),
    rain_days_200_wind_pm1day = sum(prcp_pop_p1 >= 200 & any_pop_above_17p5_pm1day, na.rm = TRUE),
    rain_days_300_wind_pm1day = sum(prcp_pop_p1 >= 300 & any_pop_above_17p5_pm1day, na.rm = TRUE),
    
    # Largest nearby wind among the extreme-rain events in this admin-year
    max_wind_on_rain_event_pm1day = max(windmax_pop_pm1day, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(max_rain_event, by = c("climate_country", "region_id", "year")) %>%
  mutate(
    # Fraction of extreme-rain days that also had high wind nearby
    share_rain_days_100_wind_pm1day = if_else(rain_days_100 > 0, rain_days_100_wind_pm1day / rain_days_100, NA_real_),
    share_rain_days_200_wind_pm1day = if_else(rain_days_200 > 0, rain_days_200_wind_pm1day / rain_days_200, NA_real_),
    share_rain_days_300_wind_pm1day = if_else(rain_days_300 > 0, rain_days_300_wind_pm1day / rain_days_300, NA_real_)
  )

# Summarize annual overlap at each daily rain cutoff
admin_year_summary <- bind_rows(lapply(rain_thresholds, function(threshold) {
  rain_col <- paste0("rain_days_", threshold)
  wind_col <- paste0("rain_days_", threshold, "_wind_pm1day")
  
  # Admin-years with at least one event above the current cutoff
  sample <- admin_year %>%
    filter(.data[[rain_col]] > 0)
  
  tibble(
    rain_threshold = paste0(">= ", threshold, " mm"),
    admin_years_with_rain_events = nrow(sample),
    total_rain_event_days = sum(sample[[rain_col]], na.rm = TRUE),
    rain_event_days_with_high_wind = sum(sample[[wind_col]], na.rm = TRUE),
    share_rain_event_days_with_high_wind = sum(sample[[wind_col]], na.rm = TRUE) / sum(sample[[rain_col]], na.rm = TRUE)
  )
}))

# -----------------------------
# Largest rain events
# -----------------------------

# Daily rain events above 300 mm
top_events <- events %>%
  filter(prcp_pop_p1 >= 300) %>%
  transmute(
    country = climate_country,
    year,
    date,
    admin_id = region_id,
    rain_on_event_day_mm = prcp_pop_p1,
    same_day_wind_ms = windmax_pop_day,
    max_wind_pm1day_ms = windmax_pop_pm1day,
    exposed_pop_above_17p5_pm1day_share = windshare_17p5_pop_pm1day
  )

top_rain_events <- top_events %>%
  arrange(desc(rain_on_event_day_mm))

# Events above 300 mm where some populated area also had high wind nearby
top_wet_and_windy_events <- events %>%
  filter(prcp_pop_p1 >= 300, any_pop_above_17p5_pm1day) %>%
  arrange(desc(prcp_pop_p1), desc(windmax_pop_pm1day)) %>%
  transmute(
    country = climate_country,
    year,
    date,
    admin_id = region_id,
    rain_on_event_day_mm = prcp_pop_p1,
    same_day_wind_ms = windmax_pop_day,
    max_wind_pm1day_ms = windmax_pop_pm1day,
    exposed_pop_above_17p5_pm1day_share = windshare_17p5_pop_pm1day
  )

# Events above 300 mm without the exposed-population high-wind flag
top_high_rain_low_wind_events <- events %>%
  filter(prcp_pop_p1 >= 300, !coalesce(any_pop_above_17p5_pm1day, FALSE)) %>%
  arrange(desc(prcp_pop_p1)) %>%
  transmute(
    country = climate_country,
    year,
    date,
    admin_id = region_id,
    rain_on_event_day_mm = prcp_pop_p1,
    same_day_wind_ms = windmax_pop_day,
    max_wind_pm1day_ms = windmax_pop_pm1day,
    exposed_pop_above_17p5_pm1day_share = windshare_17p5_pop_pm1day
  )

# -----------------------------
# Write outputs
# -----------------------------

# Write all summary and event tables to one workbook
write_xlsx(
  list(
    "Global summary" = global_summary,
    "Country summary" = country_summary,
    "Admin year variables" = admin_year,
    "Admin year summary" = admin_year_summary,
    "Top rain events" = top_rain_events,
    "Wet and windy events" = top_wet_and_windy_events,
    "High rain low wind" = top_high_rain_low_wind_events
  ),
  table_file
)

message("Wrote daily rain-wind overlap table workbook: ", table_file)
