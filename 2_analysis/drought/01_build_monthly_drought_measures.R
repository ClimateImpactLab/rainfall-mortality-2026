# ============================================================================
# 01_build_monthly_drought_measures.R
#
# Build monthly climate-only drought measures from existing ERA5-Land
# admin-month rainfall. Uses only prcp_pop_p1 and prcp_area_p1.
#
# You can run this script two ways:
#   1. Open it in RStudio and run it with the settings below
#   2. Submit it with sbatch; sbatch can pass a country list and --write
#
# Settings in the R script:
#   countries <- c("BRA")                countries to process
#   BASELINE_TYPE <- "fixed"|"rolling20" fixed baseline or prior-years baseline
#   ROLLING_BASELINE_YEARS <- 20         years used for rolling20
#   BASELINE_START <- 1981               first fixed-baseline year
#   BASELINE_END <- 2010                 last fixed-baseline year
#   output_suffix <- "_bra"              text added to the output file name
#
# Command-line/sbatch options:
#   --countries=BRA                      countries to process
#   --write                              save the RDS output
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/monthly/era5land_admin_drought_monthly<output_suffix>.rds
# ==============================================================================


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

# paths to ERA5-Land monthly country folders
DATA_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data"
ERA5_DIR <- file.path(DATA_DIR, "ERA5-LAND")
DROUGHT_DIR <- file.path(ERA5_DIR, "drought")
DROP_REGIONS <- file.path(ERA5_DIR, "diagnostics/drought_baseline/drought_baseline_drop_regions.csv")

# ------ Change these settings before running the script ------

countries <- c("BRA")
BASELINE_TYPE <- "rolling20" # fixed or rolling20
BASELINE_START <- 1981 # fixed baseline and Rocha-Soares start year
BASELINE_END <- 2010 # fixed baseline and Rocha-Soares end year
ROLLING_BASELINE_YEARS <- 20 # complete prior years required for rolling20
WINDOWS <- c(1, 3, 6, 12) # rolling rainfall windows, in months
WEIGHTINGS <- c("pop", "area") # pop- and area-weighted precip
write_output <- FALSE # TRUE only when --write is passed
output_suffix <- "_bra" # appended to era5land_admin_drought_monthly


# Sbatch can change only the country list and whether the file is written.
args <- commandArgs(trailingOnly = TRUE)
write_output <- "--write" %in% args

country_arg <- args[str_detect(args, "^--countries=")]
if (length(country_arg) > 0) {
  countries <- str_remove(country_arg[[1]], "^--countries=") %>%
    str_split(",", simplify = FALSE) %>%
    unlist(use.names = FALSE) %>%
    str_trim() %>%
    toupper()
}


BASELINE_YEARS <- BASELINE_START:BASELINE_END


# Print the choices actually used in this run:
message(
  "Countries: ", paste(countries, collapse = ", "),
  " | baseline: ", ifelse(BASELINE_TYPE == "fixed",
    paste0("fixed ", BASELINE_START, "-", BASELINE_END),
    paste0("prior ", ROLLING_BASELINE_YEARS, " years")
    )
)


# -----------------------------
# Small functions
# -----------------------------

# Rolling sum ending in the current row
# The month index check keeps a 3-month total from spanning a missing month if
# a country-admin panel has a gap
rolling_month_sum <- function(rain, month_index, window) {
  if (window == 1) return(as.numeric(rain))

  rolling_total <- as.numeric(stats::filter(rain, rep(1, window), sides = 1))
  first_month <- dplyr::lag(month_index, window - 1)
  complete_window <- !is.na(first_month) & month_index - first_month == window - 1
  rolling_total[!complete_window] <- NA_real_
  rolling_total
}

# Mid-rank percentile: share of baseline values below the current value + half the 
# share tied with it
midrank_percentile <- function(value, baseline_values) {
  if (is.na(value) || length(baseline_values) == 0) return(NA_real_)
  (sum(baseline_values < value) + 0.5 * sum(baseline_values == value)) / length(baseline_values)
}


# -----------------------------
# Read monthly rainfall
# -----------------------------

# -------- 1. Read country files --------

drop_regions <- read_csv(DROP_REGIONS, show_col_types = FALSE) %>%
  filter(drought_baseline_action == "drop_or_flag") %>%
  transmute(climate_country = country, region_id)

monthly_list <- list()

