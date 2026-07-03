
# ============================================================
# 03_psgc_shp_crosswalk.R
#
# Purpose:
# Build a crosswalk between the official PSGC codes and the
# administrative shapefile codes.
#
# The PSGC and shapefile describe the same admin units, but they do not
# always use the same codes. Some shapefile codes match old PSGC codes,
# some match current PSGC codes, and a few require name-based matching.
# 
# This script reconciles the two coding systems into a single crosswalk
# while keeping the corresponding region and province information from
# both systems.
#
# Steps:
# 1. Read the cleaned PSGC table and shapefile attributes
# 2. Format PSGC/shapefile codes for matching
# 3. Build PSGC and shapefile lookup tables by admin level
# 4. Match ADM1, ADM2, and ADM3 units
# 5. Use name-based fallbacks where code matches fail
# 6. Combine ADM1/ADM2/ADM3 results into one crosswalk
# 7. Write output and print quick checks
#
# Input:
# - Admin_Geocodes/1_Clean/psgc_adm_codes.csv
# - Shapefiles/Post2023/PH_Adm1_Regions.shp
# - Shapefiles/Post2023/PH_Adm2_ProvDists.shp
# - Shapefiles/Post2023/PH_Adm3_MuniCities.shp
#
# Output:
# - Admin_Geocodes/2_Crosswalks/psgc_shp_crosswalk_master.csv
# ===========================================================


library(sf)
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

psgc_path <- file.path(admin_geocodes_clean_dir, "psgc_adm_codes.csv")

adm1_path <- file.path(post2023_shapefiles_dir, "PH_Adm1_Regions.shp")
adm2_path <- file.path(post2023_shapefiles_dir, "PH_Adm2_ProvDists.shp")
adm3_path <- file.path(post2023_shapefiles_dir, "PH_Adm3_MuniCities.shp")

crosswalk_file <- file.path(
  admin_crosswalks_dir,
  "psgc_shp_crosswalk_master.csv"
)


# -----------------------------
# Small helper functions
# -----------------------------

# Helper functions reused across the ADM1, ADM2, and ADM3 matching steps

# keep digits only (handles excel formatting, spaces, punctuation)
digits_only <- function(x) {
  if (is.numeric(x)) x <- sprintf("%.0f", x)
  x <- as.character(x)
  x <- str_trim(x)
  x[x == ""] <- NA
  str_replace_all(x, "[^0-9]", "")
}

# Some shapefile codes are missing the leading zero present in
# the standard 10-digit PSGC format.
shp_to_10 <- function(x) {
  x <- digits_only(x)
  if_else(!is.na(x) & str_length(x) == 9, str_c("0", x), x)
}

# PSGC correspondence (old) codes can also be stored as
# 9 digits. Unlike shapefile codes, the missing zero is
# inserted after the first two digits.
corr9_to_10 <- function(x) {
  x <- digits_only(x)
  idx <- !is.na(x) & str_length(x) == 9
  x[idx] <- str_c(str_sub(x[idx], 1, 2), "0", str_sub(x[idx], 3, 9))
  x
}

# Simple name key used for fallback name matching.
# (lowercase, remove punctuation, normalize spaces) 
key_name <- function(x) {
  str_to_lower(x) %>%
    str_replace_all("[^a-z0-9]+", " ") %>%
    str_squish()
}


# -----------------------------
# Read inputs
# -----------------------------

psgc <- read_csv(psgc_path, show_col_types = FALSE)

adm1 <- st_read(adm1_path, layer = "PH_Adm1_Regions.shp", quiet = TRUE)
adm2 <- st_read(adm2_path, layer = "PH_Adm2_ProvDists.shp", quiet = TRUE)
adm3 <- st_read(adm3_path, layer = "PH_Adm3_MuniCities.shp", quiet = TRUE)


# ------------------------------------
# PSGC reference tables by adm level
# -------------------------------------

# split the cleaned PSGC table into separate ADM1, ADM2, and ADM3 lookup tables
# Each level is matched separately later in the script
# Higher-level admin codes and names are kept where applicable

# -------- ADM1: regions --------

psgc_adm1 <- psgc %>%
  transmute(
    psgc_new_code = digits_only(region_code),
    mortality_old_code10 = corr9_to_10(region_code_old),
    psgc_name = region_name,
    psgc_region_code = digits_only(region_code),
    psgc_region_name = region_name,
    psgc_province_code = NA,
    psgc_province_name = NA
  ) %>%
  distinct()

