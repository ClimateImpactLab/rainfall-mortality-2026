# ============================================================
# 03_align_mortality_boundaries.R
#
# Align Philippines death records to the same fixed ADM3 geography as
# population.
#
# The population scripts already reallocate historical parent-municipality
# population to current ADM3 units for BARMM SGA and selected 2007 boundary
# changes. This script applies the same shares to residence death records.
#
# Output death records keep one row per original record for unaffected places.
# Affected parent records are copied to target ADM3 units with fractional
# death_weight values. Death totals are conserved by year.
#
# Outputs:
#   Mortality/1_Clean/Death_Records/PHL_death_records_adm3_aligned.csv
#   Mortality/1_Clean/Death_Records/PHL_death_boundary_alignment_checks.xlsx
# ============================================================

# -------------------------
# Packages
# -------------------------

library(dplyr)
library(readr)
library(readxl)
library(writexl)

data.table::setDTthreads(4)


# -------------------------
# Paths
# -------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"))

input_file <- file.path(death_records_dir, "PHL_death_records.csv")
output_file <- file.path(death_records_dir, "PHL_death_records_adm3_aligned.csv")
checks_file <- file.path(death_records_dir, "PHL_death_boundary_alignment_checks.xlsx")
allocation_file <- file.path(population_clean_dir, "census_final_checks.xlsx")

if (!file.exists(input_file)) stop("Missing death records file: ", input_file)
if (!file.exists(allocation_file)) stop("Missing population allocation workbook: ", allocation_file)


# -------------------------
# Read inputs
# -------------------------

deaths <- data.table::fread(
  input_file,
  colClasses = "character",
  showProgress = TRUE
) %>%
  tibble::as_tibble() %>%
  mutate(
    record_id = row_number(),
    year = suppressWarnings(as.integer(year_file))
  )

allocation_rows <- read_excel(allocation_file, sheet = "Allocation Details") %>%
  mutate(
    census_year = as.integer(census_year),
    allocation_basis_year = as.integer(allocation_basis_year),
    allocation_share = as.numeric(allocation_share),
    target_shp_adm3_code = as.character(target_shp_adm3_code),
    source_parent_shp_adm3_code = as.character(source_parent_shp_adm3_code)
  )

allocation_template <- allocation_rows %>%
  arrange(allocation_group, allocation_row_type, target_shp_adm3_code, census_year) %>%
  group_by(
    allocation_group,
    allocation_row_type,
    target_shp_adm3_code
  ) %>%
  slice_head(n = 1) %>%
  ungroup()

death_years <- sort(unique(deaths$year[!is.na(deaths$year)]))


# -------------------------
# Decide which years to adjust
# -------------------------

# BARMM SGA never appears in the residence death records, so its parent
# municipalities are split in every mortality year.
#
# The 2007 split cases are adjusted only before 2010, unless the child unit is
# already present in the death records for that group-year.

child_units <- allocation_template %>%
  filter(allocation_row_type == "child_current_unit") %>%
  distinct(allocation_group, child_shp_adm3_code = target_shp_adm3_code)

direct_child_deaths <- deaths %>%
  inner_join(
    child_units,
    by = c("res_shp_adm3_code" = "child_shp_adm3_code")
  ) %>%
  count(year, allocation_group, name = "direct_child_deaths")

allocation_groups <- allocation_template %>%
  group_by(allocation_group) %>%
  summarise(
    allocation_basis_year = first(allocation_basis_year),
    sga_group = any(grepl("^19999", target_shp_adm3_code)),
    .groups = "drop"
  )

allocation_group_years <- tidyr::crossing(
  allocation_groups,
  year = death_years
) %>%
  mutate(
    intended_adjustment = if_else(
      sga_group,
      TRUE,
      year < allocation_basis_year
    )
  ) %>%
  left_join(direct_child_deaths, by = c("year", "allocation_group")) %>%
  mutate(
    direct_child_deaths = tidyr::replace_na(direct_child_deaths, 0L),
    apply_adjustment = intended_adjustment & direct_child_deaths == 0
  )

group_years_to_adjust <- allocation_group_years %>%
  filter(apply_adjustment) %>%
  select(year, allocation_group)


# -------------------------
# Build weighted death records
# -------------------------

source_units_to_replace <- allocation_template %>%
  filter(allocation_row_type == "parent_residual_unit") %>%
  distinct(
    allocation_group,
    source_shp_adm3_code = target_shp_adm3_code
  )

