# ============================================================
# 02_build_mortality_rates.R
#
# Build all-cause mortality rate tables using ADM3-aligned death records and
# annual ADM3 population estimates.
#
# Rates use residence ADM3 and resident population. Deaths must already be
# aligned to the same fixed ADM3 geography as population. Population is used as
# the base table, so ADM3-years with no deaths are kept with zero deaths.
#
# The script produces:
#   - annual and monthly rate tables for the full country
#   - the same rate tables excluding BARMM, with _no_barmm suffixes
#
# Monthly rates use annual population, assuming population is constant within
# each calendar year.
#
# Deaths with unknown age or sex are included whenever those variables are not
# required. Ages 80 and older are grouped together to match the population
# estimates.
#
# The final panel uses the BARMM-excluded ADM3 annual all-age and broad-age
# outputs.
#
# Outputs:
#   Mortality/1_Clean/Death_Rates/*.csv
#   Mortality/1_Clean/Death_Rates/rate_checks.xlsx
# ============================================================

#--------------------------
# Packages
# -------------------------

library(dplyr)
library(purrr)
library(tidyr)
library(writexl)

data.table::setDTthreads(4)


# -----------------------------
# Paths
# -----------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")
source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"))

mortality_file <- file.path(death_records_dir, "PHL_death_records_adm3_aligned.csv")
population_file <- file.path(
  population_interpolated_dir,
  "PHL_population_annual_adm3.csv"
)

dir.create(death_rates_dir, recursive = TRUE, showWarnings = FALSE)
checks_file <- file.path(death_rates_dir, "rate_checks.xlsx")

# -----------------------------
# Age-group definitions
# -----------------------------

age_broad_levels <- c("0-4", "5-64", "65+")

age_standard_levels <- c(
  "0", "1-4", "5-14", "15-24", "25-34", "35-44",
  "45-54", "55-64", "65-74", "75-79", "80+"
)

# Create age-group variables for both deaths and population. Missing ages stay
# missing, so records are excluded only from outputs that require age

add_age_groups <- function(x) {
  x %>%
    mutate(
      # Broad groups for monthly rates
      age_group_broad = as.character(cut(
        age,
        breaks = c(0, 5, 65, 81),
        labels = age_broad_levels,
        right = FALSE
      )),

      # Standard age groups
      age_group_standard = as.character(cut(
        age,
        breaks = c(0, 1, 5, 15, 25, 35, 45, 55, 65, 75, 80, 81),
        labels = age_standard_levels,
        right = FALSE
      ))
    )
}


# -----------------------------
# Rate calculation helpers
# -----------------------------

geo_columns <- c(
  "year", "shp_adm1_code", "shp_adm1_name", "shp_adm2_code",
  "shp_adm2_name", "shp_adm3_code", "shp_adm3_name",
  "psgc_adm3_code", "psgc_adm3_name"
)

# Aggregate population to the required level
aggregate_population <- function(dimensions = character()) {
  population %>%
    group_by(across(all_of(c(geo_columns, dimensions)))) %>%
    summarise(population = sum(population, na.rm = TRUE), .groups = "drop")
}

# Sum deaths at the same level. Most records have weight 1. Boundary-aligned
# records can have fractional weights, matching the population allocation.
aggregate_deaths <- function(x, dimensions = character()) {
  x %>%
    group_by(across(all_of(c("year", "shp_adm3_code", dimensions)))) %>%
    summarise(deaths = sum(death_weight, na.rm = TRUE), .groups = "drop")
}

# Keep population rows with no matching deaths
build_annual_rate <- function(dimensions, death_counts) {
  population_counts <- aggregate_population(dimensions)
  join_columns <- c("year", "shp_adm3_code", dimensions)

  population_counts %>%
    left_join(death_counts, by = join_columns) %>%
    mutate(
      deaths = replace_na(deaths, 0),
      death_rate_per_100000 = if_else(
        population > 0,
        deaths / population * 100000,
        NA
      )
    ) %>%
    arrange(across(all_of(join_columns)))
}

# Sort age groups in numeric order
order_grouped_rate <- function(x, group_column, group_levels, trailing = character()) {
  order_columns <- c("year", "shp_adm3_code", "age_group_order", trailing)

  x %>%
    mutate(age_group_order = match(.data[[group_column]], group_levels)) %>%
    arrange(across(all_of(order_columns))) %>%
    select(-age_group_order)
}


