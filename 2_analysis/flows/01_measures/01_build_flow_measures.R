# ============================================================================
# 01_build_flow_measures.R
#
# Yearly rainfall flow measures for each USA county, from the ERA5-Land
# routed-flow admin files. One row per county x year, merged into the
# mortality panel in 02_regressions/01_build_usa_panel.R.
#
# Flow is rainfall_flow: each month's liquid rainfall summed over a grid cell
# and every cell upstream of it (hydro/coarse/prepflow.py).
#
# 1. Flow polynomial: the 12 monthly values of flow, flow^2 and flow^3 summed
#    over the calendar year. The powers are taken at the grid-cell level
#    before spatial averaging (hydro_era5land_admin/01_aggregate_monthly_flow.py),
#    like prcp_poly in the mortality panel. Negative cell flow is set to 0
#    first.
#    Upstream polynomial: the same for upstream inflow, a cell's flow minus
#    its own rainfall (the rain that fell upstream and flowed in).
#
# 2. Drought and flood: annual mean and annual max of monthly flow, from
#    hydro_era5land_admin/02_make_drought_flood.py (raw flow, negatives kept).
#
# 3. How unusual the annual mean and max are.
#    Baseline: same county, 20 previous years (for ex 1990 vs 1970-1989).
#      z-score
#
# 4. SPI of calendar-year flow, built like the Brazil SPI
#    (drought/annual_1997_2010/01_measures/03_build_spi_measures.R).
#    Baseline: same county, 1981-2010.
#
# 5. Percentiles of the annual mean and max among the county's 20 previous
#    years (the z-score baseline), with the Brazil mid-rank percentile
#    (drought/annual_1997_2010/01_measures/02_build_annual_drought_summaries.R).
#    Brazil ranks against fixed 1981-2010 years instead.
#    01_build_usa_panel.R cuts them into the Brazil percentile bins.
#
# Pop- and area-weighted versions of everything. The panel uses the pop ones,
# like prcp_poly_*_ERA5LAND.
#
# Options:
#   --write    save the RDS output
#
# Inputs:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/
#   USA/hydro/monthly/era5land_usa_adm2_flow_monthly_<year>.csv
#   USA/hydro/annual/era5land_usa_adm2_flow_annual_<year>.csv
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# flows/annual/era5land_admin_flow_annual_usa.rds
#
# Dependencies: dplyr, tidyr, readr, stringr; ../../../0_utils/paths.R, so run
# this script from its own folder.
# ============================================================================


# --------------
# Packages
# --------------

library(dplyr)
library(tidyr)
library(readr)
library(stringr)


# -------------------------
# Paths and settings
# -------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DATA_DIR

CLIMATE_DIR <- file.path(DATA_DIR, "climate_data")

# Admin flow files from hydro_era5land_admin (01 monthly, 02 annual)
FLOW_DIR <- file.path(CLIMATE_DIR, "ERA5-LAND-GLOBAL", "USA", "hydro")

OUTPUT_DIR <- file.path(CLIMATE_DIR, "ERA5-LAND", "flows", "annual")
OUTPUT_FILE <- file.path(OUTPUT_DIR, "era5land_admin_flow_annual_usa.rds")

ROLLING_BASELINE_YEARS <- 20 # complete prior years required for the z-scores
FLOW_POWERS <- 1:3 # flow polynomial terms written by 01_aggregate_monthly_flow.py
WEIGHTINGS <- c("pop", "area") # pop- and area-weighted flow

# SPI settings, the same as the Brazil SPI
SPI_BASELINE_START <- 1981
SPI_BASELINE_END <- 2010
SPI_P_MIN <- 1e-4 # caps SPI at about +/-3.7 (probabilities 0.0001 and 0.9999)

# The file is saved only with --write
write_output <- "--write" %in% commandArgs(trailingOnly = TRUE)

# Monthly power columns: flow_pop_p1 ... flow_area_p3, upstream_pop_p1 ... upstream_area_p3
POWER_COLS <- paste0("flow_", rep(WEIGHTINGS, each = length(FLOW_POWERS)), "_p", FLOW_POWERS)
UPSTREAM_COLS <- paste0("upstream_", rep(WEIGHTINGS, each = length(FLOW_POWERS)), "_p", FLOW_POWERS)


# -----------------------------
# Small functions
# -----------------------------

