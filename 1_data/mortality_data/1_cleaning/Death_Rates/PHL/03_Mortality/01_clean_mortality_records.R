# ============================================================
# 01_clean_mortality_records.R
#
# Purpose:
# Build the cleaned Philippines mortality dataset for 2006-2024.
#
# Context:
# The yearly mortality files are not fully consistent across years
# Column names, available variables, age coding, cause-of-death fields,
# and mortality metadata geocodes all change over time
#
# The four scripts in 01_Admin_Codes create the admin-code crosswalks. This
# script combines the yearly mortality files, standardizes variables across
# years, and attaches official PSGC and shapefile identifiers.
#
# Main steps:
# 1. Read and combine yearly mortality data
# 2. Clean death dates
# 3. Clean age
# 4. Harmonize cause-of-death codes
# 5. Link death records to PSGC and shapefile identifiers
# 6. Write the cleaned mortality dataset
#
# Inputs:
# - Mortality/0_Raw/PHL-PSA-VSRD-YYYY-PUF/*.xlsx
# - Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_adm3.csv
#
# Outputs:
# - Mortality/1_Clean/Death_Records/PHL_death_records.csv
# - Mortality/1_Clean/Death_Records/PHL_death_records.dta
# - Mortality/1_Clean/Death_Records/PHL_unmatched_geocodes.csv
# ============================================================




# -------------------------------
#           0. Set-up
# -------------------------------


# ---------------------- Packages -------------------------

library(readxl)
library(dplyr)
library(purrr)
library(stringr)
library(tidyr)
library(tibble)
library(readr)


# ---------------------- Paths -----------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"))

dir.create(death_records_dir, recursive = TRUE, showWarnings = FALSE)

# Final ADM3 crosswalk created by 01_Admin_Codes/04
# already links mortality metadata geocodes to official PSGC and shapefile codes
metadata_geo_crosswalk_path <- file.path(
  admin_crosswalks_dir,
  "metadata_psgc_shp_crosswalk_adm3.csv"
)


# -------------- helper functions for cleaning -------------------

# make column names consistent across yearly Excel files
clean_names_simple <- function(nm) {
  nm <- tolower(nm)
  nm <- gsub("[^a-z0-9]+", "_", nm)
  nm <- gsub("^_+|_+$", "", nm)
  nm
}

# clean general code variables without changing leading zeros
normalize_code <- function(x) {
  x <- as.character(x)
  x <- str_trim(x)
  x[x == ""] <- NA
  x <- ifelse(str_detect(x, "^[0-9]+\\.0$"), str_replace(x, "\\.0$", ""), x)
  x
}

# normalize one geo code piece for joins
# numeric pieces may differ only because of zero padding
normalize_geocode_piece <- function(x) {
  x <- normalize_code(x)
  ifelse(str_detect(x, "^[0-9]+$"), str_replace(x, "^0+(?=[0-9])", ""), x)
}

# build full ADM3 geocode key: region|province|municipality
make_geocode_key <- function(region, province, mun, normalize_numeric = FALSE) {
  if (normalize_numeric) {
    region <- normalize_geocode_piece(region)
    province <- normalize_geocode_piece(province)
    mun <- normalize_geocode_piece(mun)
  }
  
  paste(
    coalesce(region, "<missing>"),
    coalesce(province, "<missing>"),
    coalesce(mun, "<missing>"),
    sep = "|"
  )
}

# build ADM1/ADM2 "parent" key for rows without usable ADM3
make_geocode_parent_key <- function(region, province, normalize_numeric = TRUE) {
  if (normalize_numeric) {
    region <- normalize_geocode_piece(region)
    province <- normalize_geocode_piece(province)
  }
  
  paste(
    coalesce(region, "<missing>"),
    coalesce(province, "<missing>"),
    sep = "|"
  )
}

# normalize an existing region|province|municipality key
normalize_geocode_key <- function(key) {
  pieces <- str_split_fixed(key, fixed("|"), 3)
  
  make_geocode_key(
    pieces[, 1],
    pieces[, 2],
    pieces[, 3],
    normalize_numeric = TRUE
  )
}