for (country in countries) {
  monthly_dir <- file.path(ERA5_DIR, country, "monthly")
  files <- list.files(monthly_dir, pattern = "^era5land_.*_monthly_[0-9]{4}\\.csv$", full.names = TRUE)
  file_years <- as.integer(str_replace(basename(files), ".*_([0-9]{4})\\.csv$", "\\1"))
  files <- files[order(file_years)]
  file_years <- file_years[order(file_years)]

  message(country, ": reading ", min(file_years), "-", max(file_years))

  monthly_list[[country]] <- bind_rows(lapply(files, function(path) {
    input <- read_csv(path, show_col_types = FALSE)
    # Keep source admin IDs plus the two rainfall variables used here
    admin_cols <- names(input)[!str_detect(names(input), "^(prcp|tmean|tmax)_")]

    input %>%
      select(all_of(admin_cols), prcp_pop_p1, prcp_area_p1) %>%
      mutate(climate_country = country, .before = 1)
  }))
}

# Bind yearly country files into one monthly admin panel
monthly <- bind_rows(monthly_list) %>%
  rename(prcp_pop_mm = prcp_pop_p1, prcp_area_mm = prcp_area_p1) %>%
  relocate(climate_country, region_id, month)

# -------- 2. Build monthly dates --------

monthly <- monthly %>%
  mutate(
    # First day is used only as a monthly date key
    date_month = as.Date(paste0(month, "-01")),
    year = as.integer(format(date_month, "%Y")),
    month_number = as.integer(format(date_month, "%m")),
    # Continuous month index used to detect gaps in rolling windows
    month_index = year * 12 + month_number
  )

# -------- 3. Flag dropped regions --------

monthly <- monthly %>%
  left_join(drop_regions %>% mutate(unsupported_baseline_region = TRUE), by = c("climate_country", "region_id")) %>%
  mutate(unsupported_baseline_region = coalesce(unsupported_baseline_region, FALSE))


# -----------------------------
# Rolling rainfall totals
# -----------------------------

# -------- 4. Calculate rolling rainfall --------

# 1 month = current month
# 3/6/12 months add the previous 2/5/11 months
# Incomplete month sequences are left missing
# Example: if March is missing, the April-ending 3-month total is missing too

monthly <- monthly %>%
  arrange(climate_country, region_id, month_index)

# Build each rainfall window for pop and area weighting
for (weighting in WEIGHTINGS) {
  source_col <- paste0("prcp_", weighting, "_mm")

  for (window in WINDOWS) {
    target_col <- sprintf("prcp_%02dm_%s_mm", window, weighting)

    # Within each admin, sum the current and prior months for this window
    monthly <- monthly %>%
      group_by(climate_country, region_id) %>%
      arrange(month_index, .by_group = TRUE) %>%
      mutate("{target_col}" := rolling_month_sum(.data[[source_col]], month_index, window)) %>%
      ungroup()
  }
}


# -----------------------------
# Baseline comparison
# -----------------------------

# -------- 5. Reshape rainfall measures --------

# Put the eight rainfall columns into one long column so the same baseline code
# applies to every window and weighting.
measure_long <- monthly %>%
  select(
    climate_country, region_id, unsupported_baseline_region,
    date_month, year, month_number,
    matches("^prcp_[0-9]{2}m_(pop|area)_mm$")
  ) %>%
  pivot_longer(
    cols = matches("^prcp_[0-9]{2}m_(pop|area)_mm$"),
    names_to = "rain_measure",
    values_to = "rain_mm"
  ) %>%
  mutate(
    # Pull window and weighting back out of names like prcp_06m_pop_mm 
    window = as.integer(str_match(rain_measure, "^prcp_([0-9]{2})m_")[, 2]),
    window_label = sprintf("%02dm", window),
    weighting = str_match(rain_measure, "^prcp_[0-9]{2}m_(pop|area)_mm$")[, 2]
  ) %>%
  arrange(climate_country, region_id, month_number, window, weighting, year)