# -----------------------------
# Read and prepare mortality
# -----------------------------

mortality <- data.table::fread(mortality_file,
  select = c("year_file", "date_of_death_month", 
             "sex", "age", "res_shp_adm3_code", "death_weight"),
  colClasses = "character",
  showProgress = TRUE
) %>%
  tibble::as_tibble()

# Read as text, then convert the variables used numerically
mortality <- mortality %>%
  mutate(
    year = suppressWarnings(as.integer(year_file)),
    month = suppressWarnings(as.integer(date_of_death_month)),
    month = if_else(month %in% 1:12, month, NA),
    res_shp_adm3_code = na_if(trimws(res_shp_adm3_code), ""),
    age = suppressWarnings(as.integer(age)),
    age = if_else(!is.na(age) & age >= 80, 80, age),
    death_weight = suppressWarnings(as.numeric(death_weight)),
    death_weight = if_else(is.na(death_weight), 1, death_weight)
  )

# Keep only male/female codes for sex-specific rates.
# Other values stay missing but still count in both-sex totals
mortality <- mortality %>%
  mutate(sex = case_when(
    sex == "1" ~ "male",
    sex == "2" ~ "female",
      TRUE ~ NA
    )
  )

# Rates use residence adm3
mortality <- mortality %>%
  mutate(shp_adm3_code = res_shp_adm3_code) %>%
  add_age_groups()

# Use each death in every output where it can be included
# Records with missing age or sex are excluded only from rates that require that info
mortality <- mortality %>%
  mutate(
    valid_residence = !is.na(year) & !is.na(shp_adm3_code),
    valid_month = valid_residence & !is.na(month),
    valid_age = valid_residence & !is.na(age),
    valid_sex = valid_residence & !is.na(sex),
    valid_age_sex = valid_age & !is.na(sex)
  )

# ----------------------------------
# Read and prepare annual population
# ----------------------------------

population <- data.table::fread(
  population_file,
  select = c("year", "shp_adm1_code", "shp_adm1_name", "shp_adm2_code",
    "shp_adm2_name", "shp_adm3_code", "shp_adm3_name", "psgc_adm3_code",
    "psgc_adm3_name", "age", "sex", "population"),
  colClasses = "character",
  showProgress = TRUE
) %>%
  tibble::as_tibble()

# Read as text to keep codes with leading 0s
population <- population %>%
  mutate(
    year = as.integer(year),
    age = as.integer(age),
    population = as.numeric(population)
  ) %>%
  add_age_groups()

# Check that population is unique at the year-ADM3-age-sex level
duplicate_population_keys <- population %>%
  count(year, shp_adm3_code, age, sex, name = "n_rows") %>%
  filter(n_rows > 1)

if (nrow(duplicate_population_keys) > 0) {
  stop("Population input has duplicate year-ADM3-age-sex keys.")
}


# -------------------------------
# Build annual all-cause rates
# -------------------------------


# All ages
deaths_year_total <- mortality %>%
  filter(valid_residence) %>%
  aggregate_deaths()
adm3_year_total <- build_annual_rate(character(), deaths_year_total)

# All ages by sex
deaths_year_sex <- mortality %>%
  filter(valid_sex) %>%
  aggregate_deaths("sex")
adm3_year_sex <- build_annual_rate("sex", deaths_year_sex)

# By single age and sex
deaths_year_age_sex <- mortality %>%
  filter(valid_age_sex) %>%
  aggregate_deaths(c("age", "sex"))
adm3_year_age_sex <- build_annual_rate(c("age", "sex"), deaths_year_age_sex)

# Broad age groups
deaths_year_age_broad <- mortality %>%
  filter(valid_age) %>%
  aggregate_deaths("age_group_broad")
adm3_year_age_broad <- build_annual_rate("age_group_broad", deaths_year_age_broad)

# By broad age group and sex:
deaths_year_age_broad_sex <- mortality %>%
  filter(valid_age_sex) %>%
  aggregate_deaths(c("age_group_broad", "sex"))
adm3_year_age_broad_sex <- build_annual_rate(c("age_group_broad", "sex"), deaths_year_age_broad_sex)

# Standard age groups
deaths_year_age_standard <- mortality %>%
  filter(valid_age) %>%
  aggregate_deaths("age_group_standard")
adm3_year_age_standard <- build_annual_rate("age_group_standard", deaths_year_age_standard)