# -------- ADM2: provinces --------

psgc_adm2 <- psgc %>%
  transmute(
    psgc_new_code = digits_only(province_code),
    mortality_old_code10 = corr9_to_10(province_code_old),
    psgc_name = province_name,
    psgc_region_code = digits_only(region_code),
    psgc_region_name = region_name,
    psgc_province_code = digits_only(province_code),
    psgc_province_name = province_name
  ) %>%
  distinct()

# -------- ADM3: municipalities/cities --------

psgc_adm3 <- psgc %>%
  transmute(
    psgc_new_code = digits_only(municipalicity_code),
    mortality_old_code10 = corr9_to_10(municipalicity_code_old),
    psgc_name = municipalicity_name,
    psgc_region_code = digits_only(region_code),
    psgc_region_name = region_name,
    psgc_province_code = digits_only(province_code),
    psgc_province_name = province_name
  ) %>%
  distinct()


# -----------------------------
# Shapefile attribute tables
# -----------------------------

# Build shapefile lookup tables at each ADM level.
# Drop geometry and keep only the attribute information needed for matching.

# -------- ADM1: regions -------- 

adm1_shp <- adm1 %>%
  st_drop_geometry() %>%
  transmute(
    shp_code = shp_to_10(adm1_psgc),
    shp_name = adm1_en
  ) %>%
  distinct()

# -------- ADM2: provinces -------- 

adm2_shp <- adm2 %>%
  st_drop_geometry() %>%
  transmute(
    shp_code = shp_to_10(adm2_psgc),
    shp_name = adm2_en,
    shp_region_code = shp_to_10(adm1_psgc)
  ) %>%
  distinct() %>%
  left_join(
    adm1_shp %>%
      select(
        shp_region_code = shp_code,
        shp_region_name = shp_name
      ),
    by = "shp_region_code"
  )

# -------- ADM3: municipalities/cities --------

adm3_shp <- adm3 %>%
  st_drop_geometry() %>%
  transmute(
    shp_code = shp_to_10(adm3_psgc),
    shp_name = adm3_en,
    shp_province_code = shp_to_10(adm2_psgc),
    shp_region_code = shp_to_10(adm1_psgc)
  ) %>%
  distinct() %>%
  left_join(
    adm2_shp %>%
      select(
        shp_province_code = shp_code,
        shp_province_name = shp_name,
        shp_region_code,
        shp_region_name
      ),
    by = c("shp_province_code", "shp_region_code")
  )




# -----------------------------
# ADM1 matching
# -----------------------------

# First match shapefile region codes to old/correspondence PSGC codes
adm1_link <- adm1_shp %>%
  left_join(
    psgc_adm1 %>%
      select(
        mortality_old_code10,
        psgc_new_code,
        psgc_name,
        psgc_region_code,
        psgc_region_name,
        psgc_province_code,
        psgc_province_name
      ),
    by = c("shp_code" = "mortality_old_code10")
  ) %>%
  mutate(match_method = if_else(!is.na(psgc_new_code), "code_old", NA))

# For regions that do not match by code, fall back to name matching
adm1_fallback <- adm1_link %>%
  filter(is.na(psgc_new_code)) %>%
  mutate(k = key_name(shp_name)) %>%
  left_join(
    psgc_adm1 %>%
      mutate(k = key_name(psgc_name)) %>%
      select(
        k,
        psgc_new_code_f = psgc_new_code,
        psgc_name_f = psgc_name,
        mortality_old_code10_f = mortality_old_code10,
        psgc_region_code_f = psgc_region_code,
        psgc_region_name_f = psgc_region_name,
        psgc_province_code_f = psgc_province_code,
        psgc_province_name_f = psgc_province_name
      ),
    by = "k"
  ) %>%
  select(
    shp_code,
    psgc_new_code_f,
    psgc_name_f,
    mortality_old_code10_f,
    psgc_region_code_f,
    psgc_region_name_f,
    psgc_province_code_f,
    psgc_province_name_f
  )

