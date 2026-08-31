# ============================================================
# 03_interpolate_population.R
#
# Scripts 01 and 02 produce population by age, sex, and current ADM3 for
# the 2007, 2010, 2015, and 2020 census years
#
# This script interpolates annual population denominators for 2006-2024
#
# ADM3 totals and age-sex shares are handled separately:
#   - ADM3 totals are linearly interpolated between census years and the
#     official 2024 totals; the 2007-2010 trend is extended back to 2006
#   - age-sex shares are interpolated only between census years
#   - 2006 uses the observed 2007 age-sex shares
#   - 2021-2024 use the observed 2020 age-sex shares
#
# This means 2024 uses the official municipality/city total together with
# the observed 2020 age-sex distribution. Public 2024 age-sex data are not
# available, so this avoids extrapolating age-sex trends past 2020
#
# Population is kept fractional because these values are mortality-rate
# denominators and should preserve the interpolated ADM3 totals exactly
#
# Main output:
#   Population/2_Interpolated/PHL_population_annual_adm3.csv
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

dir.create(population_interpolated_dir, recursive = TRUE, showWarnings = FALSE)

census_file <- file.path(population_clean_dir, "census_pop_final.csv")
annual_file <- file.path(population_interpolated_dir, "PHL_population_annual_adm3.csv")
checks_file <- file.path(population_interpolated_dir, "interpolation_checks.xlsx")
psgc_file <- file.path(admin_geocodes_clean_dir, "psgc_adm_codes.csv")


# -----------------------------
# Census population and 2024 totals
# -----------------------------

# Read codes as text so leading zeros are preserved
pop_census <- read_csv(
  census_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    census_year = as.integer(census_year),
    shp_adm1_code, shp_adm1_name, shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name, psgc_adm3_code, psgc_adm3_name,
    age = as.integer(age), age_group, sex,
    population = as.numeric(population)
  )

# Official 2024 municipality/city population totals
psgc_2024_pop <- read_csv(
  psgc_file, show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    psgc_adm3_code = municipalicity_code,
    psgc_adm3_name_2024 = municipalicity_name,
    population_total_2024 = parse_number(municipalicity_2024_pop)
  ) %>%
  filter(!is.na(psgc_adm3_code))


# -----------------------------
# ADM3 and age-sex coverage
# -----------------------------

census_years <- c(2007, 2010, 2015, 2020)
annual_years <- 2006:2024

# Use the 2020 geography as the fixed ADM3 set for the annual output
current_adm3 <- pop_census %>%
  filter(census_year == 2020) %>%
  distinct(
    shp_adm1_code, shp_adm1_name, shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name, psgc_adm3_code, psgc_adm3_name
  ) %>%
  arrange(shp_adm3_code)

# Age-sex cells expected for every ADM3-year
age_sex_grid <- pop_census %>%
  distinct(age, age_group, sex) %>%
  arrange(age, sex)

