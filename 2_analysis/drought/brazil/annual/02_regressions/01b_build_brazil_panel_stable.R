# ============================================================
# 01b_build_brazil_panel_stable.R
#
# Build the annual Brazil regression panel on the stable ADM2 map, for
# 2000-2024 or 1997-2010 (--period, see "paths" below)
#
# 1997-2010: mortality from the same 1997-2010 cleaning used for the monthly
# analysis. The annual file keeps deaths w/out a usable month, so it is a
# little more complete than summing the monthly panel.
# 2000-2024: Brazil from the new mortality panel (1_data/panel_build), already
# with the ERA5-Land climate.
#
# Rain and SPI come from ERA5-Land aggregated to the same 5,474 stable units.
# The old rolling-window measures are not available on this map, so this panel
# keeps the annual rain, rainfall-bin and SPI measures only.
#
# Inputs:
#   1997-2010: brazil_pilot/legacy_1997_2010/BRA_mortality_climate_annual_1997_2010.csv
#   2000-2024: panel_update/combined_panel/03_panel_full.rds (Brazil rows)
#   brazil_annual_2000_2024/brazil_annual_measures_stable.rds (both)
#
# Output:
#   brazil_annual/brazil_annual_drought_regression_panel_stable_<period>.rds
# ============================================================


# -----------------------------
# packages
# -----------------------------

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
})


# -----------------------------
# paths
# -----------------------------

REPO <- "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"

# Years: --period=2000_2024 (default) or 1997_2010. If the option isn't given,
# use the default
args <- commandArgs(trailingOnly = TRUE)
PERIOD <- sub("^--period=", "", grep("^--period=", args, value = TRUE))
if (length(PERIOD) == 0) PERIOD <- "2000_2024"
YEARS <- as.integer(strsplit(PERIOD, "_")[[1]])

# Mortality and climate: the 1997-2010 cleaning, or Brazil from the new panel
MORTALITY_FILE <- if (PERIOD == "1997_2010") {
  paste0("/project/cil/gcp/estimation/rainfall-mortality/mortality_data/annual/",
         "brazil_pilot/legacy_1997_2010/BRA_mortality_climate_annual_1997_2010.csv")
} else {
  paste0("/project/cil/gcp/estimation/rainfall-mortality/mortality_data/annual/",
         "panel_update/combined_panel/03_panel_full.rds")
}

MEASURES_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/",
  "drought/brazil_annual_2000_2024/brazil_annual_measures_stable.rds"
)

OUTPUT_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/",
  "drought/brazil_annual/",
  "brazil_annual_drought_regression_panel_stable_", PERIOD, ".rds"
)

write_output <- "--write" %in% args

source(file.path(REPO, "0_utils/functions.R"))
source(file.path(REPO, "2_analysis/regressions/00_prep_analysis_panel.R"))


# -----------------------------
# mortality panel
# -----------------------------

# 2000-2024: the Brazil rows of the new panel
mortality <- if (PERIOD == "1997_2010") fread(MORTALITY_FILE) else filter(readRDS(MORTALITY_FILE), iso == "BRA")

panel <- mortality %>%
  as_tibble() %>%
  mutate(
    admin_id = as.character(admin_id),
    adm1_name = tolower(adm1_name)
  ) %>%
  filter(agegroup != 0) %>%
  add_regression_ids() %>%
  mutate(agegroup = droplevels(agegroup)) %>%
  add_winsorized_deathrate() %>%
  use_climate_product(
    prcp_product = "ERA5LAND",
    temp_product = "ERA5LAND"
  ) %>%
  get_weights()

northeast_states <- c(
  "alagoas", "bahia", "ceará", "maranhão", "paraíba",
  "pernambuco", "piauí", "rio grande do norte", "sergipe"
)
southeast_states <- c(
  "são paulo", "rio de janeiro", "minas gerais", "espírito santo"
)
south_states <- c("paraná", "santa catarina", "rio grande do sul")
center_west_states <- c(
  "goiás", "mato grosso", "mato grosso do sul", "distrito federal"
)

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


# -----------------------------
# stable drought measures
# -----------------------------

drought <- readRDS(MEASURES_FILE) %>%
  as_tibble() %>%
  transmute(
    admin_id = as.character(admin_id),
    year,
    annual_rain_mm_pop,
    gs_neglog_annual_rain_pop = annual_rain_neglog_pop,
    rain_dry_logdev_pop = -annual_rain_logdev_pop,
    rain_wet_p90_pop = as.integer(annual_rain_percentile_pop >= 0.90),
    rain_bin_p00_10_pop = as.integer(annual_rain_percentile_pop <= 0.10),
    rain_bin_p10_25_pop = as.integer(
      annual_rain_percentile_pop > 0.10 &
        annual_rain_percentile_pop <= 0.25
    ),
    rain_bin_p75_90_pop = as.integer(
      annual_rain_percentile_pop >= 0.75 &
        annual_rain_percentile_pop < 0.90
    ),
    rain_bin_p90_100_pop = as.integer(
      annual_rain_percentile_pop >= 0.90
    ),
    spi12_dry_pop = -spi12_cal_pop,
    spi06_worst_severity_pop = pmax(0, -spi06_worst_pop)
  ) %>%
  group_by(admin_id) %>%
  arrange(year, .by_group = TRUE) %>%
  mutate(
    rain_dry_logdev_lag1_pop = lag(rain_dry_logdev_pop),
    rain_dry_logdev_lead1_pop = lead(rain_dry_logdev_pop),
    rain_bin_p00_10_lag1_pop = lag(rain_bin_p00_10_pop),
    rain_bin_p00_10_lead1_pop = lead(rain_bin_p00_10_pop),
    spi12_dry_lag1_pop = lag(spi12_dry_pop),
    spi12_dry_lead1_pop = lead(spi12_dry_pop)
  ) %>%
  ungroup()


# -----------------------------
# merge and checks
# -----------------------------

reg_panel <- panel %>%
  left_join(drought, by = c("admin_id", "year"))

summary <- reg_panel %>%
  summarise(
    rows = n(),
    first_year = min(year),
    last_year = max(year),
    admin_units = n_distinct(admin_id),
    missing_drought = sum(is.na(rain_dry_logdev_pop)),
    weight_sum_min = min(tapply(weight, list(year, agegroup), sum)),
    weight_sum_max = max(tapply(weight, list(year, agegroup), sum))
  )

print(summary)

missing_climate <- reg_panel %>%
  filter(is.na(rain_dry_logdev_pop)) %>%
  distinct(admin_id, admin_name)

print(missing_climate)

if (summary$first_year != YEARS[1] || summary$last_year != YEARS[2]) {
  stop("Expected mortality years ", YEARS[1], "-", YEARS[2])
}

if (any(missing_climate$admin_id != "260545")) {
  stop("Unexpected stable ADM2 is missing the drought measures")
}


# -----------------------------
# write panel
# -----------------------------

if (write_output) {
  saveRDS(reg_panel, OUTPUT_FILE)
  message("wrote: ", OUTPUT_FILE)
}

