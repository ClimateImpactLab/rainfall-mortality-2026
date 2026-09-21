# ============================================================
# 07d_add_daily_rain_wind_overlap.R
#
# Add daily rain/wind overlap variables to the mortality panel.
#
# The event file comes from the ERA5-Land admin scripts:
#
#   1_data/climate_data/climate_aggregation_global/era5land_admin/panel/
#   04_rain_wind_events.py
#   05_combine_rain_wind_events.py
#
# Old-panel countries use the ERA5-Land panel crosswalk. New countries use
# the admin ID already stored in `region_id`.
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel.csv
#   panel_build/combined_panel/new_mortality_panel_urban.csv, if present
# ============================================================


# -----------------------------
# Packages and paths
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

# `paths.R` points to the shared panel-build output folder.
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

# Add overlap variables to the base panel and, if it already exists, the urban panel.
panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
urban_panel_file <- file.path(panel_dir, "new_mortality_panel_urban.csv")

# Daily event file from the ERA5-Land admin folder.
# One row is a climate admin-day with rain >= 100 mm.
event_file <- file.path(
  era5land_dir, "combined", "daily_rain_event_wind_overlap",
  "daily_extreme_rain_wind_events_ge100mm.csv"
)

# Old-panel climate regions need the same crosswalk used for ERA5-Land climate.
crosswalk_file <- file.path(
  era5land_dir, "combined",
  "era5land_to_global_panel_crosswalk.csv"
)


# -----------------------------
# Variables
# -----------------------------

new_countries <- c("AUS", "COL", "ECU", "KOR", "PER", "PHL")

# Counts use daily rain cutoffs. Wind overlap means some population-weighted
# grid-cell exposure crossed 17.5 m/s within one day of the rain event.
overlap_count_vars <- c(
  "rain_days_100",
  "rain_days_100_wind_pm1day",
  "rain_days_200",
  "rain_days_200_wind_pm1day",
  "rain_days_300",
  "rain_days_300_wind_pm1day"
)

# Final variables added to the panel.
# Maxima describe the wettest event or the windiest rain-event day.
# Shares divide rain-wind overlap days by all rain days at that cutoff.
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


# -----------------------------
# ID linking
# -----------------------------

# Missing wind should stay missing, not become -Inf after max().
max_or_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  max(x)
}