if (BASELINE_TYPE == "fixed") {
  
  # -------- 6. Fixed baseline --------

  # Same-calendar-month baseline: July-ending 6-month rainfall is compared
  # with July-ending 6-month rainfall for the same admin and weighting.
  baseline <- measure_long %>%
    filter(year >= BASELINE_START, year <= BASELINE_END) %>%
    # Separate baselines for each admin, ending month, window, and weighting.
    group_by(
      climate_country, region_id, unsupported_baseline_region,
      month_number, window, window_label, weighting
    ) %>%
    summarise(
      # Keep the baseline values for the empirical percentile calc:
      baseline_values = list(rain_mm[!is.na(rain_mm)]),
      baseline_n = length(baseline_values[[1]]),
      baseline_mean_mm = if (baseline_n == 0) NA_real_ else mean(baseline_values[[1]]),
      baseline_min_mm = if (baseline_n == 0) NA_real_ else min(baseline_values[[1]]),
      baseline_sd_mm = if (baseline_n < 2) NA_real_ else sd(baseline_values[[1]]),
      .groups = "drop"
    )

  # Most regions should have one baseline value per fixed-baseline year
  bad_baseline <- baseline %>%
    filter(unsupported_baseline_region == FALSE, baseline_n != length(BASELINE_YEARS))

  if (nrow(bad_baseline) > 0) {
    print(head(bad_baseline, 20))
    stop("Some baseline groups do not have the expected number of years", call. = FALSE)
  }

  # Attach fixed-baseline statistics to every monthly rainfall observation
  measure_long <- measure_long %>%
    left_join(
      baseline,
      by = c(
        "climate_country", "region_id", "unsupported_baseline_region",
        "month_number", "window", "window_label", "weighting"
      )
    ) %>%
    mutate(
      # Mid-rank percentile: share below plus half of ties
      percentile = mapply(midrank_percentile, rain_mm, baseline_values)
    ) %>%
    select(-baseline_values)
} else {
  
  # -------- 7. Rolling baseline --------

  # Same admin, ending calendar month, window, and weighting
  # Each group is a year-by-year series for one exact comparison
  rolling_groups <- measure_long %>%
    group_by(
      climate_country, region_id, unsupported_baseline_region,
      month_number, window, window_label, weighting
    ) %>%
    group_split()

  # Compare each row with the previous N years in its own group
  rolling_baseline <- bind_rows(lapply(rolling_groups, function(group) {
    group <- group %>%
      arrange(year) %>%
      mutate(
        baseline_n = NA_integer_,
        baseline_mean_mm = NA_real_,
        baseline_min_mm = NA_real_,
        baseline_sd_mm = NA_real_,
        percentile = NA_real_
      )

    for (row_id in seq_len(nrow(group))) {
      # Require the full 20 prior years: current year and future years are excluded
      prior_years <- group$year >= group$year[row_id] - ROLLING_BASELINE_YEARS &
        group$year <= group$year[row_id] - 1
      baseline_values <- group$rain_mm[prior_years & !is.na(group$rain_mm)]

      # Leave measures missing until the full rolling baseline is available
      if (length(baseline_values) == ROLLING_BASELINE_YEARS) {
        group$baseline_n[row_id] <- length(baseline_values)
        group$baseline_mean_mm[row_id] <- mean(baseline_values)
        group$baseline_min_mm[row_id] <- min(baseline_values)
        group$baseline_sd_mm[row_id] <- sd(baseline_values)
        group$percentile[row_id] <- midrank_percentile(group$rain_mm[row_id], baseline_values)
      }
    }

    group
  }))

  measure_long <- rolling_baseline
}

measure_long <- measure_long %>%
  mutate(percentile = if_else(unsupported_baseline_region | is.na(rain_mm), NA_real_, percentile))


# -----------------------------
# Monthly drought measures
# -----------------------------

# -------- 8. Percentiles, z-scores and deficits --------

measure_long <- measure_long %>%
  mutate(
    # Standardized relative to the relevant fixed or rolling baseline
    z = if_else(
      !is.na(rain_mm) & !is.na(baseline_sd_mm) & baseline_sd_mm > 0,
      (rain_mm - baseline_mean_mm) / baseline_sd_mm,
      NA_real_
    ),
    # Empirical drought thresholds and the stricter "below all baseline values" case
    dry10 = if_else(is.na(percentile), NA_integer_, as.integer(percentile <= 0.10)),
    dry05 = if_else(is.na(percentile), NA_integer_, as.integer(percentile <= 0.05)),
    below_baseline_min = if_else(
      is.na(rain_mm) | is.na(baseline_min_mm),
      NA_integer_,
      as.integer(rain_mm < baseline_min_mm)
    ),
    # Rainfall deficit below the baseline mean (in mm)
    deficit_mm = if_else(
      !is.na(rain_mm) & !is.na(baseline_mean_mm),
      pmax(0, baseline_mean_mm - rain_mm),
      NA_real_
    ),
    # Same deficit but as a share of the baseline mean
    deficit_share = if_else(
      !is.na(rain_mm) & !is.na(baseline_mean_mm) & baseline_mean_mm > 0,
      pmax(0, 1 - rain_mm / baseline_mean_mm),
      NA_real_
    )
  )

