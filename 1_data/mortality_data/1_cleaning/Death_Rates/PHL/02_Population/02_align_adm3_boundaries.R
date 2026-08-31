# ============================================================
# 02_align_adm3_boundaries.R
#
# Align all census years to the current 2020 ADM3 boundaries
#
# Script 01 cleans the census data and links records to current PSGC and
# shapefile codes where a direct match is available. This script handles the
# remaining municipality boundary changes so that every census year uses the
# same set of 2020 ADM3 units.
#
# The 2020 census is used as the reference because it contains all 1,642
# current municipalities and cities. Some of these units did not yet exist in
# the older census years.
#
# For the affected areas, older municipality populations are split across the
# current ADM3 units using population shares from the first census year in
# which the newer boundaries are observed.
#
# Because population is allocated proportionally, some adjusted counts are
# fractional. Population totals are preserved.
#
# Main output:
#   Population/1_Clean/census_pop_final.csv
# ============================================================


# -----------------------------
# Packages and paths
# -----------------------------

library(dplyr)
library(readr)
library(stringr)
library(tidyr)
library(writexl)

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")

source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"))

dir.create(population_clean_dir, recursive = TRUE, showWarnings = FALSE)

input_file <- file.path(population_clean_dir, "census_pop_pre_alignment.csv")
output_file <- file.path(population_clean_dir, "census_pop_final.csv")
checks_file <- file.path(population_clean_dir, "census_final_checks.xlsx")


# -----------------------------
# Input data and current ADM3s
# -----------------------------

