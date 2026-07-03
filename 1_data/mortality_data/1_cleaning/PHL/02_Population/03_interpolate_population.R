# ============================================================
# 03_interpolate_population.R
#
# Scripts 01 and 02 produced cleaned population by age, sex, and current ADM3
# for census years:
#   2007, 2010, 2015, 2020
#
# This script turns those census-year files into annual population denominators
# for 2006-2024.
#
# Method:
#   - ADM3 total population is interpolated separately from age-sex shares
#   - ADM3 totals use linear interpolation between census years and the
#     official 2024 population totals. The 2007-2010 total trend is extended
#     back one year to 2006
#   - Age-sex shares are linearly interpolated only between census years.
#   - 2006 uses the observed 2007 age-sex distribution
#   - 2021-2024 use the observed 2020 age-sex distribution
#
# As a result, 2024 uses the official municipality/city total population
# together with the observed 2020 age-sex distribution because public
# 2024 age-sex data are not available. Using the 2020 shares avoids
# extrapolating age-sex trends beyond the observed census period
#
# The output keeps fractional population. This is appropriate because these
# are denominators for death rates, and preserving exact totals is more
# important than integer counts
#
# Main output:
#   Population/2_Interpolated/PHL_population_annual_adm3.csv
# ============================================================



# ------------------------------------
#   0. Set-Up
# ------------------------------------



# ----------- Packages -----------

  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
  library(writexl)


# ----------- Paths -----------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/PHL/paths.R"))

dir.create(population_interpolated_dir, recursive = TRUE, showWarnings = FALSE)

census_file <- file.path(population_clean_dir, "census_pop_final.csv")
annual_file <- file.path(population_interpolated_dir, "PHL_population_annual_adm3.csv")
checks_file <- file.path(population_interpolated_dir, "interpolation_checks.xlsx")

psgc_file <- file.path(admin_geocodes_clean_dir, "psgc_adm_codes.csv")


# ------------------------------------
# 1. Read census years and 2024 totals
# ------------------------------------

# Read codes as text so leading zeros are preserved
# Convert year, age, and population after reading
pop_census <- read_csv(
  census_file,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    census_year = as.integer(census_year),
    shp_adm1_code, shp_adm1_name, shp_adm2_code,
    shp_adm2_name, shp_adm3_code, shp_adm3_name,
    psgc_adm3_code,psgc_adm3_name,
    age = as.integer(age),
    age_group, sex,
    population = as.numeric(population)
    )