# Return to one row per admin-month, with separate columns for each window and weighting
monthly_measures <- measure_long %>%
  select(
    climate_country, region_id, date_month, year, month_number,
    window_label, weighting,
    rain_mm, percentile, z, dry10, dry05, below_baseline_min,
    deficit_mm, deficit_share, baseline_n
  ) %>%
  pivot_wider(
    names_from = c(window_label, weighting),
    values_from = c(rain_mm, percentile, z, dry10, dry05, below_baseline_min, deficit_mm, deficit_share, baseline_n),
    names_glue = "{.value}_{window_label}_{weighting}"
  )


# -----------------------------
# Rocha-Soares measure
# -----------------------------

# -------- 9. Annual baseline --------

# Rocha-Soares is separate: rolling 12-month rainfall is compared with a
# fixed-baseline annual rainfall mean and SD, not same-calendar-month rainfall

# Annual rainfall requires all 12 monthly observations in the calendar year
annual_rain <- monthly %>%
  group_by(climate_country, region_id, unsupported_baseline_region, year) %>%
  summarise(
    prcp_pop_annual_mm = {
      n <- sum(!is.na(prcp_pop_mm))
      if (n == 12) sum(prcp_pop_mm, na.rm = TRUE) else NA_real_
    },
    prcp_area_annual_mm = {
      n <- sum(!is.na(prcp_area_mm))
      if (n == 12) sum(prcp_area_mm, na.rm = TRUE) else NA_real_
    },
    .groups = "drop"
  )


# Estimate the fixed annual baseline mean and SD for each admin and weighting
rs_stats <- annual_rain %>%
  pivot_longer(
    cols = c(prcp_pop_annual_mm, prcp_area_annual_mm),
    names_to = "rain_measure",
    values_to = "annual_rain_mm"
  ) %>%
  mutate(weighting = str_match(rain_measure, "^prcp_(pop|area)_annual_mm$")[, 2]) %>%
  filter(year >= BASELINE_START, year <= BASELINE_END) %>%
  group_by(climate_country, region_id, unsupported_baseline_region, weighting) %>%
  summarise(
    rs_n = sum(!is.na(annual_rain_mm)),
    rs_mean_annual_mm = if (rs_n == 0) NA_real_ else mean(annual_rain_mm, na.rm = TRUE),
    rs_sd_annual_mm = if (rs_n < 2) NA_real_ else sd(annual_rain_mm, na.rm = TRUE),
    .groups = "drop"
  )

# Rocha-Soares drought cutoff: one SD below fixed-baseline annual rainfall
rs_stats <- rs_stats %>%
  mutate(rs_threshold_mm = rs_mean_annual_mm - rs_sd_annual_mm)

# -------- 10. Rolling 12-month measure --------

# Attach annual baseline stats to each rolling 12-month rainfall observation
rs_long <- monthly %>%
  select(
    climate_country, region_id, unsupported_baseline_region,
    date_month, year, month_number,
    prcp_12m_pop_mm, prcp_12m_area_mm
  ) %>%
  pivot_longer(
    cols = c(prcp_12m_pop_mm, prcp_12m_area_mm),
    names_to = "rain_measure",
    values_to = "prcp_12m_mm"
  ) %>%
  mutate(weighting = str_match(rain_measure, "^prcp_12m_(pop|area)_mm$")[, 2]) %>%
  left_join(rs_stats, by = c("climate_country", "region_id", "unsupported_baseline_region", "weighting")) %>%
  mutate(
    # Log difference from the fixed-baseline annual mean
    rs_logdev_12m = if_else(
      !is.na(prcp_12m_mm) & prcp_12m_mm > 0 & !is.na(rs_mean_annual_mm) & rs_mean_annual_mm > 0,
      log(prcp_12m_mm) - log(rs_mean_annual_mm),
      NA_real_
    ),
    # Percent difference from the fixed-baseline annual mean
    rs_pctdev_12m = if_else(
      !is.na(prcp_12m_mm) & !is.na(rs_mean_annual_mm) & rs_mean_annual_mm > 0,
      100 * (prcp_12m_mm / rs_mean_annual_mm - 1),
      NA_real_
    ),
    # Indicator for rolling 12-month rainfall below mean minus one SD
    rs_drought_12m = if_else(
      is.na(prcp_12m_mm) | is.na(rs_threshold_mm),
      NA_integer_,
      as.integer(prcp_12m_mm < rs_threshold_mm)
    )
  )

