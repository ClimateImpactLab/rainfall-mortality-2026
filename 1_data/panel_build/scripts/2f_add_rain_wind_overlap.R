# ==============================================================================
# 2f_add_rain_wind_overlap.R
#
# Add rain/wind overlap measures
#
# Count days w/ at least 100, 200 or 300 mm of rain that also had wind
# above 17.5 m/s within 1 day. Also keep the wettest day and the windiest
# wet day. These vars help check whether heavy-rain effects are driven by wind.
#
# A year with complete rain data but no event row gets zero heavy-rain days.
# A rain event with unknown wind stays missing, not counted as low wind.
#
# Built from daily ERA5-Land in
# 1_data/climate_data/climate_aggregation_global/era5land_admin/panel/
# 04_rain_wind_events.py and 05_combine_rain_wind_events.py.
# Old-panel countries are matched through the ERA5-Land panel crosswalk.
# Current country IDs come from country_files.csv.
#
# Input:  ERA5-LAND-GLOBAL/combined/current_boundaries/
#           daily_rain_event_wind_overlap/
#           daily_extreme_rain_wind_events_ge100mm.csv
#         ERA5-LAND-GLOBAL/combined/era5land_to_global_panel_crosswalk.csv
#         combined_panel/02_panel_climate.csv
# Output: 02_panel_climate.csv (same rows, overlap added)
# ==============================================================================


# ----------------------
# Packages and paths
# ----------------------

library(dplyr)
library(readr)

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "climate_inputs.R"))

# The overlap vars are added to the stage-2 climate panel
panel_file <- climate_panel_file

# 1 row = 1 climate admin-day w/ at least 100 mm of rain
event_file <- file.path(
  era5land_global_dir, "combined", "current_boundaries", "daily_rain_event_wind_overlap",
  "daily_extreme_rain_wind_events_ge100mm.csv"
)


# ---------------
# Variables
# ---------------

# Wind overlap means at least one positively population-weighted cell had wind
# above 17.5 m/s within one day of the rain event
# Count cols are days per admin-year at each rain cutoff (mm per day)
overlap_count_vars <- c(
  "rain_days_100",
  "rain_days_100_wind_pm1day",
  "rain_days_200",
  "rain_days_200_wind_pm1day",
  "rain_days_300",
  "rain_days_300_wind_pm1day"
)

# Maxima describe the wettest event or the windiest wet day
# Shares divide rain/wind overlap days by all rain days at that cutoff
# These are all the vars added to the panel
overlap_vars <- c(
  "max_rain_event_mm",
  "max_wind_on_rain_event_pm1day",
  "wind_on_max_rain_day",
  "wind_pm1day_on_max_rain_day",
  overlap_count_vars,
  "share_rain_days_100_wind_pm1day",
  "share_rain_days_200_wind_pm1day",
  "share_rain_days_300_wind_pm1day"
)


# ---------------
# ID linking
# ---------------

# Max that returns NA for an all-missing group
# Missing wind should stay missing, not become -Inf
max_or_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  max(x)
}

# Attach the panel iso and admin_id to each climate event row
make_overlap_panel_ids <- function(events, crosswalk) {
  # Old-panel countries use the crosswalk built for the ERA5-Land panel merge
  # The old panel uses ADM1_ADM2 as the mortality panel admin ID
  old_ready <- events %>%
    inner_join(crosswalk, by = c("climate_country", "region_id")) %>%
    transmute(
      iso,
      admin_id,
      admin_code = paste(iso, admin_id, sep = "_"),
      year,
      date,
      prcp_pop_p1,
      windmax_pop_day,
      windmax_pop_pm1day,
      any_pop_above_17p5_pm1day
    )

  # New countries: the climate region ID is the country prefix plus the admin ID
  # Remove only the country prefix, keeping merged IDs and leading zeroes
  # BRA_STABLE is the climate source for the current Brazil panel
  new_ready <- events %>%
    inner_join(country_files %>% select(iso, climate_country), by = "climate_country") %>%
    mutate(admin_id = substring(region_id, nchar(climate_country) + 2L)) %>%
    transmute(
      iso,
      admin_id,
      admin_code = paste(iso, admin_id, sep = "_"),
      year,
      date,
      prcp_pop_p1,
      windmax_pop_day,
      windmax_pop_pm1day,
      any_pop_above_17p5_pm1day
    )

  bind_rows(old_ready, new_ready)
}


# -----------------------
# Admin-year measures
# -----------------------