# Read codes as text so leading zeros are preserved
pop_input <- read_csv(
  input_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  mutate(
    census_year = as.integer(census_year),
    age = as.integer(age),
    population = as.numeric(population)
  )

# Keep only the variables needed for boundary alignment and interpolation
pop_pre_boundary <- pop_input %>%
  select(
    census_year, shp_adm1_code, shp_adm1_name, shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name, psgc_adm3_code, psgc_adm3_name,
    age, age_group, sex, population
  )

# Use the 2020 census as the reference set of current municipalities/cities
# Sum over age and sex to get the 2020 population of each ADM3
current_adm3 <- pop_pre_boundary %>%
  filter(census_year == 2020) %>%
  group_by(
    shp_adm1_code, shp_adm1_name, shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name, psgc_adm3_code, psgc_adm3_name
  ) %>%
  summarise(population_2020 = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(shp_adm3_code)

# Number of current ADM3 units already represented in each census year
coverage_before <- pop_pre_boundary %>%
  distinct(census_year, shp_adm3_code) %>%
  count(census_year, name = "n_shp_adm3_before") %>%
  mutate(
    target_current_adm3 = nrow(current_adm3),
    missing_before = target_current_adm3 - n_shp_adm3_before
  ) %>%
  arrange(census_year)

# Current ADM3 units missing from the older census years
# These are the units that may require a boundary adjustment below
missing_current_adm3 <- tidyr::crossing(
  census_year = sort(unique(pop_pre_boundary$census_year)),
  current_adm3
) %>%
  anti_join(
    pop_pre_boundary %>% distinct(census_year, shp_adm3_code),
    by = c("census_year", "shp_adm3_code")
  ) %>%
  filter(census_year != 2020) %>%
  arrange(census_year, shp_adm2_code, shp_adm3_code)

# -----------------------------
# Boundary adjustment rules
# -----------------------------


# BARMM Special Geographic Area
#
# Eight BARMM SGA municipalities were created from parts of older Cotabato
# municipalities. They appear as separate ADM3 units in 2020 but not in the
# 2007, 2010, or 2015 census data. For the older census years, the affected
# municipality populations are split across the 2020 ADM3 units using 2020
# population shares.
#
# Pikit Cluster III / Tugunan is the main exception because its 2020 boundary
# includes barangays from two older municipalities. Six barangays trace back
# to Pikit, while Dunguan and Tapodoc trace back to Aleosan in the 2015 HDX
# file and public descriptions of the SGA boundary changes.
#
# For Pikit Cluster III, the 2020 population is split into:
#   24,486 from Pikit-origin barangays
#    5,052 from Dunguan and Tapodoc, which previously belonged to Aleosan
#
# `allocation_group` keeps units from the same older municipality together when
# calculating the split. The 2020 population totals are used as the basis for
# the shares, except for the two Pikit Cluster III pieces above, which use the
# manually specified totals.



barmm_map <- tribble(
  ~target_shp_adm3_code, ~source_parent_shp_adm3_code,
  ~allocation_group, ~target_population_basis_manual,
  "1999901000", "1204702000", "carmen_to_kapalawan", NA,
  "1999902000", "1204703000", "kabacan_to_old_kaabakan", NA,
  "1999903000", "1204709000", "midsayap_to_kadayangan_nabalawag", NA,
  "1999904000", "1204709000", "midsayap_to_kadayangan_nabalawag", NA,
  "1999905000", "1204711000", "pigcawayan_to_pahamuddin", NA,
  "1999906000", "1204712000", "pikit_to_malidegao_ligawasan_tugunan", NA,
  "1999907000", "1204712000", "pikit_to_malidegao_ligawasan_tugunan", NA,
  "1999908000", "1204712000", "pikit_to_malidegao_ligawasan_tugunan", 24486,
  "1999908000", "1204717000", "aleosan_to_pikit_cluster_iii", 5052
)

# Keep the missing BARMM SGA units and attach their older source municipalities
# Pikit Cluster III has two source municipalities
barmm_child_rows <- missing_current_adm3 %>%
  filter(str_detect(shp_adm3_code, "^19999")) %>%
  inner_join(
    barmm_map,
    by = c("shp_adm3_code" = "target_shp_adm3_code"),
    relationship = "one-to-many"
  ) %>%
  transmute(
    census_year, allocation_group,
    allocation_row_type = "child_current_unit",
    target_shp_adm3_code = shp_adm3_code,
    source_parent_shp_adm3_code,
    allocation_basis_year = 2020,
    target_population_basis = coalesce(target_population_basis_manual, population_2020),
    notes = case_when(
      allocation_group == "aleosan_to_pikit_cluster_iii" ~
        "BARMM SGA split. Aleosan-origin part of Pikit Cluster III.",
      target_shp_adm3_code == "1999908000" ~
        "BARMM SGA split. Pikit-origin part of Pikit Cluster III.",
      TRUE ~
        "BARMM SGA split. Share based on 2020 population."
    )
  )

# Add the part of each source municipality that remains after the new SGA unit
# is separated out. Its 2020 population provides the basis for the residual
# share within the same allocation group.
barmm_parent_rows <- barmm_child_rows %>%
  distinct(census_year, allocation_group, source_parent_shp_adm3_code, allocation_basis_year) %>%
  left_join(
    current_adm3 %>%
      select(
        source_parent_shp_adm3_code = shp_adm3_code,
        source_parent_population_2020 = population_2020
      ),
    by = "source_parent_shp_adm3_code"
  ) %>%
  transmute(
    census_year, allocation_group,
    allocation_row_type = "parent_residual_unit",
    target_shp_adm3_code = source_parent_shp_adm3_code,
    source_parent_shp_adm3_code,
    allocation_basis_year,
    target_population_basis = source_parent_population_2020,
    notes = case_when(
      allocation_group == "aleosan_to_pikit_cluster_iii" ~
        "BARMM SGA split. Remaining Aleosan.",
      allocation_group == "pikit_to_malidegao_ligawasan_tugunan" ~
        "BARMM SGA split. Remaining Pikit.",
      TRUE ~
        "BARMM SGA split. Remaining source municipality."
    )
  )

# Together these rows describe how each older source municipality is divided
# across the current ADM3 units
barmm_allocation_rows <- bind_rows(barmm_child_rows, barmm_parent_rows)


# 2007 boundary changes
#
# These cases only affect 2007. The municipalities below are present in 2010,
# 2015, and 2020 but not as separate ADM3 units in the 2007 census, so the 2010
# population distribution is used to split the 2007 source municipalities.
#
# Tabuan-Lasa was created from Sumisip.
#
# Datu Hoffer Ampatuan, Datu Salibo, and Shariff Saydona Mustapha are treated
# together because the three municipalities were formed from overlapping parts
# of several older Maguindanao municipalities. Keeping them in one allocation
# group makes sure the same 2007 source population is not allocated twice.
#
# For each split, `child_current_unit` marks a municipality that is missing
# from the 2007 data and needs to be added. `parent_residual_unit` marks the
# part of an older source municipality that remains after the split.
#
# The Maguindanao rows use `multi_parent` because the three new municipalities
# do not each come from a single older municipality. The source municipalities
# used for the split are listed separately in the `parent_residual_unit` rows
# for the same allocation group.


split_2007_map <- tribble(
  ~target_shp_adm3_code, ~allocation_row_type, ~allocation_group, ~source_parent_shp_adm3_code,
  "1900713000", "child_current_unit",   "sumisip_to_tabuan_lasa",  "1900705000",
  "1900705000", "parent_residual_unit", "sumisip_to_tabuan_lasa",  "1900705000",
  "1908805000", "child_current_unit",   "maguindanao_2009_splits", "multi_parent",
  "1908808000", "child_current_unit",   "maguindanao_2009_splits", "multi_parent",
  "1908821000", "child_current_unit",   "maguindanao_2009_splits", "multi_parent",
  "1908807000", "parent_residual_unit", "maguindanao_2009_splits", "1908807000",
  "1908809000", "parent_residual_unit", "maguindanao_2009_splits", "1908809000",
  "1908810000", "parent_residual_unit", "maguindanao_2009_splits", "1908810000",
  "1908813000", "parent_residual_unit", "maguindanao_2009_splits", "1908813000",
  "1908820000", "parent_residual_unit", "maguindanao_2009_splits", "1908820000"
)

# Use 2010 ADM3 totals to determine the 2007 allocation shares
population_2010_by_adm3 <- pop_pre_boundary %>%
  filter(census_year == 2010) %>%
  group_by(shp_adm3_code) %>%
  summarise(population_2010 = sum(population, na.rm = TRUE), .groups = "drop")

# Put the 2007 cases in the same format as the BARMM allocation rows
split_2007_allocation_rows <- split_2007_map %>%
  left_join(
    population_2010_by_adm3,
    by = c("target_shp_adm3_code" = "shp_adm3_code")
  ) %>%
  transmute(
    census_year = 2007, allocation_group, allocation_row_type,
    target_shp_adm3_code, source_parent_shp_adm3_code,
    allocation_basis_year = 2010,
    target_population_basis = population_2010,
    notes = case_when(
      allocation_group == "sumisip_to_tabuan_lasa" ~
        "2007 Sumisip split. Share based on 2010 population.",
      allocation_group == "maguindanao_2009_splits" ~
        "2007 Maguindanao split. Share based on 2010 population.",
      TRUE ~ NA_character_
    )
  )


# -----------------------------
# Allocation shares
# -----------------------------

# Combine all boundary cases and calculate the population share assigned to
# each target ADM3. Shares should sum to one within each year/group.
allocation_rows <- bind_rows(barmm_allocation_rows, split_2007_allocation_rows) %>%
  group_by(census_year, allocation_group) %>%
  mutate(
    group_population_basis = sum(target_population_basis, na.rm = TRUE),
    allocation_share = target_population_basis / group_population_basis
  ) %>%
  ungroup() %>%
  
  # Attach the current geography identifiers for each target ADM3
  left_join(
    current_adm3 %>%
      select(
        target_shp_adm1_code = shp_adm1_code,
        target_shp_adm1_name = shp_adm1_name,
        target_shp_adm2_code = shp_adm2_code,
        target_shp_adm2_name = shp_adm2_name,
        target_shp_adm3_code = shp_adm3_code,
        target_shp_adm3_name = shp_adm3_name,
        target_psgc_adm3_code = psgc_adm3_code,
        target_psgc_adm3_name = psgc_adm3_name
      ),
    by = "target_shp_adm3_code"
  ) %>%
  arrange(census_year, allocation_group, allocation_row_type, target_shp_adm3_code)

# Check that every allocation group preserves the full population
allocation_share_checks <- allocation_rows %>%
  group_by(census_year, allocation_group) %>%
  summarise(
    n_rows = n(),
    share_sum = sum(allocation_share, na.rm = TRUE),
    share_sum_error = abs(share_sum - 1),
    .groups = "drop"
  ) %>%
  arrange(census_year, allocation_group)

# Allow only tiny floating-point differences
bad_share_groups <- allocation_share_checks %>%
  filter(share_sum_error > 1e-8)

if (nrow(bad_share_groups) > 0) {
  stop("At least one boundary allocation group does not sum to 1.")
}

# Every target needs current PSGC and shapefile identifiers so that the adjusted
# population data can later merge with mortality and climate data
missing_target_metadata <- allocation_rows %>%
  filter(is.na(target_psgc_adm3_code) | is.na(target_shp_adm3_code))

if (nrow(missing_target_metadata) > 0) {
  stop("At least one boundary allocation target is missing current ADM3 metadata.")
}


# -----------------------------
# Apply boundary adjustments
# -----------------------------

# The parent residual rows identify the older ADM3 units whose original census
# populations need to be removed and redistributed
source_units_to_replace <- allocation_rows %>%
  filter(allocation_row_type == "parent_residual_unit") %>%
  distinct(
    census_year, allocation_group,
    source_shp_adm3_code = target_shp_adm3_code
  )

# Get the original age-sex population that needs to be split
# Groups with several source municipalities are summed before shares are applied
source_age_sex_population <- pop_pre_boundary %>%
  inner_join(
    source_units_to_replace,
    by = c("census_year", "shp_adm3_code" = "source_shp_adm3_code")
  ) %>%
  group_by(census_year, allocation_group, age, age_group, sex) %>%
  summarise(source_population = sum(population, na.rm = TRUE), .groups = "drop")

# Every allocation group should find population in the source census data
# A missing group usually means an ADM3 code or census year was specified wrong
missing_source_groups <- source_units_to_replace %>%
  distinct(census_year, allocation_group) %>%
  anti_join(
    source_age_sex_population %>% distinct(census_year, allocation_group),
    by = c("census_year", "allocation_group")
  )

if (nrow(missing_source_groups) > 0) {
  stop("Could not find source population rows for at least one boundary allocation group.")
}

# Apply the allocation shares to each age-sex cell
# Sum afterward because several source pieces can contribute to one target ADM3
allocated_population <- source_age_sex_population %>%
  inner_join(
    allocation_rows,
    by = c("census_year", "allocation_group"),
    relationship = "many-to-many"
  ) %>%
  transmute(
    census_year,
    shp_adm3_code = target_shp_adm3_code,
    age, age_group, sex,
    population = source_population * allocation_share
  ) %>%
  group_by(census_year, shp_adm3_code, age, age_group, sex) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop")

# Add the current ADM1-ADM3 identifiers to the adjusted rows
allocated_rows <- allocated_population %>%
  left_join(
    current_adm3 %>% select(-population_2020),
    by = "shp_adm3_code"
  ) %>%
  select(
    census_year,
    shp_adm1_code, shp_adm1_name,
    shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name,
    psgc_adm3_code, psgc_adm3_name,
    age, age_group, sex, population
  )

# Remove the original source rows that were split
# All unaffected ADM3 rows remain unchanged
pop_not_replaced <- pop_pre_boundary %>%
  anti_join(
    source_units_to_replace %>%
      distinct(census_year, source_shp_adm3_code),
    by = c("census_year", "shp_adm3_code" = "source_shp_adm3_code")
  )

# Add the adjusted rows back to the unchanged census data
pop_current_adm3 <- bind_rows(pop_not_replaced, allocated_rows) %>%
  arrange(census_year, shp_adm3_code, age, sex)


# -----------------------------
# Checks
# -----------------------------

# Final key should be unique
duplicate_rows_after <- pop_current_adm3 %>%
  count(census_year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(n_rows > 1) %>%
  arrange(census_year, shp_adm3_code, age, sex)

# Population must be conserved for every year × age × sex cell
# full_join also catches cells appearing only before or only after adjustment
total_checks <- pop_pre_boundary %>%
  group_by(census_year, age, age_group, sex) %>%
  summarise(population_before = sum(population, na.rm = TRUE), .groups = "drop") %>%
  full_join(
    pop_current_adm3 %>%
      group_by(census_year, age, age_group, sex) %>%
      summarise(population_after = sum(population, na.rm = TRUE), .groups = "drop"),
    by = c("census_year", "age", "age_group", "sex")
  ) %>%
  mutate(
    population_before = replace_na(population_before, 0),
    population_after = replace_na(population_after, 0),
    difference = population_after - population_before,
    abs_difference = abs(difference)
  ) %>%
  arrange(census_year, age, sex)

# Every census year should contain the full set of 1,642 current ADM3 units
coverage_after <- pop_current_adm3 %>%
  distinct(census_year, shp_adm3_code) %>%
  count(census_year, name = "n_shp_adm3_after") %>%
  mutate(
    target_current_adm3 = nrow(current_adm3),
    missing_after = target_current_adm3 - n_shp_adm3_after
  ) %>%
  left_join(coverage_before, by = c("census_year", "target_current_adm3")) %>%
  select(
    census_year, target_current_adm3,
    n_shp_adm3_before, missing_before,
    n_shp_adm3_after, missing_after
  ) %>%
  arrange(census_year)

# One compact check table for the workbook
check_summary <- tibble::tibble(
  check = c(
    "duplicate year-ADM3-age-sex rows",
    "years missing current ADM3 units",
    "largest population difference",
    "allocation groups with shares not summing to one",
    "allocation targets missing ADM3 metadata",
    "allocation groups missing source population"
  ),
  value = c(
    nrow(duplicate_rows_after),
    sum(coverage_after$missing_after != 0),
    max(total_checks$abs_difference, na.rm = TRUE),
    nrow(bad_share_groups),
    nrow(missing_target_metadata),
    nrow(missing_source_groups)
  )
)

# Stop if the core checks fail
if (check_summary$value[check_summary$check == "duplicate year-ADM3-age-sex rows"] > 0) {
  stop("The current-ADM3 output has duplicate year-ADM3-age-sex rows.")
}

if (check_summary$value[check_summary$check == "years missing current ADM3 units"] > 0) {
  stop("At least one census year is missing current ADM3 units after boundary allocation.")
}

if (check_summary$value[check_summary$check == "largest population difference"] > 1e-6) {
  stop("Population totals are not conserved after boundary allocation.")
}


# -----------------------------
# Output
# -----------------------------

# Write the final population file only after all checks pass
write_csv(pop_current_adm3, output_file)

# Write one workbook with the main checks
write_xlsx(
  list(
    "Summary" = check_summary,
    "Allocation Details" = allocation_rows,
    "Geography Coverage" = coverage_after,
    "Total Conservation" = total_checks
  ),
  checks_file
)


# -----------------------------
# Summary
# -----------------------------

cat("\nWrote ADM3-aligned census population file:\n")
cat(" - ", output_file, "\n", sep = "")

cat("\nWrote boundary adjustment checks workbook:\n")
cat(" - ", checks_file, "\n", sep = "")

cat("\nCheck summary:\n")
print(check_summary, n = Inf)