# Keep separate pop and area-weighted Rocha-Soares columns: 
rs_measures <- rs_long %>%
  select(
    climate_country, region_id, date_month, year, month_number, weighting,
    rs_logdev_12m, rs_pctdev_12m, rs_drought_12m,
    rs_mean_annual_mm, rs_sd_annual_mm, rs_threshold_mm, rs_n
  ) %>%
  pivot_wider(
    names_from = weighting,
    values_from = c(
      rs_logdev_12m, rs_pctdev_12m, rs_drought_12m,
      rs_mean_annual_mm, rs_sd_annual_mm, rs_threshold_mm, rs_n
    ),
    names_glue = "{.value}_{weighting}"
  )


# -----------------------------
# Final monthly file
# -----------------------------

# -------- 11. Assemble output --------

# Country files can carry different source admin IDs, so keep whichever are present.
admin_info <- monthly %>%
  select(climate_country, region_id,
         any_of(c("ID_0", "ID_1", "ID_2", "UNID")),
         unsupported_baseline_region) %>%
  distinct()

# Combine monthly drought measures, Rocha-Soares measures, and source admin IDs 
drought_monthly <- monthly_measures %>%
  left_join(rs_measures, by = c("climate_country", "region_id", "date_month", "year", "month_number")) %>%
  left_join(admin_info, by = c("climate_country", "region_id")) %>%
  relocate(climate_country, region_id, any_of(c("ID_0", "ID_1", "ID_2", "UNID")), unsupported_baseline_region)


# Keep dropped regions in the file, but set drought measures to missing
drought_measure_prefixes <- c(
  "rain_mm_", "percentile_", "z_", "dry10_", "dry05_",
  "below_baseline_min_", "deficit_mm_", "deficit_share_",
  "baseline_n_", "rs_"
)
drought_measure_cols <- drought_monthly %>%
  select(starts_with(drought_measure_prefixes)) %>%
  names()
drought_monthly[drought_monthly$unsupported_baseline_region, drought_measure_cols] <- NA


# Add baseline settings as columns. This does not affect the file name
drought_monthly <- drought_monthly %>%
  mutate(
    drought_baseline_type = BASELINE_TYPE,
    drought_fixed_baseline_start = if_else(BASELINE_TYPE == "fixed", BASELINE_START, NA_integer_),
    drought_fixed_baseline_end = if_else(BASELINE_TYPE == "fixed", BASELINE_END, NA_integer_),
    drought_rolling_baseline_years = if_else(BASELINE_TYPE == "rolling20", ROLLING_BASELINE_YEARS, NA_integer_),
    drought_rs_baseline_start = BASELINE_START,
    drought_rs_baseline_end = BASELINE_END
  ) %>%
  arrange(climate_country, region_id, date_month)

# -------- 12. Final checks --------

# Each admin-month should appear once after the measure joins
if (drought_monthly %>% count(climate_country, region_id, year, month_number) %>% filter(n > 1) %>% nrow() > 0) {
  stop("Final monthly drought rows are not unique", call. = FALSE)
}

# Quick run summary printed to the console or sbatch log
summary_table <- drought_monthly %>%
  group_by(climate_country) %>%
  summarise(
    first_year = min(year),
    last_year = max(year),
    admin_units = n_distinct(region_id),
    unsupported_regions = n_distinct(region_id[unsupported_baseline_region]),
    rows = n(),
    .groups = "drop"
  )

print(summary_table)


# -----------------------------
# Write output
# -----------------------------

if (write_output) {
  output_dir <- file.path(DROUGHT_DIR, "monthly")
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  output_file <- file.path(output_dir, paste0("era5land_admin_drought_monthly", output_suffix, ".rds"))
  saveRDS(drought_monthly, output_file)

  message("wrote: ", output_file)
} else {
  message("No output written. Add --write to save the monthly drought file.")
}
