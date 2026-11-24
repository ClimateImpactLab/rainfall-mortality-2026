# ==============================================================================
# 3c_add_urban.R
#
# Add GHSL population, settlement type and urban, city and town shares for the
# current admin boundaries.
# Building cover uses the fixed 2000 values for every mortality year.
# Years use the closest five-year snapshot, from 1975 to 2025.
# Years before 1975 use 1975, and years after 2025 use 2025.
#
# The GHSL extraction already uses panel admin IDs, including combined IDs
# with underscores.
#
# Input:  ghsl/current_boundaries/ghsl_urban.csv, ghsl_built.csv and
#         03_panel_full.csv
# Output: 03_panel_full.csv (same rows, urban vars added)
# ==============================================================================

# ----------------------
# Packages and paths
# ----------------------

library(dplyr)
library(readr)

# Run from the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "checks.R"))

# Urban vars change by year, building cover vars are fixed per admin unit
# year_5s is the five-year snapshot year used to join the two
urban_vars <- c("year_5s", "ghsl_population", "settlement_type", "urban_share",
                "city_population", "city_share", "town_population", "town_share", "urban_status")
built_vars <- c("built_share_pop", "built_share_area")
keys <- c("iso", "admin_id", "year_5s")

# ----------------------------------------------
# Read current urban data and the full panel
# ----------------------------------------------

# Urban data by admin unit and five-year snapshot
urban <- read_csv(ghsl_file, show_col_types = FALSE,
                   col_types = cols(.default = col_double(), iso = col_character(),
                                    admin_id = col_character(), urban_status = col_character())) %>%
  select(iso, admin_id, all_of(urban_vars))

# Building cover is one row per admin unit, without a year join.
# admin_code is the country iso and admin_id joined with an underscore
built <- read_csv(ghsl_built_file, show_col_types = FALSE,
                   col_select = all_of(c("admin_code", built_vars)),
                   col_types = cols(admin_code = col_character(), .default = col_double()))

# Drop any urban cols from an earlier run
# Each mortality year gets the closest snapshot year, between 1975 and 2025
panel <- read_csv(full_panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character(), year = col_integer())) %>%
  select(-any_of(c(urban_vars, built_vars))) %>%
  mutate(year_5s = as.integer(pmin(2025, pmax(1975, round(year / 5) * 5))))

# ----------------------------------------------
# Check that every panel unit has urban data
# ----------------------------------------------

# Stop if a panel unit has no GHSL row (a missing value in a row is fine)
unmatched <- panel %>% distinct(iso, admin_id, year_5s) %>% anti_join(urban, by = keys)
write_checks(list(unmatched_urban_ids = unmatched))
if (nrow(unmatched) > 0) stop("Some panel IDs have no current GHSL row.", call. = FALSE)

# -------------------------------------------------------
# Add urban variables without changing mortality rows
# -------------------------------------------------------

# Urban vars join on snapshot year, building cover on admin unit only
updated <- panel %>% left_join(urban, by = keys) %>%
  mutate(admin_code = paste(iso, admin_id, sep = "_")) %>%
  left_join(built, by = "admin_code") %>% select(-admin_code)
stopifnot(nrow(updated) == nrow(panel))

write_csv(updated, full_panel_file, na = "")

# Record the units with missing building cover (no polygon, for ex the 3
# Chile island and Antarctic units, or zero GHSL population)
missing_built <- updated %>% distinct(iso, admin_id, across(all_of(built_vars))) %>%
  filter(is.na(built_share_pop) | is.na(built_share_area)) %>%
  mutate(admin_code = paste(iso, admin_id, sep = "_"))
write_checks(list(building_cover_missing = missing_built))
message("Updated full panel with current urban share: ", full_panel_file)