# combine code matches and name fallback matches
adm1_link <- adm1_link %>%
  left_join(adm1_fallback, by = "shp_code") %>%
  mutate(
    psgc_new_code = coalesce(psgc_new_code, psgc_new_code_f),
    psgc_name = coalesce(psgc_name, psgc_name_f),
    psgc_region_code = coalesce(psgc_region_code, psgc_region_code_f),
    psgc_region_name = coalesce(psgc_region_name, psgc_region_name_f),
    psgc_province_code = coalesce(psgc_province_code, psgc_province_code_f),
    psgc_province_name = coalesce(psgc_province_name, psgc_province_name_f),
    
    mortality_old_code10 = case_when(
      match_method == "code_old" ~ shp_code,
      !is.na(psgc_new_code_f) ~ mortality_old_code10_f,
      TRUE ~ NA
    ),
    match_method = case_when(
      match_method == "code_old" ~ "code_old",
      !is.na(psgc_new_code_f) ~ "name",
      TRUE ~ "unmatched"
    ),
    note = ""
  ) %>%
  select(shp_code, shp_name, psgc_new_code, 
         psgc_name, psgc_region_code, 
         psgc_region_name, psgc_province_code,
         psgc_province_name, mortality_old_code10, 
         match_method, note)



# -----------------------------
# ADM2 matching
# -----------------------------

# first match shapefile province/district codes to old/correspondence PSGC codes
# code matching is safer than names when boundaries or admin names have changed
adm2_link <- adm2_shp %>%
  left_join(
    psgc_adm2 %>%
     select(mortality_old_code10, psgc_new_code, psgc_name,
             psgc_region_code, psgc_region_name, psgc_province_code,
             psgc_province_name),
    by = c("shp_code" = "mortality_old_code10")
  ) %>%
  mutate(match_method = if_else(!is.na(psgc_new_code), "code_old", NA))

# for rows that do not match by code, fall back to normalized names
adm2_fallback <- adm2_link %>%
  filter(is.na(psgc_new_code)) %>%
  mutate(k = key_name(shp_name)) %>%
  left_join(
    psgc_adm2 %>%
      filter(!is.na(psgc_name)) %>%
      mutate(k = key_name(psgc_name)) %>%
      select(
        k,
        psgc_new_code_f = psgc_new_code,
        psgc_name_f = psgc_name,
        mortality_old_code10_f = mortality_old_code10,
        psgc_region_code_f = psgc_region_code,
        psgc_region_name_f = psgc_region_name,
        psgc_province_code_f = psgc_province_code,
        psgc_province_name_f = psgc_province_name),
    by = "k") %>%
  select(shp_code, psgc_new_code_f, psgc_name_f,
         mortality_old_code10_f, psgc_region_code_f,
         psgc_region_name_f, psgc_province_code_f,
         psgc_province_name_f)

# combine code matches and name fallback matches
adm2_link <- adm2_link %>%
  left_join(adm2_fallback, by = "shp_code") %>%
  mutate(
    psgc_new_code = coalesce(psgc_new_code, psgc_new_code_f),
    psgc_name = coalesce(psgc_name, psgc_name_f),
    psgc_region_code = coalesce(psgc_region_code, psgc_region_code_f),
    psgc_region_name = coalesce(psgc_region_name, psgc_region_name_f),
    psgc_province_code = coalesce(psgc_province_code, psgc_province_code_f),
    psgc_province_name = coalesce(psgc_province_name, psgc_province_name_f),
    
    mortality_old_code10 = case_when(
      match_method == "code_old" ~ shp_code,
      !is.na(psgc_new_code_f) ~ mortality_old_code10_f,
      TRUE ~ NA
    ),
    match_method = case_when(
      match_method == "code_old" ~ "code_old",
      !is.na(psgc_new_code_f) ~ "name",
      TRUE ~ "unmatched"
    ),
    
    # flag known shapefile grouping rows that are not ordinary province rows
    note = case_when(
      shp_code %in% c("1303900000", "1307400000", "1307500000", "1307600000") ~ "NCR district aggregate in shapefile",
      shp_code == "0990100000" ~ "Isabela City aggregate in shapefile",
      shp_code == "1909900000" ~ "Special BARMM grouping in shapefile",
      TRUE ~ "")) %>%
  select(shp_code, shp_name,
         shp_region_code, shp_region_name,
         psgc_new_code, psgc_name,
         psgc_region_code, psgc_region_name,
         psgc_province_code, psgc_province_name,
         mortality_old_code10, match_method, note)



# -----------------------------
# ADM3 matching
# -----------------------------