# expand metadata keys that represent a range of ADM3 codes
expand_geocode_key_for_join <- function(key) {
  pieces <- str_split_fixed(key, fixed("|"), 3)
  adm3_piece <- str_trim(pieces[, 3])
  
  # Manila is listed as "00 to 14" in metadata but joins to one ADM3:
  # City of Manila
  range_match <- str_match(adm3_piece, "^([0-9]+)\\s+to\\s+([0-9]+)$")
  
  if (!is.na(range_match[, 1])) {
    range_start <- as.integer(range_match[, 2])
    range_end <- as.integer(range_match[, 3])
    range_values <- as.character(seq(range_start, range_end))
    
    return(make_geocode_key(
      rep(pieces[, 1], length(range_values)),
      rep(pieces[, 2], length(range_values)),
      range_values,
      normalize_numeric = TRUE
    ))
  }
  
  normalize_geocode_key(key)
}




# ----------------------------------------------------------------
#           1. Read and combine yearly mortality data
# ----------------------------------------------------------------

 
# ------------------- 1.1 Find yearly files ------------------


# Each year's mortality data and metadata are stored in their own folder
dirs <- list.dirs(mortality_raw_dir, recursive = FALSE, full.names = TRUE) %>%
  keep(~ str_detect(basename(.x), "^PHL-PSA-VSRD-[0-9]{4}-PUF$"))

years <- as.integer(str_match(basename(dirs), "^PHL-PSA-VSRD-([0-9]{4})-PUF$")[, 2])

ord <- order(years)
dirs <- dirs[ord]
years <- years[ord]

# Mortality data workbook 
data_files <- map_chr(dirs, function(d) {
  f <- list.files(d, pattern = "\\.xlsx$", full.names = TRUE, ignore.case = TRUE)
  f <- f[!str_detect(basename(f), "^~\\$")]
  f <- f[!str_detect(basename(f), regex("metadata", ignore_case = TRUE))]
  f[[1]]
})

# Metadata workbook
metadata_files <- map_chr(dirs, function(d) {
  f <- list.files(d, pattern = "\\.xlsx$", full.names = TRUE, ignore.case = TRUE)
  f <- f[!str_detect(basename(f), "^~\\$")]
  f <- f[str_detect(basename(f), regex("metadata|dictionary", ignore_case = TRUE))]
  f[[1]]
})


# ---------------- 1.2 Read cause-of-death metadata -------------------

# Read the ICD cause-code lookup from one metadata workbook
read_cause_lookup <- function(metadata_file, source_year) {
  
  # Sheet names differ slightly across years
  sheets <- excel_sheets(metadata_file)
  cause_sheet <- sheets[str_detect(sheets, regex("ICD.*codes?|3[- ]digit ICD", ignore_case = TRUE))][1]
  
  cause_metadata <- read_excel(
    metadata_file,
    sheet = cause_sheet,
    col_types = "text",
    .name_repair = "minimal"
  )
  names(cause_metadata) <- clean_names_simple(names(cause_metadata))

  # Column names also vary across years
  code_col <- names(cause_metadata)[str_detect(names(cause_metadata), regex("^icd.*code$|icd_10_code", ignore_case = TRUE))][1]
  name_col <- names(cause_metadata)[str_detect(names(cause_metadata), regex("^description$|cause", ignore_case = TRUE))][1]

  cause_metadata %>%
    transmute(
      cause_code_3d = str_to_upper(normalize_code(.data[[code_col]])),
      cause_name = str_squish(as.character(.data[[name_col]])),
      cause_metadata_year = source_year,
      cause_metadata_sheet = cause_sheet
    ) %>%
    filter(!is.na(cause_code_3d), !is.na(cause_name), cause_name != "")
}

# Combine all yearly ICD lookups
# If a code appears more than once, keep the most recent description
cause_lookup <- map2_dfr(metadata_files, years, read_cause_lookup) %>%
  arrange(desc(cause_metadata_year)) %>%
  distinct(cause_code_3d, .keep_all = TRUE)



# ---------------- 1.3 Read yearly mortality files ---------------------

# Read all yearly mortality workbooks
year_data <- map(data_files, function(p) {
  x <- read_excel(p, col_types = "text", .name_repair = "minimal")
  names(x) <- clean_names_simple(names(x))
  x
}) %>%
  set_names(as.character(years))


