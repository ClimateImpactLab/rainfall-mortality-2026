# ==============================================================================
# 3a_add_adm1_income.R
#
# Start the full panel from the climate panel, then add ADM0 and ADM1 income.
# The mortality-only and climate panels are left unchanged.
#
# Old-country income comes from the trimmed old panel. New-country income comes
# from the ADM1 income table. Two merged units that span ADM1 boundaries (ECU
# 1503 and THA TH38_43) use supplied unit-level overrides instead.
# Any panel unit without an income match is listed in the checks and stops
# the script before saving.
#
# Input:  02_panel_climate.csv, old_panel/old_panel_era5_trimmed.csv,
#         new-country ADM1 income table and unit overrides (paths.R)
# Output: 03_panel_full.csv
# Kummu income is added separately in 3b.
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

# Always start from the climate panel, so a rerun never builds on a partly
# updated full panel
# row keeps the original row order for the end
panel <- read_csv(climate_panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character())) %>%
  mutate(row = row_number())

# --------------------
# Income variables
# --------------------

# ADM0 and ADM1 income, the same vars the old panel carries (see 1a)
income_vars <- c(
  "gdppc_adm0", "gdppc_adm0_13br", "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg"
)

# Flags saying where each new-country income value came from
income_flags <- c("income_source_type", "income_basis")

# -------------------------------------------
# Read old-country and new-country income
# -------------------------------------------

# These columns used to travel through the mortality file.
# Load them here instead.
# distinct() keeps one row per admin-year, since the old panel has a row
# for each age group
old_income <- read_csv(
  file.path(old_panel_dir, "old_panel_era5_trimmed.csv"), show_col_types = FALSE,
  col_select = all_of(c("iso", "admin_id", "year", income_vars)),
  col_types = cols(.default = col_character())
) %>% mutate(across(all_of(income_vars), as.numeric)) %>% distinct()

# New-country income is by ADM1 and year
# Both inputs already have text IDs with their original leading zeroes.
# .income_matched marks rows that found an income value
income <- read_csv(income_file, show_col_types = FALSE,
                   col_types = cols(.default = col_character())) %>%
  select(all_of(c("iso", "adm1_id", "year", income_vars, income_flags))) %>%
  mutate(across(all_of(income_vars), as.numeric), .income_matched = TRUE)

# The two merged units get income by admin_id, not ADM1
overrides <- read_csv(income_overrides_file, show_col_types = FALSE,
                      col_types = cols(.default = col_character())) %>%
  select(all_of(c("iso", "admin_id", "year", income_vars, income_flags))) %>%
  mutate(across(all_of(income_vars), as.numeric), .income_matched = TRUE)

# Repeated source keys would multiply mortality rows.
if (anyDuplicated(old_income[c("iso", "admin_id", "year")]) ||
    anyDuplicated(income[c("iso", "adm1_id", "year")]) ||
    anyDuplicated(overrides[c("iso", "admin_id", "year")])) {
  stop("Income IDs are not unique.", call. = FALSE)
}
if (anyNA(income[c("iso", "adm1_id", "year")]) ||
    anyNA(overrides[c("iso", "admin_id", "year")])) {
  stop("Income source keys contain missing IDs or years.", call. = FALSE)
}

# --------------------------------------
# Add income and save the full panel
# --------------------------------------

# Drop any income cols from an earlier run, then join by country type
# Old countries join on admin_id and year
panel <- panel %>% select(-any_of(c(income_vars, income_flags)))
old_rows <- panel %>% filter(source_panel == "old") %>%
  left_join(old_income, by = c("iso", "admin_id", "year"))

# New countries join on ADM1 and year, except the override units
new_panel <- panel %>% filter(source_panel == "new")
override_keys <- overrides %>% select(iso, admin_id, year)
new_rows <- new_panel %>% anti_join(override_keys, by = c("iso", "admin_id", "year")) %>%
  left_join(income, by = c("iso", "adm1_id", "year"))

# ECU 1503 and THA TH38_43 have no single true ADM1 parent.
# Attach their reviewed income without changing the mortality geography.
override_rows <- new_panel %>% semi_join(override_keys, by = c("iso", "admin_id", "year")) %>%
  left_join(overrides, by = c("iso", "admin_id", "year"))
new_rows <- bind_rows(new_rows, override_rows)

# Every new-country row must find an income value, otherwise stop
unmatched <- new_rows %>% filter(is.na(.income_matched)) %>%
  distinct(iso, adm1_id, admin_id, year)
write_checks(list(unmatched_adm1_income = unmatched))
if (nrow(unmatched) > 0) {
  stop("Unmatched income keys. See unmatched_adm1_income in the check workbook.", call. = FALSE)
}

# Put the rows back in their original order and check none were added or lost
updated <- bind_rows(old_rows, new_rows) %>% arrange(row)
stopifnot(nrow(updated) == nrow(panel), identical(updated$row, panel$row))
updated <- updated %>% select(-row, -.income_matched)
write_csv(updated, full_panel_file, na = "")
message("Wrote full panel: ", full_panel_file)