duplicate_census_keys <- pop_census %>%
  count(census_year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(n_rows > 1)


# -----------------------------
# Missing census cells
# -----------------------------

# Some census files omit cells with zero population
# Add those cells explicitly before calculating shares
missing_census_cells <- tidyr::crossing(
  census_year = census_years, current_adm3, age_sex_grid
) %>%
  anti_join(
    pop_census %>% distinct(census_year, shp_adm3_code, age, sex),
    by = c("census_year", "shp_adm3_code", "age", "sex")
  ) %>%
  arrange(census_year, shp_adm3_code, age, sex)

pop_census <- tidyr::crossing(
  census_year = census_years, current_adm3, age_sex_grid
) %>%
  left_join(
    pop_census %>% select(census_year, shp_adm3_code, age, sex, population),
    by = c("census_year", "shp_adm3_code", "age", "sex")
  ) %>%
  mutate(population = replace_na(population, 0)) %>%
  arrange(census_year, shp_adm3_code, age, sex)


# -----------------------------
# 2024 ADM3 totals
# -----------------------------

# Match the current ADM3 units to their official 2024 population totals
pop_2024_controls <- current_adm3 %>%
  left_join(psgc_2024_pop, by = "psgc_adm3_code")

missing_2024_controls <- pop_2024_controls %>%
  filter(is.na(population_total_2024))

if (nrow(missing_2024_controls) > 0) {
  stop("At least one current ADM3 unit is missing a 2024 total population control.")
}


# -----------------------------
# Census totals and age-sex shares
# -----------------------------

# ADM3 total population in each census year
census_totals <- pop_census %>%
  group_by(census_year, shp_adm3_code) %>%
  summarise(population_total = sum(population, na.rm = TRUE), .groups = "drop")

# Age-sex shares within each ADM3 census total
census_shares <- pop_census %>%
  left_join(census_totals, by = c("census_year", "shp_adm3_code")) %>%
  mutate(age_sex_share = if_else(population_total > 0, population / population_total, 0)) %>%
  select(census_year, shp_adm3_code, age, sex, age_sex_share)

# Total-population points used for interpolation
# The 2024 control has no age-sex detail
total_points <- bind_rows(
  census_totals,
  pop_2024_controls %>%
    transmute(
      census_year = 2024, shp_adm3_code,
      population_total = population_total_2024
    )
)


# -----------------------------
# Annual ADM3 totals
# -----------------------------

# Interpolate totals between census years and the 2024 control
# For 2006, extend the 2007-2010 trend backward by one year
annual_totals <- tidyr::crossing(
  year = annual_years,
  current_adm3 %>% select(shp_adm3_code)
) %>%
  mutate(
    total_start_year = case_when(
      year <= 2010 ~ 2007,
      year <= 2015 ~ 2010,
      year <= 2020 ~ 2015,
      TRUE ~ 2020
    ),
    total_end_year = case_when(
      year <= 2010 ~ 2010,
      year <= 2015 ~ 2015,
      year <= 2020 ~ 2020,
      TRUE ~ 2024
    )
  ) %>%
  left_join(
    total_points %>%
      rename(total_start_year = census_year,
             population_total_start = population_total),
    by = c("shp_adm3_code", "total_start_year")
  ) %>%
  left_join(
    total_points %>%
      rename(total_end_year = census_year,
             population_total_end = population_total),
    by = c("shp_adm3_code", "total_end_year")
  ) %>%
  mutate(
    total_t = (year - total_start_year) / (total_end_year - total_start_year),
    population_total_raw = population_total_start +
      total_t * (population_total_end - population_total_start),
    
    # A backward projection to 2006 could theoretically go slightly below zero
    population_total = pmax(population_total_raw, 0)
  )


# -----------------------------
# Annual age-sex shares
# -----------------------------

# Interpolate shares only within the observed census period
# 2006 uses 2007 shares and 2021-2024 use 2020 shares
annual_share_rows <- tidyr::crossing(
  year = annual_years,
  current_adm3 %>% select(shp_adm3_code),
  age_sex_grid
) %>%
  mutate(
    share_start_year = case_when(
      year == 2006 ~ 2007,
      year <= 2010 ~ 2007,
      year <= 2015 ~ 2010,
      year <= 2020 ~ 2015,
      TRUE ~ 2020
    ),
    share_end_year = case_when(
      year == 2006 ~ 2007,
      year <= 2010 ~ 2010,
      year <= 2015 ~ 2015,
      year <= 2020 ~ 2020,
      TRUE ~ 2020
    )
  ) %>%
  left_join(
    census_shares %>%
      rename(share_start_year = census_year,
             age_sex_share_start = age_sex_share),
    by = c("shp_adm3_code", "age", "sex", "share_start_year")
  ) %>%
  left_join(
    census_shares %>%
      rename(share_end_year = census_year,
             age_sex_share_end = age_sex_share),
    by = c("shp_adm3_code", "age", "sex", "share_end_year")
  ) %>%
  mutate(
    # When start and end are the same, keep the observed census share
    share_t = if_else(
      share_start_year == share_end_year, 0,
      (year - share_start_year) / (share_end_year - share_start_year)
    ),
    age_sex_share_raw = age_sex_share_start +
      share_t * (age_sex_share_end - age_sex_share_start),
    share_method = case_when(
      year == 2006 ~ "hold_2007_shares",
      year %in% census_years ~ "census_year_shares",
      year <= 2020 ~ "interpolate_census_shares",
      TRUE ~ "hold_2020_shares"
    )
  )

# Missing inputs mean one of the expected census shares was not found
missing_share_inputs <- annual_share_rows %>%
  filter(is.na(age_sex_share_start) | is.na(age_sex_share_end))

if (nrow(missing_share_inputs) > 0) {
  stop("At least one annual age-sex row is missing start/end share inputs.")
}

# Allow tiny floating-point noise but stop on genuinely negative shares
negative_share_rows <- annual_share_rows %>%
  filter(age_sex_share_raw < -1e-12) %>%
  select(
    year, shp_adm3_code, age, sex,
    share_start_year, share_end_year, share_t,
    age_sex_share_start, age_sex_share_end, age_sex_share_raw
  )

if (nrow(negative_share_rows) > 0) {
  stop("At least one annual age-sex share is negative.")
}

annual_shares <- annual_share_rows %>%
  mutate(age_sex_share = age_sex_share_raw)

# Shares should sum to one within every ADM3-year
bad_share_sums <- annual_shares %>%
  group_by(year, shp_adm3_code) %>%
  summarise(share_sum = sum(age_sex_share, na.rm = TRUE), .groups = "drop") %>%
  mutate(share_sum_error = abs(share_sum - 1)) %>%
  filter(share_sum_error > 1e-8)

if (nrow(bad_share_sums) > 0) {
  stop("At least one ADM3-year age-sex share distribution does not sum to 1.")
}


# -----------------------------
# Build annual population
# -----------------------------

# Combine each ADM3 total with its interpolated age-sex shares
pop_annual <- annual_shares %>%
  left_join(
    annual_totals %>%
      select(year, shp_adm3_code, population_total,
             total_start_year, total_end_year, total_t),
    by = c("year", "shp_adm3_code")
  ) %>%
  left_join(current_adm3, by = "shp_adm3_code") %>%
  transmute(
    year, shp_adm1_code, shp_adm1_name, shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name, psgc_adm3_code, psgc_adm3_name,
    age, age_group, sex,
    population = population_total * age_sex_share,
    population_total_adm3 = population_total,
    age_sex_share,
    interpolation_method = case_when(
      year == 2006 ~ "2007_shares_with_2006_total",
      year %in% census_years ~ "census_year",
      year <= 2020 ~ "between_census_years",
      TRUE ~ "2020_shares_with_2024_total_control"
    ),
    total_start_year, total_end_year, total_t,
    share_start_year, share_end_year, share_t, share_method
  ) %>%
  arrange(year, shp_adm3_code, age, sex)


# -----------------------------
# Output checks
# -----------------------------

# Duplicate year-ADM3-age-sex rows
duplicate_final_keys <- pop_annual %>%
  count(year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(n_rows > 1) %>%
  arrange(year, shp_adm3_code, age, sex)

# ADM3 coverage by year
coverage_by_year <- pop_annual %>%
  distinct(year, shp_adm3_code) %>%
  count(year, name = "n_shp_adm3") %>%
  mutate(
    target_shp_adm3 = nrow(current_adm3),
    n_missing_shp_adm3 = target_shp_adm3 - n_shp_adm3
  ) %>%
  arrange(year)

# Full ADM3 × age × sex coverage by year
cell_coverage_by_year <- pop_annual %>%
  count(year, name = "n_age_sex_adm3_cells") %>%
  mutate(
    expected_cells = nrow(current_adm3) * nrow(age_sex_grid),
    missing_cells = expected_cells - n_age_sex_adm3_cells
  ) %>%
  arrange(year)

# Missing or negative final population values
negative_or_missing_population <- pop_annual %>%
  filter(is.na(population) | population < 0) %>%
  select(year, shp_adm3_code, age, sex, population)

# Census years should reproduce the cleaned census counts
census_reproduction_summary <- pop_annual %>%
  filter(year %in% census_years) %>%
  select(year, shp_adm3_code, age, sex,
         population_interpolated = population) %>%
  left_join(
    pop_census %>%
      transmute(
        year = census_year, shp_adm3_code, age, sex,
        population_census = population
      ),
    by = c("year", "shp_adm3_code", "age", "sex")
  ) %>%
  mutate(abs_difference = abs(population_interpolated - population_census)) %>%
  summarise(
    max_abs_difference = max(abs_difference, na.rm = TRUE),
    n_rows_over_tolerance = sum(abs_difference > 1e-7, na.rm = TRUE),
    .groups = "drop"
  )

# 2024 age-sex cells must sum back to the official ADM3 totals
control_2024_summary <- pop_annual %>%
  filter(year == 2024) %>%
  group_by(psgc_adm3_code) %>%
  summarise(population_interpolated = sum(population, na.rm = TRUE), .groups = "drop") %>%
  left_join(
    psgc_2024_pop %>% select(psgc_adm3_code, population_total_2024),
    by = "psgc_adm3_code"
  ) %>%
  mutate(abs_difference = abs(population_interpolated - population_total_2024)) %>%
  summarise(
    max_abs_difference = max(abs_difference, na.rm = TRUE),
    n_rows_over_tolerance = sum(abs_difference > 1e-6, na.rm = TRUE),
    .groups = "drop"
  )

# Number of ADM3s using each share method by year
share_method_summary <- pop_annual %>%
  distinct(year, shp_adm3_code, share_method) %>%
  count(year, share_method, name = "n_adm3") %>%
  arrange(year)

# Zero-population cells are valid but useful to track before merging mortality
zero_population_summary <- pop_annual %>%
  filter(population == 0) %>%
  count(year, name = "n_zero_population_cells") %>%
  arrange(year)

# National annual totals by sex and overall
year_sex_totals <- pop_annual %>%
  group_by(year, sex) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(year, sex)

year_totals <- pop_annual %>%
  group_by(year) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(year)

# One-row summary of the main checks
check_summary <- tibble(
  check = c(
    "duplicate_year_adm3_age_sex_keys",
    "years_missing_adm3",
    "years_missing_age_sex_cells",
    "negative_or_missing_population_rows",
    "missing_census_cells_filled_zero",
    "max_census_reproduction_difference",
    "census_reproduction_rows_over_tolerance",
    "max_2024_control_difference",
    "2024_control_rows_over_tolerance",
    "negative_age_sex_share_rows",
    "zero_population_rows"
  ),
  value = c(
    nrow(duplicate_final_keys),
    sum(coverage_by_year$n_missing_shp_adm3 != 0),
    sum(cell_coverage_by_year$missing_cells != 0),
    nrow(negative_or_missing_population),
    nrow(missing_census_cells),
    census_reproduction_summary$max_abs_difference,
    census_reproduction_summary$n_rows_over_tolerance,
    control_2024_summary$max_abs_difference,
    control_2024_summary$n_rows_over_tolerance,
    nrow(negative_share_rows),
    sum(zero_population_summary$n_zero_population_cells, na.rm = TRUE)
  )
)

# Save the diagnostic tables in one workbook
checks_for_excel <- list(
  "Check Summary" = check_summary,
  "ADM3 Coverage" = coverage_by_year,
  "Age Sex Cell Coverage" = cell_coverage_by_year,
  "National Year Totals" = year_totals,
  "National Year Sex Totals" = year_sex_totals,
  "Share Methods" = share_method_summary,
  "Zero Population Cells" = zero_population_summary,
  "Negative Share Check" = negative_share_rows,
  "Duplicate Key Check" = duplicate_final_keys,
  "Negative Missing Pop" = negative_or_missing_population
)

writexl::write_xlsx(checks_for_excel, checks_file)


# -----------------------------
# Final checks and output
# -----------------------------

if (nrow(duplicate_final_keys) > 0) {
  stop("Annual population output has duplicate year-ADM3-age-sex rows")
}

if (any(coverage_by_year$n_missing_shp_adm3 != 0)) {
  stop("At least one annual year is missing current ADM3 units")
}

if (any(cell_coverage_by_year$missing_cells != 0)) {
  stop("At least one annual year is missing ADM3-age-sex cells")
}

if (nrow(negative_or_missing_population) > 0) {
  stop("Annual population output has negative or missing population cells")
}

if (census_reproduction_summary$n_rows_over_tolerance > 0) {
  stop("Annual interpolation does not reproduce one or more census-year age-sex cells")
}

if (control_2024_summary$n_rows_over_tolerance > 0) {
  stop("Annual interpolation does not reproduce one or more 2024 ADM3 total controls")
}

# Write the annual file only after the main checks pass
write_csv(pop_annual, annual_file)


# -----------------------------
# Summary
# -----------------------------

cat("\nWrote annual population file:\n")
cat(" - ", annual_file, "\n", sep = "")

cat("\nCheck summary:\n")
print(check_summary, n = Inf)

cat("\nCoverage by year:\n")
print(coverage_by_year, n = Inf)

cat("\nCell coverage by year:\n")
print(cell_coverage_by_year, n = Inf)

cat("\nNational annual totals:\n")
print(year_totals, n = Inf)
