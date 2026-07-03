
# ============================================================
# 01_clean_population_census_years.R
#
# This script cleans the population files for the census years
# where we have age and gender breakdown:
#
#   2007: PSADA Population Census person files
#   2010: PSADA Census of Population and Housing Form 2 person files
#   2015: HDX/PSA adm4 age-sex table
#   2020: HDX/PSA adm4 age-sex table
#
# The output is one municipality/city-level file with:
#
#   census year x ADM3 x single-year age x sex
#
# Ages 80 and older are grouped to 80+  (practical 
# level of detail we can keep consistently across all years) 
# some census years breakdown age from 0 to 99 then 100+, others 
# from 0 to 79 and 80+
#
# This script links population records to the current PSGC and
# shapefile administrative codes whenever a direct correspondence
# already exists. Population redistribution across boundary changes
# is handled in Script 02.
#
# Main output:
#   Population/1_Clean/census_pop_pre_alignment.csv
# ============================================================


# -----------------------------
# Packages
# -----------------------------

  library(data.table)
  library(dplyr)
  library(readr)
  library(readxl)
  library(stringr)
  library(tidyr)
  library(writexl)

# running this script using slurm in rcc and specifying 4 CPUs for this job in my sbatch file 
# so letting data.table use them when reading and grouping the large person-level census files 
setDTthreads(4)

# -----------------------------
# Paths
# -----------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/PHL/paths.R"))

dir.create(population_clean_dir, recursive = TRUE, showWarnings = FALSE)

dir_2007 <- file.path(population_raw_dir, "PHL-PSA-POPCEN-2007-PUF")
dir_2010 <- file.path(population_raw_dir, "PHL-PSA-CPH-2010-PUF", "Form 2 - Non Sample")

hdx_2015_path <- file.path(population_raw_dir, "180816_philippines-population-barangay-admin-4_2015-single-age.csv")
hdx_2020_path <- file.path(population_raw_dir, "2020-census-total-popn_single-age_malefemale_admin4.xlsx")

psgc_path <- file.path(admin_geocodes_clean_dir, "psgc_adm_codes.csv")
psgc_shp_path <- file.path(admin_crosswalks_dir, "psgc_shp_crosswalk_master.csv")


# --------------------------------
# Current PSGC and shapefile codes
# --------------------------------

# mortality data is already linked to shapefile adm3 codes
# population data must align with same adm3 geography so the two files can be merged later

# Current PSGC adm3 codes
psgc_adm3 <- read_csv(
  psgc_path,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    psgc_adm3_code = municipalicity_code,
    psgc_adm3_code_old = municipalicity_code_old,
    psgc_adm3_name = municipalicity_name,
    psgc_adm1_code = region_code,
    psgc_adm1_name = region_name,
    psgc_adm2_code = province_code,
    psgc_adm2_name = province_name
  ) %>%
  distinct()

