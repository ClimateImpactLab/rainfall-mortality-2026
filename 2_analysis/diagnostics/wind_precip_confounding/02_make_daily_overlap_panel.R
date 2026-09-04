# ============================================================
# 02_make_daily_overlap_panel.R
#
# Make annual rain-wind variables for the regression checks
#
# The input is the daily rain-event file: admin-days with rainfall >= 100 mm,
# plus ERA5-Land wind on the rain day and within +/-1 day.
#
# The regressions need one row per mortality admin-year. This script matches
# each daily event to mortality admin_id, then counts how many extreme-rain days
# and rain-wind overlap days each admin-year has.
#
# Main outputs:
#   output/data/wind_precip_confounding/daily_precip_wind_overlap_panel_ready/
#     admin_year_daily_overlap_panel_ready.csv
#     daily_overlap_match_checks.xlsx
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(writexl)

# -----------------------------
# Paths
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R")

panel_file <- file.path(
  DATA_DIR, "mortality_data", "panel_build", "combined_panel",
  "new_mortality_panel_urban.csv"
)

event_file <- file.path(
  DATA_DIR, "climate_data", "ERA5-LAND", "combined",
  "daily_rain_event_wind_overlap",
  "daily_extreme_rain_wind_events_ge100mm.csv"
)

# India uses the old 1961 district IDs in the daily event file
# Use this crosswalk to get the state and district IDs used in the panel
india_crosswalk_file <- paste0(
  "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/",
  "Countries/IND/Shapefile/1961_districts/",
  "districts_1961_final_w_iaa_codes.csv"
)

output_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "wind_precip_confounding",
  "daily_precip_wind_overlap_panel_ready"
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

output_panel <- file.path(output_dir, "admin_year_daily_overlap_panel_ready.csv")
output_checks <- file.path(output_dir, "daily_overlap_match_checks.xlsx")


# -----------------------------
# ID cleaning
# -----------------------------

# Clean the ID strings before matching
clean_id <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- trimws(x)
  x <- sub("\\.0$", "", x)
  x[tolower(x) %in% c("nan", "na", "<na>")] <- ""
  x
}

# Add leading zeroes for fixed-width numeric IDs
add_leading_zeroes <- function(x, width) {
  x <- clean_id(x)
  out <- x
  use <- x != ""
  out[use] <- sprintf(paste0("%0", width, "d"), as.integer(x[use]))
  out
}

# Read TRUE/FALSE columns from the CSV
read_true_false <- function(x) {
  tolower(clean_id(x)) %in% c("true", "t", "1", "yes")
}


# -----------------------------
# Mortality panel IDs
# -----------------------------

# Keep one row per mortality admin unit
# Some countries match on admin_id, while others need ADM1/ADM2/ADM3 IDs
panel_admin_lookup <- read_csv(
  panel_file,
  col_select = c(
    iso, admin_id, admin_name, admin_level,
    adm1_id, adm2_id, adm3_id
  ),
  col_types = cols(.default = col_character())
) %>%
  distinct() %>%
  mutate(
    admin_id = clean_id(admin_id),
    adm1_id = clean_id(adm1_id),
    adm2_id = clean_id(adm2_id),
    adm3_id = clean_id(adm3_id),
    admin_code = paste(iso, admin_id, sep = "_")
  )

# Stop if the panel has duplicate admin IDs within a country
if (anyDuplicated(panel_admin_lookup[c("iso", "admin_id")])) {
  stop("Panel admin IDs are not unique within country", call. = FALSE)
}


# -----------------------------
# Daily rain events
# -----------------------------

