# ============================================================
#  01_metadata_geocode_crosswalk.R
# Philippines mortality metadata geocode crosswalk
#
# Purpose
# This script builds a crosswalk between the different
# admin coding systems used in PHL mortality metadata files 
# from 2006-2024
#
# The metadata do not use a single geocode system across all
# years. Several coding schemes appear over time, with major
# changes around 2021-2022 and again in the 2023-2024 files.
#
# The goal is to place all observed geocodes side-by-side in a
# single reference table so that mortality records can later be
# linked consistently to official PSGC (Philippines Standard 
# Geographic Codes) and administrative shapefiles
#
# Outputs:
#   - mortality_metadata_geocode_crosswalk_adm3.csv
#   - mortality_metadata_geocode_crosswalk_exceptions.csv
#
# Geocode systems included:
#   - old_2006_2020: codes used in the 2006-2020 metadata
#   - new_2021_2022: codes introduced in 2021-2022
#   - old_2023_2024: older codes reused in the 2023-2024 metadata
#   - new_2024: latest codes, closest to current PSGC 
# ============================================================

library(readxl)
library(dplyr)
library(stringr)
library(readr)
library(tibble)


# ------------
# Paths
# -----------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/PHL/paths.R"))


# -----------------------
# Metadata file index
# -----------------------

# Getting metadata files from raw mortality data year folders: 
metadata_index <- tibble(
  year = 2006:2024,
  folder = file.path(mortality_raw_dir, paste0("PHL-PSA-VSRD-", 2006:2024, "-PUF")),
  metadata_file = character(19)
)

for (i in seq_len(nrow(metadata_index))) {
  files <- list.files(
    metadata_index$folder[i],
    pattern = "\\.xlsx$",
    full.names = TRUE,
    ignore.case = TRUE
  )
  files <- files[!str_detect(basename(files), "^~\\$")]
  files <- files[str_detect(basename(files), regex("metadata|dictionary", ignore_case = TRUE))]
  metadata_index$metadata_file[i] <- files[1]
}


# -------------------------------
# Read metadata geocode sheets
# ------------------------------

# read one representative metadata workbook for a given geocode system (not consistent
# across years)
# this function loads one representative metadata sheet and applies the common
# cleaning steps before the different systems are combined into a single crosswalk

read_metadata_geocodes <- function(metadata_file, source_year, source_sheet) {
  geocodes <- read_excel(
    metadata_file,
    sheet = source_sheet,
    col_types = "text",
    .name_repair = "minimal"
  )

  # keep only the geographic columns needed for the crosswalk
  geocodes <- geocodes[, 1:6]
  names(geocodes) <- c("adm1_code", "adm1_name", "adm2_code", "adm2_name", "adm3_code", "adm3_name")

  geocodes %>%
    mutate(
      source_year = source_year,
      source_sheet = source_sheet,
      source_row = row_number() + 1,

      # basic geocode cleaning
      # remove excel ".0" artifacts
      adm1_code = str_trim(as.character(adm1_code)),
      adm2_code = str_trim(as.character(adm2_code)),
      adm3_code = str_trim(as.character(adm3_code)),
      adm1_code = if_else(str_detect(adm1_code, "^[0-9]+\\.0$"), str_replace(adm1_code, "\\.0$", ""), adm1_code),
      adm2_code = if_else(str_detect(adm2_code, "^[0-9]+\\.0$"), str_replace(adm2_code, "\\.0$", ""), adm2_code),
      adm3_code = if_else(str_detect(adm3_code, "^[0-9]+\\.0$"), str_replace(adm3_code, "\\.0$", ""), adm3_code),
      adm1_code = na_if(adm1_code, ""),
      adm2_code = na_if(adm2_code, ""),
      adm3_code = na_if(adm3_code, ""),

      # clean names only enough to remove spacing issues
      # more name standardization happens later
      adm1_name = str_squish(as.character(adm1_name)),
      adm2_name = str_squish(as.character(adm2_name)),
      adm3_name = str_squish(as.character(adm3_name)),
      adm1_name = na_if(adm1_name, ""),
      adm2_name = na_if(adm2_name, ""),
      adm3_name = na_if(adm3_name, ""),

      # keep simple row ids for checking duplicates and mismatches
      is_note_row = str_detect(coalesce(adm1_code, ""), "^\\*"),
      code_key = str_c(coalesce(adm1_code, "<missing>"), coalesce(adm2_code, "<missing>"), coalesce(adm3_code, "<missing>"), sep = "|"),
      name_key = str_c(str_to_upper(coalesce(adm1_name, "<missing>")), str_to_upper(coalesce(adm2_name, "<missing>")), str_to_upper(coalesce(adm3_name, "<missing>")), sep = "|")
    ) %>%
    # drop explanatory notes and completely empty rows that sometimes
    # appear in metadata sheets
    filter(!is_note_row) %>%
    filter(
      !is.na(adm1_code) |
        !is.na(adm1_name) |
        !is.na(adm2_code) |
        !is.na(adm2_name) |
        !is.na(adm3_code) |
        !is.na(adm3_name)
    ) %>%
    select(-is_note_row)
}