# PSGC-to-shapefile adm3 crosswalk
shp_adm3 <- read_csv(
  psgc_shp_path,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  filter(level == "adm3") %>%
  transmute(
    psgc_adm3_code = psgc_new_code,
    shp_adm1_code = shp_region_code,
    shp_adm1_name = shp_region_name,
    shp_adm2_code = shp_province_code,
    shp_adm2_name = shp_province_name,
    shp_adm3_code = shp_code,
    shp_adm3_name = shp_name,
    psgc_shp_match_method = match_method
  ) %>%
  distinct()

psgc_current <- psgc_adm3 %>%
  left_join(shp_adm3, by = "psgc_adm3_code") %>%
  distinct(psgc_adm3_code, .keep_all = TRUE)

# older census files (2007, 2010, 2015) use nine-digit PSGC codes
# build the corresponding lookup
psgc_old <- psgc_current %>%
  filter(!is.na(psgc_adm3_code_old)) %>%
  distinct(psgc_adm3_code_old, .keep_all = TRUE)

# Davao Occidental was created after the older census files
# These five municipalities appear under old Davao del Sur codes in 2007/2010/2015, 
# but they should point to their current Davao Occidental PSGC/shapefile units

# manual crosswalk for those admin units
davao_occidental_old_codes <- tribble(
  ~psgc_adm3_code_old_alias, ~psgc_adm3_code,
  "112405000", "1108602000",  # Jose Abad Santos
  "112409000",  "1108603000",  # Malita
  "112413000", "1108604000",  # Santa Maria
  "112415000",  "1108601000",  # Don Marcelino
  "112416000", "1108605000"  # Sarangani
)

# Add the Davao Occidental historical aliases
psgc_old <- bind_rows(
  psgc_old,
  psgc_current %>%
    inner_join(davao_occidental_old_codes, by = "psgc_adm3_code") %>%
    mutate(psgc_adm3_code_old = psgc_adm3_code_old_alias) %>%
    select(-psgc_adm3_code_old_alias)
) %>%
  distinct(psgc_adm3_code_old, .keep_all = TRUE)


# -----------------------------
# 2007 Population Census
# -----------------------------

# link to microdata: https://psada.psa.gov.ph/catalog/16

#  person-level files: we only read the 5 columns needed to
# count population by municipality, age, and sex 

files_2007 <- list.files(
  dir_2007,
  pattern = "\\.csv$",
  recursive = TRUE,
  full.names = TRUE,
  ignore.case = TRUE
)

pop_2007_list <- vector("list", length(files_2007))

# process one file at a time to avoid holding the full census in memory.
# each file is reduced to grouped counts immediately
for (i in seq_along(files_2007)) {
  file <- files_2007[i]

  # Keep source metadata:
  source_file <- str_remove(file, fixed(str_c(dir_2007, "/")))
  message("2007: ", source_file)

  # Read admin codes, sex, and age as text to preserve leading zeros
  pop_2007_list[[i]] <- fread(
    file,
    select = c("PREG", "PPRV", "PMUN", "SEX", "AGE"),
    colClasses = "character",
    showProgress = FALSE,
    encoding = "UTF-8"
  ) %>%
    as_tibble() %>%
    mutate(
      # clean code values before rebuilding the old ADM3 code
      region_clean = str_remove(str_remove(str_trim(as.character(PREG)), "^PH"), "\\.0$"),
      province_clean = str_remove(str_remove(str_trim(as.character(PPRV)), "^PH"), "\\.0$"),
      mun_clean = str_remove(str_remove(str_trim(as.character(PMUN)), "^PH"), "\\.0$"),
      sex_clean = str_remove(str_trim(as.character(SEX)), "\\.0$"),
      age_clean = str_remove(str_trim(as.character(AGE)), "\\.0$"),

      # reconstruct historical nine-digit ADM3 code
      # (from 2 region digits, 2 province digits, 2 municipality digits, and 000)
      region2 = str_pad(region_clean, 2, side = "left", pad = "0"),
      province2 = str_sub(str_pad(province_clean, 4, side = "left", pad = "0"), 1, 2),
      mun2 = str_pad(mun_clean, 2, side = "left", pad = "0"),
      source_adm3_old_code = str_c(region2, province2, mun2, "000"),
      
      # 1339 special case used in the admin crosswalk.
      source_adm3_old_code = case_when(
        str_detect(source_adm3_old_code, "^1339(0[1-9]|1[0-4])000$") ~ "133900000",
        TRUE ~ source_adm3_old_code
      ),

      # Harmonize all census years to ages 0-79 plus a single 80+ category
      # remove invalid ages or sex codes before counting
      age = suppressWarnings(as.integer(age_clean)),
      age = if_else(age >= 80, 80, age),
      age_group = if_else(age == 80, "80+", as.character(age)),
      sex = case_when(
        sex_clean == "1" ~ "male",
        sex_clean == "2" ~ "female",
        TRUE ~ NA
      )
    ) %>%
    filter(!is.na(source_adm3_old_code), !is.na(age), !is.na(sex)) %>%

    # Convert person records into population counts at the required level
    group_by(
      source_adm3_old_code,
      age,
      age_group,
      sex
    ) %>%
    summarise(population = n(), .groups = "drop") %>%
    mutate(source_file = source_file)
}

# Combine the summaries from all source files. Sum population counts for any
# repeated ADM3-age-sex cells and record which source files contributed to
# each final observation.
pop_2007 <- bind_rows(pop_2007_list) %>%
  group_by(source_adm3_old_code, age, age_group, sex) %>%
  summarise(
    n_source_files = n_distinct(source_file),
    source_files = str_c(sort(unique(source_file)), collapse = " | "),
    population = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    # Derive parent admin codes from the historical adm3 code.
    # The 2007 files do not include current adm3 codes or names.
    census_year = 2007,
    source = "PSADA 2007 POPCEN",
    source_adm1_code = str_sub(source_adm3_old_code, 1, 2),
    source_adm2_code = str_c(str_sub(source_adm3_old_code, 1, 4), "00000"),
    source_adm3_new_code = NA,
    source_adm3_name = NA
  )


# -------------------------------------
# 2010 Census of Population and Housing
# -------------------------------------

# link to microdata: https://psada.psa.gov.ph/catalog/13

# Use Form 2 non-sample person files
# folder also contains housing files, so drop those first
# filtering out Housing.csv is more reliable than looking for "Person"
# because not every person file includes that in its name
files_2010 <- list.files(
  dir_2010,
  pattern = "\\.csv$",
  recursive = TRUE,
  full.names = TRUE,
  ignore.case = TRUE
)
files_2010 <- files_2010[
  !str_detect(files_2010, regex("Housing\\.csv$", ignore_case = TRUE))
]

if (length(files_2010) == 0) {
  stop("No 2010 Form 2 person CSV files found.")
}

cat("2010 Form 2 person CSV files:", length(files_2010), "\n")

pop_2010_list <- vector("list", length(files_2010))

# same process as 2007 census cleaning above but we use Form 2 variable names here for 2010
for (i in seq_along(files_2010)) {
  file <- files_2010[i]

  # Keep a shorter source-file path for tracking inputs
  source_file <- str_remove(file, fixed(str_c(dir_2010, "/")))
  message("2010: ", source_file)

  # REG, PRRCD, and MUN identify the admin unit; P3 is sex and P5 is age.
  pop_2010_list[[i]] <- fread(
    file,
    select = c("REG", "PRRCD", "MUN", "P3", "P5"),
    colClasses = "character",
    showProgress = FALSE,
    encoding = "UTF-8"
  ) %>%
    as_tibble() %>%
    mutate(
      # Standardize identifier text before rebuilding the old nine-digit adm3 code
      region_clean = str_remove(str_remove(str_trim(as.character(REG)), "^PH"), "\\.0$"),
      province_clean = str_remove(str_remove(str_trim(as.character(PRRCD)), "^PH"), "\\.0$"),
      mun_clean = str_remove(str_remove(str_trim(as.character(MUN)), "^PH"), "\\.0$"),
      sex_clean = str_remove(str_trim(as.character(P3)), "\\.0$"),
      age_clean = str_remove(str_trim(as.character(P5)), "\\.0$"),
      region2 = str_pad(region_clean, 2, side = "left", pad = "0"),
      province2 = str_sub(str_pad(province_clean, 4, side = "left", pad = "0"), 1, 2),
      mun2 = str_pad(mun_clean, 2, side = "left", pad = "0"),
      source_adm3_old_code = str_c(region2, province2, mun2, "000"),

      # Apply the same special-code treatment and age/sex harmonization as 2007
      source_adm3_old_code = case_when(
        str_detect(source_adm3_old_code, "^1339(0[1-9]|1[0-4])000$") ~ "133900000",
        TRUE ~ source_adm3_old_code
      ),
      age = suppressWarnings(as.integer(age_clean)),
      age = if_else(age >= 80, 80, age),
      age_group = if_else(age == 80, "80+", as.character(age)),
      sex = case_when(
        sex_clean == "1" ~ "male",
        sex_clean == "2" ~ "female",
        TRUE ~ NA
      )
    ) %>%
    filter(!is.na(source_adm3_old_code), !is.na(age), !is.na(sex)) %>%

    # Count population by ADM3, age, and sex within each source file.
    group_by(
      source_adm3_old_code,
      age,
      age_group,
      sex
    ) %>%
    summarise(population = n(), .groups = "drop") %>%
    mutate(source_file = source_file)
}

# Combine the summaries from all source files. Sum population counts for any
# repeated ADM3-age-sex cells and record which source files contributed.
pop_2010 <- bind_rows(pop_2010_list) %>%
  group_by(source_adm3_old_code, age, age_group, sex) %>%
  summarise(
    n_source_files = n_distinct(source_file),
    source_files = str_c(sort(unique(source_file)), collapse = " | "),
    population = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    # As in 2007, the source provides the historical code but not the current
    # ten-digit adm3 code used by the current PSGC.
    # The 2010 files only provide historical adm3 codes, derive adm1/adm2 from that code
    census_year = 2010,
    source = "PSADA 2010 CPH Form 2",
    source_adm1_code = str_sub(source_adm3_old_code, 1, 2),
    source_adm2_code = str_c(str_sub(source_adm3_old_code, 1, 4), "00000"),
    source_adm3_new_code = NA,
    source_adm3_name = NA
  )


# -----------------------------------------------------------------
# 2015 HDX / PSA (Philippines Statistical Authority) adm4 pop table
# -----------------------------------------------------------------

# data source: Humanatarian Data Exchange (HDX)
# population counts by sex and age and adm4 already processed from 2015 Population Census
# link: https://data.humdata.org/dataset/philippines-2015-census-population-admin4-single-age

# The 2015 table already has age-sex columns. We reshape it from wide to long,
# then add barangays (adm4) up to municipality/city (adm3)

raw_2015 <- read_csv(
  hdx_2015_path,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

  # Keep only the age-sex columns
age_cols_2015 <- names(raw_2015)[str_detect(names(raw_2015), "^[FM](Under_1|[0-9]+|100_Over)$")]

pop_2015 <- raw_2015 %>%
  select(adm1_code, adm2_code, adm3_code, adm3_name, all_of(age_cols_2015)) %>%

  # Reshape from one barangay row with many age-sex columns to one row per # barangay-age-sex cell
  pivot_longer(
    cols = all_of(age_cols_2015),
    names_to = "age_sex_column",
    values_to = "population"
  ) %>%
  mutate(
    # 2015 uses historical adm3 codes, clean them and apply the same 1339 fix
    source_adm3_old_code = str_remove(str_remove(str_trim(as.character(adm3_code)), "^PH"), "\\.0$"),
    source_adm3_old_code = case_when(
      str_detect(source_adm3_old_code, "^1339(0[1-9]|1[0-4])000$") ~ "133900000",
      TRUE ~ source_adm3_old_code
    ),

    # Age-sex columns start with M/F, followed by the age label 
    # Collapse 80+ to match the other census years
    age_text = str_sub(age_sex_column, 2),
    age_number = suppressWarnings(as.integer(age_text)),
    age = case_when(
      age_text == "Under_1" ~ 0,
      age_text == "100_Over" ~ 80,
      !is.na(age_number) & age_number >= 80 ~ 80,
      !is.na(age_number) ~ age_number,
      TRUE ~ NA
    ),
    age_group = if_else(age == 80, "80+", as.character(age)),
    sex = case_when(
      str_sub(age_sex_column, 1, 1) == "M" ~ "male",
      str_sub(age_sex_column, 1, 1) == "F" ~ "female",
      TRUE ~ NA
    ),
    population = parse_number(population),
    source_adm3_name = str_squish(adm3_name)
  ) %>%
  filter(!is.na(source_adm3_old_code), !is.na(age), !is.na(sex)) %>%

  # sum barangay cells to ADM3. Keep source names for checking code matches.
  group_by(source_adm3_old_code, age, age_group, sex) %>%
  summarise(
    source_adm3_name = str_c(sort(unique(source_adm3_name)), collapse = "; "),
    population = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    # File counts only apply to the person-level census files
    census_year = 2015,
    source = "HDX/PSA 2015 barangay table",
    source_adm1_code = str_sub(source_adm3_old_code, 1, 2),
    source_adm2_code = str_c(str_sub(source_adm3_old_code, 1, 4), "00000"),
    source_adm3_new_code = NA,
    n_source_files = NA,
    source_files = NA
  )


# -----------------------------------------------------------------
# 2020 HDX / PSA (Philippines Statistical Authority) adm4 pop table
# -----------------------------------------------------------------

# data source: Humanatarian Data Exchange
# population counts by sex and age and adm4 already processed from 2015 Population Census
# link: https://data.humdata.org/dataset/philippines-2015-census-population-admin4-single-age


# The 2020 table has both old and new barangay codes
# Use the new code first, but keep the old code as a fallback for rows
# that do not match cleanly to a current adm3

# read as text so barangay codes keep their leading zeros
# clean column names in case the workbook has extra space
raw_2020 <- read_excel(hdx_2020_path, sheet = "Brgy_adm4", col_types = "text")
names(raw_2020) <- str_squish(names(raw_2020))

# Keep only the age-sex columns: Under 1, single ages, and 80 and Over
# each split by _M / _F
age_cols_2020 <- names(raw_2020)[str_detect(names(raw_2020), "^(Under 1|[0-9]+|80 and Over)_[MF]$")]

pop_2020 <- raw_2020 %>%
  select(Mun, BgyCode_new, BgyCode_old, all_of(age_cols_2020)) %>%

  # Reshape to barangay-age-sex cells, then split the source column
  # into age and sex.
  pivot_longer(
    cols = all_of(age_cols_2020),
    names_to = "age_sex_column",
    values_to = "population"
  ) %>%
  separate(
    age_sex_column,
    into = c("age_text", "sex_code"),
    sep = "_(?=[MF]$)",
    remove = FALSE
  ) %>%
  mutate(
    # Clean both barangay code versions before rolling them up to ADM3
    # Current codes use the first 7 digits; old codes use the first 6
    bgy_new_clean = str_remove(str_remove(str_trim(as.character(BgyCode_new)), "^PH"), "\\.0$"),
    bgy_old_clean = str_remove(str_remove(str_trim(as.character(BgyCode_old)), "^PH"), "\\.0$"),

    # Build current and historical ADM3 codes
    # handling special cases 13806 and 1339 
    source_adm3_new_code = case_when(
      str_detect(bgy_new_clean, "^13806") ~ "1380600000",
      nchar(bgy_new_clean) == 10 ~ str_c(str_sub(bgy_new_clean, 1, 7), "000"),
      TRUE ~ NA
    ),
    source_adm3_old_code = case_when(
      str_detect(bgy_old_clean, "^1339") ~ "133900000",
      nchar(bgy_old_clean) == 9 ~ str_c(str_sub(bgy_old_clean, 1, 6), "000"),
      TRUE ~ NA
    ),

    # Same age/sex format as the earlier census years
    age_number = suppressWarnings(as.integer(age_text)),
    age = case_when(
      age_text == "Under 1" ~ 0,
      age_text == "80 and Over" ~ 80,
      !is.na(age_number) & age_number >= 80 ~ 80,
      !is.na(age_number) ~ age_number,
      TRUE ~ NA
    ),
    age_group = if_else(age == 80, "80+", as.character(age)),
    sex = case_when(
      sex_code == "M" ~ "male",
      sex_code == "F" ~ "female",
      TRUE ~ NA
    ),
    population = parse_number(population),
    source_adm3_name = str_squish(Mun)
  ) %>%
  filter(!is.na(age), !is.na(sex)) %>%

  # Sum barangay cells to ADM3, keeping both old and new codes
  # The old code is still needed as a fallback in the match below
  group_by(source_adm3_old_code, source_adm3_new_code, age, age_group, sex) %>%
  summarise(
    source_adm3_name = str_c(sort(unique(source_adm3_name)), collapse = "; "),
    population = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    # Leave parent source codes empty because the old and new barangay codes
    # do not always correspond to the same ad1 & adm2 
    census_year = 2020,
    source = "HDX/PSA 2020 barangay table",
    source_adm1_code = NA,
    source_adm2_code = NA,
    n_source_files = NA,
    source_files = NA
  )


# -------------------------------------------------
# Link 2007, 2010, and 2015 to current ADM3 codes
# -------------------------------------------------

# Combine the census years that only have historical adm3 codes, then link
# them to the current PSGC and shapefile codes using the old-code lookup
pop_old_code_years <- bind_rows(pop_2007, pop_2010, pop_2015) %>%
  left_join(psgc_old, by = c("source_adm3_old_code" = "psgc_adm3_code_old")) %>%
  mutate(
    # Record whether each row matched to a shapefile adm3, only to the current
    # PSGC, or not at all. script 02 requires a shapefile adm3 match.
    geo_match_method = case_when(
      !is.na(shp_adm3_code) ~ "old_psgc_to_current_shapefile",
      !is.na(psgc_adm3_code) ~ "old_psgc_to_current_psgc_no_shapefile",
      TRUE ~ "unmatched_old_psgc"
    ),
    geo_match_status = if_else(!is.na(shp_adm3_code), "matched_to_shapefile", "unmatched")
  )


# -------------------------------
# Link 2020 to current ADM3 codes
# -------------------------------

# First match using the current ADM3 code derived from the 2020 barangay code

# Prefer matches through the current ADM3 code. Keep track of which rows
# matched directly so the final match method can distinguish them from
# historical-code fallbacks
pop_2020_current_match <- pop_2020 %>%
  left_join(psgc_current, by = c("source_adm3_new_code" = "psgc_adm3_code")) %>%
  mutate(
    matched_with_current_code = !is.na(psgc_adm3_name),
    psgc_adm3_code = if_else(matched_with_current_code, source_adm3_new_code, NA)
  )

# Create a fallback match using the historical barangay code
# Most rows match through the current code, but a few only match here

# Rename the old-code match columns so they can be joined to the
# current-code match without name conflicts
pop_2020_old_match <- pop_2020 %>%
  left_join(psgc_old, by = c("source_adm3_old_code" = "psgc_adm3_code_old")) %>%
  transmute(
    census_year,
    source,
    source_adm3_old_code,
    source_adm3_new_code,
    source_adm3_name,
    age,
    age_group,
    sex,
    psgc_adm3_code_from_old = psgc_adm3_code,
    psgc_adm3_name_from_old = psgc_adm3_name,
    psgc_adm1_code_from_old = psgc_adm1_code,
    psgc_adm1_name_from_old = psgc_adm1_name,
    psgc_adm2_code_from_old = psgc_adm2_code,
    psgc_adm2_name_from_old = psgc_adm2_name,
    shp_adm1_code_from_old = shp_adm1_code,
    shp_adm1_name_from_old = shp_adm1_name,
    shp_adm2_code_from_old = shp_adm2_code,
    shp_adm2_name_from_old = shp_adm2_name,
    shp_adm3_code_from_old = shp_adm3_code,
    shp_adm3_name_from_old = shp_adm3_name
  )

# Join the two candidate matches at the original ADM3-age-sex cell level
pop_2020_linked <- pop_2020_current_match %>%
  left_join(
    pop_2020_old_match,
    by = c(
      "census_year",
      "source",
      "source_adm3_old_code",
      "source_adm3_new_code",
      "source_adm3_name",
      "age",
      "age_group",
      "sex"
    )
  ) %>%
  mutate(
    # prefer the current-code match, if missing, fill in the PSGC/shapefile
    # codes from the old-code fallback
    psgc_adm3_code = coalesce(psgc_adm3_code, psgc_adm3_code_from_old),
    psgc_adm3_name = coalesce(psgc_adm3_name, psgc_adm3_name_from_old),
    psgc_adm1_code = coalesce(psgc_adm1_code, psgc_adm1_code_from_old),
    psgc_adm1_name = coalesce(psgc_adm1_name, psgc_adm1_name_from_old),
    psgc_adm2_code = coalesce(psgc_adm2_code, psgc_adm2_code_from_old),
    psgc_adm2_name = coalesce(psgc_adm2_name, psgc_adm2_name_from_old),
    shp_adm1_code = coalesce(shp_adm1_code, shp_adm1_code_from_old),
    shp_adm1_name = coalesce(shp_adm1_name, shp_adm1_name_from_old),
    shp_adm2_code = coalesce(shp_adm2_code, shp_adm2_code_from_old),
    shp_adm2_name = coalesce(shp_adm2_name, shp_adm2_name_from_old),
    shp_adm3_code = coalesce(shp_adm3_code, shp_adm3_code_from_old),
    shp_adm3_name = coalesce(shp_adm3_name, shp_adm3_name_from_old),
    geo_match_method = case_when(
      !is.na(shp_adm3_code) & matched_with_current_code ~ "current_barangay_rollup_to_shapefile",
      !is.na(shp_adm3_code) & !matched_with_current_code ~ "old_barangay_rollup_fallback_to_shapefile",
      !is.na(psgc_adm3_code) ~ "matched_psgc_no_shapefile",
      TRUE ~ "unmatched_2020_barangay_rollup"
    ),
    geo_match_status = if_else(!is.na(shp_adm3_code), "matched_to_shapefile", "unmatched")
  ) %>%

  # use same columns as earlier census years before combining all years
  select(all_of(names(pop_old_code_years)))


# -----------------------------
# Final census-year file
# -----------------------------

# Combine all four census years, keep the final columns, and sort rows
pop_census_years <- bind_rows(pop_old_code_years, pop_2020_linked) %>%
  transmute(
    census_year, source,  source_adm1_code, source_adm2_code,
    source_adm3_old_code, source_adm3_new_code, source_adm3_name,
    psgc_adm1_code, psgc_adm1_name, psgc_adm2_code, psgc_adm2_name,
    psgc_adm3_code, psgc_adm3_name, shp_adm1_code, shp_adm1_name,
    shp_adm2_code, shp_adm2_name, shp_adm3_code, shp_adm3_name,
    age, age_group, sex, population, n_source_files, source_files,
    geo_match_method, geo_match_status
    ) %>%
  arrange(census_year, shp_adm3_code, source_adm3_old_code,
          source_adm3_new_code, age, sex)

out_file <- file.path(population_clean_dir, "census_pop_pre_alignment.csv")
checks_file <- file.path(population_clean_dir, "census_pre_alignment_checks.xlsx")

# write output (used in script 02)
write_csv(pop_census_years, out_file)


# -----------------------------
# Checks
# -----------------------------

# Check ADM3 matches, unmatched places, duplicate keys, and pop totals

# count unique source ADM3 units by year and match result
# use distinct places so age-sex rows do not inflate the counts
geography_summary <- pop_census_years %>%
  distinct(
    census_year, source_adm3_old_code,
    source_adm3_new_code, psgc_adm3_code,
    shp_adm3_code, geo_match_method,
    geo_match_status) %>%
  count(census_year, geo_match_status,
        geo_match_method, name = "n_adm3")

# list source places that did not match to a shapefile adm3
# include pop totals to show the scale of unresolved cases
unmatched_places <- pop_census_years %>%
  filter(geo_match_status != "matched_to_shapefile") %>%
  group_by(
    census_year, source_adm3_old_code,
    source_adm3_new_code, source_adm3_name,
    geo_match_method) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(census_year, desc(population))

# Final duplicate key check: one row per census year, shapefile ADM3, age, and sex
duplicate_keys <- pop_census_years %>%
  count(census_year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(!is.na(shp_adm3_code), n_rows > 1) %>%
  arrange(census_year, shp_adm3_code, age, sex)

# census-year totals by sex, useful catching missing files, # duplicated files etc. 
year_sex_totals <- pop_census_years %>%
  group_by(census_year, sex) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(census_year, sex)

# Keep all checks in one workbook rather than writing separate diagnostic CSVs
write_xlsx(
  list(
    "Geography Summary" = geography_summary,
    "Unmatched Places" = unmatched_places,
    "Duplicate Keys" = duplicate_keys,
    "Population Totals" = year_sex_totals
    
    
  ),
  checks_file
)


# Print outputs and checks 
cat("\nWrote cleaned census-year population file:\n")
cat(" - ", out_file, "\n", sep = "")
cat(" - ", checks_file, "\n", sep = "")

cat("\nGeography summary:\n")
print(geography_summary, n = Inf)

cat("\nUnmatched places:\n")
print(unmatched_places, n = Inf)

cat("\nDuplicate year-ADM3-age-sex keys:\n")
print(duplicate_keys, n = Inf)

cat("\nYear-sex totals:\n")
print(year_sex_totals, n = Inf)