# Read the daily event file
# It only contains admin-days with at least 100 mm of rain
# The wind variables are measured on the rain day and within +/-1 day
events <- read_csv(event_file, col_types = cols(.default = col_character())) %>%
  mutate(
    source_row = row_number(),
    climate_country = clean_id(climate_country),
    year = as.integer(clean_id(year)),
    date = as.Date(date),
    prcp_pop_p1 = as.numeric(clean_id(prcp_pop_p1)),
    windmax_pop_day = as.numeric(clean_id(windmax_pop_day)),
    windmax_pop_pm1day = as.numeric(clean_id(windmax_pop_pm1day)),
    any_pop_above_17p5_pm1day = read_true_false(any_pop_above_17p5_pm1day),
    windmean_ge_17p5_pop_pm1day = read_true_false(windmean_ge_17p5_pop_pm1day)
  )



# India 1961 district IDs and their corresponding panel state/district IDs
india_crosswalk <- read_csv(
  india_crosswalk_file,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    india_region_id = paste0("IND_", add_leading_zeroes(unid, 3)),
    india_adm1_id = clean_id(statecode_iaa61),
    india_adm2_id = clean_id(districtcode_iaa61)
  )


# -----------------------------
# Match daily events to mortality admins
# -----------------------------

# Add the India panel IDs before matching each country
events_with_india_ids <- events %>%
  left_join(india_crosswalk, by = c("region_id" = "india_region_id"))

# These countries use the same admin level in the daily event file and the panel
# Only the ID formatting has to be fixed
match_admin_id <- events_with_india_ids %>%
  filter(climate_country %in% c("AUS", "COL", "ECU", "KOR", "PER")) %>%
  mutate(
    admin_id_match = case_when(
      climate_country == "AUS" ~ clean_id(adm2_id),
      climate_country == "COL" ~ add_leading_zeroes(adm2_code, 5),
      climate_country == "ECU" ~ add_leading_zeroes(adm2_id, 4),
      climate_country == "KOR" ~ add_leading_zeroes(adm2_n_, 5),
      climate_country == "PER" ~ add_leading_zeroes(shp_adm2_code, 4)
    )
  ) %>%
  left_join(
    panel_admin_lookup %>% mutate(admin_id_match = admin_id),
    by = c("climate_country" = "iso", "admin_id_match"),
    relationship = "many-to-one"
  )

# PHL is ADM3 in the panel
# Match municipalities/cities using the full PSGC path
match_phl <- events_with_india_ids %>%
  filter(climate_country == "PHL") %>%
  mutate(
    adm1_id_match = add_leading_zeroes(adm1_psgc, 10),
    adm2_id_match = add_leading_zeroes(adm2_psgc, 10),
    adm3_id_match = add_leading_zeroes(adm3_psgc, 10)
  ) %>%
  left_join(
    panel_admin_lookup,
    by = c(
      "climate_country" = "iso",
      "adm1_id_match" = "adm1_id",
      "adm2_id_match" = "adm2_id",
      "adm3_id_match" = "adm3_id"
    ),
    relationship = "many-to-one"
  )

# These countries match on the ADM1 and ADM2 IDs
# India uses the crosswalk added above
match_adm1_adm2 <- events_with_india_ids %>%
  filter(climate_country %in% c("BRA", "FRA", "CHL", "CHN", "IND")) %>%
  mutate(
    adm1_id_match = case_when(
      climate_country %in% c("BRA", "FRA") ~ clean_id(ID_1),
      climate_country == "CHL" ~ clean_id(adm1_id),
      climate_country == "CHN" ~ clean_id(PROVGB),
      climate_country == "IND" ~ india_adm1_id
    ),
    adm2_id_match = case_when(
      climate_country %in% c("BRA", "FRA") ~ clean_id(ID_2),
      climate_country == "CHL" ~ clean_id(adm2_id),
      climate_country == "CHN" ~ clean_id(CNTYGB),
      climate_country == "IND" ~ india_adm2_id
    )
  ) %>%
  left_join(
    panel_admin_lookup,
    by = c(
      "climate_country" = "iso",
      "adm1_id_match" = "adm1_id",
      "adm2_id_match" = "adm2_id"
    ),
    relationship = "many-to-one"
  )

