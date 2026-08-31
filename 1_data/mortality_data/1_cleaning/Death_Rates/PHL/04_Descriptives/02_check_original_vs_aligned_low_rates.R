# ============================================================
# 02_check_original_vs_aligned_low_rates.R
#
# Check whether high-population zero-death cells were already present before
# death records were aligned to the fixed ADM3 geography
#
# Output:
#   Country_Descriptives/PHL/phl_low_rate_investigation/
#   phl_original_vs_aligned_low_rates.xlsx
# ============================================================

library(data.table)
library(writexl)


# -------------------------
# Paths
# -------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])
repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") repo_dir <- file.path("/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026")

source(file.path(repo_dir, "1_data/mortality_data/1_cleaning/Death_Rates/PHL/paths.R"))

out_dir <- file.path(repo_dir,
                     "1_data/mortality_data/1_cleaning/Country_Descriptives/PHL/phl_low_rate_investigation")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

raw_death_file <- file.path(death_records_dir, "PHL_death_records.csv")
aligned_death_file <- file.path(death_records_dir, "PHL_death_records_adm3_aligned.csv")
pop_file <- file.path(population_interpolated_dir, "PHL_population_annual_adm3.csv")
rate_file <- file.path(death_rates_dir, "adm3_year_total.csv")
out_file <- file.path(out_dir, "phl_original_vs_aligned_low_rates.xlsx")


# -------------------------
# Population and current rates
# -------------------------

# Annual ADM3 population
pop <- fread(
  pop_file,
  select = c("year", "shp_adm1_code", "shp_adm1_name", "shp_adm2_code",
             "shp_adm2_name", "shp_adm3_code", "shp_adm3_name", "population_total_adm3"),
  colClasses = list(character = c("shp_adm1_code", "shp_adm2_code", "shp_adm3_code")),
  showProgress = FALSE
)

# Collapse age-sex rows to one ADM3-year population
pop <- unique(pop)
pop[, population := as.numeric(population_total_adm3)]
pop <- pop[, .(
  population = max(population, na.rm = TRUE)
), by = .(year, shp_adm1_code, shp_adm1_name, shp_adm2_code,
          shp_adm2_name, shp_adm3_code, shp_adm3_name)]

# Current all-age ADM3 rates
current_rates <- fread(
  rate_file,
  colClasses = list(character = c("shp_adm1_code", "shp_adm2_code", "shp_adm3_code")),
  showProgress = FALSE
)

# High-population ADM3-years with zero deaths in the current rates
current_suspicious <- current_rates[
  population >= 10000 & deaths == 0,
  .(currently_zero_high_pop = TRUE),
  by = .(year, shp_adm3_code)
]


# -------------------------
# Original and aligned deaths
# -------------------------

# Original cleaned death records
raw_deaths <- fread(
  raw_death_file,
  select = c("year_file", "res_shp_adm1_code", "res_shp_adm1_name",
             "res_shp_adm2_code", "res_shp_adm2_name",
             "res_shp_adm3_code", "res_shp_adm3_name"),
  colClasses = "character",
  showProgress = TRUE
)

# Death records after ADM3 alignment
aligned_deaths <- fread(
  aligned_death_file,
  select = c("year_file", "death_weight", "res_shp_adm1_code", "res_shp_adm1_name",
             "res_shp_adm2_code", "res_shp_adm2_name",
             "res_shp_adm3_code", "res_shp_adm3_name"),
  colClasses = "character",
  showProgress = TRUE
)

# Trim geography codes and treat blanks as missing
clean_codes <- function(x) {
  for (v in names(x)) {
    if (grepl("_code$", v)) {
      x[, (v) := trimws(get(v))]
      x[get(v) == "", (v) := NA_character_]
    }
  }
  x
}

raw_deaths <- clean_codes(raw_deaths)
aligned_deaths <- clean_codes(aligned_deaths)

# Put years and death weights on the same footing
raw_deaths[, year := as.integer(year_file)]
raw_deaths[, death_weight := 1]
aligned_deaths[, year := as.integer(year_file)]
aligned_deaths[, death_weight := as.numeric(death_weight)]
aligned_deaths[is.na(death_weight), death_weight := 1]

# Resident deaths by ADM3-year before and after alignment
raw_adm3 <- raw_deaths[
  !is.na(year) & !is.na(res_shp_adm3_code),
  .(raw_deaths = sum(death_weight)),
  by = .(year, shp_adm3_code = res_shp_adm3_code)
]

aligned_adm3 <- aligned_deaths[
  !is.na(year) & !is.na(res_shp_adm3_code),
  .(aligned_deaths = sum(death_weight)),
  by = .(year, shp_adm3_code = res_shp_adm3_code)
]

# Original deaths with a province but no ADM3
raw_missing_adm3_adm2 <- raw_deaths[
  !is.na(year) & !is.na(res_shp_adm2_code) & is.na(res_shp_adm3_code),
  .(raw_missing_adm3_deaths = .N),
  by = .(year, shp_adm2_code = res_shp_adm2_code)
]


# -------------------------
# ADM3 comparison
# -------------------------

# Compare the original and aligned counts on the population geography
adm3_compare <- merge(pop, raw_adm3, by = c("year", "shp_adm3_code"), all.x = TRUE)
adm3_compare <- merge(adm3_compare, aligned_adm3, by = c("year", "shp_adm3_code"), all.x = TRUE)
adm3_compare <- merge(adm3_compare, current_suspicious, by = c("year", "shp_adm3_code"), all.x = TRUE)

