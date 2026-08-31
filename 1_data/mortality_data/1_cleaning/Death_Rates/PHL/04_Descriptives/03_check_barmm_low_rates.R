# ============================================================
# 03_check_barmm_low_rates.R
#
# Follow-up checks for low resident mortality rates in BARMM
#
# Compare resident deaths with population, expected deaths from national
# and nearby-year rates, and deaths by place of death
#
# Output:
#   Country_Descriptives/PHL/phl_low_rate_investigation/
#   phl_barmm_low_rate_followup_checks.xlsx
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

death_file <- file.path(death_records_dir, "PHL_death_records_adm3_aligned.csv")
rate_file <- file.path(death_rates_dir, "adm3_year_total.csv")
out_file <- file.path(out_dir, "phl_barmm_low_rate_followup_checks.xlsx")


# -------------------------
# Flag cutoffs
# -------------------------

low_adm2_rate_cutoff <- 100
high_pop_cutoff <- 10000
low_expected_ratio_cutoff <- 0.25


# -------------------------
# Population and resident rates
# -------------------------

# Read ADM3 all-age rates
adm3_rates <- fread(
  rate_file,
  colClasses = list(character = c("shp_adm1_code", "shp_adm2_code",
                                  "shp_adm3_code", "psgc_adm3_code")),
  showProgress = FALSE
)

# Mark BARMM and high-population zero-death ADM3-years
adm3_rates[, barmm := shp_adm1_name == "Bangsamoro Autonomous Region In Muslim Mindanao (BARMM)"]
adm3_rates[, high_pop_zero_adm3 := population >= high_pop_cutoff & deaths == 0]

# Count repeated high-population zeroes by ADM3
repeat_zero <- adm3_rates[
  high_pop_zero_adm3 == TRUE,
  .(repeated_zero_adm3 = .N >= 2, high_pop_zero_years = .N,
    first_zero_year = min(year), last_zero_year = max(year)),
  by = shp_adm3_code
]

adm3_rates <- merge(adm3_rates, repeat_zero, by = "shp_adm3_code", all.x = TRUE)
adm3_rates[is.na(repeated_zero_adm3), repeated_zero_adm3 := FALSE]
adm3_rates[is.na(high_pop_zero_years), high_pop_zero_years := 0L]

# Aggregate resident deaths and population to province-years
adm2_resident <- adm3_rates[, .(
  resident_deaths = sum(deaths, na.rm = TRUE),
  population = sum(population, na.rm = TRUE),
  adm3_units = .N,
  high_pop_zero_adm3s = sum(high_pop_zero_adm3, na.rm = TRUE),
  repeated_zero_adm3s = uniqueN(shp_adm3_code[repeated_zero_adm3 == TRUE]),
  barmm = first(barmm)
), by = .(year, shp_adm1_name, shp_adm2_code, shp_adm2_name)]

adm2_resident[, resident_rate := 100000 * resident_deaths / population]
adm2_resident[, low_adm2_rate := resident_rate < low_adm2_rate_cutoff]

# Calculate national rates by year
national_rates <- adm2_resident[, .(
  national_deaths = sum(resident_deaths, na.rm = TRUE),
  national_population = sum(population, na.rm = TRUE)
), by = year]
national_rates[, national_rate := 100000 * national_deaths / national_population]

adm2_resident <- merge(adm2_resident, national_rates, by = "year", all.x = TRUE)

# Compare province deaths with deaths expected at the national rate
adm2_resident[, `:=`(
  expected_deaths_national = population * national_rate / 100000,
  observed_expected_ratio_national = resident_deaths / (population * national_rate / 100000)
)]


# -------------------------
# Adjacent-year expected deaths
# -------------------------

adm2_rates_for_lag <- adm2_resident[, .(year, shp_adm2_code, resident_rate)]

# Attach previous- and next-year province rates
prev_rates <- copy(adm2_rates_for_lag)
prev_rates[, year := year + 1]
setnames(prev_rates, "resident_rate", "previous_year_resident_rate")

next_rates <- copy(adm2_rates_for_lag)
next_rates[, year := year - 1]
setnames(next_rates, "resident_rate", "next_year_resident_rate")

