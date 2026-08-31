# ============================================================
# 02_psgc_geocodes_clean.R
#
# Purpose:
# Clean the official PSGC file into a city/municipality lookup table
#
# The official PSGC file contains all admin levels in a single
# worksheet (regions, provinces, cities/municipalities, barangays, etc.)
# To build the metadata geocode crosswalk, we need the
# city/municipality level (adm3), along with the corresponding parent adm1
# region and adm2 province included 
#
# We later use this cleaned table as the official PSGC reference to
# link mortality metadata geocodes to the admin shapefiles
#
# Input:
# - Admin_Geocodes/0_Raw/PSGC-1Q-2026-Publication-Datafile.xlsx
#   sheet: PSGC
#
# Output:
# - Admin_Geocodes/1_Clean/psgc_adm_codes.csv
#
# Output includes:
# - city/municipality PSGC code, name, old code/name, type, and 2024 population
# - parent region code/name and 2024 population
# - parent province code/name and 2024 population
# ============================================================

library(readxl)
library(dplyr)
library(readr)

# -----------------------------
# Paths
# -----------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"))

psgc_xlsx <- file.path(
  admin_geocodes_raw_dir,
  "PSGC-1Q-2026-Publication-Datafile.xlsx"
)

# ----------------------------------------
# Read PSGC and keep only needed variables
# ----------------------------------------

psgc <- read_excel(psgc_xlsx, sheet = "PSGC", col_types = "text") %>%
  select(
    psgc_code = `10-digit PSGC`,
    name = Name,
    correspondence_code = `Correspondence Code`,
    geo_level = `Geographic Level`,
    old_name = `Old names`,
    urban_rural = `Urban / Rural\r\n(based on 2020 CPH)`,
    pop_2024 = `2024 Population`
  ) %>%
  mutate(
    correspondence_code = na_if(correspondence_code, ""),
    pop_2024 = readr::parse_number(pop_2024)
  ) %>%
  filter(!is.na(geo_level))

# -----------------------------
# Build ADM1 lookup (regions)
# -----------------------------

region_codes <- psgc %>%
  filter(geo_level == "Reg") %>%
  transmute(
    region_code = psgc_code,
    region_name = name,
    region_code_old = correspondence_code,
    old_region_name = old_name,
    region_2024_pop = pop_2024
  )

# -----------------------------------------
# Build ADM2 lookup (strict provinces only)
# -----------------------------------------

# Keeping strict provinces here is intentional
# Cities/HUC-like units that behave like ADM2 are handled via ADM3 rows
province_codes <- psgc %>%
  filter(geo_level == "Prov") %>%
  transmute(
    province_code = psgc_code,
    province_name = name,
    province_code_old = correspondence_code,
    old_province_name = old_name,
    province_2024_pop = pop_2024
  )

# ---------------------------------------
# Build ADM3 lookup (municipality + city)
# ---------------------------------------

# Parent codes are derived from the 10-digit PSGC structure
municipality_city_codes <- psgc %>%
  filter(geo_level %in% c("Mun", "City")) %>%
  mutate(
    region_code = paste0(substr(psgc_code, 1, 2), "00000000"),
    province_code = paste0(substr(psgc_code, 1, 5), "00000")
  ) %>%
  transmute(
    municipalicity_code = psgc_code,
    municipalicity_name = name,
    municipalicity_type = geo_level,
    municipalicity_code_old = correspondence_code,
    old_municipality_name = old_name,
    urban_rural,
    municipalicity_2024_pop = pop_2024,
    region_code,
    province_code
  )

# -----------------------------------------------
# Final table later used by cleaning script
# -----------------------------------------------

# Join adm3 units to their parent region/province information
psgc_adm_codes <- municipality_city_codes %>%
  left_join(region_codes, by = "region_code") %>%
  left_join(province_codes, by = "province_code") %>%
  mutate(
    # This helps us track units that are not strict provinces at ADM2.
    adm2_type = if_else(is.na(province_name), "city_or_special_adm2", "province")
  )

# ------------------------------------
# Quick counts/sanity checks in console
# --------------------------------------

cat("\nPSGC summary\n")
cat("ADM1 new:", n_distinct(psgc_adm_codes$region_code), "\n")
cat("ADM1 old:", n_distinct(psgc_adm_codes$region_code_old, na.rm = TRUE), "\n")
cat("ADM2 new (derived from ADM3 parents):", n_distinct(psgc_adm_codes$province_code), "\n")
cat("ADM2 old (strict province field):", n_distinct(psgc_adm_codes$province_code_old, na.rm = TRUE), "\n")
cat("ADM3 new (mun+city):", n_distinct(psgc_adm_codes$municipalicity_code), "\n")
cat("ADM3 old (mun+city):", n_distinct(psgc_adm_codes$municipalicity_code_old, na.rm = TRUE), "\n")

# ------------------------
# Write output
# ------------------------

write.csv(psgc_adm_codes,
          file.path(admin_geocodes_clean_dir, "psgc_adm_codes.csv"),
          row.names = FALSE)
