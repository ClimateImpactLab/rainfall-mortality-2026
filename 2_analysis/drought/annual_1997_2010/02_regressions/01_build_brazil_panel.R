# ============================================================================
# 01_build_brazil_panel.R
#
# Brazil annual mortality + drought panel for the regs, 1997-2010. 
# One row per municipality x age group x year.
#
# Mortality: our mortality panel, with the same prep as the main annual
# regs (IDs, winsorized death rate, ERA5-Land temp and precip poly).
# Weights are population shares within Brazil x year x age.
#
# Drought (same value for every age group of a municipality-year):
#   - the yearly measures from 01_measures/02 (6-month p10/p5 counts, worst
#     6-month z, Rocha-Soares, -log annual rainfall)
#   - calendar-year rainfall vs 1981-2010, dry and wet years (not cut at 0),
#     with last and next year (placebo)
#   - very wet year (>= p90) and rainfall percentile bins
#   - SPI from 01_measures/03, with last and next year
#
# Also a Northeast flag and the 5 IBGE macro-regions (for the region x year
# FE check).
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)


# -----------------------------
# Paths and settings
# -----------------------------

REPO <- "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"

# mortality panel used by the current annual regression scripts
PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/",
  "panel_build/combined_panel/new_mortality_panel_urban.rds"
)

# Annual Brazil drought summaries from 01_measures/02_build_annual_drought_summaries.R
DROUGHT_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/annual/era5land_admin_drought_annual_bra.rds"
)

# SPI measures from 01_measures/03_build_spi_measures.R
SPI_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual/era5land_admin_spi_annual_bra.rds"
)

# Where the panel is saved
OUTPUT_DIR <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual"
)

OUTPUT_FILE <- file.path(OUTPUT_DIR, "brazil_annual_drought_regression_panel_urban.rds")

# The panel is saved only with --write (the sbatch passes it)
write_output <- "--write" %in% commandArgs(trailingOnly = TRUE)


# -----------------------------
# Existing regression prep
# -----------------------------

# These functions are the same ones used by the main annual regressions:
#   * add_regression_ids(): creates admin_code, adm1_code, adm0_code
#   * add_winsorized_deathrate(): creates deathrate_w99
#   * get_weights(): population weights within year-age group 
#     applied after keeping Brazil so the shares are within Brazil, not the global panel
#   * use_climate_product(): uses ERA5-Land temp/precip polynomial columns

source(file.path(REPO, "0_utils/functions.R"))
source(file.path(REPO, "2_analysis/regressions/00_prep_analysis_panel.R"))


# -----------------------------
# Read Brazil mortality panel
# -----------------------------

# Match the current annual regr sample as closely as possible
# Drop all-age group
# Weights are computed after filter(iso == "BRA"), so they are shares of Brazil's 
# pop in each year x age
# Shares of the full multi-country panel would make Brazil's total weight change
# by year with the other countries in the panel
# weight_global_panel keeps that version only for the weights diagnostic in 05_summary_figures/
# winsorizing is by country x age, so its order does not matter

panel <- readRDS(PANEL_FILE) %>%
  add_regression_ids() %>%
  filter(agegroup != 0) %>%
  mutate(agegroup = droplevels(agegroup)) %>%
  add_winsorized_deathrate() %>%
  use_climate_product(prcp_product = "ERA5LAND", temp_product = "ERA5LAND") %>%
  get_weights() %>%
  rename(weight_global_panel = weight) %>%
  filter(iso == "BRA") %>%
  get_weights()

# Macro regions for the Northeast-only runs. adm1_name is lower case.
northeast_states <- c(
  "alagoas", "bahia", "ceará", "maranhão", "paraíba",
  "pernambuco", "piauí", "rio grande do norte", "sergipe"
)
southeast_states <- c("são paulo", "rio de janeiro", "minas gerais", "espírito santo")
south_states <- c("paraná", "santa catarina", "rio grande do sul")
center_west_states <- c("goiás", "mato grosso", "mato grosso do sul", "distrito federal")

