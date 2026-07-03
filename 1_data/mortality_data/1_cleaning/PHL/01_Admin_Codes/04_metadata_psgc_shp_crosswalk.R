# ============================================================
# 04_metadata_psgc_shp_crosswalk.R
#
# Purpose:
# Link the mortality metadata geocode crosswalk to official PSGC
# codes and administrative shapefile codes.
#
# 01_Admin_Codes/01 builds a crosswalk between the mortality metadata geocode
# systems used across different years.
# 01_Admin_Codes/02 cleans the official PSGC reference.
# 01_Admin_Codes/03 links PSGC codes to shapefile codes.
#
# This script combines those outputs into one ADM3 crosswalk:
#     mortality metadata codes <-> PSGC <-> shapefile codes
#
# The new_2024 metadata system is closest to the current PSGC coding
# system. This script first reconstructs a 10-digit PSGC code from the
# new_2024 metadata codes, then joins it to the PSGC-shapefile crosswalk.
# A name fallback is kept for cases where code matching is not sufficient.
#
# Steps:
# 1. Read the metadata crosswalk and PSGC-shapefile crosswalk
# 2. Keep matched ADM3 rows from the PSGC-shapefile crosswalk
# 3. Build a 10-digit PSGC code from the new_2024 metadata codes
# 4. Join metadata rows to the PSGC-shapefile crosswalk
# 5. Use a name fallback for any remaining unmatched admin units
# 6. Label matched, unmatched, and non-mappable rows
# 7. Write the final crosswalk and exception file
#
# Inputs:
# - Admin_Geocodes/1_Clean/metadata_geocode_crosswalk_adm3.csv
# - Admin_Geocodes/2_Crosswalks/psgc_shp_crosswalk_master.csv
#
# Outputs:
# - Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_adm3.csv
# - Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_exceptions.csv
# ============================================================


library(dplyr)
library(readr)
library(stringr)


# -----------------------------
# Paths
# -----------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/PHL/paths.R"))

metadata_crosswalk_file <- file.path(
  admin_geocodes_clean_dir,
  "metadata_geocode_crosswalk_adm3.csv"
)
psgc_shp_file <- file.path(
  admin_crosswalks_dir,
  "psgc_shp_crosswalk_master.csv"
)

out_file <- file.path(
  admin_crosswalks_dir,
  "metadata_psgc_shp_crosswalk_adm3.csv"
)
exceptions_file <- file.path(
  admin_crosswalks_dir,
  "metadata_psgc_shp_crosswalk_exceptions.csv"
)


# -----------------------------
# Read inputs
# -----------------------------

# read as character to preserve leading zeros in geographic codes
metadata_crosswalk <- read_csv(
  metadata_crosswalk_file,
  col_types = cols(.default = col_character())
)

psgc_shp <- read_csv(
  psgc_shp_file,
  col_types = cols(.default = col_character())
)


# -----------------------------
# Small code helpers
# -----------------------------

# trim whitespace, remove Excel ".0" artifacts, and convert blanks to NA
clean_code <- function(x) {
  x <- str_trim(as.character(x))
  x <- str_replace(x, "\\.0$", "")
  na_if(x, "")
}

# build a 10-digit PSGC code from ADM1, ADM2, and ADM3 code pieces
make_psgc10 <- function(region, province, mun) {
  region <- clean_code(region)
  province <- clean_code(province)
  mun <- clean_code(mun)
  
  # only construct codes from valid numeric components
  ok <- str_detect(region, "^[0-9]+$") &
    str_detect(province, "^[0-9]+$") &
    str_detect(mun, "^[0-9]+$")
  
  if_else(
    ok,
    paste0(
      str_pad(region, 2, pad = "0"),
      str_pad(province, 3, pad = "0"),
      str_pad(mun, 2, pad = "0"),
      "000"
    ),
    NA
  )
}

# standardize names for fallback matching
name_key <- function(x) {
  x <- as.character(x)
  x <- str_replace_all(x, "[ñÑ]", "n")
  x <- iconv(x, from = "", to = "ASCII//TRANSLIT")
  x <- str_to_upper(x)
  x <- str_replace_all(x, "\\*", "")
  x <- str_replace_all(x, "\\([^)]*\\)", "")
  x <- str_replace_all(x, "[^A-Z0-9]+", " ")
  x <- str_squish(x)
  na_if(x, "")
}


# -----------------------------
# Prepare PSGC-shapefile side
# -----------------------------

# keep matched ADM3 rows from the PSGC-shapefile crosswalk
# the metadata crosswalk is already at ADM3 level
psgc_shp_adm3 <- psgc_shp %>%
  filter(level == "adm3") %>%
  filter(match_method != "unmatched") %>%
  select(psgc_new_code, psgc_name,
         psgc_region_code, psgc_region_name,
         psgc_province_code, psgc_province_name,
         shp_code, shp_name,
         shp_region_code, shp_region_name,
         shp_province_code, shp_province_name,
         shp_mun_code, psgc_shp_match_method = match_method,
         psgc_shp_note = note) %>%
  distinct(psgc_new_code, .keep_all = TRUE)