# z-score against the same county's previous N years. All N prior years are
# required (current and future years are excluded), as in the rolling20
# baseline of drought/annual_1997_2010/01_measures/01_build_monthly_drought_measures.R
rolling_prior_z <- function(value, year, baseline_years = ROLLING_BASELINE_YEARS) {
  z <- rep(NA_real_, length(value))

  for (row_id in seq_along(value)) {
    prior_years <- year >= year[row_id] - baseline_years & year <= year[row_id] - 1
    baseline_values <- value[prior_years & !is.na(value)]

    # Leave the z-score missing until the full baseline is available
    if (!is.na(value[row_id]) && length(baseline_values) == baseline_years) {
      baseline_sd <- sd(baseline_values)
      if (baseline_sd > 0) {
        z[row_id] <- (value[row_id] - mean(baseline_values)) / baseline_sd
      }
    }
  }

  z
}

# SPI for one value given the county's baseline gamma fit. Zeros get the
# baseline share of zeros as their probability (standard mixed gamma SPI), as
# in the Brazil SPI script
spi_from_gamma <- function(value, zero_share, shape, rate) {
  p <- ifelse(value <= 0, zero_share, zero_share + (1 - zero_share) * pgamma(value, shape = shape, rate = rate))
  qnorm(pmin(pmax(p, SPI_P_MIN), 1 - SPI_P_MIN))
}

# Mid-rank percentile: share of baseline values below the current value + half
# the share tied with it. Copied from the Brazil drought measures
# (drought/annual_1997_2010/01_measures/01_build_monthly_drought_measures.R)
midrank_percentile <- function(value, baseline_values) {
  if (is.na(value) || length(baseline_values) == 0) return(NA_real_)
  (sum(baseline_values < value) + 0.5 * sum(baseline_values == value)) / length(baseline_values)
}

# Mid-rank percentile against the same county's previous N years, with the
# rule of rolling_prior_z(): all N prior years required, current and future
# years excluded. With N = 20 the percentile moves in steps of 1/20, so a
# year at or below p10 is below all but at most 2 of the previous 20 years
rolling_prior_percentile <- function(value, year, baseline_years = ROLLING_BASELINE_YEARS) {
  pct <- rep(NA_real_, length(value))

  for (row_id in seq_along(value)) {
    prior_years <- year >= year[row_id] - baseline_years & year <= year[row_id] - 1
    baseline_values <- value[prior_years & !is.na(value)]

    # Leave the percentile missing until the full baseline is available
    if (!is.na(value[row_id]) && length(baseline_values) == baseline_years) {
      pct[row_id] <- midrank_percentile(value[row_id], baseline_values)
    }
  }

  pct
}

# One monthly flow file, stopped if it was written before the power columns
# were added to 01_aggregate_monthly_flow.py
read_monthly_file <- function(path) {
  # Admin IDs as text so leading zeros are kept (for ex ID_1 = "01")
  input <- read_csv(
    path,
    col_types = cols(month = "c", region_id = "c", ID_0 = "c", ID_1 = "c", ID_2 = "c", .default = "d")
  )

  missing_cols <- setdiff(c("flow_pop", "flow_area", POWER_COLS, UPSTREAM_COLS), names(input))
  if (length(missing_cols) > 0) {
    stop(
      basename(path), " has no ", paste(missing_cols, collapse = ", "),
      ". Rerun hydro_era5land_admin/jobs/01_monthly_flow.sbatch for USA",
      call. = FALSE
    )
  }

  input
}


# -----------------------------
# Read monthly flow
# -----------------------------

# -------- 1. Read monthly files --------

# One CSV per year with one row per county x month
monthly_files <- list.files(
  file.path(FLOW_DIR, "monthly"),
  pattern = "^era5land_usa_adm2_flow_monthly_[0-9]{4}\\.csv$",
  full.names = TRUE
)

monthly <- bind_rows(lapply(monthly_files, read_monthly_file)) %>%
  mutate(
    year = as.integer(substr(month, 1, 4)),
    month_number = as.integer(substr(month, 6, 7))
  )

message("Monthly flow: ", min(monthly$year), "-", max(monthly$year))

if (anyDuplicated(monthly[c("region_id", "month")]) > 0) {
  stop("Monthly flow has duplicate county-months", call. = FALSE)
}

# Every year file should have all 12 months for every county
if (any(count(monthly, region_id, year)$n != 12)) {
  stop("Some county-years do not have 12 monthly rows", call. = FALSE)
}


# -----------------------------
# Flow polynomial
# -----------------------------

# -------- 2. Annual sums of the monthly powers --------