psgc_2024_pop <- read_csv(
  psgc_file,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  transmute(
    psgc_adm3_code = municipalicity_code,
    psgc_adm3_name_2024 = municipalicity_name,
    population_total_2024 = parse_number(municipalicity_2024_pop)
  ) %>%
  # Keep only rows with municipality/city codes
  filter(!is.na(psgc_adm3_code))


# -----------------------------
# 2. Basic checks
# -----------------------------

census_years <- c(2007, 2010, 2015, 2020)
annual_years <- 2006:2024

current_adm3 <- pop_census %>%
  # Use 2020 as the current ADM3 set for the annual output
  filter(census_year == 2020) %>%
  distinct(
    shp_adm1_code, shp_adm1_name,
    shp_adm2_code, shp_adm2_name,
    shp_adm3_code, shp_adm3_name,
    psgc_adm3_code, psgc_adm3_name
  ) %>%
  arrange(shp_adm3_code)

age_sex_grid <- pop_census %>%
  # Age-sex cells expected for every ADM3-year
  distinct(age, age_group, sex) %>%
  arrange(age, sex)

duplicate_census_keys <- pop_census %>%
  count(census_year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(n_rows > 1)


# ----------------------------------
# 3. Fill missing census cells
# ----------------------------------

# Some census files omit zero-count cells
# Treat those as real zeros before interpolation
# and keep the list of inserted cells for diagnostics
missing_census_cells <- tidyr::crossing(
  census_year = census_years,
  current_adm3,
  age_sex_grid
) %>%
  anti_join(
    pop_census %>%
      distinct(census_year, shp_adm3_code, age, sex),
    by = c("census_year", "shp_adm3_code", "age", "sex")
  ) %>%
  arrange(census_year, shp_adm3_code, age, sex)

pop_census <- tidyr::crossing(
  census_year = census_years,
  current_adm3,
  age_sex_grid
) %>%
  left_join(
    pop_census %>%
      select(census_year, shp_adm3_code, age, sex, population),
    by = c("census_year", "shp_adm3_code", "age", "sex")
  ) %>%
  # Fill omitted census cells with zero so every ADM3-year uses the same
  # age-sex grid before shares are calculated
  mutate(population = replace_na(population, 0)) %>%
  arrange(census_year, shp_adm3_code, age, sex)


# --------------------------------
# 4. Add official 2024 ADM3 totals
# --------------------------------

pop_2024_controls <- current_adm3 %>%
  # Join through the cleaned PSGC code retained from Script 02
  left_join(psgc_2024_pop, by = "psgc_adm3_code")

missing_2024_controls <- pop_2024_controls %>%
  filter(is.na(population_total_2024))

if (nrow(missing_2024_controls) > 0) {
  stop("At least one current ADM3 unit is missing a 2024 total population control.")
}


# -------------------------------------------
# 5. Build census totals and age-sex shares
# -------------------------------------------

census_totals <- pop_census %>%
  # Sum age-sex cells to get the ADM3 total for each census year
  group_by(census_year, shp_adm3_code) %>%
  summarise(population_total = sum(population, na.rm = TRUE), .groups = "drop")

census_shares <- pop_census %>%
  # Convert age-sex counts to shares of the ADM3 census total
  left_join(census_totals, by = c("census_year", "shp_adm3_code")) %>%
  mutate(age_sex_share = if_else(population_total > 0, population / population_total, 0)) %>%
  select(census_year, shp_adm3_code, age, sex, age_sex_share)

total_points <- bind_rows(
  # Total-population values used for interpolation: census totals plus the 
  # official 2024 municipality/city totals. The 2024 totals have no age-sex detail
  census_totals,
  pop_2024_controls %>%
    transmute(
      census_year = 2024,
      shp_adm3_code,
      population_total = population_total_2024
    )
)


# -------------------------------------------
# 6. Interpolate annual ADM3 total population
# -------------------------------------------

# Interpolate ADM3 totals between census years and the official 2024 totals
# For 2006, extend the 2007-2010 trend back one year.
annual_totals <- tidyr::crossing(
  # Start with every year-ADM3 pair so missing total-population inputs show up after the joins
  year = annual_years,
  current_adm3 %>% select(shp_adm3_code)
) %>%
  mutate(
    # Pick the start and end years used to interpolate each annual total
    # For 2006, use the 2007-2010 segment and extend it backward
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
      rename(total_start_year = census_year, population_total_start = population_total),
    by = c("shp_adm3_code", "total_start_year")
  ) %>%
  left_join(
    total_points %>%
      rename(total_end_year = census_year, population_total_end = population_total),
    by = c("shp_adm3_code", "total_end_year")
  ) %>%
  mutate(
    # Interpolate between the start and end totals
    # Clip only the ADM3 total at zero in case the 2006 backcast goes negative
    total_t = (year - total_start_year) / (total_end_year - total_start_year),
    population_total_raw = population_total_start +
      total_t * (population_total_end - population_total_start),
    population_total = pmax(population_total_raw, 0)
  )


# ----------------------------------
# 7. Interpolate annual age-sex shares
# ----------------------------------

# Age-sex shares come only from the four census years. Interpolate shares 
# between census years, but do not extrapolate them outside the census range: 
# 
#   2006: use 2007 age-sex shares 
#   2021-2024: use 2020 age-sex shares 
# 
# This avoids extrapolating small shares below zero. 
# ADM3 totals are still interpolated annually and controlled to the official 2024 totals

annual_share_rows <- tidyr::crossing(
  # Start with every year-ADM3-age-sex row so missing share inputs show up after the joins
  year = annual_years,
  current_adm3 %>% select(shp_adm3_code),
  age_sex_grid
) %>%
  mutate(
    # Pick the census years used for each share. For 2006 and 2021-2024, 
    # start and end are the same so the nearest observed shares are copied
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
      rename(share_start_year = census_year, age_sex_share_start = age_sex_share),
    by = c("shp_adm3_code", "age", "sex", "share_start_year")
  ) %>%
  left_join(
    census_shares %>%
      rename(share_end_year = census_year, age_sex_share_end = age_sex_share),
    by = c("shp_adm3_code", "age", "sex", "share_end_year")
  ) %>%
  mutate(
    # If start and end are the same, copy that census-year share
    # Otherwise, linearly interpolate between the two census years
    share_t = if_else(
      share_start_year == share_end_year,
      0,
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

missing_share_inputs <- annual_share_rows %>%
  # Missing share inputs mean a census cell was not found.
  filter(is.na(age_sex_share_start) | is.na(age_sex_share_end))

if (nrow(missing_share_inputs) > 0) {
  stop("At least one annual age-sex row is missing start/end share inputs.")
}

negative_share_rows <- annual_share_rows %>%
  # Allow tiny floating-point noise, but stop on real negative shares
  filter(age_sex_share_raw < -1e-12) %>%
  select(
    year,
    shp_adm3_code,
    age,
    sex,
    share_start_year,
    share_end_year,
    share_t,
    age_sex_share_start,
    age_sex_share_end,
    age_sex_share_raw
  )

if (nrow(negative_share_rows) > 0) {
  stop("At least one annual age-sex share is negative.")
}

annual_shares <- annual_share_rows %>%
  mutate(age_sex_share = age_sex_share_raw)

bad_share_sums <- annual_shares %>%
  # Age-sex shares should sum to one within each ADM3-year
  group_by(year, shp_adm3_code) %>%
  summarise(share_sum = sum(age_sex_share, na.rm = TRUE), .groups = "drop") %>%
  mutate(share_sum_error = abs(share_sum - 1)) %>%
  filter(share_sum_error > 1e-8)

if (nrow(bad_share_sums) > 0) {
  stop("At least one ADM3-year age-sex share distribution does not sum to 1.")
}


# -----------------------------
# 8. Build annual population
# -----------------------------

pop_annual <- annual_shares %>%
  # Combine the interpolated ADM3 totals and age-sex shares to # produce annual population counts
  left_join(
    annual_totals %>%
      select(
        year, shp_adm3_code,
        population_total,
        total_start_year,
        total_end_year,
        total_t
      ),
    by = c("year", "shp_adm3_code")
  ) %>%
  left_join(current_adm3, by = "shp_adm3_code") %>%
  transmute( year, shp_adm1_code, shp_adm1_name,
    shp_adm2_code, shp_adm2_name, shp_adm3_code,
    shp_adm3_name, psgc_adm3_code, psgc_adm3_name,
    age, age_group, sex,
    population = population_total * age_sex_share,
    population_total_adm3 = population_total,
    age_sex_share,
    interpolation_method = case_when(
      # Record how each annual estimate was constructed:
      year == 2006 ~ "2007_shares_with_2006_total",
      year %in% census_years ~ "census_year",
      year <= 2020 ~ "between_census_years",
      TRUE ~ "2020_shares_with_2024_total_control"
    ),
    total_start_year, total_end_year,
    total_t, share_start_year, share_end_year,
    share_t, share_method) %>%
  arrange(year, shp_adm3_code, age, sex)


# -----------------------------
#           9. Checks
# -----------------------------

# Build the diagnostic tables before running the final stop checks:
duplicate_final_keys <- pop_annual %>%
  count(year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(n_rows > 1) %>%
  arrange(year, shp_adm3_code, age, sex)

coverage_by_year <- pop_annual %>%
  distinct(year, shp_adm3_code) %>%
  count(year, name = "n_shp_adm3") %>%
  mutate(
    target_shp_adm3 = nrow(current_adm3),
    n_missing_shp_adm3 = target_shp_adm3 - n_shp_adm3
  ) %>%
  arrange(year)

cell_coverage_by_year <- pop_annual %>%
  count(year, name = "n_age_sex_adm3_cells") %>%
  mutate(
    expected_cells = nrow(current_adm3) * nrow(age_sex_grid),
    missing_cells = expected_cells - n_age_sex_adm3_cells
  ) %>%
  arrange(year)

negative_or_missing_population <- pop_annual %>%
  filter(is.na(population) | population < 0) %>%
  select(year, shp_adm3_code, age, sex, population)

census_reproduction_summary <- pop_annual %>%
  # Census years should reproduce the cleaned census counts
  # aside from tiny floating-point differences
  filter(year %in% census_years) %>%
  select(year, shp_adm3_code, age, sex, population_interpolated = population) %>%
  left_join(
    pop_census %>%
      transmute(
        year = census_year,
        shp_adm3_code,
        age,
        sex,
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

control_2024_summary <- pop_annual %>%
  # 2024 uses 2020 age-sex shares, but must still sum to # the official 2024 ADM3 totals
  filter(year == 2024) %>%
  group_by(psgc_adm3_code) %>%
  summarise(population_interpolated = sum(population, na.rm = TRUE), .groups = "drop") %>%
  left_join(
    psgc_2024_pop %>%
      select(psgc_adm3_code, population_total_2024),
    by = "psgc_adm3_code"
  ) %>%
  mutate(abs_difference = abs(population_interpolated - population_total_2024)) %>%
  summarise(
    max_abs_difference = max(abs_difference, na.rm = TRUE),
    n_rows_over_tolerance = sum(abs_difference > 1e-6, na.rm = TRUE),
    .groups = "drop"
  )

share_method_summary <- pop_annual %>%
  distinct(year, shp_adm3_code, share_method) %>%
  count(year, share_method, name = "n_adm3") %>%
  arrange(year)

zero_population_summary <- pop_annual %>%
  # Zero-population cells are valid, but useful to flag before merging deaths
  filter(population == 0) %>%
  count(year, name = "n_zero_population_cells") %>%
  arrange(year)

year_sex_totals <- pop_annual %>%
  # National totals by sex, for a quick check of annual trends
  group_by(year, sex) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(year, sex)

year_totals <- pop_annual %>%
  group_by(year) %>%
  summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
  arrange(year)

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

checks_for_excel <- list(
  # Keep diagnostics in one excel workbook:
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
# 10. Validate output
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

# Write the final file only after all checks pass
write_csv(pop_annual, annual_file)


# -----------------------------
# Print summary
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