# macro_region is used for the region x year FE check: 5 IBGE regions (IBGE = Brazil's stats office)
panel <- panel %>%
  mutate(
    northeast = adm1_name %in% northeast_states,
    macro_region = case_when(
      adm1_name %in% northeast_states ~ "northeast",
      adm1_name %in% southeast_states ~ "southeast",
      adm1_name %in% south_states ~ "south",
      adm1_name %in% center_west_states ~ "center_west",
      TRUE ~ "north"
    )
  )


# -----------------------------------
# Read Brazil annual drought measures
# ------------------------------------

# Yearly drought measures: one row per municipality x year.
# Brazil mortality admin IDs are ID_1_ID_2, so build that key before merging
drought <- readRDS(DROUGHT_FILE) %>%
  filter(climate_country == "BRA") %>%
  mutate(
    iso = climate_country,
    admin_id = paste(as.integer(ID_1), as.integer(ID_2), sep = "_"),

    # Gehring-Schaudt-style annual rainfall measure:
    # annual rainfall in logs, multiplied by -1, so larger means lower rainfall
    gs_neglog_annual_rain_pop = annual_rain_neglog_pop,

    # Duration measures: number of monthly ending points in the year below the
    # 6-month 10th or 5th percentile threshold
    drought_6m_low10_months_pop = drought_months_dry10_06m_pop,
    drought_6m_low05_months_pop = drought_months_dry05_06m_pop,

    # Severity measures are transformed so larger values mean worse drought
    # The raw worst z-score and raw RS deviations are more negative when drought
    # is more severe (RS = Rocha-Soares)
    drought_6m_worst_z_severity_pop = pmax(0, -worst_z_06m_pop),
    rs_worst_logdev_severity_pop = pmax(0, -rs_min_logdev_12m_pop),
    rs_worst_pctdev_severity_pop = pmax(0, -rs_min_pctdev_12m_pop),

    # Calendar-year (Jan-Dec) rainfall vs the ADM2's 1981-2010 mean, in logs, with
    # the sign flipped so larger = drier. Wet years are negative, not cut to
    # zero. With ADM2 FE this is equivalent to -log annual rainfall,
    # but reads as a deviation from normal
    rain_dry_logdev_pop = -annual_rain_logdev_pop,

    # Very wet year: calendar-year rainfall at or above the ADM2's 1981-2010
    # 90th percentile. (this is a wet control obvio)
    rain_wet_p90_pop = as.integer(annual_rain_percentile_pop >= 0.90),

    # Calendar-year rainfall percentile bins vs 1981-2010. Middle bin (25th-75th)
    # is the omitted group, so each bin is compared with a normal year.
    # 1997-2010 years are inside their own 1981-2010 baseline, as in RS.
    rain_bin_p00_10_pop = as.integer(annual_rain_percentile_pop <= 0.10),
    rain_bin_p10_25_pop = as.integer(annual_rain_percentile_pop > 0.10 & annual_rain_percentile_pop <= 0.25),
    rain_bin_p75_90_pop = as.integer(annual_rain_percentile_pop >= 0.75 & annual_rain_percentile_pop < 0.90),
    rain_bin_p90_100_pop = as.integer(annual_rain_percentile_pop >= 0.90)
  ) %>%
  # Last year's and next year's rainfall deviation. The annual file covers
  # 1960-2024 with every year present, so 1997 and 2010 keep their lag/lead.
  # The lead is a placebo: next year's rainfall cannot cause this year's deaths.
  group_by(admin_id) %>%
  arrange(year, .by_group = TRUE) %>%
  mutate(
    rain_dry_logdev_lag1_pop = lag(rain_dry_logdev_pop),
    rain_dry_logdev_lead1_pop = lead(rain_dry_logdev_pop),
    rain_bin_p00_10_lag1_pop = lag(rain_bin_p00_10_pop),
    rain_bin_p00_10_lead1_pop = lead(rain_bin_p00_10_pop)
  ) %>%
  ungroup() %>%
  select(
    iso, admin_id, year,
    annual_rain_mm_pop,
    gs_neglog_annual_rain_pop,
    rs_drought_months_12m_pop,
    rs_min_logdev_12m_pop,
    rs_min_pctdev_12m_pop,
    rs_worst_logdev_severity_pop,
    rs_worst_pctdev_severity_pop,
    drought_6m_low10_months_pop,
    drought_6m_low05_months_pop,
    worst_z_06m_pop,
    drought_6m_worst_z_severity_pop,
    deficit_mm_max_06m_pop,
    below_baseline_min_months_06m_pop,
    rain_dry_logdev_pop,
    rain_dry_logdev_lag1_pop,
    rain_dry_logdev_lead1_pop,
    rain_bin_p00_10_lag1_pop,
    rain_bin_p00_10_lead1_pop,
    rain_wet_p90_pop,
    rain_bin_p00_10_pop,
    rain_bin_p10_25_pop,
    rain_bin_p75_90_pop,
    rain_bin_p90_100_pop,
    no_drought_baseline
  )