adm3_compare[is.na(raw_deaths), raw_deaths := 0]
adm3_compare[is.na(aligned_deaths), aligned_deaths := 0]
adm3_compare[is.na(currently_zero_high_pop), currently_zero_high_pop := FALSE]

# Rates and zero-death flags before and after alignment
adm3_compare[, `:=`(
  raw_rate = 100000 * raw_deaths / population,
  aligned_rate = 100000 * aligned_deaths / population,
  raw_zero_high_pop = population >= 10000 & raw_deaths == 0,
  aligned_zero_high_pop = population >= 10000 & aligned_deaths == 0,
  barmm = shp_adm1_name == "Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)",
  sga_current_unit = grepl("^19999", shp_adm3_code)
)]


# -------------------------
# Province-year comparison
# -------------------------

# Aggregate the same comparison to province-year
adm2_compare <- adm3_compare[, .(
  population = sum(population, na.rm = TRUE),
  raw_deaths = sum(raw_deaths, na.rm = TRUE),
  aligned_deaths = sum(aligned_deaths, na.rm = TRUE),
  adm3_units = .N,
  raw_zero_high_pop_adm3s = sum(raw_zero_high_pop),
  aligned_zero_high_pop_adm3s = sum(aligned_zero_high_pop),
  current_suspicious_adm3s = sum(currently_zero_high_pop),
  barmm = first(barmm)
), by = .(year, shp_adm1_name, shp_adm2_code, shp_adm2_name)]

adm2_compare[, `:=`(
  raw_rate = 100000 * raw_deaths / population,
  aligned_rate = 100000 * aligned_deaths / population,
  alignment_death_change = aligned_deaths - raw_deaths
)]

adm2_compare[, `:=`(
  raw_low_adm2_rate = raw_rate < 100,
  aligned_low_adm2_rate = aligned_rate < 100
)]

# Add original deaths that had province but no ADM3
adm2_compare <- merge(adm2_compare, raw_missing_adm3_adm2,
                      by = c("year", "shp_adm2_code"), all.x = TRUE)
adm2_compare[is.na(raw_missing_adm3_deaths), raw_missing_adm3_deaths := 0]


# -------------------------
# Output tables
# -------------------------

summary <- data.table(
  metric = c(
    "Current high-population zero ADM3-years",
    "Already zero before death reallocation", "Created by death reallocation",
    "Resolved by death reallocation",
    "Current high-population zero ADM3-years in BARMM",
    "Current high-population zero ADM3-years in SGA current units",
    "BARMM province-years with raw ADM2 rate < 100",
    "BARMM province-years with aligned ADM2 rate < 100"
  ),
  value = c(
    nrow(adm3_compare[currently_zero_high_pop == TRUE]),
    nrow(adm3_compare[currently_zero_high_pop == TRUE & raw_zero_high_pop == TRUE]),
    nrow(adm3_compare[currently_zero_high_pop == TRUE & raw_zero_high_pop == FALSE]),
    nrow(adm3_compare[raw_zero_high_pop == TRUE & aligned_zero_high_pop == FALSE]),
    nrow(adm3_compare[currently_zero_high_pop == TRUE & barmm == TRUE]),
    nrow(adm3_compare[currently_zero_high_pop == TRUE & sga_current_unit == TRUE]),
    nrow(adm2_compare[barmm == TRUE & raw_low_adm2_rate == TRUE]),
    nrow(adm2_compare[barmm == TRUE & aligned_low_adm2_rate == TRUE])
  )
)

# BARMM province-years with low rates or zero-death ADM3s
barmm_province_years <- adm2_compare[
  barmm == TRUE &
    (raw_low_adm2_rate == TRUE | aligned_low_adm2_rate == TRUE | current_suspicious_adm3s > 0)
][order(year, shp_adm2_name)]

# ADM3-years with zero-death concerns before or after alignment
suspicious_adm3 <- adm3_compare[
  currently_zero_high_pop == TRUE |
    raw_zero_high_pop == TRUE |
    aligned_zero_high_pop == TRUE
][order(shp_adm1_name, shp_adm2_name, shp_adm3_name, year)]

# Current SGA units
sga_check <- adm3_compare[
  sga_current_unit == TRUE,
  .(years = .N, raw_zero_years = sum(raw_deaths == 0),
    aligned_zero_years = sum(aligned_deaths == 0),
    current_high_pop_zero_years = sum(currently_zero_high_pop),
    median_population = median(population, na.rm = TRUE),
    raw_deaths_total = sum(raw_deaths, na.rm = TRUE),
    aligned_deaths_total = sum(aligned_deaths, na.rm = TRUE)),
  by = .(shp_adm1_name, shp_adm2_name, shp_adm3_code, shp_adm3_name)
][order(-current_high_pop_zero_years, shp_adm2_name, shp_adm3_name)]

writexl::write_xlsx(
  list("Summary" = summary, "BARMM Province Years" = barmm_province_years,
    "Suspicious ADM3 Years" = suspicious_adm3, "SGA Current Units" = sga_check),
  out_file
)

cat("Wrote original-vs-aligned low-rate check to:\n")
cat(out_file, "\n\n")
print(summary)