# first match shapefile municipality/city codes to old/correspondence PSGC codes
adm3_link <- adm3_shp %>%
  left_join(
    psgc_adm3 %>%
      select(mortality_old_code10, psgc_new_code, psgc_name,
             psgc_region_code, psgc_region_name,
             psgc_province_code, psgc_province_name),
    by = c("shp_code" = "mortality_old_code10")
  ) %>%
  mutate(match_method = if_else(!is.na(psgc_new_code), "code_old", NA))

# fallback 1: match municipality/city name within the same province
# municipality names can repeat across provinces
adm3_fb1 <- adm3_link %>%
  filter(is.na(psgc_new_code)) %>%
  mutate(
    k_name = key_name(shp_name),
    k_prov = key_name(shp_province_name)
  ) %>%
  left_join(
    psgc_adm3 %>%
      filter(!is.na(psgc_name), !is.na(psgc_province_name)) %>%
      mutate(
        k_name = key_name(psgc_name),
        k_prov = key_name(psgc_province_name)
      ) %>%
      select(k_name, k_prov,
             psgc_new_code_f = psgc_new_code,
             psgc_name_f = psgc_name,
             mortality_old_code10_f = mortality_old_code10,
             psgc_region_code_f = psgc_region_code,
             psgc_region_name_f = psgc_region_name,
             psgc_province_code_f = psgc_province_code, 
             psgc_province_name_f = psgc_province_name),
    by = c("k_name", "k_prov")
  ) %>%
  select(shp_code,
         psgc_new_code_f, psgc_name_f, mortality_old_code10_f,
         psgc_region_code_f, psgc_region_name_f,
         psgc_province_code_f, psgc_province_name_f)

# fill matches found by name within province
adm3_link <- adm3_link %>%
  left_join(adm3_fb1, by = "shp_code") %>%
  mutate(
    psgc_new_code = coalesce(psgc_new_code, psgc_new_code_f),
    psgc_name = coalesce(psgc_name, psgc_name_f),
    psgc_region_code = coalesce(psgc_region_code, psgc_region_code_f),
    psgc_region_name = coalesce(psgc_region_name, psgc_region_name_f),
    psgc_province_code = coalesce(psgc_province_code, psgc_province_code_f),
    psgc_province_name = coalesce(psgc_province_name, psgc_province_name_f),
    
    mortality_old_code10 = case_when(
      match_method == "code_old" ~ shp_code,
      !is.na(psgc_new_code_f) ~ mortality_old_code10_f,
      TRUE ~ NA
    ),
    match_method = case_when(
      match_method == "code_old" ~ "code_old",
      !is.na(psgc_new_code_f) ~ "name_province",
      TRUE ~ match_method
    )
  )

# fallback 2 setup: names that appear only once nationally in PSGC ADM3
unique_name_map <- psgc_adm3 %>%
  filter(!is.na(psgc_name)) %>%
  mutate(k_name = key_name(psgc_name)) %>%
  group_by(k_name) %>%
  filter(n() == 1) %>%
  ungroup() %>%
  select(k_name,
         psgc_new_code_u = psgc_new_code, 
         psgc_name_u = psgc_name,
         mortality_old_code10_u = mortality_old_code10,
         psgc_region_code_u = psgc_region_code,
         psgc_region_name_u = psgc_region_name,
         psgc_province_code_u = psgc_province_code,
         psgc_province_name_u = psgc_province_name)

# fallback 2: match remaining rows by nationally unique municipality/city name
adm3_fb2 <- adm3_link %>%
  filter(is.na(psgc_new_code)) %>%
  mutate(k_name = key_name(shp_name)) %>%
  left_join(unique_name_map, by = "k_name") %>%
  select(shp_code,
         psgc_new_code_u, psgc_name_u, mortality_old_code10_u,
         psgc_region_code_u, psgc_region_name_u,
         psgc_province_code_u, psgc_province_name_u)

# fallback 3: try current PSGC code for rows still unmatched
# some shapefile ADM3 codes already use the current PSGC code
adm3_fb3 <- adm3_link %>%
  filter(is.na(psgc_new_code)) %>%
  left_join(
    psgc_adm3 %>%
      select(psgc_new_code_j = psgc_new_code,
             psgc_name_j = psgc_name,
             mortality_old_code10_j = mortality_old_code10,
             psgc_region_code_j = psgc_region_code, 
             psgc_region_name_j = psgc_region_name,
             psgc_province_code_j = psgc_province_code,
             psgc_province_name_j = psgc_province_name),
    by = c("shp_code" = "psgc_new_code_j")
  ) %>%
  mutate(psgc_new_code_j = shp_code) %>%
  select(shp_code,
         psgc_new_code_j, psgc_name_j, mortality_old_code10_j,
         psgc_region_code_j, psgc_region_name_j,
         psgc_province_code_j, psgc_province_name_j)

