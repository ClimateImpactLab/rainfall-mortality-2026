
# ============================================================
# 02_align_adm3_boundaries.R
#
# Align all census years to the current (2020) ADM3 boundaries.
#
# Script 01 cleaned the census data and matched records to current PSGC and
# shapefile codes. This script adjusts municipality boundary changes so every
# census year uses the same set of 2020 ADM3 units.
#
# The 2020 census is used as the reference because it contains the complete
# set of 1,642 current municipalities and cities. Earlier censuses are missing
# some of these units because they had not yet been created.
#
# The script:
#   1. identifies current ADM3 units missing from older census years
#   2. defines boundary adjustment rules
#   3. reallocates population to current ADM3 boundaries
#   4. validates the adjusted data
#   5. writes the final datasets and checks
#
# Population is allocated proportionally across boundary changes, so some
# population counts are fractional while census totals remain unchanged.
#
# Main output:
#   Population/1_Clean/census_pop_final.csv
# ============================================================


# -----------------------------
#         0. Set-Up
# -----------------------------

# --------Packages --------------

library(dplyr)
library(readr)
library(stringr)
library(tidyr)
library(writexl)


# ----------- Paths ------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/PHL/paths.R"))

dir.create(population_clean_dir, recursive = TRUE, showWarnings = FALSE)

input_file <- file.path(population_clean_dir, "census_pop_pre_alignment.csv")
output_file <- file.path(population_clean_dir, "census_pop_final.csv")
checks_file <- file.path(population_clean_dir, "census_final_checks.xlsx")




# ------------------------------------------
# 1. Read data and define current ADM3 units
# ------------------------------------------


# --------------- 1.1 Read input data ------------------