# SPI measures, flipped so larger = drier
#   spi12_dry_pop: -SPI of calendar-year rainfall, wet years negative.
#   spi06_worst_severity_pop: max(0, -worst 6-month SPI), built exactly like
#   drought_6m_worst_z_severity_pop so the only change is z -> SPI.
spi <- readRDS(SPI_FILE) %>%
  transmute(
    iso = climate_country,
    admin_id = paste(as.integer(ID_1), as.integer(ID_2), sep = "_"),
    year,
    spi12_dry_pop = -spi12_cal_pop,
    spi06_worst_severity_pop = pmax(0, -spi06_worst_pop)
  )

# Last and next year's annual SPI, for the same placebo test as the annual
# rainfall deviation. The SPI file also covers 1960-2024.
drought <- drought %>%
  left_join(spi, by = c("iso", "admin_id", "year")) %>%
  group_by(admin_id) %>%
  arrange(year, .by_group = TRUE) %>%
  mutate(
    spi12_dry_lag1_pop = lag(spi12_dry_pop),
    spi12_dry_lead1_pop = lead(spi12_dry_pop)
  ) %>%
  ungroup()


# -----------------------------
# Merge
# -----------------------------

# Keep all mortality rows and attach the drought vars by Brazil ADM2-year
reg_panel <- panel %>%
  left_join(drought, by = c("iso", "admin_id", "year"))


# -----------------------------
# Checks
# -----------------------------

# drought vars used by 02_brazil_regs.R
drought_vars <- c(
  "gs_neglog_annual_rain_pop",
  "rs_drought_months_12m_pop",
  "rs_worst_logdev_severity_pop",
  "rs_worst_pctdev_severity_pop",
  "drought_6m_low10_months_pop",
  "drought_6m_low05_months_pop",
  "drought_6m_worst_z_severity_pop",
  "deficit_mm_max_06m_pop",
  "rain_dry_logdev_pop",
  "rain_dry_logdev_lag1_pop",
  "rain_dry_logdev_lead1_pop",
  "rain_wet_p90_pop",
  "rain_bin_p00_10_pop",
  "spi12_dry_pop",
  "spi06_worst_severity_pop"
)

# The Brazil panel should be 1997-2010, with no missing drought values for the
# first test variables. Brazil weights should sum to 1 in each year x age.
merge_summary <- reg_panel %>%
  summarise(
    rows = n(),
    first_year = min(year),
    last_year = max(year),
    admin_units = n_distinct(admin_id),
    age_groups = n_distinct(agegroup),
    missing_any_drought = sum(if_any(all_of(drought_vars), is.na)),
    weight_sum_min = min(tapply(weight, list(year, agegroup), sum)),
    weight_sum_max = max(tapply(weight, list(year, agegroup), sum)),
    northeast_admin_units = n_distinct(admin_id[northeast]),
    .groups = "drop"
)

# Variable-level check, easier to read if a future drought measure has missing
# rows after the merge
var_summary <- reg_panel %>%
  summarise(across(all_of(drought_vars), ~ sum(!is.na(.x)))) %>%
  tidyr::pivot_longer(everything(), names_to = "variable", values_to = "nonmissing_rows")

print(merge_summary)
print(var_summary)


# -----------------------------
# Write output
# -----------------------------

if (write_output) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(reg_panel, OUTPUT_FILE)
  message("wrote: ", OUTPUT_FILE)
}