# Use one representative file per geocode system:
metadata_file_2006 <- metadata_index$metadata_file[metadata_index$year == 2006]
metadata_file_2022 <- metadata_index$metadata_file[metadata_index$year == 2022]
metadata_file_2024 <- metadata_index$metadata_file[metadata_index$year == 2024]


# read and clean representative metadata sheets using function defined above
old_2006_2020_raw <- read_metadata_geocodes(metadata_file_2006, 2006, "geocodes")
new_2021_2022_raw <- read_metadata_geocodes(metadata_file_2022, 2022, "geocodes")
old_2023_2024_raw <- read_metadata_geocodes(metadata_file_2024, 2024, "geocodes")
new_2024_raw <- read_metadata_geocodes(metadata_file_2024, 2024, "geocodes_new")


# -----------------------------
# Standardize geocode systems
# -----------------------------


# Standardize one metadata geocode system before joining it to the others.
#
# Original codes and names are preserved, but cleaned name keys are created
# because the same place can appear differently across systems.
#
# The function also applies a few known aliases, builds the ADM3 matching key,
# and renames the columns to identify which geocode system they come from.


standardize_geocode_system <- function(geocodes, system_suffix) {
  
  # standardize names 
  # same place may appear with different cap, punctuation
  # accents, abbreviations, or formatting across metadata systems
  geocodes <- geocodes %>%
    mutate(
      # adm1
    adm1_key = as.character(adm1_name),
    adm1_key = str_replace_all(adm1_key, "[ñÑ]", "n"),
    adm1_key = iconv(adm1_key, from = "", to = "ASCII//TRANSLIT"),
    adm1_key = str_to_upper(adm1_key),
    adm1_key = str_replace_all(adm1_key, "\\*", ""),
    adm1_key = str_replace_all(adm1_key, "\\([^)]*\\)", ""),
    adm1_key = str_replace_all(adm1_key, "[^A-Z0-9]+", " "),
    adm1_key = str_squish(adm1_key),
    adm1_key = na_if(adm1_key, ""),
      # adm2
    adm2_key = as.character(adm2_name),
    adm2_key = str_replace_all(adm2_key, "[ñÑ]", "n"),
    adm2_key = iconv(adm2_key, from = "", to = "ASCII//TRANSLIT"),
    adm2_key = str_to_upper(adm2_key),
    adm2_key = str_replace_all(adm2_key, "\\*", ""),
    adm2_key = str_replace_all(adm2_key, "\\([^)]*\\)", ""),
    adm2_key = str_replace_all(adm2_key, "[^A-Z0-9]+", " "),
    adm2_key = str_squish(adm2_key),
    adm2_key = na_if(adm2_key, ""),
    adm2_key = str_replace_all(adm2_key, " ", ""),

   # adm3 names need a few extra rules for city labels and common abbreviation
    adm3_key = as.character(adm3_name),
    adm3_key = str_replace_all(adm3_key, "[ñÑ]", "n"),
    adm3_key = iconv(adm3_key, from = "", to = "ASCII//TRANSLIT"),
    adm3_key = str_to_upper(adm3_key),
    adm3_key = str_replace_all(adm3_key, "\\*", ""),
    adm3_key = str_replace_all(adm3_key, "\\([^)]*\\)", ""),
    adm3_key = str_replace_all(adm3_key, "[^A-Z0-9]+", " "),
    adm3_key = str_squish(adm3_key),
    adm3_key = na_if(adm3_key, ""),
    adm3_key = str_replace(adm3_key, "^CITY OF ", ""),
    adm3_key = str_replace(adm3_key, "^CITY ", ""),
    adm3_key = str_replace(adm3_key, "^STO ", "SANTO "),
    adm3_key = str_replace(adm3_key, " STO ", " SANTO "),
    adm3_key = str_replace(adm3_key, "^PRES ", "PRESIDENT "),
    adm3_key = str_replace_all(adm3_key, " ", ""),

    # province/city-area aliases (adm2) needed because the systems changed: 
    adm2_key_common = case_when(
      str_detect(coalesce(adm1_key, ""), "NATIONAL CAPITAL REGION") ~ "NCR",
      adm1_code == "0" ~ "FOREIGNCOUNTRY",
      adm2_key %in% c("COMPOSTELAVALLEY", "DAVAODEORO") ~ "DAVAODEORO",
      adm2_key %in% c("CITYOFCOTABATO", "MAGUINDANAO", "MAGUINDANAODELNORTE") & adm3_key == "COTABATO" ~ "COTABATOCITYAREA",
      adm2_key %in% c("MAGUINDANAO", "MAGUINDANAODELNORTE", "MAGUINDANAODELSUR") ~ "MAGUINDANAO",
      TRUE ~ adm2_key
    ),

    # municipality/city (adm3) aliases needed for official renames/spelling changes:
    adm3_key_common = case_when(
      adm1_code == "0" ~ "FOREIGNCOUNTRY",
      adm2_key == "PALAWAN" & adm3_key == "RIZAL" ~ "DRJOSEPRIZAL",
      adm2_key == "BULACAN" & adm3_key == "BALIUAG" ~ "BALIWAG",
      adm2_key == "LANAODELSUR" & adm3_key == "BUMBARAN" ~ "AMAIMANABILANG",
      adm2_key == "ZAMBOANGADELNORTE" & str_detect(coalesce(adm3_name, ""), "Leon T\\. Postigo") ~ "LEONTPOSTIGO",
      adm3_key == "PINAMUNGAHAN" ~ "PINAMUNGAJAN",
      adm3_key == "PIOVCORPUZ" ~ "PIOVCORPUS",
      TRUE ~ adm3_key
    ),
   
   # combine province and municipality into the ADM3 matching key.
    crosswalk_key = str_c(adm2_key_common, adm3_key_common, sep = "|"),
    crosswalk_key = if_else(is.na(adm2_key_common) & is.na(adm3_key_common), NA, crosswalk_key)
    ) %>%
    # keep only vars needed for the wide crosswalk
    select(crosswalk_key, adm1_code, adm1_name,
      adm2_code, adm2_name, adm3_code,adm3_name,
      code_key,name_key)

  # rename columns to identify which geocode system they come from 
  # where system suffix is old_2006_2020, new_2021_2022 etc. 
  names(geocodes) <- c("crosswalk_key",
    paste0("adm1_code_", system_suffix),
    paste0("adm1_name_", system_suffix),
    paste0("adm2_code_", system_suffix),
    paste0("adm2_name_", system_suffix),
    paste0("adm3_code_", system_suffix),
    paste0("adm3_name_", system_suffix),
    paste0("code_key_", system_suffix),
    paste0("name_key_", system_suffix))

  geocodes
}