source_records <- deaths %>%
  inner_join(group_years_to_adjust, by = "year") %>%
  inner_join(
    source_units_to_replace,
    by = c(
      "allocation_group",
      "res_shp_adm3_code" = "source_shp_adm3_code"
    )
  )

records_to_replace <- source_records %>%
  distinct(record_id)

deaths_not_replaced <- deaths %>%
  anti_join(records_to_replace, by = "record_id") %>%
  mutate(
    death_weight = 1,
    boundary_alignment_status = "unchanged",
    boundary_allocation_group = NA_character_,
    source_res_shp_adm3_code = res_shp_adm3_code,
    source_res_shp_adm3_name = res_shp_adm3_name
  )

allocated_deaths <- source_records %>%
  inner_join(
    allocation_template,
    by = "allocation_group",
    relationship = "many-to-many"
  ) %>%
  mutate(
    death_weight = allocation_share,
    boundary_alignment_status = "allocated_to_fixed_adm3",
    boundary_allocation_group = allocation_group,
    source_res_shp_adm3_code = res_shp_adm3_code,
    source_res_shp_adm3_name = res_shp_adm3_name,
    res_psgc_adm3_code = target_psgc_adm3_code,
    res_psgc_adm3_name = target_psgc_adm3_name,
    res_shp_adm1_code = target_shp_adm1_code,
    res_shp_adm1_name = target_shp_adm1_name,
    res_shp_adm2_code = target_shp_adm2_code,
    res_shp_adm2_name = target_shp_adm2_name,
    res_shp_adm3_code = target_shp_adm3_code,
    res_shp_adm3_name = target_shp_adm3_name,
    res_geocode_alias_note = paste(
      "Residence ADM3 boundary allocation:",
      allocation_group
    )
  ) %>%
  select(names(deaths_not_replaced))

deaths_aligned <- bind_rows(deaths_not_replaced, allocated_deaths) %>%
  arrange(record_id, res_shp_adm3_code)


# -------------------------
# Checks
# -------------------------

death_total_checks <- deaths %>%
  group_by(year) %>%
  summarise(deaths_before = n(), .groups = "drop") %>%
  full_join(
    deaths_aligned %>%
      group_by(year) %>%
      summarise(deaths_after = sum(death_weight, na.rm = TRUE), .groups = "drop"),
    by = "year"
  ) %>%
  mutate(
    deaths_before = tidyr::replace_na(deaths_before, 0),
    deaths_after = tidyr::replace_na(deaths_after, 0),
    difference = deaths_after - deaths_before,
    abs_difference = abs(difference)
  ) %>%
  arrange(year)

allocation_summary <- source_records %>%
  group_by(year, allocation_group) %>%
  summarise(source_records = n(), .groups = "drop") %>%
  full_join(
    allocated_deaths %>%
      group_by(year, boundary_allocation_group) %>%
      summarise(allocated_deaths = sum(death_weight, na.rm = TRUE), .groups = "drop") %>%
      rename(allocation_group = boundary_allocation_group),
    by = c("year", "allocation_group")
  ) %>%
  mutate(
    source_records = tidyr::replace_na(source_records, 0),
    allocated_deaths = tidyr::replace_na(allocated_deaths, 0),
    difference = allocated_deaths - source_records
  ) %>%
  arrange(year, allocation_group)

remaining_sga_zero_source <- deaths_aligned %>%
  filter(grepl("^19999", res_shp_adm3_code)) %>%
  group_by(year, res_shp_adm3_code, res_shp_adm3_name) %>%
  summarise(deaths = sum(death_weight, na.rm = TRUE), .groups = "drop") %>%
  arrange(year, res_shp_adm3_code)

if (max(death_total_checks$abs_difference, na.rm = TRUE) > 1e-6) {
  stop("Death totals are not conserved after ADM3 boundary alignment.")
}


# -------------------------
# Write outputs
# -------------------------

data.table::fwrite(deaths_aligned, output_file)

write_xlsx(
  list(
    "Death Total Checks" = death_total_checks,
    "Adjusted Group Years" = allocation_summary,
    "Group Year Decisions" = allocation_group_years,
    "SGA Weighted Deaths" = remaining_sga_zero_source
  ),
  checks_file
)

cat("\nWrote ADM3-aligned death records:\n")
cat(" - ", output_file, "\n", sep = "")
cat("\nWrote death boundary alignment checks:\n")
cat(" - ", checks_file, "\n", sep = "")
cat("\nDeath total checks:\n")
print(death_total_checks, n = Inf)