# ---------------- 1.4 Align columns across years ----------------------

# years do not all contain the same variables
# add missing columns before combining all years
all_cols <- year_data %>%
  map(names) %>%
  unlist() %>%
  unique()

year_data_aligned <- list()

for (y in names(year_data)) {
  df <- year_data[[y]] %>%
    mutate(across(everything(), as.character))

  missing_cols <- setdiff(all_cols, names(df))
  if (length(missing_cols) > 0) df[missing_cols] <- NA

  df <- df %>%
    select(all_of(all_cols)) %>%
    mutate(year_file = as.integer(y))

  year_data_aligned[[y]] <- df
}

deaths_all <- bind_rows(year_data_aligned)


# ------------- 1.5 Basic code cleanup ---------------


# keep raw codes as clean strings
# then put year_file back to integer because we use it for year-specific rules
deaths_all <- deaths_all %>%
  mutate(
    across(everything(), normalize_code),
    year_file = as.integer(year_file)
  )



# --------------------------------------------
#               2. Date cleaning
# --------------------------------------------


deaths_all <- deaths_all %>%
  mutate(
    date_of_death_day = na_if(date_of_death_day, "99"),
    date_of_death_day = str_pad(date_of_death_day, 2, pad = "0"),
    date_of_death_month = str_pad(date_of_death_month, 2, pad = "0"),
    death_date_str = paste(date_of_death_year, date_of_death_month, date_of_death_day, sep = "-"),
    death_date = suppressWarnings(as.Date(if_else(is.na(date_of_death_day), NA, death_date_str))),
    date_of_death_month = as.numeric(date_of_death_month),
    date_of_death_day = as.numeric(date_of_death_day),
    date_of_death_year = as.numeric(date_of_death_year)
  )


# -----------------------------------------------
#               3. Age cleaning
# -----------------------------------------------


# The age variable is encoded slightly differently across years:
# - days for infant deaths
# - months with a leading 1
# - years with a leading 2
# - 100+ years with a leading 3 in 2023-2024
#
# Final age is kept as integer years
# Days and months are set to 0 years

deaths_all <- deaths_all %>%
  mutate(
    age_raw = as.character(age),
    age_code = str_remove(str_squish(age_raw), "\\.0$"),
    age_num = suppressWarnings(as.integer(age_code)),
    age_tail = suppressWarnings(as.integer(substr(age_code, 2, nchar(age_code)))),

    age_unit = case_when(
      is.na(age_num) ~ NA,

      year_file %in% 2006:2022 & between(age_num, 0, 28) ~ "days",
      year_file %in% 2006:2022 & between(age_num, 101, 111) ~ "months",
      year_file %in% 2006:2022 & between(age_num, 201, 297) ~ "years",
      year_file %in% 2006:2022 & age_num == 298 ~ "years_98plus_topcoded",
      year_file %in% 2006:2022 & age_num == 999 ~ "not_stated",

      year_file == 2023 & between(age_num, 0, 28) ~ "days",
      year_file == 2023 & between(age_num, 101, 111) ~ "months",
      year_file == 2023 & between(age_num, 201, 299) ~ "years",
      year_file == 2023 & age_num >= 300 & age_num < 999 ~ "years_100plus_prefix3",
      year_file == 2023 & age_num == 999 ~ "not_stated",

      year_file == 2024 & between(age_num, 0, 30) ~ "days",
      year_file == 2024 & between(age_num, 101, 111) ~ "months",
      year_file == 2024 & between(age_num, 201, 299) ~ "years",
      year_file == 2024 & age_num >= 300 & age_num < 999 ~ "years_100plus_prefix3",
      year_file == 2024 & age_num == 999 ~ "not_stated",

      TRUE ~ "invalid"
    ),

    age_value = case_when(
      age_unit == "days" ~ age_num,
      age_unit == "months" ~ age_tail,
      age_unit == "years" ~ age_tail,
      age_unit == "years_98plus_topcoded" ~ 98,
      age_unit == "years_100plus_prefix3" ~ 100 + age_tail,
      TRUE ~ NA
    ),

    age_value_unit = case_when(
      age_unit == "days" ~ "days",
      age_unit == "months" ~ "months",
      age_unit %in% c("years", "years_98plus_topcoded", "years_100plus_prefix3") ~ "years",
      TRUE ~ NA
    ),

    age_topcoded = age_unit == "years_98plus_topcoded",
    age_not_stated = age_unit == "not_stated",
    age_invalid = age_unit == "invalid",

    age = case_when(
      age_value_unit == "years" ~ age_value,
      age_value_unit %in% c("days", "months") ~ 0,
      TRUE ~ NA
    )
  )