adm2_resident <- merge(adm2_resident, prev_rates,
                       by = c("year", "shp_adm2_code"), all.x = TRUE)
adm2_resident <- merge(adm2_resident, next_rates,
                       by = c("year", "shp_adm2_code"), all.x = TRUE)

# Use adjacent years as a second expected-deaths check
adm2_resident[, nearby_year_rate := rowMeans(
  cbind(previous_year_resident_rate, next_year_resident_rate), na.rm = TRUE
)]
adm2_resident[is.nan(nearby_year_rate), nearby_year_rate := NA_real_]

adm2_resident[, `:=`(
  expected_deaths_nearby_years = population * nearby_year_rate / 100000,
  observed_expected_ratio_nearby = resident_deaths / (population * nearby_year_rate / 100000)
)]

adm2_resident[, low_expected_deaths := fifelse(
  !is.na(observed_expected_ratio_national),
  observed_expected_ratio_national < low_expected_ratio_cutoff, FALSE
)]


# -------------------------
# Place-of-death checks
# -------------------------

# Read residence and place-of-death geography
deaths <- fread(
  death_file,
  select = c("year_file", "death_weight",
             "res_shp_adm2_code", "res_shp_adm3_code",
             "pod_shp_adm2_code", "pod_shp_adm3_code"),
  colClasses = "character",
  showProgress = TRUE
)

deaths[, year := as.integer(year_file)]
deaths[, death_weight := as.numeric(death_weight)]
deaths[is.na(death_weight), death_weight := 1]

# Treat blank geography codes as missing
for (v in c("res_shp_adm2_code", "res_shp_adm3_code",
            "pod_shp_adm2_code", "pod_shp_adm3_code")) {
  deaths[, (v) := trimws(get(v))]
  deaths[get(v) == "", (v) := NA_character_]
}

# Count deaths by place-of-death province
pod_adm2 <- deaths[
  !is.na(year) & !is.na(pod_shp_adm2_code),
  .(place_of_death_deaths = sum(death_weight, na.rm = TRUE)),
  by = .(year, shp_adm2_code = pod_shp_adm2_code)
]

# Count deaths by place-of-death ADM3
pod_adm3 <- deaths[
  !is.na(year) & !is.na(pod_shp_adm3_code),
  .(place_of_death_deaths_adm3 = sum(death_weight, na.rm = TRUE)),
  by = .(year, shp_adm3_code = pod_shp_adm3_code)
]

# Compare resident deaths with deaths by place of death
adm2_checks <- merge(adm2_resident, pod_adm2,
                     by = c("year", "shp_adm2_code"), all.x = TRUE)
adm2_checks[is.na(place_of_death_deaths), place_of_death_deaths := 0]

adm2_checks[, `:=`(
  pod_resident_death_gap = place_of_death_deaths - resident_deaths,
  pod_resident_ratio = place_of_death_deaths / resident_deaths,
  place_of_death_residence_gap =
    place_of_death_deaths >= expected_deaths_national * low_expected_ratio_cutoff &
    resident_deaths < expected_deaths_national * low_expected_ratio_cutoff
)]
adm2_checks[is.infinite(pod_resident_ratio), pod_resident_ratio := NA_real_]

# Check whether zero-residence ADM3-years still have place-of-death deaths
adm3_checks <- merge(adm3_rates, pod_adm3,
                     by = c("year", "shp_adm3_code"), all.x = TRUE)
adm3_checks[is.na(place_of_death_deaths_adm3), place_of_death_deaths_adm3 := 0]
adm3_checks[, place_of_death_exists_residence_zero :=
              high_pop_zero_adm3 == TRUE & place_of_death_deaths_adm3 > 0]


# -------------------------
# Sensitivity flags
# -------------------------

# Province-year flag table
adm2_flags <- adm2_checks[, .(
  year, shp_adm1_name, shp_adm2_code, shp_adm2_name, barmm,
  population, resident_deaths, resident_rate, place_of_death_deaths,
  pod_resident_death_gap, national_rate, expected_deaths_national,
  observed_expected_ratio_national, nearby_year_rate,
  expected_deaths_nearby_years, observed_expected_ratio_nearby,
  high_pop_zero_adm3s, repeated_zero_adm3s, low_adm2_rate,
  low_expected_deaths, place_of_death_residence_gap
)]