# Each monthly value is the weighted county mean of cell flow^k (or upstream
# inflow^k), with negative cell values set to 0. The annual term is the sum
# over the 12 months, kept only when all 12 are present (same complete-year
# rule as 02_aggregate_prcp_temp.py).
#
# flow_clip_months_*: months in which at least one of the county's weighted
# cells had negative flow set to 0. Setting negatives to 0 can only raise the
# weighted mean, so these are the months with p1 > raw flow.
flow_poly <- monthly %>%
  mutate(
    clipped_pop = flow_pop_p1 > flow_pop,
    clipped_area = flow_area_p1 > flow_area
  ) %>%
  group_by(region_id, year) %>%
  summarise(
    flow_clip_months_pop = if (sum(!is.na(flow_pop)) == 12) as.integer(sum(clipped_pop)) else NA_integer_,
    flow_clip_months_area = if (sum(!is.na(flow_area)) == 12) as.integer(sum(clipped_area)) else NA_integer_,
    across(all_of(c(POWER_COLS, UPSTREAM_COLS)), ~ if (sum(!is.na(.x)) == 12) sum(.x) else NA_real_),
    .groups = "drop"
  ) %>%
  # flow_pop_p2 -> flow_poly_2_pop, upstream_pop_p2 -> upstream_poly_2_pop
  rename_with(
    ~ str_replace(.x, "^(flow|upstream)_(pop|area)_p([0-9])$", "\\1_poly_\\3_\\2"),
    all_of(c(POWER_COLS, UPSTREAM_COLS))
  )

# -------- 3. Share of negative flow --------

# Negative flow is the rainfall residual (tp_total - SWE change) where the
# snowpack grows faster than precipitation. Two shares are reported:
#   negative_county_mean: county-months whose raw weighted mean is negative
#   negative_cells_set_to_0: county-months with at least one negative weighted
#     cell, i.e. the county-months changed by setting negatives to 0
# The share of negative cell-months is in the 01_aggregate_monthly_flow.py logs.
# Before the power columns were added (checked 2026-10-16 on the monthly files
# from Slurm job 59831286), 2,852 of the non-missing pop-weighted county-months
# (0.097%) had a negative county mean, mostly in Dec-Feb.
negative_summary <- bind_rows(lapply(WEIGHTINGS, function(weighting) {
  raw <- monthly[[paste0("flow_", weighting)]]
  p1 <- monthly[[paste0("flow_", weighting, "_p1")]]

  tibble(
    weighting = weighting,
    county_months = sum(!is.na(raw)),
    negative_county_mean = sum(raw < 0, na.rm = TRUE),
    negative_cells_set_to_0 = sum(p1 > raw, na.rm = TRUE)
  )
})) %>%
  mutate(
    negative_county_mean_pct = 100 * negative_county_mean / county_months,
    negative_cells_set_to_0_pct = 100 * negative_cells_set_to_0 / county_months
  )

print(negative_summary, width = Inf)


# -----------------------------
# Drought and flood measures
# -----------------------------

# -------- 4. Read annual files --------

# Drought = annual mean of the 12 monthly county values. Flood = each cell's
# highest monthly flow in the year, then the weighted county mean. Both use
# raw flow (02_make_drought_flood.py)
annual_files <- list.files(
  file.path(FLOW_DIR, "annual"),
  pattern = "^era5land_usa_adm2_flow_annual_[0-9]{4}\\.csv$",
  full.names = TRUE
)

annual <- bind_rows(lapply(annual_files, function(path) {
  read_csv(
    path,
    col_types = cols(year = "i", region_id = "c", ID_0 = "c", ID_1 = "c", ID_2 = "c", .default = "d")
  )
}))

if (anyDuplicated(annual[c("region_id", "year")]) > 0) {
  stop("Annual flow has duplicate county-years", call. = FALSE)
}

# -------- 5. z-scores vs the previous 20 years --------

# The flow files start in 1950, so the first possible z-score year is 1970.
# The z-score of the annual mean is also the z-score of annual total flow
# (the mean is the total / 12).
annual <- annual %>%
  group_by(region_id) %>%
  arrange(year, .by_group = TRUE) %>%
  mutate(
    flowmean_z_pop = rolling_prior_z(flowmean_pop_annual, year),
    flowmean_z_area = rolling_prior_z(flowmean_area_annual, year),
    flowmax_z_pop = rolling_prior_z(flowmax_pop_annual, year),
    flowmax_z_area = rolling_prior_z(flowmax_area_annual, year)
  ) %>%
  ungroup()

# -------- 6. SPI of calendar-year flow --------