# --------------------------------------------------
#       4. Cause of death code harmonization
# --------------------------------------------------


# The cause-code column name changes across years.
# Create one common cause code and record which source column it came from

deaths_all <- deaths_all %>%
  mutate(
    cause_code_3d = str_to_upper(coalesce(icd_code_3d, icd_code, cause_of_death_3digit)),
    cause_source = case_when(
      !is.na(icd_code_3d) ~ "icd_code_3d",
      !is.na(icd_code) ~ "icd_code",
      !is.na(cause_of_death_3digit) ~ "cause_of_death_3digit",
      TRUE ~ NA
    )
  ) %>%
  left_join(cause_lookup, by = "cause_code_3d")




# ---------------------------------------------------
#           5. Geocode linkage
# ---------------------------------------------------


#---------------- 5.1 Prepare ADM3 lookup ------------------

# 01_Admin_Codes/04 created the ADM3 crosswalk linking mortality metadata
# geocodes to official PSGC and shapefile geography
#
# Here we reshape that crosswalk into a lookup table with one row per
# metadata geocode system and code key. This makes it possible to join
# each death record to the correct geography based on its year


geo_crosswalk <- read_csv(
  metadata_geo_crosswalk_path,
  col_types = cols(.default = col_character())
)

# Prepare the ADM3 crosswalk for joining to death records
# Keep one row per metadata geocode system and code key
geo_lookup <- bind_rows(
  
  
  # 2006-2020 metadata system
  geo_crosswalk %>%
    transmute(
      geo_system = "old_2006_2020",
      code_key = code_key_old_2006_2020,

      metadata_adm1_code = adm1_code_old_2006_2020,
      metadata_adm1_name = adm1_name_old_2006_2020,
      metadata_adm2_code = adm2_code_old_2006_2020,
      metadata_adm2_name = adm2_name_old_2006_2020,
      metadata_adm3_code = adm3_code_old_2006_2020,
      metadata_adm3_name = adm3_name_old_2006_2020,

      psgc_adm1_code = psgc_region_code,
      psgc_adm1_name = psgc_region_name,
      psgc_adm2_code = psgc_province_code,
      psgc_adm2_name = psgc_province_name,
      psgc_adm3_code = psgc_new_code,
      psgc_adm3_name = psgc_name,

      shp_adm1_code = shp_region_code,
      shp_adm1_name = shp_region_name,
      shp_adm2_code = shp_province_code,
      shp_adm2_name = shp_province_name,
      shp_adm3_code = shp_code,
      shp_adm3_name = shp_name,

      metadata_psgc_code = metadata_psgc_code,
      metadata_crosswalk_status = crosswalk_status,
      metadata_psgc_match_method = metadata_psgc_match_method,
      psgc_shp_match_method = psgc_shp_match_method,
      geocode_status = metadata_psgc_shp_status
    ),

  # 2021-2022 metadata system
  geo_crosswalk %>%
    transmute(
      geo_system = "new_2021_2022",
      code_key = code_key_new_2021_2022,

      metadata_adm1_code = adm1_code_new_2021_2022,
      metadata_adm1_name = adm1_name_new_2021_2022,
      metadata_adm2_code = adm2_code_new_2021_2022,
      metadata_adm2_name = adm2_name_new_2021_2022,
      metadata_adm3_code = adm3_code_new_2021_2022,
      metadata_adm3_name = adm3_name_new_2021_2022,

      psgc_adm1_code = psgc_region_code,
      psgc_adm1_name = psgc_region_name,
      psgc_adm2_code = psgc_province_code,
      psgc_adm2_name = psgc_province_name,
      psgc_adm3_code = psgc_new_code,
      psgc_adm3_name = psgc_name,

      shp_adm1_code = shp_region_code,
      shp_adm1_name = shp_region_name,
      shp_adm2_code = shp_province_code,
      shp_adm2_name = shp_province_name,
      shp_adm3_code = shp_code,
      shp_adm3_name = shp_name,

      metadata_psgc_code = metadata_psgc_code,
      metadata_crosswalk_status = crosswalk_status,
      metadata_psgc_match_method = metadata_psgc_match_method,
      psgc_shp_match_method = psgc_shp_match_method,
      geocode_status = metadata_psgc_shp_status
    ),

  # 2023-2024 metadata system
  geo_crosswalk %>%
    transmute(
      geo_system = "old_2023_2024",
      code_key = code_key_old_2023_2024,

      metadata_adm1_code = adm1_code_old_2023_2024,
      metadata_adm1_name = adm1_name_old_2023_2024,
      metadata_adm2_code = adm2_code_old_2023_2024,
      metadata_adm2_name = adm2_name_old_2023_2024,
      metadata_adm3_code = adm3_code_old_2023_2024,
      metadata_adm3_name = adm3_name_old_2023_2024,

      psgc_adm1_code = psgc_region_code,
      psgc_adm1_name = psgc_region_name,
      psgc_adm2_code = psgc_province_code,
      psgc_adm2_name = psgc_province_name,
      psgc_adm3_code = psgc_new_code,
      psgc_adm3_name = psgc_name,

      shp_adm1_code = shp_region_code,
      shp_adm1_name = shp_region_name,
      shp_adm2_code = shp_province_code,
      shp_adm2_name = shp_province_name,
      shp_adm3_code = shp_code,
      shp_adm3_name = shp_name,

      metadata_psgc_code = metadata_psgc_code,
      metadata_crosswalk_status = crosswalk_status,
      metadata_psgc_match_method = metadata_psgc_match_method,
      psgc_shp_match_method = psgc_shp_match_method,
      geocode_status = metadata_psgc_shp_status
    )
) %>%
  filter(!is.na(code_key)) %>%
  mutate(
    # build normalized join keys from the metadata code
    # most rows produce one key, but ranges such as Manila's
    # "00 to 14" expand into multiple join keys
    code_key_join = map(code_key, expand_geocode_key_for_join)
  ) %>%
  unnest(code_key_join)



