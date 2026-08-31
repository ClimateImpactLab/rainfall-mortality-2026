# ============================================================
# 08_add_urban.R
#
# Add GHSL urban variables to the combined mortality panel
#
# The GHSL extract is stored in:
#
#   heterogeniety_data/ghsl/cleaned/ghsl_pop_landuse_popshare.csv
#
# GHSL is available every five years. Each mortality year is matched to the
# nearest five-year GHSL year, with all years before 1975 assigned to 1975
#
# Added variables:
#   year_5s, ghsl_population, settlement_type, urban_share
#
# Input:
#   panel_build/combined_panel/new_mortality_panel.csv
#
# Outputs:
#   panel_build/combined_panel/new_mortality_panel_urban.csv
#
# Usually run through:
#   1_data/panel_build/run_panel_build.sbatch
# ============================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
})


# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_file <- file.path(panel_dir, "new_mortality_panel.csv")
panel_out <- file.path(panel_dir, "new_mortality_panel_urban.csv")

ghsl_file <- file.path(
  "/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data/ghsl/cleaned",
  "ghsl_pop_landuse_popshare.csv"
)


# -----------------------------
# Variables
# -----------------------------

urban_vars <- c("year_5s", "ghsl_population", "settlement_type", "urban_share")
new_countries <- c("AUS", "COL", "ECU", "KOR", "PER", "PHL")


# -----------------------------
# Admin IDs
# -----------------------------

# Remove leading zeroes when matching IDs across source files
drop_leading_zeroes <- function(x) {
  out <- str_replace(as.character(x), "^0+", "")
  if_else(out == "", "0", out)
}

# Clean IDs before matching and keep missing IDs as missing
clean_id <- function(x) {
  x <- as.character(x)
  if_else(is.na(x) | x == "", NA_character_, drop_leading_zeroes(x))
}

# -----------------------------
# Read inputs
# -----------------------------

if (!file.exists(panel_file)) {
  stop("Missing panel file: ", panel_file, call. = FALSE)
}

if (!file.exists(ghsl_file)) {
  stop("Missing GHSL file: ", ghsl_file, call. = FALSE)
}

panel <- read_csv(
  panel_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

old_names <- names(panel)
old_rows <- nrow(panel)

# Drop old GHSL variables first if the script is being rerun
panel <- panel %>%
  select(-any_of(urban_vars)) %>%
  mutate(
    year_num = as.numeric(year),
    year_5s = round(year_num / 5) * 5,
    year_5s = if_else(year_5s < 1975, 1975, year_5s)
  )

# Build the panel IDs used to match the GHSL extract
# Leading zeroes are removed because they differ across some source files
geo_lookup <- panel %>%
  distinct(iso, adm1_id, adm2_id, admin_id) %>%
  mutate(
    adm1_key = clean_id(adm1_id),
    adm2_key = clean_id(adm2_id),
    admin_key = clean_id(admin_id)
  )

ghsl <- read_csv(
  ghsl_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

# Convert the wide GHSL file to one row per admin unit and GHSL year
ghsl_long <- ghsl %>%
  pivot_longer(
    cols = matches("_[0-9]{4}$"),
    names_to = c(".value", "year_5s"),
    names_pattern = "(.+)_(\\d{4})"
  ) %>%
  transmute(
    ghsl_iso = iso2,
    adm1_key = clean_id(ID_1),
    adm2_key = clean_id(ID_2),
    year_5s = as.numeric(year_5s),
    ghsl_population = as.numeric(sum.POP),
    settlement_type = as.numeric(majority.SMOD),
    urban_share = as.numeric(urban_share)
  )


# -----------------------------
# Match GHSL admin units
# -----------------------------

# New countries use GHSL `ID_2` as the panel `admin_id`
ghsl_new <- ghsl_long %>%
  filter(ghsl_iso %in% new_countries) %>%
  inner_join(
    geo_lookup,
    by = c("ghsl_iso" = "iso", "adm2_key" = "admin_key")
  ) %>%
  transmute(
    iso = ghsl_iso, admin_id, year_5s,
    ghsl_population, settlement_type, urban_share
  )

# Most old-panel countries match on ISO, ADM1, and ADM2
ghsl_country <- ghsl_long %>%
  filter(!ghsl_iso %in% c("EU", "JPN", new_countries), !is.na(adm2_key)) %>%
  inner_join(
    geo_lookup,
    by = c("ghsl_iso" = "iso", "adm1_key", "adm2_key")
  ) %>%
  transmute(
    iso = ghsl_iso, admin_id, year_5s,
    ghsl_population, settlement_type, urban_share
  )

# Japan is ADM1 in the mortality panel, so match only on ADM1
ghsl_jpn <- ghsl_long %>%
  filter(ghsl_iso == "JPN", is.na(adm2_key)) %>%
  inner_join(
    geo_lookup %>% filter(iso == "JPN"),
    by = "adm1_key"
  ) %>%
  transmute(
    iso = ghsl_iso, admin_id, year_5s,
    ghsl_population, settlement_type, urban_share
  )

# Europe uses NUTS IDs, the panel ISO comes from the panel lookup after matching
ghsl_eu <- ghsl_long %>%
  filter(ghsl_iso == "EU") %>%
  inner_join(
    geo_lookup,
    by = c("adm1_key", "adm2_key")
  ) %>%
  transmute(
    iso, admin_id, year_5s,
    ghsl_population, settlement_type, urban_share
  )

ghsl_admin <- bind_rows(ghsl_new, ghsl_country, ghsl_jpn, ghsl_eu) %>%
  distinct()

# Duplicate GHSL rows would duplicate mortality rows after the merge
duplicate_urban <- ghsl_admin %>%
  count(iso, admin_id, year_5s, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_urban) > 0) {
  stop("GHSL has duplicate country-admin-year rows after matching", call. = FALSE)
}


# -----------------------------
# Merge
# -----------------------------

# Add GHSL variables using country, admin ID, and five-year GHSL year
panel_urban <- panel %>%
  left_join(ghsl_admin, by = c("iso", "admin_id", "year_5s")) %>%
  select(-year_num)

# The merge should not add or remove mortality rows
if (nrow(panel_urban) != old_rows) {
  stop("Urban merge changed the row count", call. = FALSE)
}

# All non-GHSL variables from the input panel should still be present
missing_old_names <- setdiff(setdiff(old_names, urban_vars), names(panel_urban))

if (length(missing_old_names) > 0) {
  stop(
    "Urban merge dropped existing columns: ",
    paste(missing_old_names, collapse = ", "),
    call. = FALSE
  )
}

# Only the expected GHSL variables should be added
new_cols <- setdiff(names(panel_urban), old_names)
expected_new <- setdiff(urban_vars, old_names)

if (!setequal(new_cols, expected_new)) {
  stop("Unexpected new columns after urban merge", call. = FALSE)
}


# -----------------------------
# Write outputs
# -----------------------------

# Write the panel with GHSL variables added
write_csv(panel_urban, panel_out, na = "")

message("Read panel: ", panel_file)
message("Wrote panel with GHSL variables: ", panel_out)