# process each geocode system using the standardization function 
old_2006_2020 <- standardize_geocode_system(old_2006_2020_raw, "old_2006_2020")
new_2021_2022 <- standardize_geocode_system(new_2021_2022_raw, "new_2021_2022")
old_2023_2024 <- standardize_geocode_system(old_2023_2024_raw, "old_2023_2024")
new_2024 <- standardize_geocode_system(new_2024_raw, "new_2024")


# -----------------------------
# Build wide crosswalk
# -----------------------------

# join the 4 metadata geocode systems into a single wide table
# full joins are used so that places missing from one system remain 
# visible instead of being dropped

metadata_crosswalk_adm3 <- full_join(old_2006_2020, new_2021_2022, by = "crosswalk_key") %>%
  full_join(old_2023_2024, by = "crosswalk_key") %>%
  full_join(new_2024, by = "crosswalk_key") %>%
  mutate(
    has_old_2006_2020 = !is.na(code_key_old_2006_2020),
    has_new_2021_2022 = !is.na(code_key_new_2021_2022),
    has_old_2023_2024 = !is.na(code_key_old_2023_2024),
    has_new_2024 = !is.na(code_key_new_2024),
    n_systems_present = as.integer(has_old_2006_2020) +
      as.integer(has_new_2021_2022) +
      as.integer(has_old_2023_2024) +
      as.integer(has_new_2024),
    crosswalk_status = case_when(
      has_old_2006_2020 & has_new_2021_2022 & has_old_2023_2024 & has_new_2024 ~ "matched_all_four_systems",
      is.na(crosswalk_key) ~ "metadata_row_without_adm3_name",
      str_detect(crosswalk_key, "NOTSTATED") ~ "not_stated_not_geographic",
      TRUE ~ "unmatched_geographic_row"
    )
  ) %>%
  arrange(desc(n_systems_present), crosswalk_key)