#---------------- 5.2 Add manual geocode aliases -------------------


# some death-record codes are missing from the representative metadata system for 
# that year group, but can be linked to known adm units in another metadata system
# only include aliases when the correct match is known
manual_geocode_aliases <- tribble(
  ~alias_geo_system, ~alias_code_key, ~target_geo_system, ~target_code_key, ~geocode_alias_note,

  # Tublay and Tinoc are missing from the 2006-2020 metadata system
  # but are present in the 2023-2024 metadata system.
  "old_2006_2020", "2|11|14", "old_2023_2024", "2|11|14", "manual_alias_tublay_benguet_missing_from_old_2006_metadata",
  "old_2006_2020", "2|27|10", "old_2023_2024", "2|27|10", "manual_alias_tinoc_ifugao_missing_from_old_2006_metadata",

  # Davao Occidental was carved out of Davao del Sur 
  # some 2017 death records still use  the former Davao del Sur province codes, but 
  # the corresponding metadata rows use the later Davao Occidental codes 
  "old_2006_2020", "14|24|5",  "old_2023_2024", "14|86|1", "manual_alias_davao_occidental_from_legacy_davao_del_sur_code",
  "old_2006_2020", "14|24|9",  "old_2023_2024", "14|86|2", "manual_alias_davao_occidental_from_legacy_davao_del_sur_code",
  "old_2006_2020", "14|24|13", "old_2023_2024", "14|86|3", "manual_alias_davao_occidental_from_legacy_davao_del_sur_code",
  "old_2006_2020", "14|24|15", "old_2023_2024", "14|86|4", "manual_alias_davao_occidental_from_legacy_davao_del_sur_code",
  "old_2006_2020", "14|24|16", "old_2023_2024", "14|86|5", "manual_alias_davao_occidental_from_legacy_davao_del_sur_code",

  # Basilisa and Loreto were formerly part of Surigao del Norte before becoming part of Dinagat Islands
  # Some 2021 residence records still  use the former Surigao del Norte codes
  "new_2021_2022", "16|67|3",  "new_2021_2022", "16|085|01", "manual_alias_basilisa_from_legacy_surigao_del_norte_code",
  "new_2021_2022", "16|67|13", "new_2021_2022", "16|085|05", "manual_alias_loreto_dinagat_from_legacy_surigao_del_norte_code",

  # The 2023-2024 mortality data include both the old and new metadata
  # geocode systems for each death record
  # The old code 16|98|4 is not listed in the old metadata, but the
  # corresponding new codes (2023: 19|038|04; 2024: 19|87|3) identify
  # City of Cotabato, allowing the old code to be linked manually
  "old_2023_2024", "16|98|4", "old_2023_2024", "15|98|04", "manual_alias_city_of_cotabato_old_code_16_98_4_from_parallel_new_codes"
)