# By standard age group and sex:
deaths_year_age_standard_sex <- mortality %>%
  filter(valid_age_sex) %>%
  aggregate_deaths(c("age_group_standard", "sex"))
adm3_year_age_standard_sex <- build_annual_rate(c("age_group_standard", "sex"), deaths_year_age_standard_sex)

# Sort age groups
adm3_year_age_broad <- order_grouped_rate(adm3_year_age_broad, "age_group_broad", age_broad_levels)
adm3_year_age_broad_sex <- order_grouped_rate(adm3_year_age_broad_sex, "age_group_broad", age_broad_levels, "sex")
adm3_year_age_standard <- order_grouped_rate(adm3_year_age_standard, "age_group_standard", age_standard_levels)
adm3_year_age_standard_sex <- order_grouped_rate(adm3_year_age_standard_sex, "age_group_standard", age_standard_levels, "sex")


# -----------------------------
# Build monthly broad-age rates
# -----------------------------

# Use annual population for each month
population_month_broad <- aggregate_population("age_group_broad")

population_month_broad <- population_month_broad %>%
  crossing(month = 1:12)

# Count deaths by month and broad age group
deaths_month_age_broad <- mortality %>%
  filter(valid_month, !is.na(age_group_broad)) %>%
  aggregate_deaths(c("month", "age_group_broad"))

adm3_month_age_broad <- population_month_broad %>%
  left_join(
    deaths_month_age_broad,
    by = c("year", "month", "shp_adm3_code", "age_group_broad")
  ) %>%
  mutate(deaths = replace_na(deaths, 0))