# -------------------------------------------------------
# First pass: construct PSGC from new_2024 metadata codes
# -------------------------------------------------------

# build a 10-digit PSGC code from the new_2024 metadata codes,
# then join directly to the PSGC-shapefile crosswalk
metadata_link <- metadata_crosswalk %>%
  mutate(metadata_psgc_code = make_psgc10(
         adm1_code_new_2024,
         adm2_code_new_2024,
         adm3_code_new_2024)) %>%
  left_join(
    psgc_shp_adm3,
    by = c("metadata_psgc_code" = "psgc_new_code")
  ) %>%
  mutate(
    metadata_psgc_match_method = if_else(
      !is.na(metadata_psgc_code),
      "constructed_from_new_2024_codes",
      NA
      )
  )


# -----------------------------------------------------------
# Second pass: name fallback for any real leftover geography
# -----------------------------------------------------------

# fallback for rows not matched by code
# uses unique region + municipality/city names
name_fallback <- psgc_shp_adm3 %>%
  mutate(
    region_name_key = name_key(psgc_region_name),
    mun_name_key = name_key(psgc_name)
  ) %>%
  group_by(region_name_key, mun_name_key) %>%
  filter(n() == 1) %>%
  ungroup() %>%
  select(region_name_key, mun_name_key,
         psgc_new_code_f = psgc_new_code, psgc_name_f = psgc_name,
         psgc_region_code_f = psgc_region_code, psgc_region_name_f = psgc_region_name,
         psgc_province_code_f = psgc_province_code, psgc_province_name_f = psgc_province_name,
         shp_code_f = shp_code, shp_name_f = shp_name,
         shp_region_code_f = shp_region_code, shp_region_name_f = shp_region_name,
         shp_province_code_f = shp_province_code, shp_province_name_f = shp_province_name,
         shp_mun_code_f = shp_mun_code,
         psgc_shp_match_method_f = psgc_shp_match_method,
         psgc_shp_note_f = psgc_shp_note)

# combine code matches and name fallback matches
metadata_link <- metadata_link %>%
  mutate(
    region_name_key = name_key(adm1_name_new_2024),
    mun_name_key = name_key(adm3_name_new_2024)
  ) %>%
  left_join(name_fallback, by = c("region_name_key", "mun_name_key")) %>%
  mutate(
    psgc_new_code = coalesce(metadata_psgc_code, psgc_new_code_f),
    psgc_name = coalesce(psgc_name, psgc_name_f),
    psgc_region_code = coalesce(psgc_region_code, psgc_region_code_f),
    psgc_region_name = coalesce(psgc_region_name, psgc_region_name_f),
    psgc_province_code = coalesce(psgc_province_code, psgc_province_code_f),
    psgc_province_name = coalesce(psgc_province_name, psgc_province_name_f),
    shp_code = coalesce(shp_code, shp_code_f),
    shp_name = coalesce(shp_name, shp_name_f),
    shp_region_code = coalesce(shp_region_code, shp_region_code_f),
    shp_region_name = coalesce(shp_region_name, shp_region_name_f),
    shp_province_code = coalesce(shp_province_code, shp_province_code_f),
    shp_province_name = coalesce(shp_province_name, shp_province_name_f),
    shp_mun_code = coalesce(shp_mun_code, shp_mun_code_f),
    psgc_shp_match_method = coalesce(psgc_shp_match_method, psgc_shp_match_method_f),
    psgc_shp_note = coalesce(psgc_shp_note, psgc_shp_note_f),
    metadata_psgc_match_method = case_when(
      !is.na(metadata_psgc_code) ~ "constructed_from_new_2024_codes",
      is.na(metadata_psgc_code) & !is.na(psgc_new_code_f) ~ "name_fallback",
      TRUE ~ metadata_psgc_match_method
    )
  ) %>%
  select(-region_name_key, -mun_name_key, -ends_with("_f"))


# -----------------------------
# Final status labels
# -----------------------------

# assign final matching status for the next script
metadata_link <- metadata_link %>%
  mutate(
    metadata_psgc_shp_status = case_when(
      !is.na(shp_code) ~ "matched_to_shapefile",
      str_detect(coalesce(crosswalk_key, ""), "FOREIGNCOUNTRY") ~ "not_mappable_foreign_country",
      str_detect(coalesce(crosswalk_key, ""), "NOTSTATED") ~ "not_mappable_not_stated",
      crosswalk_status == "metadata_row_without_adm3_name" ~ "not_mappable_no_adm3_name",
      TRUE ~ "unmatched_geographic_row"
    )
  )


# -----------------------------
# Checks
# -----------------------------

# quick summary of match outcomes
checks <- metadata_link %>%
  count(metadata_psgc_shp_status, metadata_psgc_match_method, name = "rows") %>%
  arrange(metadata_psgc_shp_status, metadata_psgc_match_method)

print(checks)


# -----------------------------
# Write outputs
# -----------------------------

write_csv(metadata_link, out_file)

# write unmatched and non-mappable rows separately for review
metadata_link %>%
  filter(metadata_psgc_shp_status != "matched_to_shapefile") %>%
  write_csv(exceptions_file)