# USA matches on state and county IDs
# A few Alaska boroughs need the same recodes used in the mortality panel
match_usa <- events_with_india_ids %>%
  filter(climate_country == "USA") %>%
  mutate(
    adm1_id_match = add_leading_zeroes(ID_1, 2),
    adm2_id_match = case_when(
      clean_id(ID_1) == "02" & clean_id(ID_2) %in% c("013", "13", "016", "16") ~ "010",
      clean_id(ID_1) == "02" & clean_id(ID_2) == "158" ~ "270",
      TRUE ~ add_leading_zeroes(ID_2, 3)
    )
  ) %>%
  left_join(
    panel_admin_lookup,
    by = c(
      "climate_country" = "iso",
      "adm1_id_match" = "adm1_id",
      "adm2_id_match" = "adm2_id"
    ),
    relationship = "many-to-one"
  )

# MEX matches on the ADM2 code used in the panel
match_mex <- events_with_india_ids %>%
  filter(climate_country == "MEX") %>%
  mutate(adm2_id_match = add_leading_zeroes(GEOID, 9)) %>%
  left_join(
    panel_admin_lookup,
    by = c("climate_country" = "iso", "adm2_id_match" = "adm2_id"),
    relationship = "many-to-one"
  )

# JPN is ADM1 in the old panel
match_jpn <- events_with_india_ids %>%
  filter(climate_country == "JPN") %>%
  mutate(adm1_id_match = clean_id(ID_1)) %>%
  left_join(
    panel_admin_lookup %>% filter(adm2_id == "", adm3_id == ""),
    by = c("climate_country" = "iso", "adm1_id_match" = "adm1_id"),
    relationship = "many-to-one"
  )

# Keep any unexpected country as unmatched so it shows up in the workbook
unmatched_country <- events_with_india_ids %>%
  filter(!climate_country %in% c(
    "AUS", "BRA", "CHL", "CHN", "COL", "ECU", "FRA",
    "IND", "JPN", "KOR", "MEX", "PER", "PHL", "USA"
  )) %>%
  mutate(
    admin_id = NA_character_,
    admin_code = NA_character_,
    admin_name = NA_character_,
    admin_level = NA_character_,
    adm1_id = NA_character_,
    adm2_id = NA_character_,
    adm3_id = NA_character_
  )

linked <- bind_rows(
  match_admin_id,
  match_phl,
  match_adm1_adm2,
  match_usa,
  match_mex,
  match_jpn,
  unmatched_country
) %>%
  mutate(matched = !is.na(admin_id))


# -----------------------------
# Admin-day events
# -----------------------------

# Collapse to one row per mortality admin-day
panel_dates <- linked %>%
  filter(matched) %>%
  group_by(climate_country, admin_id, admin_code, year, date) %>%
  summarize(
    prcp_pop_p1 = max(prcp_pop_p1, na.rm = TRUE),
    windmax_pop_day = max(windmax_pop_day, na.rm = TRUE),
    windmax_pop_pm1day = max(windmax_pop_pm1day, na.rm = TRUE),
    
    # Whether this admin-day had high wind near the rain event
    any_pop_above_17p5_pm1day = any(any_pop_above_17p5_pm1day, na.rm = TRUE),
    
    # Number of daily event rows behind this admin-day
    source_event_rows = n(),
    .groups = "drop"
  )

# Keep the wettest event in each admin-year
# The wind columns here are the wind values on or around that wettest day
max_rain_rows <- panel_dates %>%
  group_by(climate_country, admin_id, admin_code, year) %>%
  arrange(desc(prcp_pop_p1), desc(windmax_pop_pm1day), .by_group = TRUE) %>%
  slice_head(n = 1) %>%
  ungroup() %>%
  transmute(
    climate_country, admin_id, admin_code, year,
    max_rain_event_mm = prcp_pop_p1,
    wind_on_max_rain_day = windmax_pop_day,
    wind_pm1day_on_max_rain_day = windmax_pop_pm1day
  )