# -----------------------------
# Checks
# -----------------------------

# summary of how well the four geocode systems align
checks <- metadata_crosswalk_adm3 %>%
  count(
    has_old_2006_2020,
    has_new_2021_2022,
    has_old_2023_2024,
    has_new_2024,
    n_systems_present,
    crosswalk_status,
    name = "rows"
  ) %>%
  arrange(desc(n_systems_present), crosswalk_status)

# rows that do not appear in all four systems
# these are kept separately for manual review

exceptions <- metadata_crosswalk_adm3 %>%
  filter(crosswalk_status != "matched_all_four_systems") %>%
  select(crosswalk_status, crosswalk_key, adm1_code_old_2006_2020,
    adm1_name_old_2006_2020, adm2_code_old_2006_2020, adm2_name_old_2006_2020,
    adm3_code_old_2006_2020, adm3_name_old_2006_2020, adm1_code_new_2021_2022,
    adm1_name_new_2021_2022, adm2_code_new_2021_2022, adm2_name_new_2021_2022,
    adm3_code_new_2021_2022, adm3_name_new_2021_2022, adm1_code_old_2023_2024,
    adm1_name_old_2023_2024, adm2_code_old_2023_2024, adm2_name_old_2023_2024,
    adm3_code_old_2023_2024, adm3_name_old_2023_2024, adm1_code_new_2024, 
    adm1_name_new_2024, adm2_code_new_2024, adm2_name_new_2024,
    adm3_code_new_2024, adm3_name_new_2024, n_systems_present
  )


# ------------------------
# Write outputs
# ----------------------

# main crosswalk used by downstream scripts
write_csv(metadata_crosswalk_adm3, file.path(admin_geocodes_clean_dir, "metadata_geocode_crosswalk_adm3.csv"))

# rows requiring manual inspection
write_csv(exceptions, file.path(admin_geocodes_clean_dir, "metadata_geocode_crosswalk_exceptions.csv"))

print(checks)