# Read all columns as character to preserve leading zeros in  geocodes
# Convert year, age, and population to numeric
pop_input <- read_csv(
  input_file,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  mutate(
    census_year = as.integer(census_year),
    age = as.integer(age),
    population = as.numeric(population)
  )


# Keep vars needed for adm3 alignment and interpolation only 
pop_pre_boundary <- pop_input %>%
  select(census_year, shp_adm1_code, shp_adm1_name,
    shp_adm2_code, shp_adm2_name, shp_adm3_code,
    shp_adm3_name, psgc_adm3_code, psgc_adm3_name,
    age, age_group, sex, population)


# ------------------ 1.2 Define current ADM3 units -----------------


# Use 2020 as the reference list of current adm3 mun/cities

# sum over age and sex to get the 2020 population total for each amd3
# keep one code/name row for each current mun/city
current_adm3 <- pop_pre_boundary %>%
  filter(census_year == 2020) %>%
  group_by(
    shp_adm1_code, shp_adm1_name,
    shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name,
    psgc_adm3_code, psgc_adm3_name
  ) %>%
  summarise(population_2020 = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(shp_adm3_code)

# count how many current ADM3 units appear in each census year before adjustment
coverage_before <- pop_pre_boundary %>%
  distinct(census_year, shp_adm3_code) %>%
  count(census_year, name = "n_shp_adm3_before") %>%
  mutate(
    target_current_adm3 = nrow(current_adm3),
    missing_before = target_current_adm3 - n_shp_adm3_before
  ) %>%
  arrange(census_year)

# find current ADM3 units missing from older census years
# these are the units that need boundary adjustments
missing_current_adm3 <- tidyr::crossing(
  census_year = sort(unique(pop_pre_boundary$census_year)),
  current_adm3
) %>%
  anti_join(
    pop_pre_boundary %>%
      distinct(census_year, shp_adm3_code),
    by = c("census_year", "shp_adm3_code")
  ) %>%
  filter(census_year != 2020) %>%
  arrange(census_year, shp_adm2_code, shp_adm3_code)


# ---------------------------------------------
#     2. Define Boundary adjustment rules
# ---------------------------------------------


# ---------------- 2.1 BARMM Special Geographic Area ----------------


# boundary changes handled in this script: 
#
# The BARMM Special Geographic Area has eight current ADM3 units carved from
# Cotabato municipalities. They appear in 2020 but not in 2007, 2010, or 2015
# Older parent-municipality populations are split using 2020 population shares
#

# Pikit Cluster III / Tugunan is split across two older parent municipalities
# In the 2020 HDX file, six barangays trace back to Pikit. Dunguan and Tapodoc
# trace back to Aleosan in the 2015 HDX file and public SGA descriptions
#
# We split the 2020 Pikit Cluster III total as:
#   24,486 from Pikit-origin barangays
#    5,052 from Aleosan-origin barangays: Dunguan + Tapodoc



# Each row links a current ADM3 unit to the municipality from which its
# historical population is drawn. allocation_group identifies municipalities
# whose census counts are split together
# the population basis is manually specified only for Pikit Cluster III

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

# Keep missing BARMM SGA units and attach their older source municipalities
# The many-to-many join is needed because Pikit Cluster III has two source municipalities
barmm_child_rows <- missing_current_adm3 %>%
  filter(str_detect(shp_adm3_code, "^19999")) %>%
  inner_join(
    barmm_map,
    by = c("shp_adm3_code" = "target_shp_adm3_code"),
    relationship = "many-to-many"
  ) %>%
  transmute(
    census_year,
    allocation_group,
    allocation_row_type = "child_current_unit",
    target_shp_adm3_code = shp_adm3_code,
    source_parent_shp_adm3_code,
    allocation_basis_year = 2020,
    target_population_basis = coalesce(target_population_basis_manual, population_2020),
    notes = case_when(
      allocation_group == "aleosan_to_pikit_cluster_iii" ~
        "BARMM Special Geographic Area split. Dunguan and Tapodoc are in Pikit Cluster III in 2020, but they trace back to Aleosan in older geography.",
      target_shp_adm3_code == "1999908000" ~
        "BARMM Special Geographic Area split. Pikit-origin part of Pikit Cluster III only; Dunguan and Tapodoc are handled separately with Aleosan.",
      TRUE ~
        "BARMM Special Geographic Area split. Share is based on 2020 population across the remaining source municipality and the new current units."
    )
  )

# Add the remaining parent municipality in each allocation group
# Its 2020 population is used to calculate the parent's residual share
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
    census_year,
    allocation_group,
    allocation_row_type = "parent_residual_unit",
    target_shp_adm3_code = source_parent_shp_adm3_code,
    source_parent_shp_adm3_code,
    allocation_basis_year,
    target_population_basis = source_parent_population_2020,
    notes = case_when(
      allocation_group == "aleosan_to_pikit_cluster_iii" ~
        "BARMM Special Geographic Area split. Remaining Aleosan after allocating the Dunguan and Tapodoc part of Pikit Cluster III.",
      allocation_group == "pikit_to_malidegao_ligawasan_tugunan" ~
        "BARMM Special Geographic Area split. Remaining Pikit after allocating Malidegao, Ligawasan, and the Pikit-origin part of Pikit Cluster III.",
      TRUE ~
        "BARMM Special Geographic Area split. Remaining source municipality after allocating the new current units."
    )
  )

# combine new BARMM units with the remaining parent municipalities
# these rows define how each older parent population is split
barmm_allocation_rows <- bind_rows(barmm_child_rows, barmm_parent_rows)



# ----------------- 2.2 2007 boundary changes -----------------------



# These boundary changes only affect 2007. The municipalities below appear in
# 2010, 2015, and 2020, but not in 2007, so we use 2010 to set the split
#
# Tabuan-Lasa is split out of Sumisip
#
# Datu Hoffer Ampatuan, Datu Salibo, and Shariff Saydona Mustapha are handled
# together because they came from overlapping Maguindanao municipalities. Keeping
# them in one group avoids subtracting twice from the same 2007 municipality

# child_current_unit rows add municipalities missing in 2007
# parent_residual_unit rows keep the remaining part of each older municipality
# "multi_parent" is only a placeholder; the actual 2007 source municipalities
# are listed in the parent_residual_unit rows for the same group
split_2007_map <- tribble(
  ~target_shp_adm3_code, ~allocation_row_type,    ~allocation_group,          ~source_parent_shp_adm3_code,
  "1900713000",          "child_current_unit",   "sumisip_to_tabuan_lasa",   "1900705000",
  "1900705000",          "parent_residual_unit", "sumisip_to_tabuan_lasa",   "1900705000",
  "1908805000",          "child_current_unit",   "maguindanao_2009_splits",  "multi_parent",
  "1908808000",          "child_current_unit",   "maguindanao_2009_splits",  "multi_parent",
  "1908821000",          "child_current_unit",   "maguindanao_2009_splits",  "multi_parent",
  "1908807000",          "parent_residual_unit", "maguindanao_2009_splits",  "1908807000",
  "1908809000",          "parent_residual_unit", "maguindanao_2009_splits",  "1908809000",
  "1908810000",          "parent_residual_unit", "maguindanao_2009_splits",  "1908810000",
  "1908813000",          "parent_residual_unit", "maguindanao_2009_splits",  "1908813000",
  "1908820000",          "parent_residual_unit", "maguindanao_2009_splits",  "1908820000"
)

# Use 2010 ADM3 totals to split the affected 2007 municipalities
population_2010_by_adm3 <- pop_pre_boundary %>%
  filter(census_year == 2010) %>%
  group_by(shp_adm3_code) %>%
  summarise(population_2010 = sum(population, na.rm = TRUE), .groups = "drop")

# Add 2010 population totals so the 2007 source municipalities can be split
# Format these rows like the BARMM cases above
split_2007_allocation_rows <- split_2007_map %>%
  left_join(population_2010_by_adm3, by = c("target_shp_adm3_code" = "shp_adm3_code")) %>%
  transmute(
    census_year = 2007,
    allocation_group,
    allocation_row_type,
    target_shp_adm3_code,
    source_parent_shp_adm3_code,
    allocation_basis_year = 2010,
    target_population_basis = population_2010,
    notes = case_when(
      allocation_group == "sumisip_to_tabuan_lasa" ~
        "2007 Sumisip split. Share is based on 2010 population across Sumisip and Tabuan-Lasa.",
      allocation_group == "maguindanao_2009_splits" ~
        "2007 Maguindanao split. Share is based on 2010 population across the affected source municipalities and the three new municipalities.",
      TRUE ~ NA
    )
  )


# ----------------- 2.3 Combine adjustment rules ---------------------------


# Combine all boundary cases and calculate each target unit's share
# Shares sum to one within each census year and allocation group
allocation_rows <- bind_rows(barmm_allocation_rows, split_2007_allocation_rows) %>%
  group_by(census_year, allocation_group) %>%
  mutate(
    group_population_basis = sum(target_population_basis, na.rm = TRUE),
    allocation_share = target_population_basis / group_population_basis
  ) %>%
  ungroup() %>%
  
  # Attach current PSGC and shapefile codes/names for each target ADM3
  # These are used later when creating the adjusted population rows
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


# --------------- 2.4 Check allocation -------------------


# Allocation shares should sum to one within each group
allocation_share_checks <- allocation_rows %>%
  group_by(census_year, allocation_group) %>%
  summarise(
    n_rows = n(),
    share_sum = sum(allocation_share, na.rm = TRUE),
    share_sum_error = abs(share_sum - 1),
    .groups = "drop"
  ) %>%
  arrange(census_year, allocation_group)

# Allow tiny floating-point differences; fail if the error exceeds 1e-8
bad_share_groups <- allocation_share_checks %>%
  filter(share_sum_error > 1e-8)

if (nrow(bad_share_groups) > 0) {
  stop("At least one boundary allocation group does not sum to 1.")
}

# Every target ADM3 must have current PSGC and shapefile codes
# Otherwise the adjusted population rows cannot merge with mortality
missing_target_metadata <- allocation_rows %>%
  filter(is.na(target_psgc_adm3_code) | is.na(target_shp_adm3_code))

if (nrow(missing_target_metadata) > 0) {
  stop("At least one boundary allocation target is missing current ADM3 metadata.")
}



# ---------------------------------------
#     3. Apply boundary adjustments
# ---------------------------------------

# ---------------- 3.1 Identify source rows ------------------

# For each boundary case, replace the older source rows with current ADM3 rows
# The remaining part of each source municipality is added back as its own row

# the residual rows identify which older ADM3 rows need to be replaced
# allocation_group keeps overlapping municipalities split together where needed
source_units_to_replace <- allocation_rows %>%
  filter(allocation_row_type == "parent_residual_unit") %>%
  distinct(
    census_year,
    allocation_group,
    source_shp_adm3_code = target_shp_adm3_code
  )

# Get the original population to split, by year, group, age, and sex
# Groups with multiple source municipalities are summed before shares are applied
source_age_sex_population <- pop_pre_boundary %>%
  inner_join(
    source_units_to_replace,
    by = c("census_year", "shp_adm3_code" = "source_shp_adm3_code")
  ) %>%
  group_by(census_year, allocation_group, age, age_group, sex) %>%
  summarise(source_population = sum(population, na.rm = TRUE), .groups = "drop")

# Make sure every allocation group matched source population rows
# This catches mistyped ADM3 codes or census years not present in the data
missing_source_groups <- source_units_to_replace %>%
  distinct(census_year, allocation_group) %>%
  anti_join(
    source_age_sex_population %>%
      distinct(census_year, allocation_group),
    by = c("census_year", "allocation_group")
  )

if (nrow(missing_source_groups) > 0) {
  stop("Could not find source population rows for at least one boundary allocation group.")
}


# ---------------- 3.2 Create adjusted ADM3 rows --------------------


# Apply allocation shares to the source population.
# Sum first in case more than one source group contributes to the same ADM3
allocated_population <- source_age_sex_population %>%
  inner_join(
    allocation_rows,
    by = c("census_year", "allocation_group"),
    relationship = "many-to-many"
  ) %>%
  transmute(
    census_year,
    shp_adm3_code = target_shp_adm3_code,
    age,
    age_group,
    sex,
    population = source_population * allocation_share
  ) %>%
  group_by(census_year, shp_adm3_code, age, age_group, sex) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop")

# Add current ADM1, ADM2, and ADM3 codes/names to the adjusted rows
# Drop population_2020, was only used to calculate shares
allocated_rows <- allocated_population %>%
  left_join(
    current_adm3 %>%
      select(-population_2020),
    by = "shp_adm3_code"
  ) %>%
  select(
    census_year,
    shp_adm1_code,
    shp_adm1_name,
    shp_adm2_code,
    shp_adm2_name,
    shp_adm3_code,
    shp_adm3_name,
    psgc_adm3_code,
    psgc_adm3_name,
    age,
    age_group,
    sex,
    population
  )

# Remove the source rows that were split
# Keep all unaffected ADM3 rows unchanged
pop_not_replaced <- pop_pre_boundary %>%
  anti_join(
    source_units_to_replace %>%
      distinct(census_year, source_shp_adm3_code),
    by = c("census_year", "shp_adm3_code" = "source_shp_adm3_code")
  )

# Add the adjusted rows back in and sort the final file
pop_current_adm3 <- bind_rows(pop_not_replaced, allocated_rows) %>%
  arrange(census_year, shp_adm3_code, age, sex)


# --------------------------------
# 4.       Final checks
# --------------------------------

# Check that the final year-ADM3-age-sex key is unique
duplicate_rows_after <- pop_current_adm3 %>%
  count(census_year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(n_rows > 1) %>%
  arrange(census_year, shp_adm3_code, age, sex)

# Check that national population totals are unchanged for each year-age-sex cell
# full_join keeps cells that appear only before or only after adjustment
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

# Check ADM3 coverage before and after adjustment
# Each census year should have all 1,642 current ADM3 units
coverage_after <- pop_current_adm3 %>%
  distinct(census_year, shp_adm3_code) %>%
  count(census_year, name = "n_shp_adm3_after") %>%
  mutate(
    target_current_adm3 = nrow(current_adm3),
    missing_after = target_current_adm3 - n_shp_adm3_after
  ) %>%
  left_join(coverage_before, by = c("census_year", "target_current_adm3")) %>%
  select(
    census_year,
    target_current_adm3,
    n_shp_adm3_before,
    missing_before,
    n_shp_adm3_after,
    missing_after
  ) %>%
  arrange(census_year)

# Stop if the final key is not unique
if (nrow(duplicate_rows_after) > 0) {
  stop("The current-ADM3 output has duplicate year-ADM3-age-sex rows.")
}

# Stop if any census year is still missing current ADM3 units
if (any(coverage_after$missing_after != 0)) {
  stop("At least one census year is missing current ADM3 units after boundary allocation.")
}

# Stop if allocation changed population totals, beyond tiny floating-point noise
if (max(total_checks$abs_difference, na.rm = TRUE) > 1e-6) {
  stop("Population totals are not conserved after boundary allocation.")
}

# --------------------------------
#        5. Write outputs
# --------------------------------


# Write outputs only after all checks pass
write_csv(pop_current_adm3, output_file)

# Save the allocation rules and checks in a separate workbook
write_xlsx(
  list(
    "Geography Coverage" = coverage_after,
    "Allocation Details" = allocation_rows,
    "Share Checks" = allocation_share_checks,
    "Duplicate Keys" = duplicate_rows_after,
    "Total Conservation" = total_checks
  ),
  checks_file
)


# Print summary: 
cat("\nWrote ADM3-aligned census population file:\n")
cat(" - ", output_file, "\n", sep = "")

cat("\nWrote boundary adjustment checks workbook:\n")
cat(" - ", checks_file, "\n", sep = "")

cat("\nADM3 coverage before and after adjustment:\n")
print(coverage_after, n = Inf)

cat("\nAllocation share checks:\n")
print(allocation_share_checks, n = Inf)

cat("\nDuplicate year-ADM3-age-sex rows after adjustment:\n")
print(duplicate_rows_after, n = Inf)

cat("\nLargest population-total differences by year-age-sex:\n")
print(total_checks %>%
        arrange(desc(abs_difference)) %>%
        slice_head(n = 20), n = Inf) 