# combine all ADM3 matching attempts
# order matters: old code, name within province, unique name, then current code
adm3_link <- adm3_link %>%
  left_join(adm3_fb2, by = "shp_code") %>%
  left_join(adm3_fb3, by = "shp_code") %>%
  mutate(
    psgc_new_code = coalesce(psgc_new_code, psgc_new_code_u, psgc_new_code_j),
    psgc_name = coalesce(psgc_name, psgc_name_u, psgc_name_j),
    psgc_region_code = coalesce(psgc_region_code, psgc_region_code_u, psgc_region_code_j),
    psgc_region_name = coalesce(psgc_region_name, psgc_region_name_u, psgc_region_name_j),
    psgc_province_code = coalesce(psgc_province_code, psgc_province_code_u, psgc_province_code_j),
    psgc_province_name = coalesce(psgc_province_name, psgc_province_name_u, psgc_province_name_j),
    
    mortality_old_code10 = coalesce(
      mortality_old_code10,
      mortality_old_code10_u,
      mortality_old_code10_j
    ),
    match_method = case_when(
      match_method == "code_old" ~ "code_old",
      match_method == "name_province" ~ "name_province",
      !is.na(psgc_new_code_u) ~ "name_unique",
      !is.na(psgc_new_code_j) ~ "code_new",
      TRUE ~ "unmatched"
    ),
    
    # flag shapefile-specific BARMM grouping rows
    note = case_when(
      str_detect(shp_code, "^19999") ~ "BARMM SGU/cluster code in shapefile",
      TRUE ~ ""
    )
  ) %>%
  select(shp_code, shp_name,
         shp_province_code, shp_province_name,
         shp_region_code, shp_region_name,
         psgc_new_code, psgc_name,
         psgc_region_code, psgc_region_name,
         psgc_province_code, psgc_province_name,
         mortality_old_code10, match_method, note)



# -----------------------------
# One master output table
# -----------------------------

# reshape ADM1, ADM2, and ADM3 matches into the same output structure
# so they can be stacked into one crosswalk

adm1_master <- adm1_link %>%
  transmute(
    level = "adm1",
    shp_region_code = shp_code, shp_region_name = shp_name,
    shp_province_code = NA, shp_province_name = NA,
    shp_mun_code = NA,
    shp_code, shp_name,
    psgc_region_code, psgc_region_name,
    psgc_province_code, psgc_province_name,
    psgc_new_code, psgc_name,
    mortality_old_code10, match_method, note
  )

adm2_master <- adm2_link %>%
  transmute(
    level = "adm2",
    shp_region_code, shp_region_name,
    shp_province_code = shp_code, shp_province_name = shp_name,
    shp_mun_code = NA,
    shp_code, shp_name,
    psgc_region_code, psgc_region_name,
    psgc_province_code, psgc_province_name,
    psgc_new_code, psgc_name,
    mortality_old_code10, match_method, note
  )

adm3_master <- adm3_link %>%
  transmute(
    level = "adm3",
    shp_region_code, shp_region_name,
    shp_province_code, shp_province_name,
    shp_mun_code = shp_code,
    shp_code, shp_name,
    psgc_region_code, psgc_region_name,
    psgc_province_code, psgc_province_name,
    psgc_new_code, psgc_name,
    mortality_old_code10, match_method, note
  )

crosswalk_master <- bind_rows(adm1_master, adm2_master, adm3_master)


# -----------------------------
# Write output
# -----------------------------

write_csv(crosswalk_master, crosswalk_file)


# -----------------------------
# Quick checks
# -----------------------------

# quick check of matches and remaining unmatched rows by level
summary_tbl <- crosswalk_master %>%
  group_by(level) %>%
  summarise(
    shp_rows = n(),
    matched_rows = sum(match_method != "unmatched"),
    unmatched_rows = sum(match_method == "unmatched"),
    mortality_key_rows = sum(!is.na(mortality_old_code10)),
    .groups = "drop"
  )

print(summary_tbl)