# Flag BARMM province-years with unusually low resident deaths
adm2_flags[, barmm_completeness_concern :=
             barmm == TRUE &
             (low_adm2_rate | low_expected_deaths | high_pop_zero_adm3s > 0)]

# ADM3-year flag table
adm3_flags <- adm3_checks[, .(
  year, shp_adm1_name, shp_adm2_code, shp_adm2_name,
  shp_adm3_code, shp_adm3_name, population,
  resident_deaths = deaths, resident_rate = death_rate_per_100000,
  place_of_death_deaths_adm3, high_pop_zero_adm3, repeated_zero_adm3,
  high_pop_zero_years, place_of_death_exists_residence_zero
)]

# Bring province-year flags onto ADM3-years
adm3_flags <- merge(
  adm3_flags,
  adm2_flags[, .(year, shp_adm2_code, low_adm2_rate, low_expected_deaths,
                 barmm_completeness_concern, place_of_death_residence_gap)],
  by = c("year", "shp_adm2_code"), all.x = TRUE
)

# Keep ADM3-years with at least one flag
adm3_flags <- adm3_flags[
  high_pop_zero_adm3 == TRUE |
    repeated_zero_adm3 == TRUE |
    low_adm2_rate == TRUE |
    low_expected_deaths == TRUE |
    barmm_completeness_concern == TRUE |
    place_of_death_exists_residence_zero == TRUE
]

# Blank columns for manual follow-up notes
source_disruption_notes <- adm2_flags[
  barmm_completeness_concern == TRUE,
  .(year, shp_adm1_name, shp_adm2_code, shp_adm2_name,
    resident_rate, expected_deaths_national, observed_expected_ratio_national,
    high_pop_zero_adm3s, manual_source_note = "", source_checked = "", reviewer = "")
][order(shp_adm2_name, year)]


# -------------------------
# Summaries
# -------------------------

# Workbook summary
summary <- data.table(
  metric = c(
    "ADM2-years checked", "BARMM ADM2-years checked",
    "BARMM ADM2-years with resident rate < 100",
    "BARMM ADM2-years with observed/expected national deaths < 0.25",
    "BARMM ADM2-years with place-of-death/residence gap flag",
    "BARMM ADM2-years flagged for completeness concern",
    "ADM3-years in sensitivity flag table", "High-population zero ADM3-years",
    "High-population zero ADM3-years with place-of-death deaths"
  ),
  value = c(
    nrow(adm2_flags), nrow(adm2_flags[barmm == TRUE]),
    nrow(adm2_flags[barmm == TRUE & low_adm2_rate == TRUE]),
    nrow(adm2_flags[barmm == TRUE & low_expected_deaths == TRUE]),
    nrow(adm2_flags[barmm == TRUE & place_of_death_residence_gap == TRUE]),
    nrow(adm2_flags[barmm_completeness_concern == TRUE]),
    nrow(adm3_flags), nrow(adm3_checks[high_pop_zero_adm3 == TRUE]),
    nrow(adm3_checks[high_pop_zero_adm3 == TRUE &
                       place_of_death_exists_residence_zero == TRUE])
  )
)

# BARMM province-years to review
adm2_priority <- adm2_flags[
  barmm == TRUE &
    (low_adm2_rate == TRUE | low_expected_deaths == TRUE | high_pop_zero_adm3s > 0)
][order(shp_adm2_name, year)]

# ADM3-years to review
adm3_priority <- adm3_flags[
  barmm_completeness_concern == TRUE | high_pop_zero_adm3 == TRUE
][order(shp_adm2_name, shp_adm3_name, year)]

# Write follow-up workbook
writexl::write_xlsx(
  list(
    "Summary" = summary, "ADM2 Flags" = adm2_priority, "ADM3 Flags" = adm3_priority,
    "Place Death ADM2" = adm2_flags[place_of_death_residence_gap == TRUE],
    "Place Death ADM3" = adm3_checks[place_of_death_exists_residence_zero == TRUE],
    "Source Notes" = source_disruption_notes
  ),
  out_file
)

cat("Wrote BARMM low-rate follow-up checks to:\n")
cat(out_file, "\n\n")
print(summary)
