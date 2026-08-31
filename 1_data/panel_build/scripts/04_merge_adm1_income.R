# ============================================================
# 04_merge_adm1_income.R
#
# Add ADM1-year income variables to the new country panel
#
# The income file is built separately in 1_cleaning/Income
# Income is matched at the ADM1 or income-region level, not at `admin_id`
# Every admin unit inside the same ADM1 therefore gets the same income value
# Kummu income is added later
#
# Inputs:
#   panel_build/new_countries/new_countries_mortality_climate.csv
#   /project/cil/gcp/estimation/rainfall-mortality/income_data/carleton/output/new_country_income_adm1_year.csv
#
# Merge keys:
#   iso, adm1_id, year
#
# Outputs:
#   panel_build/new_countries/new_country_mortality_climate_income.csv
# ============================================================


# -----------------------------
# Packages
# -----------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

# -----------------------------
# Paths
# -----------------------------

# Set paths relative to the panel_build folder
build_dir <- getwd()
source(file.path(build_dir, "paths.R"))

panel_in <- file.path(new_country_dir, "new_countries_mortality_climate.csv")
panel_out <- file.path(new_country_dir, "new_country_mortality_climate_income.csv")


# -----------------------------
# Income variables
# -----------------------------

income_vars <- c(
  "gdppc_adm0", "gdppc_adm0_13br",
  "loggdppc_adm0", "loggdppc_adm0_13br",
  "gdppc_adm1", "gdppc_adm1_13br", "gdppc_adm1_avg",
  "loggdppc_adm1", "loggdppc_adm1_13br", "loggdppc_adm1_avg"
)

# Annual income variables, excluding the fixed 2005-2014 ADM1 averages used
# for income classification
annual_income_vars <- setdiff(
  income_vars,
  c("gdppc_adm1_avg", "loggdppc_adm1_avg")
)

# Optional variables describing the source of the income estimates
income_flags <- c("income_source_type", "income_basis")

# Add leading zeroes where needed so ADM1 IDs match the panel
adm1_id_width <- c(
  AUS = 1, COL = 2, ECU = 2,
  KOR = 2, PER = 2, PHL = 10
)


# -----------------------------
# Read inputs
# -----------------------------

# Stop here if the climate-merged panel from step 03 is missing
if (!file.exists(panel_in)) {
  stop("Missing panel input. Run 03_merge_climate.R first: ", panel_in, call. = FALSE)
}

# Stop here if the ADM1 income file is missing
if (!file.exists(income_file)) {
  stop("Missing income file: ", income_file, call. = FALSE)
}

# Read the mortality-climate panel from step 03
panel <- read_csv(
  panel_in,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
) %>%
  mutate(
    year = as.integer(year),
    agegroup = as.integer(agegroup),
    deaths = as.numeric(deaths),
    population = as.numeric(population),
    deathrate = as.numeric(deathrate)
  )

# Read the ADM1-year income data
income_raw <- read_csv(
  income_file,
  show_col_types = FALSE,
  col_types = cols(.default = col_character())
)

# Stop here if the income file is missing a variable used below
required_income <- c("iso", "adm1_id", "year", income_vars)
missing_income_cols <- setdiff(required_income, names(income_raw))

if (length(missing_income_cols) > 0) {
  stop(
    "Income file is missing expected columns:\n",
    paste(missing_income_cols, collapse = ", "),
    call. = FALSE
  )
}

# Keep the income source variables if they are available
income_flags <- intersect(income_flags, names(income_raw))

# Keep the required variables and format ADM1 IDs for the merge
income <- income_raw %>%
  select(all_of(c(required_income, income_flags))) %>%
  mutate(
    year = as.integer(year),
    adm1_id = str_pad(as.character(adm1_id), adm1_id_width[iso], pad = "0"),
    across(all_of(income_vars), as.numeric)
  )


# -----------------------------
# Check income keys
# -----------------------------

# There should be only one income row for each country-ADM1-year
duplicate_income <- income %>%
  count(iso, adm1_id, year, name = "rows") %>%
  filter(rows > 1)

if (nrow(duplicate_income) > 0) {
  stop("Income country-ADM1-year IDs are not unique", call. = FALSE)
}

# ADM1-years that need income data
needed <- panel %>%
  distinct(iso, adm1_id, year)

# ADM1-years in the panel with no matching income row
unmatched <- needed %>%
  anti_join(income, by = c("iso", "adm1_id", "year")) %>%
  arrange(iso, adm1_id, year)

if (nrow(unmatched) > 0) {
  stop("Some panel ADM1-years have no income row", call. = FALSE)
}



# -----------------------------
# Merge
# -----------------------------

# Merge ADM1-year income onto the panel. The same income value repeats across
# age groups and admin units within an ADM1
panel_income <- panel %>%
  left_join(income, by = c("iso", "adm1_id", "year"))

# The merge should not change the number of mortality rows
if (nrow(panel_income) != nrow(panel)) {
  stop("Income merge changed the row count.", call. = FALSE)
}



# -----------------------------
# Write outputs
# -----------------------------

dir.create(new_country_dir, recursive = TRUE, showWarnings = FALSE)

# Write the mortality-climate panel with income added
write_csv(panel_income, panel_out)

# Keep a copy of the income file used for this panel build
file.copy(
  income_file,
  file.path(new_country_dir, "new_countries_income.csv"),
  overwrite = TRUE
)

message("Wrote panel file: ", panel_out)