# ;ink each alias to the corresponding adm3 in the lookup table
manual_alias_lookup <- manual_geocode_aliases %>%
  mutate(
    alias_code_key_join = normalize_geocode_key(alias_code_key),
    target_code_key_join = normalize_geocode_key(target_code_key)
  ) %>%
  left_join(
    geo_lookup,
    by = c(
      "target_geo_system" = "geo_system",
      "target_code_key_join" = "code_key_join"
    )
  )

# Check that every manual alias points to a valid lookup row
# This should be empty
missing_manual_alias_targets <- manual_alias_lookup %>%
  filter(is.na(geocode_status)) %>%
  select(alias_geo_system, alias_code_key, target_geo_system, target_code_key, geocode_alias_note)

print(missing_manual_alias_targets)
stopifnot(nrow(missing_manual_alias_targets) == 0)

geo_lookup <- geo_lookup %>%
  mutate(geocode_alias_note = NA) %>%
  bind_rows(
    manual_alias_lookup %>%
      mutate(
        geo_system = alias_geo_system,
        code_key = alias_code_key,
        code_key_join = alias_code_key_join
      ) %>%
      select(all_of(names(geo_lookup)), geocode_alias_note)
  )

# Check that each normalized geocode key maps to one lookup row
# This should be empty, otherwise the join could create duplicate death records
duplicate_geocode_keys <- geo_lookup %>%
  count(geo_system, code_key_join) %>%
  filter(n > 1)

print(duplicate_geocode_keys)
stopifnot(nrow(duplicate_geocode_keys) == 0)

geo_lookup <- geo_lookup %>%
  distinct(geo_system, code_key_join, .keep_all = TRUE)




# ------- 5.3 Build ADM1/ADM2 lookup for non-mappable ADM3 codes --------



# Build an ADM1/ADM2 lookup for records that cannot be matched at ADM3
# This preserves the available higher-level adm unit info without
# creating a false ADM3 match

parent_lookup_candidates <- geo_lookup %>%
  mutate(
    code_key_pieces = str_split_fixed(code_key_join, fixed("|"), 3),
    parent_code_key_join = make_geocode_parent_key(
      code_key_pieces[, 1],
      code_key_pieces[, 2],
      normalize_numeric = FALSE
    )
  ) %>%
  select(
    geo_system,
    parent_code_key_join,
    parent_metadata_adm1_code = metadata_adm1_code,
    parent_metadata_adm1_name = metadata_adm1_name,
    parent_metadata_adm2_code = metadata_adm2_code,
    parent_metadata_adm2_name = metadata_adm2_name,
    parent_psgc_adm1_code = psgc_adm1_code,
    parent_psgc_adm1_name = psgc_adm1_name,
    parent_psgc_adm2_code = psgc_adm2_code,
    parent_psgc_adm2_name = psgc_adm2_name,
    parent_shp_adm1_code = shp_adm1_code,
    parent_shp_adm1_name = shp_adm1_name,
    parent_shp_adm2_code = shp_adm2_code,
    parent_shp_adm2_name = shp_adm2_name
  ) %>%
  distinct()


# Some ADM1/ADM2 code combinations become ambiguous after applying
# manual ADM3 aliases. Exclude them to avoid duplicate or ambiguous
# ADM1/ADM2 matches
ambiguous_parent_keys <- parent_lookup_candidates %>%
  count(geo_system, parent_code_key_join, name = "parent_versions") %>%
  filter(parent_versions > 1)