# Same steps as spi12_cal_pop in the Brazil SPI script: one gamma fit per
# county on its 1981-2010 calendar-year values (method of moments), the year's
# value turned into a probability under that fit, then put on the z scale.
# Calendar-year flow is the annual mean of raw flow. The SPI would be the same
# for the annual total: the gamma fit scales with the data.
# Sign: wet years are positive, like the z-scores. The Brazil regs flip it
# (spi12_dry_pop = -SPI) because there every measure is coded larger = drier.
for (weighting in WEIGHTINGS) {
  flow_col <- paste0("flowmean_", weighting, "_annual")
  spi_col <- paste0("spi12_flow_", weighting)

  spi_fit <- annual %>%
    filter(year >= SPI_BASELINE_START, year <= SPI_BASELINE_END, !is.na(.data[[flow_col]])) %>%
    group_by(region_id) %>%
    summarise(
      baseline_n = n(),
      zero_share = mean(.data[[flow_col]] <= 0),
      pos_mean = mean(.data[[flow_col]][.data[[flow_col]] > 0]),
      pos_var = var(.data[[flow_col]][.data[[flow_col]] > 0]),
      .groups = "drop"
    ) %>%
    mutate(shape = pos_mean^2 / pos_var, rate = pos_mean / pos_var)

  # Counties with flow have it in every year (the land mask does not change),
  # so every fit should use all 30 baseline years
  if (any(spi_fit$baseline_n != SPI_BASELINE_END - SPI_BASELINE_START + 1)) {
    stop("Some ", spi_col, " gamma fits do not have all 1981-2010 years", call. = FALSE)
  }

  annual <- annual %>%
    left_join(select(spi_fit, region_id, zero_share, shape, rate), by = "region_id") %>%
    mutate("{spi_col}" := spi_from_gamma(.data[[flow_col]], zero_share, shape, rate)) %>%
    select(-zero_share, -shape, -rate)
}

# Quick check over 1981-2010, as in the Brazil SPI script: about mean 0, SD 1
print(
  annual %>%
    filter(year >= SPI_BASELINE_START, year <= SPI_BASELINE_END) %>%
    summarise(across(
      c(spi12_flow_pop, spi12_flow_area),
      list(mean = ~ mean(.x, na.rm = TRUE), sd = ~ sd(.x, na.rm = TRUE),
           min = ~ min(.x, na.rm = TRUE), max = ~ max(.x, na.rm = TRUE))
    )),
  width = Inf
)

# -------- 7. Percentiles vs the previous 20 years --------

# Where the year's annual mean (drought) and annual max (flood) fall among the
# same county's 20 previous years: the z-score baseline, with the mid-rank
# percentile of annual_rain_percentile in the Brazil drought measures (which
# rank against fixed 1981-2010 years). Like the z-scores, the first year with
# a percentile is 1970
annual <- annual %>%
  group_by(region_id) %>%
  arrange(year, .by_group = TRUE) %>%
  mutate(
    flowmean_pct_pop = rolling_prior_percentile(flowmean_pop_annual, year),
    flowmean_pct_area = rolling_prior_percentile(flowmean_area_annual, year),
    flowmax_pct_pop = rolling_prior_percentile(flowmax_pop_annual, year),
    flowmax_pct_area = rolling_prior_percentile(flowmax_area_annual, year)
  ) %>%
  ungroup()

for (pct_col in c("flowmean_pct_pop", "flowmean_pct_area", "flowmax_pct_pop", "flowmax_pct_area")) {
  pct <- annual[[pct_col]]
  if (any(pct < 0 | pct > 1, na.rm = TRUE)) {
    stop(pct_col, " has values outside 0-1", call. = FALSE)
  }
}


# -----------------------------
# Final annual file
# -----------------------------

# -------- 8. Assemble output --------

# The annual file is built from the monthly one, so both should cover the
# same county-years
if (!setequal(paste(annual$region_id, annual$year), paste(flow_poly$region_id, flow_poly$year))) {
  stop("Monthly and annual flow files cover different county-years", call. = FALSE)
}

flow_annual <- annual %>%
  left_join(flow_poly, by = c("region_id", "year")) %>%
  mutate(flow_rolling_baseline_years = ROLLING_BASELINE_YEARS) %>%
  relocate(region_id, ID_0, ID_1, ID_2, year) %>%
  arrange(region_id, year)

# -------- 9. Final checks --------

if (anyDuplicated(flow_annual[c("region_id", "year")]) > 0) {
  stop("Final annual flow rows are not unique", call. = FALSE)
}

# Quick run summary printed to the console or log
summary_table <- flow_annual %>%
  summarise(
    first_year = min(year),
    last_year = max(year),
    counties = n_distinct(region_id),
    rows = n(),
    first_z_year = min(year[!is.na(flowmean_z_pop)])
  )

# Non-missing county-years for each measure
measure_summary <- flow_annual %>%
  summarise(across(
    c(
      starts_with("flow_poly_"), starts_with("upstream_poly_"), starts_with("flowmean_"),
      starts_with("flowmax_"), starts_with("spi12_flow_"), starts_with("flow_clip_")
    ),
    ~ sum(!is.na(.x))
  )) %>%
  pivot_longer(everything(), names_to = "variable", values_to = "nonmissing_rows")

print(summary_table)
print(measure_summary, n = Inf)


# -----------------------------
# Write output
# -----------------------------

if (write_output) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(flow_annual, OUTPUT_FILE)
  message("wrote: ", OUTPUT_FILE)
}