# Count extreme-rain days and rain-wind overlap days by admin-year
# An overlap day has rain above the cutoff and some exposed population with
# wind >= 17.5 m/s within one day
panel_ready <- panel_dates %>%
  group_by(climate_country, admin_id, admin_code, year) %>%
  summarize(
    # Extreme-rain days at each cutoff
    rain_days_100 = sum(prcp_pop_p1 >= 100, na.rm = TRUE),
    rain_days_200 = sum(prcp_pop_p1 >= 200, na.rm = TRUE),
    rain_days_300 = sum(prcp_pop_p1 >= 300, na.rm = TRUE),
    
    # Same counts, restricted to days with high wind nearby
    rain_days_100_wind_pm1day = sum(prcp_pop_p1 >= 100 & any_pop_above_17p5_pm1day, na.rm = TRUE),
    rain_days_200_wind_pm1day = sum(prcp_pop_p1 >= 200 & any_pop_above_17p5_pm1day, na.rm = TRUE),
    rain_days_300_wind_pm1day = sum(prcp_pop_p1 >= 300 & any_pop_above_17p5_pm1day, na.rm = TRUE),
    
    # Number of daily event rows and unique event dates in this admin-year
    source_event_rows = sum(source_event_rows),
    event_dates = n_distinct(date),
    
    # Largest nearby wind among the rain events in this admin-year
    max_wind_on_rain_event_pm1day = max(windmax_pop_pm1day, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(
    max_rain_rows,
    by = c("climate_country", "admin_id", "admin_code", "year")
  ) %>%
  mutate(
    iso = climate_country,
    
    # Share of rain-event days that also had high wind nearby
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
  select(
    iso, admin_id, admin_code, year,
    max_rain_event_mm,
    max_wind_on_rain_event_pm1day,
    wind_on_max_rain_day,
    wind_pm1day_on_max_rain_day,
    rain_days_100, rain_days_100_wind_pm1day, share_rain_days_100_wind_pm1day,
    rain_days_200, rain_days_200_wind_pm1day, share_rain_days_200_wind_pm1day,
    rain_days_300, rain_days_300_wind_pm1day, share_rain_days_300_wind_pm1day,
    source_event_rows, event_dates
  ) %>%
  arrange(iso, admin_id, year)

if (anyDuplicated(panel_ready[c("iso", "admin_id", "year")])) {
  stop("Panel-ready daily overlap rows are not unique by iso/admin_id/year", call. = FALSE)
}


# -----------------------------
# Match summary
# -----------------------------

# Count matched and unmatched event rows by country
audit <- linked %>%
  group_by(climate_country) %>%
  summarize(
    source_event_rows = n(),
    matched_event_rows = sum(matched),
    unmatched_event_rows = sum(!matched),
    
    # Number of mortality admin-years with at least one matched daily event
    matched_panel_admin_years = n_distinct(paste(admin_id[matched], year[matched])),
    .groups = "drop"
  ) %>%
  mutate(
    event_row_match_share = matched_event_rows / source_event_rows
  ) %>%
  arrange(climate_country)

# Keep a few unmatched rows to make ID problems easier to see
unmatched_examples <- linked %>%
  filter(!matched) %>%
  group_by(climate_country) %>%
  slice_head(n = 20) %>%
  ungroup() %>%
  select(
    climate_country, year, date, region_id,
    any_of(c("admin_id_match", "adm1_id_match", "adm2_id_match", "adm3_id_match")),
    any_of(c("ID_1", "ID_2", "GEOID", "adm1_id", "adm2_id", "adm1_psgc", "adm2_psgc", "adm3_psgc")),
    prcp_pop_p1, windmax_pop_pm1day, any_pop_above_17p5_pm1day
  )


# -----------------------------
# Write outputs
# -----------------------------

# Admin-year file used by the rain-wind regression checks
write_csv(panel_ready, output_panel)

# Small workbook for checking the country ID matches
write_xlsx(
  list(
    "Match audit" = audit,
    "Unmatched examples" = unmatched_examples
  ),
  output_checks
)

message("Wrote panel-ready daily overlap file to: ", output_panel)
message("Wrote daily overlap match checks to: ", output_checks)
print(audit, n = Inf)