print(ambiguous_parent_keys)

parent_lookup <- parent_lookup_candidates %>%
  anti_join(ambiguous_parent_keys, by = c("geo_system", "parent_code_key_join"))


# ----------- 5.4 Build death-record geocode keys ---------------

# Select the metadata geocode system used by each year
# Then build place-of-death and residence keys for joining
deaths_all <- deaths_all %>%
  mutate(
    geo_system = case_when(
      year_file %in% 2006:2020 ~ "old_2006_2020",
      year_file %in% 2021:2022 ~ "new_2021_2022",
      year_file %in% 2023:2024 ~ "old_2023_2024",
      TRUE ~ NA
    ),

    # Keep the original code keys so unmatched records can be inspected
    pod_code_key = make_geocode_key(
      place_of_death_region,
      place_of_death_province,
      place_of_death_mun
    ),
    res_code_key = make_geocode_key(
      residence_region,
      residence_province,
      residence_mun
    ),

    # Use normalized keys for the actual join
    # This handles inconsistent zero padding across metadata and death records
    pod_code_key_join = make_geocode_key(
      place_of_death_region,
      place_of_death_province,
      place_of_death_mun,
      normalize_numeric = TRUE
    ),
    res_code_key_join = make_geocode_key(
      residence_region,
      residence_province,
      residence_mun,
      normalize_numeric = TRUE
    ),
    pod_parent_code_key_join = make_geocode_parent_key(
      place_of_death_region,
      place_of_death_province
    ),
    res_parent_code_key_join = make_geocode_parent_key(
      residence_region,
      residence_province
    )
  )


n_before_geo_join <- nrow(deaths_all)


#---------- 5.5 Link death records ------------

# Attach PSGC and shapefile codes for place of death
pod_lookup <- geo_lookup %>%
  rename(
    pod_code_key_join = code_key_join,
    matched_metadata_code_key = code_key
  ) %>%
  rename_with(~ paste0("pod_", .x), -c(geo_system, pod_code_key_join))

deaths_all <- deaths_all %>%
  left_join(
    pod_lookup,
    by = c("geo_system", "pod_code_key_join")
  )


# Attach PSGC and shapefile codes for residence
res_lookup <- geo_lookup %>%
  rename(
    res_code_key_join = code_key_join,
    matched_metadata_code_key = code_key
  ) %>%
  rename_with(~ paste0("res_", .x), -c(geo_system, res_code_key_join))

deaths_all <- deaths_all %>%
  left_join(
    res_lookup,
    by = c("geo_system", "res_code_key_join")
  )


# Add available ADM1/ADM2 codes separately for records without a usable ADM3 match
# For example, "10|12|99" has unknown ADM3 but may still identify ADM1/ADM2
# These columns remain separate from the main ADM3 match

pod_parent_lookup <- parent_lookup %>%
  rename(pod_parent_code_key_join = parent_code_key_join) %>%
  rename_with(~ paste0("pod_", .x), -c(geo_system, pod_parent_code_key_join))

deaths_all <- deaths_all %>%
  left_join(
    pod_parent_lookup,
    by = c("geo_system", "pod_parent_code_key_join")
  )

res_parent_lookup <- parent_lookup %>%
  rename(res_parent_code_key_join = parent_code_key_join) %>%
  rename_with(~ paste0("res_", .x), -c(geo_system, res_parent_code_key_join))

deaths_all <- deaths_all %>%
  left_join(
    res_parent_lookup,
    by = c("geo_system", "res_parent_code_key_join")
  )

# Check that the joins did not duplicate death records
stopifnot(nrow(deaths_all) == n_before_geo_join)


#------------------- 5.6 Geocode checks ---------------