# Turn the daily event rows into one row per admin unit and year
make_admin_year_overlap <- function(events) {
  # One row per admin unit and day
  # Several climate regions can map to 1 mortality unit
  # Counting them separately would double count days
  panel_dates <- events %>%
    group_by(iso, admin_id, admin_code, year, date) %>%
    summarize(
      prcp_pop_p1 = max_or_na(prcp_pop_p1),
      windmax_pop_day = max_or_na(windmax_pop_day),
      windmax_pop_pm1day = max_or_na(windmax_pop_pm1day),

      # Any observed high wind establishes overlap. Otherwise an unknown
      # source stays unknown instead of being counted as low wind
      any_pop_above_17p5_pm1day = any(any_pop_above_17p5_pm1day),
      .groups = "drop"
    )

  # Pick the wettest event in each admin-year
  # Wind breaks ties
  max_rain_rows <- panel_dates %>%
    group_by(iso, admin_id, admin_code, year) %>%
    arrange(desc(prcp_pop_p1), desc(windmax_pop_pm1day), .by_group = TRUE) %>%
    slice_head(n = 1) %>%
    ungroup() %>%
    transmute(
      iso,
      admin_id,
      admin_code,
      year,
      max_rain_event_mm = prcp_pop_p1,
      wind_on_max_rain_day = windmax_pop_day,
      wind_pm1day_on_max_rain_day = windmax_pop_pm1day
    )

  # Count extreme-rain days and rain-wind overlap days by admin-year
  # An overlap day has rain above the cutoff and high wind within one day
  panel_dates %>%
    group_by(iso, admin_id, admin_code, year) %>%
    summarize(
      rain_days_100 = sum(prcp_pop_p1 >= 100, na.rm = TRUE),
      rain_days_200 = sum(prcp_pop_p1 >= 200, na.rm = TRUE),
      rain_days_300 = sum(prcp_pop_p1 >= 300, na.rm = TRUE),

      rain_days_100_wind_pm1day = sum(prcp_pop_p1 >= 100 & any_pop_above_17p5_pm1day),
      rain_days_200_wind_pm1day = sum(prcp_pop_p1 >= 200 & any_pop_above_17p5_pm1day),
      rain_days_300_wind_pm1day = sum(prcp_pop_p1 >= 300 & any_pop_above_17p5_pm1day),
      
      max_wind_on_rain_event_pm1day = max_or_na(windmax_pop_pm1day),
      .groups = "drop"
    ) %>%
    left_join(max_rain_rows, by = c("iso", "admin_id", "admin_code", "year")) %>%
    mutate(
      # Share = rain days with high wind nearby / total rain days
      # Years with no rain days at the cutoff keep a missing share
      share_rain_days_100_wind_pm1day = if_else(
        rain_days_100 > 0,
        rain_days_100_wind_pm1day / rain_days_100,
        NA_real_
      ),
      share_rain_days_200_wind_pm1day = if_else(
        rain_days_200 > 0,
        rain_days_200_wind_pm1day / rain_days_200,
        NA_real_
      ),
      share_rain_days_300_wind_pm1day = if_else(
        rain_days_300 > 0,
        rain_days_300_wind_pm1day / rain_days_300,
        NA_real_
      )
    ) %>%
    select(iso, admin_id, year, all_of(overlap_vars)) %>%
    arrange(iso, admin_id, year)
}


# ----------------
# Add to panel
# ----------------

# Merge the overlap vars into the panel, keeping every mortality row
add_daily_overlap <- function(path, overlap) {
  panel <- read_csv(path, show_col_types = FALSE,
                    col_types = cols(.default = col_character()))

  # Replace these columns on a rerun, without adding duplicate panel rows
  if (anyDuplicated(overlap[c("iso", "admin_id", "year")])) {
    stop("Repeated admin-years in the overlap table.", call. = FALSE)
  }
  panel_overlap <- panel %>%
    select(-any_of(overlap_vars)) %>%
    left_join(mutate(overlap, overlap_has_events = TRUE), by = c("iso", "admin_id", "year")) %>%
    mutate(across(all_of(overlap_count_vars), ~ case_when(
      # A missing annual rain value cannot establish a complete event count
      is.na(prcp_poly_1_ERA5LAND) ~ NA_real_,
      # No event row, with complete rain coverage, means zero heavy-rain days
      is.na(overlap_has_events) ~ 0,
      # An event with unknown wind stays missing in the overlap count
      TRUE ~ as.numeric(.x)
    ))) %>%
    select(-overlap_has_events)

  stopifnot(nrow(panel_overlap) == nrow(panel))
  write_csv(panel_overlap, paste0(path, ".tmp"), na = "")
  if (!file.rename(paste0(path, ".tmp"), path)) stop("Could not save overlap panel.")
  invisible(NULL)
}


# -----------------------
# Read inputs and run
# -----------------------

# Daily rain events at or above 100 mm
# Only keep the climate country, region ID, rain, wind and date
events <- read_csv(
  event_file,
  show_col_types = FALSE,
  col_select = c(
    climate_country,
    year,
    date,
    region_id,
    prcp_pop_p1,
    windmax_pop_day,
    windmax_pop_pm1day,
    any_pop_above_17p5_pm1day
  ),
  col_types = cols(
    climate_country = col_character(),
    year = col_character(),
    date = col_date(),
    region_id = col_character(),
    prcp_pop_p1 = col_double(),
    windmax_pop_day = col_double(),
    windmax_pop_pm1day = col_double(),
    any_pop_above_17p5_pm1day = col_character()
  )
) %>%
  mutate(
    # Keep missing wind as missing. It should not become "no high wind"
    any_pop_above_17p5_pm1day = case_when(
      any_pop_above_17p5_pm1day == "True" ~ TRUE,
      any_pop_above_17p5_pm1day == "False" ~ FALSE,
      TRUE ~ NA
    )
  )

# Match climate IDs to panel IDs, then count events by admin-year
# crosswalk and country_files come from climate_inputs.R
overlap <- events %>%
  make_overlap_panel_ids(crosswalk) %>%
  make_admin_year_overlap()

# Add the same annual overlap variables to the base panel
add_daily_overlap(panel_file, overlap)

message("Updated daily rain/wind overlap variables")