# calculate monthly person-years from the annual population
# february uses 29 days in leap years.
month_days <- c(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
adm3_month_age_broad <- adm3_month_age_broad %>%
  mutate(
    leap_year = year %% 400 == 0 | (year %% 4 == 0 & year %% 100 != 0),
    days_in_year = if_else(leap_year, 366, 365),
    days_in_month = month_days[month],
    days_in_month = if_else(month == 2 & leap_year, 29, days_in_month),
    person_years = population * days_in_month / days_in_year,

    # the first rate is the month's deaths divided by annual population
    # the annualized rate divides by monthly person-time to make months of different
    # lengths comparable
    monthly_deaths_per_100000 = if_else(
      population > 0,
      deaths / population * 100000,
      NA
    ),
    annualized_rate_per_100000_person_years = if_else(
      person_years > 0,
      deaths / person_years * 100000,
      NA
    )
  ) %>%
  # Drop the temporary leap-year flag
  select(-leap_year)

adm3_month_age_broad <- order_grouped_rate(
  adm3_month_age_broad, "age_group_broad", age_broad_levels, "month"
)


# -----------------------------
# Build national rate tables
# -----------------------------

# Aggregate deaths and population before calculating national rates. These
# compact tables are used by the descriptive R Markdown file.
national_year_total <- adm3_year_total %>%
  group_by(year) %>%
  summarise(
    deaths = sum(deaths),
    population = sum(population),
    death_rate_per_100000 = deaths / population * 100000,
    .groups = "drop"
  )

national_year_sex <- adm3_year_sex %>%
  group_by(year, sex) %>%
  summarise(
    deaths = sum(deaths),
    population = sum(population),
    death_rate_per_100000 = deaths / population * 100000,
    .groups = "drop"
  )

national_year_age_broad <- adm3_year_age_broad %>%
  group_by(year, age_group_broad) %>%
  summarise(
    deaths = sum(deaths),
    population = sum(population),
    death_rate_per_100000 = deaths / population * 100000,
    .groups = "drop"
  )

national_year_age_broad_sex <- adm3_year_age_broad_sex %>%
  group_by(year, age_group_broad, sex) %>%
  summarise(
    deaths = sum(deaths),
    population = sum(population),
    death_rate_per_100000 = deaths / population * 100000,
    .groups = "drop"
  )

national_year_age_standard <- adm3_year_age_standard %>%
  group_by(year, age_group_standard) %>%
  summarise(
    deaths = sum(deaths),
    population = sum(population),
    death_rate_per_100000 = deaths / population * 100000,
    .groups = "drop"
  )

national_month_age_broad <- adm3_month_age_broad %>%
  group_by(year, month, age_group_broad) %>%
  summarise(
    deaths = sum(deaths),
    population = sum(population),
    person_years = sum(person_years),
    monthly_deaths_per_100000 = deaths / population * 100000,
    annualized_rate_per_100000_person_years =
      deaths / person_years * 100000,
    .groups = "drop"
  )


# -----------------------------
# Diagnostics and validation
# -----------------------------

# Show how many death records can be used at each level of detail
# Differences are expected when residence, month, age, or sex is missing
death_coverage_by_year <- mortality %>%
  group_by(year) %>%
  summarise(
    deaths_input = sum(death_weight, na.rm = TRUE),
    valid_residence = sum(if_else(valid_residence, death_weight, 0), na.rm = TRUE),
    valid_month = sum(if_else(valid_month, death_weight, 0), na.rm = TRUE),
    valid_age = sum(if_else(valid_age, death_weight, 0), na.rm = TRUE),
    valid_sex = sum(if_else(valid_sex, death_weight, 0), na.rm = TRUE),
    valid_age_sex = sum(if_else(valid_age_sex, death_weight, 0), na.rm = TRUE),
    missing_residence_adm3 = sum(is.na(shp_adm3_code)),
    missing_month = sum(is.na(month)),
    missing_age = sum(is.na(age)),
    missing_or_nonbinary_sex = sum(is.na(sex)),
    .groups = "drop"
  ) %>%
  arrange(year)

# Confirm annual population coverage and totals
population_coverage_by_year <- population %>%
  group_by(year) %>%
  summarise(
    population_rows = n(),
    adm3_units = n_distinct(shp_adm3_code),
    population = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(year)

# Check for residence ADM3-years with deaths but no population
unmatched_residence_units <- mortality %>%
  filter(valid_residence) %>%
  count(year, shp_adm3_code, name = "deaths") %>%
  anti_join(
    population %>% distinct(year, shp_adm3_code),
    by = c("year", "shp_adm3_code")
  ) %>%
  arrange(year, desc(deaths))

# Check for age-sex death counts with no matching population
unmatched_age_sex_cells <- deaths_year_age_sex %>%
  anti_join(
    population %>% distinct(year, shp_adm3_code, age, sex),
    by = c("year", "shp_adm3_code", "age", "sex")
  ) %>%
  arrange(year, shp_adm3_code, age, sex)

# zero-pop cases occur only in detailed age-sex cells
deaths_with_zero_population <- adm3_year_age_sex %>%
  filter(population <= 0, deaths > 0) %>%
  arrange(year, shp_adm3_code, age, sex)

# List outputs and their identifying columns
rate_tables <- list(
  adm3_year_total = adm3_year_total,
  adm3_year_sex = adm3_year_sex,
  adm3_year_age_sex = adm3_year_age_sex,
  adm3_year_age_broad = adm3_year_age_broad,
  adm3_year_age_broad_sex = adm3_year_age_broad_sex,
  adm3_year_age_standard = adm3_year_age_standard,
  adm3_year_age_standard_sex = adm3_year_age_standard_sex,
  adm3_month_age_broad = adm3_month_age_broad,
  national_year_total = national_year_total,
  national_year_sex = national_year_sex,
  national_year_age_broad = national_year_age_broad,
  national_year_age_broad_sex = national_year_age_broad_sex,
  national_year_age_standard = national_year_age_standard,
  national_month_age_broad = national_month_age_broad
)

rate_keys <- list(
  adm3_year_total = c("year", "shp_adm3_code"),
  adm3_year_sex = c("year", "shp_adm3_code", "sex"),
  adm3_year_age_sex = c("year", "shp_adm3_code", "age", "sex"),
  adm3_year_age_broad = c("year", "shp_adm3_code", "age_group_broad"),
  adm3_year_age_broad_sex = c("year", "shp_adm3_code", "age_group_broad", "sex"),
  adm3_year_age_standard = c("year", "shp_adm3_code", "age_group_standard"),
  adm3_year_age_standard_sex = c("year", "shp_adm3_code", "age_group_standard", "sex"),
  adm3_month_age_broad = c("year", "month", "shp_adm3_code", "age_group_broad"),
  national_year_total = "year",
  national_year_sex = c("year", "sex"),
  national_year_age_broad = c("year", "age_group_broad"),
  national_year_age_broad_sex = c("year", "age_group_broad", "sex"),
  national_year_age_standard = c("year", "age_group_standard"),
  national_month_age_broad = c("year", "month", "age_group_broad")
  )


# -----------------------------
# BARMM exclusion
# -----------------------------

# BARMM is dropped from the ADM3 rates used in the final panel
# The full-country rates are still written
barmm_region_name <- "Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)"

# Drop BARMM from tables that carry ADM1 names
drop_barmm_rows <- function(x) {
  if ("shp_adm1_name" %in% names(x)) {
    x %>% filter(is.na(shp_adm1_name) | shp_adm1_name != barmm_region_name)
  } else {
    x
  }
}

# Rebuild national rates after the ADM3 drop
summarise_national_year <- function(x, dimensions = character()) {
  x %>%
    group_by(across(all_of(c("year", dimensions)))) %>%
    summarise(
      deaths = sum(deaths),
      population = sum(population),
      death_rate_per_100000 = deaths / population * 100000,
      .groups = "drop"
    )
}

# Apply the ADM3 drop to every subnational output
adm3_year_total_no_barmm <- drop_barmm_rows(adm3_year_total)
adm3_year_sex_no_barmm <- drop_barmm_rows(adm3_year_sex)
adm3_year_age_sex_no_barmm <- drop_barmm_rows(adm3_year_age_sex)
adm3_year_age_broad_no_barmm <- drop_barmm_rows(adm3_year_age_broad)
adm3_year_age_broad_sex_no_barmm <- drop_barmm_rows(adm3_year_age_broad_sex)
adm3_year_age_standard_no_barmm <- drop_barmm_rows(adm3_year_age_standard)
adm3_year_age_standard_sex_no_barmm <- drop_barmm_rows(adm3_year_age_standard_sex)
adm3_month_age_broad_no_barmm <- drop_barmm_rows(adm3_month_age_broad)

# Recalculate annual national outputs without BARMM
national_year_total_no_barmm <- summarise_national_year(adm3_year_total_no_barmm)
national_year_sex_no_barmm <- summarise_national_year(adm3_year_sex_no_barmm, "sex")
national_year_age_broad_no_barmm <- summarise_national_year(adm3_year_age_broad_no_barmm, "age_group_broad")
national_year_age_broad_sex_no_barmm <- summarise_national_year(adm3_year_age_broad_sex_no_barmm, c("age_group_broad", "sex"))
national_year_age_standard_no_barmm <- summarise_national_year(adm3_year_age_standard_no_barmm, "age_group_standard")

# Recalculate monthly national outputs without BARMM
national_month_age_broad_no_barmm <- adm3_month_age_broad_no_barmm %>%
  group_by(year, month, age_group_broad) %>%
  summarise(
    deaths = sum(deaths),
    population = sum(population),
    person_years = sum(person_years),
    monthly_deaths_per_100000 = deaths / population * 100000,
    annualized_rate_per_100000_person_years =
      deaths / person_years * 100000,
    .groups = "drop"
  )

# Add the no-BARMM tables to the output list
rate_tables_no_barmm <- list(
  adm3_year_total_no_barmm = adm3_year_total_no_barmm,
  adm3_year_sex_no_barmm = adm3_year_sex_no_barmm,
  adm3_year_age_sex_no_barmm = adm3_year_age_sex_no_barmm,
  adm3_year_age_broad_no_barmm = adm3_year_age_broad_no_barmm,
  adm3_year_age_broad_sex_no_barmm = adm3_year_age_broad_sex_no_barmm,
  adm3_year_age_standard_no_barmm = adm3_year_age_standard_no_barmm,
  adm3_year_age_standard_sex_no_barmm = adm3_year_age_standard_sex_no_barmm,
  adm3_month_age_broad_no_barmm = adm3_month_age_broad_no_barmm,
  national_year_total_no_barmm = national_year_total_no_barmm,
  national_year_sex_no_barmm = national_year_sex_no_barmm,
  national_year_age_broad_no_barmm = national_year_age_broad_no_barmm,
  national_year_age_broad_sex_no_barmm = national_year_age_broad_sex_no_barmm,
  national_year_age_standard_no_barmm = national_year_age_standard_no_barmm,
  national_month_age_broad_no_barmm = national_month_age_broad_no_barmm
)

# Use the same key definitions for the `_no_barmm` outputs
rate_keys_no_barmm <- set_names(rate_keys, paste0(names(rate_keys), "_no_barmm"))

# Write both full-country and no-BARMM tables
all_rate_tables <- c(rate_tables, rate_tables_no_barmm)
all_rate_keys <- c(rate_keys, rate_keys_no_barmm)


# -----------------------------
# Output checks
# -----------------------------

# Summarize row counts, death coverage, denominator problems, and key
# uniqueness for every output
output_summary <- imap_dfr(all_rate_tables, function(x, table_name) {
  key_columns <- all_rate_keys[[table_name]]

  x %>%
    summarise(
      rows = n(),
      deaths = sum(deaths, na.rm = TRUE),
      zero_death_rows = sum(deaths == 0, na.rm = TRUE),
      missing_population = sum(is.na(population)),
      nonpositive_population = sum(population <= 0, na.rm = TRUE),
      deaths_with_nonpositive_population = sum(
        if_else(population <= 0, deaths, 0),
        na.rm = TRUE
      )
    ) %>%
    mutate(
      output = table_name,
      duplicate_keys = nrow(x) != nrow(
        x %>% distinct(across(all_of(key_columns)))
      ),
      .before = 1
    )
})

barmm_exclusion_summary <- tibble::tibble(
  metric = c(
    "BARMM ADM3 units excluded",
    "BARMM ADM3-years excluded",
    "BARMM share of ADM3 units",
    "BARMM share of ADM3-years",
    "BARMM share of population over ADM3-years",
    "High-population zero ADM3-years",
    "High-population zero ADM3-years in BARMM",
    "Low-rate ADM3-years below 100 per 100,000",
    "Low-rate ADM3-years below 100 per 100,000 in BARMM"
  ),
  value = c(
    n_distinct(adm3_year_total$shp_adm3_code[
      adm3_year_total$shp_adm1_name == barmm_region_name
    ]),
    sum(adm3_year_total$shp_adm1_name == barmm_region_name),
    n_distinct(adm3_year_total$shp_adm3_code[
      adm3_year_total$shp_adm1_name == barmm_region_name
    ]) / n_distinct(adm3_year_total$shp_adm3_code),
    mean(adm3_year_total$shp_adm1_name == barmm_region_name),
    sum(
      adm3_year_total$population[
        adm3_year_total$shp_adm1_name == barmm_region_name
      ],
      na.rm = TRUE
    ) / sum(adm3_year_total$population, na.rm = TRUE),
    sum(adm3_year_total$population >= 10000 & adm3_year_total$deaths == 0, na.rm = TRUE),
    sum(
      adm3_year_total$shp_adm1_name == barmm_region_name &
        adm3_year_total$population >= 10000 &
        adm3_year_total$deaths == 0,
      na.rm = TRUE
    ),
    sum(adm3_year_total$death_rate_per_100000 < 100, na.rm = TRUE),
    sum(
      adm3_year_total$shp_adm1_name == barmm_region_name &
        adm3_year_total$death_rate_per_100000 < 100,
      na.rm = TRUE
    )
  )
)

# Stop before writing outputs if checks fail
if (any(output_summary$duplicate_keys)) {
  stop("At least one mortality-rate output has duplicate keys.")
}

if (any(output_summary$missing_population > 0)) {
  stop("At least one mortality-rate output has missing population.")
}

if (any(output_summary$deaths_with_nonpositive_population > 0)) {
  # This warning applies only to detailed age-sex cells, not ADM3-year totals.
  warning(
    "Some detailed death cells have zero population. ",
    "Their rates remain missing; see Deaths With Zero Population in rate_checks.xlsx."
  )
}

if (nrow(unmatched_residence_units) > 0) {
  stop("Some residence ADM3-year death counts do not match the population data.")
}

if (nrow(unmatched_age_sex_cells) > 0) {
  stop("Some residence ADM3-year-age-sex death counts do not match population cells.")
}


# -----------------------------
# Write outputs
# -----------------------------

# Use the output names as CSV filename
output_files <- set_names(
  file.path(death_rates_dir, paste0(names(all_rate_tables), ".csv")),
  names(all_rate_tables)
)

iwalk(all_rate_tables, ~ data.table::fwrite(.x, output_files[[.y]]))

# Write checks to one workbook
write_xlsx(
  list(
    "Output Summary" = output_summary,
    "Death Coverage By Year" = death_coverage_by_year,
    "Population Coverage By Year" = population_coverage_by_year,
    "BARMM Exclusion Summary" = barmm_exclusion_summary,
    "Unmatched Residence Units" = unmatched_residence_units,
    "Unmatched Age Sex Cells" = unmatched_age_sex_cells,
    "Deaths With Zero Population" = deaths_with_zero_population
  ),
  checks_file
)