# Count yearly matches to the metadata crosswalk, PSGC, and shapefile
# for place of death and residence.
geocode_checks <- deaths_all %>%
  group_by(year_file) %>%
  summarise(
    n_records = n(),

    pod_crosswalk_row = sum(!is.na(pod_geocode_status)),
    pod_psgc_match = sum(!is.na(pod_psgc_adm3_code)),
    pod_shp_match = sum(!is.na(pod_shp_adm3_code)),
    pod_parent_psgc_match = sum(!is.na(pod_parent_psgc_adm2_code)),
    pod_parent_shp_match = sum(!is.na(pod_parent_shp_adm2_code)),

    res_crosswalk_row = sum(!is.na(res_geocode_status)),
    res_psgc_match = sum(!is.na(res_psgc_adm3_code)),
    res_shp_match = sum(!is.na(res_shp_adm3_code)),
    res_parent_psgc_match = sum(!is.na(res_parent_psgc_adm2_code)),
    res_parent_shp_match = sum(!is.na(res_parent_shp_adm2_code)),

    .groups = "drop"
  )

print(geocode_checks)


# ----------- 5.7 Unmatched geocode diagnostics ----------

# List place-of-death and residence codes that failed to match the
# ADM3 lookup (unmatched death-record codes, not unmatched PSGC/shapefile units)

unmatched_pod_keys <- deaths_all %>%
  filter(is.na(pod_geocode_status)) %>%
  count(
    year_file,
    location_type = "place_of_death",
    geo_system,
    raw_code_key = pod_code_key,
    join_code_key = pod_code_key_join,
    parent_code_key = pod_parent_code_key_join,
    parent_psgc_adm1_code = pod_parent_psgc_adm1_code,
    parent_psgc_adm1_name = pod_parent_psgc_adm1_name,
    parent_psgc_adm2_code = pod_parent_psgc_adm2_code,
    parent_psgc_adm2_name = pod_parent_psgc_adm2_name,
    parent_shp_adm1_code = pod_parent_shp_adm1_code,
    parent_shp_adm2_code = pod_parent_shp_adm2_code,
    sort = TRUE,
    name = "n_records"
  )

unmatched_res_keys <- deaths_all %>%
  filter(is.na(res_geocode_status)) %>%
  count(
    year_file,
    location_type = "residence",
    geo_system,
    raw_code_key = res_code_key,
    join_code_key = res_code_key_join,
    parent_code_key = res_parent_code_key_join,
    parent_psgc_adm1_code = res_parent_psgc_adm1_code,
    parent_psgc_adm1_name = res_parent_psgc_adm1_name,
    parent_psgc_adm2_code = res_parent_psgc_adm2_code,
    parent_psgc_adm2_name = res_parent_psgc_adm2_name,
    parent_shp_adm1_code = res_parent_shp_adm1_code,
    parent_shp_adm2_code = res_parent_shp_adm2_code,
    sort = TRUE,
    name = "n_records"
  )

unmatched_geocode_keys <- bind_rows(unmatched_pod_keys, unmatched_res_keys) %>%
  arrange(year_file, location_type, desc(n_records), join_code_key)

if (nrow(unmatched_geocode_keys) > 0) {
  print(unmatched_geocode_keys, n = 100)
} else {
  cat("\nAll observed death-record geocode keys matched the ADM3 lookup.\n")
}

write_csv(
  unmatched_geocode_keys,
  file.path(death_records_dir, "PHL_unmatched_geocodes.csv")
)


# -----------------------------------------
#         6. Write final  outputs
# -----------------------------------------


# Select final set of  variables

deaths_final <- deaths_all %>%
  select(
    year_file, date_of_death_year, date_of_death_month,
    date_of_death_day, death_date, sex,
    age, cause_code_3d, cause_name,
    pod_psgc_adm3_code, pod_psgc_adm3_name,
    pod_shp_adm1_code, pod_shp_adm1_name,
    pod_shp_adm2_code, pod_shp_adm2_name,
    pod_shp_adm3_code, pod_shp_adm3_name,
    pod_geocode_alias_note,
    res_psgc_adm3_code, res_psgc_adm3_name,
    res_shp_adm1_code, res_shp_adm1_name,
    res_shp_adm2_code, res_shp_adm2_name,
    res_shp_adm3_code, res_shp_adm3_name,
    res_geocode_alias_note
  )

write_csv(deaths_final, file.path(death_records_dir, "PHL_death_records.csv"))
haven::write_dta(deaths_final, file.path(death_records_dir, "PHL_death_records.dta"))
cat("\nDone. Outputs written to:\n", death_records_dir, "\n")