make_overlap_panel_ids <- function(events, crosswalk) {
  # Old-panel countries use the crosswalk built for the ERA5-Land panel merge.
  # The old panel uses ADM1_ADM2 as the mortality panel admin ID.
  old_ready <- events %>%
    inner_join(crosswalk, by = c("climate_country", "region_id")) %>%
    transmute(
      iso = panel_iso,
      admin_id = paste(coalesce(panel_adm1_id, ""), coalesce(panel_adm2_id, ""), sep = "_"),
      admin_code = paste(iso, admin_id, sep = "_"),
      year,
      date,
      prcp_pop_p1,
      windmax_pop_day,
      windmax_pop_pm1day,
      any_pop_above_17p5_pm1day
    )

  # New-country `region_id` already ends with the panel admin ID.
  # Philippine panel IDs are 10-digit PSGC codes with leading zeroes.
  new_ready <- events %>%
    filter(climate_country %in% new_countries) %>%
    mutate(
      admin_id = str_extract(region_id, "[^_]+$"),
      admin_id = if_else(
        climate_country == "PHL",
        str_pad(admin_id, width = 10, side = "left", pad = "0"),
        admin_id
      )
    ) %>%
    transmute(
      iso = climate_country,
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


# -----------------------------
# Admin-year measures
# -----------------------------

make_admin_year_overlap <- function(events) {
  # Collapse source climate rows before counting event days. This avoids
  # counting multiple source regions as multiple mortality admin-days.
  panel_dates <- events %>%
    group_by(iso, admin_id, admin_code, year, date) %>%
    summarize(
      prcp_pop_p1 = max_or_na(prcp_pop_p1),
      windmax_pop_day = max_or_na(windmax_pop_day),
      windmax_pop_pm1day = max_or_na(windmax_pop_pm1day),

      # If all source rows are missing wind, keep the overlap flag missing.
      # Otherwise TRUE means at least one source row had high wind nearby.
      any_pop_above_17p5_pm1day = if_else(
        all(is.na(any_pop_above_17p5_pm1day)),
        NA,
        any(any_pop_above_17p5_pm1day, na.rm = TRUE)
      ),
      .groups = "drop"
    )

  # Pick the wettest rain event in each admin-year. Wind only breaks ties.
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

  # Count extreme-rain days and rain-wind overlap days by admin-year.
  # An overlap day has rain above the cutoff and high wind within one day.
  panel_dates %>%
    group_by(iso, admin_id, admin_code, year) %>%
    summarize(
      rain_days_100 = sum(prcp_pop_p1 >= 100, na.rm = TRUE),
      rain_days_200 = sum(prcp_pop_p1 >= 200, na.rm = TRUE),
      rain_days_300 = sum(prcp_pop_p1 >= 300, na.rm = TRUE),

      rain_days_100_wind_pm1day = sum(
        prcp_pop_p1 >= 100 & any_pop_above_17p5_pm1day,
        na.rm = TRUE
      ),
      rain_days_200_wind_pm1day = sum(
        prcp_pop_p1 >= 200 & any_pop_above_17p5_pm1day,
        na.rm = TRUE
      ),
      rain_days_300_wind_pm1day = sum(
        prcp_pop_p1 >= 300 & any_pop_above_17p5_pm1day,
        na.rm = TRUE
      ),

      max_wind_on_rain_event_pm1day = max_or_na(windmax_pop_pm1day),
      .groups = "drop"
    ) %>%
    left_join(max_rain_rows, by = c("iso", "admin_id", "admin_code", "year")) %>%
    mutate(
      # Share = rain days with high wind nearby / total rain days.
      # Years with no rain days at the cutoff keep a missing share.
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


# -----------------------------
# Add to panel
# -----------------------------

add_daily_overlap <- function(path, overlap) {
  panel <- read_csv(path, show_col_types = FALSE,
                    col_types = cols(.default = col_character()))

  panel_overlap <- panel %>%
    left_join(overlap, by = c("iso", "admin_id", "year")) %>%
    # No event row means zero event counts. Maxima and shares stay missing.
    mutate(across(all_of(overlap_count_vars), ~ coalesce(.x, 0)))

  write_csv(panel_overlap, path, na = "")
  invisible(NULL)
}


# -----------------------------
# Read inputs and run
# -----------------------------

# The event file also has country-specific source IDs, but this script only
# needs the climate country, climate region ID, rain, wind, and date.
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
    # Keep missing wind as missing. It should not become "no high wind".
    any_pop_above_17p5_pm1day = case_when(
      any_pop_above_17p5_pm1day == "True" ~ TRUE,
      any_pop_above_17p5_pm1day == "False" ~ FALSE,
      TRUE ~ NA
    )
  )

# The crosswalk is only needed for old-panel countries.
# New-country IDs are pulled from `region_id` inside `make_overlap_panel_ids()`.
crosswalk <- read_csv(
  crosswalk_file,
  show_col_types = FALSE,
  col_select = c(
    climate_country,
    region_id,
    panel_iso,
    panel_adm1_id,
    panel_adm2_id,
    match_status
  ),
  col_types = cols(.default = col_character())
) %>%
  filter(match_status == "matched") %>%
  select(climate_country, region_id, panel_iso, panel_adm1_id, panel_adm2_id)

# Translate climate IDs to panel IDs, then summarize daily events to admin-years.
overlap <- events %>%
  make_overlap_panel_ids(crosswalk) %>%
  make_admin_year_overlap()

# Add the same annual overlap variables to the base panel.
add_daily_overlap(panel_file, overlap)

# The urban panel is created later in some partial runs, so update it only if present.
if (file.exists(urban_panel_file)) {
  add_daily_overlap(urban_panel_file, overlap)
}

message("Updated daily rain/wind overlap variables")
