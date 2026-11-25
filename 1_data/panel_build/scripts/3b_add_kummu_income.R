# ==============================================================================
# 3b_add_kummu_income.R
#
# Add Kummu annual income in constant 2021 PPP dollars, plus five fixed
# income windows, to the full panel.
# Mortality before 1990 uses 1990 income, and after 2024 uses 2024.
# Actual years, all non-Kummu columns and row order are unchanged.
#
# The script stops if the Kummu input is not the price-corrected release.
# It also stops if a panel unit has no Kummu match and is not on the list of
# known missing units. Known missing units keep missing income.
#
# Input:  Kummu annual and fixed-window income files (kummu_dir in paths.R),
#         03_panel_full.csv
# Output: 03_panel_full.csv (same rows, Kummu income added)
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
source(file.path(build_dir, "../heterogeniety_data/1_data_cleaning/Income/kummu/scripts/income_windows.R"))

# Only use the price-corrected income, in constant 2021 PPP dollars
metadata <- readRDS(file.path(kummu_dir, "income_release.rds"))
if (!isTRUE(metadata$price_corrected) || metadata$units != "constant 2021 international dollars PPP")
  stop("Kummu input is not the approved constant-price product")

# Names of the fixed-window cols: mean income, mean log income and years
# observed and filled for each window
# Plus the 2010-2024 population-weighted mean
window_vars <- unlist(lapply(names(income_windows), function(period) paste0(
  c("kummu_gdppc_avg_", "kummu_loggdppc_avg_", "kummu_years_observed_", "kummu_years_filled_"), period
)), use.names = FALSE)
window_vars <- c(window_vars, "kummu_gdppc_popwt_2010_2024", "kummu_loggdppc_popwt_2010_2024")

# -----------------------------
# Read income with text IDs
# -----------------------------

# Annual income by admin unit and year, with gaps already filled
# .income_match marks panel rows that find a Kummu value
annual <- read_csv(file.path(kummu_dir, "kummu_admin_year_income.csv"),
  show_col_types = FALSE, col_types = cols(.default = col_character()),
  col_select = c(iso, admin_id, year, kummu_gdppc_ppp_filled,
                 kummu_log_gdppc_ppp_filled, kummu_income_basis)) %>%
  transmute(iso, admin_id, income_year = as.integer(year),
    kummu_gdppc = as.numeric(kummu_gdppc_ppp_filled),
    kummu_loggdppc = as.numeric(kummu_log_gdppc_ppp_filled), kummu_income_basis,
    .income_match = TRUE)

# Fixed-window income, one row per admin unit
profile <- read_csv(file.path(kummu_dir, "kummu_admin_profile_income.csv"),
  show_col_types = FALSE, col_types = cols(.default = col_character()),
  col_select = all_of(c("iso", "admin_id", window_vars))) %>%
  mutate(across(all_of(window_vars), as.numeric))

# Repeated keys would multiply mortality rows
if (anyDuplicated(annual[c("iso", "admin_id", "income_year")]) ||
    anyDuplicated(profile[c("iso", "admin_id")])) stop("Duplicate Kummu income keys")
if (nrow(anti_join(distinct(annual, iso, admin_id), profile, by = c("iso", "admin_id"))))
  stop("An annual Kummu unit has no fixed-window profile")

# ----------------------------------------
# Join annual values and fixed windows
# ----------------------------------------

panel <- read_csv(full_panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character()))

# Drop the Kummu cols from an earlier run, so a rerun replaces them
owned <- c(window_vars, "kummu_gdppc", "kummu_loggdppc", "kummu_income_basis",
  "kummu_lowinc_share", "kummu_lowinc_avg_2010_2024", "kummu_income_pctile_country",
  "kummu_low_income_pop_share", "kummu_low_income_pop_share_avg_2010_2024",
  "kummu_profile_income_basis", "kummu_admin_fallback", "kummu_fallback_level")

# income_year is the year of income used for each mortality row
# Mortality years before 1990 get 1990 income, and years after 2024 get 2024
# .kummu_row keeps the original row order
panel <- panel %>% select(-any_of(owned)) %>% mutate(.kummu_row = row_number(),
  income_year = pmin(2024L, pmax(1990L, as.integer(year))))
if (anyNA(panel$income_year)) stop("Missing or invalid mortality years")

# Annual income joins on admin unit and income year
# Fixed windows join on admin unit only
updated <- panel %>% left_join(annual, by = c("iso", "admin_id", "income_year")) %>%
  left_join(profile, by = c("iso", "admin_id"))
stopifnot(nrow(updated) == nrow(panel), identical(updated$.kummu_row, panel$.kummu_row))

# Panel units with no Kummu match must be on the known missing list
# Anything else means the panel IDs and the Kummu geography disagree
unmatched <- updated %>% filter(is.na(.income_match)) %>% distinct(iso, admin_id, year)
known_missing <- read_csv(kummu_missing_units_file, show_col_types = FALSE,
                          col_types = cols(.default = col_character()))
if (anyDuplicated(known_missing[c("iso", "admin_id")]) || anyNA(known_missing[c("iso", "admin_id")]))
  stop("Invalid known-missing Kummu unit keys")
unexpected <- anti_join(unmatched, known_missing, by = c("iso", "admin_id"))
if (nrow(unexpected)) stop("Panel IDs do not match the selected Kummu geography")
updated$kummu_income_basis[is.na(updated$.income_match)] <- "No Kummu geography"

# ------------------
# Check and save
# ------------------

# Rows, units and missing income by country, year and income year
attachment <- updated %>% group_by(iso, year, income_year) %>% summarize(
  rows = n(), units = n_distinct(admin_id), missing_income = sum(is.na(kummu_gdppc)), .groups = "drop")
write_checks(list("Kummu Attachment" = attachment,
  "Kummu Unmatched" = left_join(unmatched, known_missing, by = c("iso", "admin_id"))))

# Drop the helper cols, then write to a temporary file and rename it
# so a failed write cannot damage the full panel
updated <- updated %>% select(-.kummu_row, -income_year, -.income_match)
temporary <- paste0(full_panel_file, ".tmp")
write_csv(updated, temporary, na = "")
if (!file.rename(temporary, full_panel_file)) stop("Could not save updated income panel")
message("Updated constant-price Kummu income: ", full_panel_file)
