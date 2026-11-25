# ============================================================================
# 02_build_annual_drought_summaries.R
#
# Yearly drought measures for each Brazil municipality, from the monthly
# file made by 01_build_monthly_drought_measures.R. One row per
# municipality x year, merged into the mortality panel later.
#
# 1. Calendar-year rainfall (Jan-Dec).
#    Baseline: 1981-2010.
#      percentile, z-score, log and % deviation from the mean, -log rainfall
#      dry10, dry05: at or below p10 / p5
#
# 2. The monthly measures summed up over the year, for the 1, 3, 6 and
#    12-month windows.
#      worst z-score and largest deficit in the year
#      number of months below p10 / p5 (and any, and longest run)
#      number of months below the driest baseline year
#      1-month window only: z-scores below 0 and deficits added up over
#      the year (all months, and only the months below p10 / p5)
#    A window belongs to the year of its last month (a 6-month window ending
#    in February 2003 counts in 2003). Longer windows overlap, so their counts
#    are counts of dry windows, not of separate dry months.
#
# 3. Dry episodes: 2+ consecutive months below p10 / p5. Episodes can span
#    two years (for ex Nov-Feb).
#
# 4. Rocha-Soares: number of months in drought, longest run, worst deviation.
#
# Options:
#   --monthly-files=file1.rds,file2.rds   monthly drought files to summarize
#   --write                               save the RDS output
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/annual/era5land_admin_drought_annual<output_suffix>.rds
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
# ------------------------

# Drought files from 01_build_monthly_drought_measures.R
DATA_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data"
ERA5_DIR <- file.path(DATA_DIR, "ERA5-LAND")
DROUGHT_DIR <- file.path(ERA5_DIR, "drought")


#  ------ Change these settings before running the script ----------

monthly_files <- file.path(
  DROUGHT_DIR,
  "monthly",
  "era5land_admin_drought_monthly_bra.rds"
)

BASELINE_START <- 1981 # annual rainfall baseline start year
BASELINE_END <- 2010 # annual rainfall baseline end year
WINDOWS <- c(1, 3, 6, 12) # rolling rainfall windows, in months
WEIGHTINGS <- c("pop", "area") # pop- and area-weighted precip
THRESHOLDS <- c("dry10", "dry05") # drought indicators to summarize

output_suffix <- "_bra" # appended to era5land_admin_drought_annual


# Sbatch can change only the monthly input files and whether the file is written
args <- commandArgs(trailingOnly = TRUE)
write_output <- "--write" %in% args

# By default the script reads the Brazil monthly file set above. The sbatch
# can point it to other monthly files instead
monthly_files_arg <- args[str_detect(args, "^--monthly-files=")]
if (length(monthly_files_arg) > 0) {
  monthly_files <- str_remove(monthly_files_arg[[1]], "^--monthly-files=") %>%
    str_split(",", simplify = FALSE) %>%
    unlist(use.names = FALSE) %>%
    str_trim()
}

# Years used for the calendar-year rainfall baseline, 1981-2010 (30 years)
BASELINE_YEARS <- BASELINE_START:BASELINE_END

# Print the choices used in this run to the log
message("Monthly files: ", paste(monthly_files, collapse = ", "))
message("Thresholds: ", paste(THRESHOLDS, collapse = ", "))
message("Annual rainfall baseline: ", BASELINE_START, "-", BASELINE_END)


# -------------------------
# Small functions
# -------------------------


# Longest uninterrupted true spell, used for drought run lengths (drought episodes)
longest_true_run <- function(values) {
  values <- values[!is.na(values)]
  if (length(values) == 0 || !any(values)) return(0)
  runs <- rle(values)
  max(runs$lengths[runs$values])
}

# Mid-rank percentile: share of baseline values below the current value + half the
# share tied with it
midrank_percentile <- function(value, baseline_values) {
  if (is.na(value) || length(baseline_values) == 0) return(NA_real_)
  (sum(baseline_values < value) + 0.5 * sum(baseline_values == value)) / length(baseline_values)
}


# -----------------------------
# Read monthly drought measures
# -----------------------------

# -------- 1. Read monthly files --------

monthly <- bind_rows(lapply(monthly_files, readRDS))

# Month index lets the episode code check whether months are adjacent
monthly <- monthly %>%
  mutate(month_index = year * 12 + month_number) %>%
  arrange(climate_country, region_id, month_index)

# Country files can carry different source admin IDs, so keep whichever are present
admin_info <- monthly %>%
  select(
    climate_country, region_id,
    any_of(c("ID_0", "ID_1", "ID_2", "UNID")),
    unsupported_baseline_region,
    any_of(c(
      "drought_baseline_type",
      "drought_fixed_baseline_start", "drought_fixed_baseline_end",
      "drought_rolling_baseline_years",
      "drought_rs_baseline_start", "drought_rs_baseline_end"
    ))
  ) %>%
  distinct()


# -----------------------------
# Annual rainfall
# -----------------------------

# -------- 2. Calendar-year rainfall --------

# Calendar-year rainfall is the sum of the 12 one-month rainfall values
annual_rain <- monthly %>%
  group_by(climate_country, region_id, year) %>%
  summarise(
    annual_rain_mm_pop = if (sum(!is.na(rain_mm_01m_pop)) == 12) sum(rain_mm_01m_pop, na.rm = TRUE) else NA_real_,
    annual_rain_mm_area = if (sum(!is.na(rain_mm_01m_area)) == 12) sum(rain_mm_01m_area, na.rm = TRUE) else NA_real_,
    .groups = "drop"
  )

# Put pop- and area-weighted annual rainfall in one column for the
# shared baseline comparison
annual_long <- annual_rain %>%
  pivot_longer(
    cols = c(annual_rain_mm_pop, annual_rain_mm_area),
    names_to = "measure",
    values_to = "annual_rain_mm"
  ) %>%
  mutate(weighting = str_remove(measure, "^annual_rain_mm_"))

# -------- 3. Annual rainfall baseline --------

# Annual rainfall is compared with the admin's annual rainfall distribution
# over the fixed baseline years
annual_baseline <- annual_long %>%
  filter(year >= BASELINE_START, year <= BASELINE_END) %>%
  group_by(climate_country, region_id, weighting) %>%
  summarise(
    baseline_values = list(annual_rain_mm[!is.na(annual_rain_mm)]),
    baseline_n = length(baseline_values[[1]]),
    baseline_mean_mm = if (baseline_n == 0) NA_real_ else mean(baseline_values[[1]]),
    baseline_sd_mm = if (baseline_n < 2) NA_real_ else sd(baseline_values[[1]]),
    .groups = "drop"
  )

# Supported regions need one annual baseline value for every baseline year
bad_annual_baseline <- annual_baseline %>%
  left_join(
    admin_info %>% select(climate_country, region_id, unsupported_baseline_region),
    by = c("climate_country", "region_id")
  ) %>%
  filter(unsupported_baseline_region == FALSE, baseline_n != length(BASELINE_YEARS))

if (nrow(bad_annual_baseline) > 0) {
  print(head(bad_annual_baseline, 20))
  stop("Some annual rainfall baseline groups do not have the expected number of years", call. = FALSE)
}

# Compare each admin-year with that admin's fixed annual rainfall baseline
annual_long <- annual_long %>%
  left_join(annual_baseline, by = c("climate_country", "region_id", "weighting")) %>%
  mutate(
    # Same mid-rank percentile definition as the monthly drought file
    annual_rain_percentile = mapply(midrank_percentile, annual_rain_mm, baseline_values),
    # Standardized relative to the annual rainfall baseline
    annual_rain_z = if_else(
      !is.na(annual_rain_mm) & !is.na(baseline_sd_mm) & baseline_sd_mm > 0,
      (annual_rain_mm - baseline_mean_mm) / baseline_sd_mm,
      NA_real_),
    # Log difference from baseline mean
    annual_rain_logdev = if_else(
      !is.na(annual_rain_mm) & annual_rain_mm > 0 & !is.na(baseline_mean_mm) & baseline_mean_mm > 0,
      log(annual_rain_mm) - log(baseline_mean_mm),
      NA_real_),
    # Percent difference from baseline mean
    annual_rain_pctdev = if_else(
      !is.na(annual_rain_mm) & !is.na(baseline_mean_mm) & baseline_mean_mm > 0,
      100 * (annual_rain_mm / baseline_mean_mm - 1),
      NA_real_),
    # Minus log annual rainfall, so larger = drier (the Gehring-Schaudt/QJE benchmark)
    annual_rain_neglog = if_else(
      !is.na(annual_rain_mm) & annual_rain_mm > 0,
      -log(annual_rain_mm),
      NA_real_),
    # Annual rainfall drought thresholds
    annual_rain_dry10 = if_else(is.na(annual_rain_percentile), NA_integer_, as.integer(annual_rain_percentile <= 0.10)),
    annual_rain_dry05 = if_else(is.na(annual_rain_percentile), NA_integer_, as.integer(annual_rain_percentile <= 0.05))) %>%
  select(-measure, -baseline_values, -baseline_n, -baseline_mean_mm, -baseline_sd_mm)

# Return to one row per admin-year, with pop and area versions side by side
annual_wide <- annual_long %>%
  pivot_wider(
    names_from = weighting,
    values_from = c(
      annual_rain_mm, annual_rain_percentile, annual_rain_z,
      annual_rain_logdev, annual_rain_pctdev, annual_rain_neglog,
      annual_rain_dry10, annual_rain_dry05
    ),
    names_glue = "{.value}_{weighting}"
  )


# ---------------------------------
# Window-specific annual summaries
# ---------------------------------

# -------- 4. Monthly drought summaries by year --------

# Start from every admin-year so each loop can add one set of summaries
annual_keys <- monthly %>%
  distinct(climate_country, region_id, year)

window_summary <- annual_keys

for (weighting in WEIGHTINGS) {
  for (window in WINDOWS) {
    pct_col <- sprintf("percentile_%02dm_%s", window, weighting)
    z_col <- sprintf("z_%02dm_%s", window, weighting)
    deficit_col <- sprintf("deficit_mm_%02dm_%s", window, weighting)
    min_col <- sprintf("below_baseline_min_%02dm_%s", window, weighting)

    # Worst value in the year. Summing would count the same months several
    # times for 3-12 month windows (they overlap)
    severity <- monthly %>%
      transmute(
        climate_country, region_id, year,
        percentile = .data[[pct_col]],
        z = .data[[z_col]],
        deficit_mm = .data[[deficit_col]],
        below_baseline_min = .data[[min_col]]) %>%
      group_by(climate_country, region_id, year) %>%
      summarise(
        usable_months = sum(!is.na(percentile)),
        # Most negative standardized rainfall value reached in the year
        worst_z = if (usable_months == 12 && any(!is.na(z))) min(z, na.rm = TRUE) else NA_real_,
        # Largest rainfall deficit relative to the relevant baseline mean
        deficit_mm_max = if (usable_months == 12 && any(!is.na(deficit_mm))) max(deficit_mm, na.rm = TRUE) else NA_real_,
        # Months/windows below every value in the comparison period
        below_baseline_min_months = if (usable_months == 12) {
          as.integer(sum(below_baseline_min == 1, na.rm = TRUE))
        } else {
          NA_integer_
        },
        .groups = "drop") %>%
      select(-usable_months)

    summary_cols <- setdiff(names(severity), c("climate_country", "region_id", "year"))
    names(severity)[names(severity) %in% summary_cols] <- sprintf("%s_%02dm_%s", summary_cols, window, weighting)

    window_summary <- window_summary %>%
      left_join(severity, by = c("climate_country", "region_id", "year"))

    if (window == 1) {
      # Calendar-year sums are kept only for the 1-month measure
      # For longer windows, summed values would reuse overlapping rainfall months
      one_month_sum <- monthly %>%
        transmute(
          climate_country, region_id, year,
          percentile = .data[[pct_col]],
          z = .data[[z_col]],
          deficit_mm = .data[[deficit_col]]
        ) %>%
        group_by(climate_country, region_id, year) %>%
        summarise(
          usable_months = sum(!is.na(percentile)),
          # Sum of below-normal monthly z-scores. Positive z-scores contribute zero
          z_belownormal_sum = if (usable_months == 12) sum(pmax(0, -z), na.rm = TRUE) else NA_real_,
          # Sum of monthly rainfall deficits relative to the baseline mean
          deficit_mm_sum = if (usable_months == 12) sum(deficit_mm, na.rm = TRUE) else NA_real_,
          .groups = "drop"
        ) %>%
        select(-usable_months)

      summary_cols <- setdiff(names(one_month_sum), c("climate_country", "region_id", "year"))
      names(one_month_sum)[names(one_month_sum) %in% summary_cols] <- sprintf("%s_%02dm_%s", summary_cols, window, weighting)

      window_summary <- window_summary %>%
        left_join(one_month_sum, by = c("climate_country", "region_id", "year"))
    }

    for (threshold in THRESHOLDS) {
      dry_col <- sprintf("%s_%02dm_%s", threshold, window, weighting)

      # Year assignment uses the ending month of the rolling window
      # A 6-month value ending in February belongs to that February's year
      # For 3, 6 and 12-month measures, this counts low rolling windows,
      # not separate non-overlapping drought months
      state <- monthly %>%
        transmute(
          climate_country, region_id, year,
          dry = .data[[dry_col]]
        ) %>%
        group_by(climate_country, region_id, year) %>%
        summarise(
          usable_months = sum(!is.na(dry)),
          has_dry_month = any(dry == 1, na.rm = TRUE),
          # Require all 12 ending months before constructing annual counts
          drought_months = if (usable_months == 12) as.integer(sum(dry == 1, na.rm = TRUE)) else NA_integer_,
          drought_any = if (usable_months == 12) as.integer(has_dry_month) else NA_integer_,
          drought_longest_run = if (usable_months == 12) longest_true_run(dry == 1) else NA_integer_,
          .groups = "drop"
        ) %>%
        select(-usable_months, -has_dry_month)

      # Name columns by threshold, window, and weighting
      summary_cols <- setdiff(names(state), c("climate_country", "region_id", "year"))
      names(state)[names(state) %in% summary_cols] <- sprintf("%s_%s_%02dm_%s", summary_cols, threshold, window, weighting)

      # Add this threshold-window-weighting summary to the annual file
      window_summary <- window_summary %>%
        left_join(state, by = c("climate_country", "region_id", "year"))

      if (window == 1) {
        # Thresholded sums are also only kept for the 1-month measure
        # This gives cumulative annual deficit among low-rainfall months
        one_month_threshold_sum <- monthly %>%
          transmute(
            climate_country, region_id, year,
            dry = .data[[dry_col]],
            percentile = .data[[pct_col]],
            z = .data[[z_col]],
            deficit_mm = .data[[deficit_col]]
          ) %>%
          group_by(climate_country, region_id, year) %>%
          summarise(
            usable_months = sum(!is.na(percentile)),
            # Below-normal z-score intensity among months crossing the threshold
            z_belownormal_sum = if (usable_months == 12) {
              sum(pmax(0, -z)[dry == 1], na.rm = TRUE)
            } else {
              NA_real_
            },
            # Rainfall deficit among months crossing the threshold
            deficit_mm_sum = if (usable_months == 12) {
              sum(deficit_mm[dry == 1], na.rm = TRUE)
            } else {
              NA_real_
            },
            .groups = "drop"
          ) %>%
          select(-usable_months)

        summary_cols <- setdiff(names(one_month_threshold_sum), c("climate_country", "region_id", "year"))
        names(one_month_threshold_sum)[names(one_month_threshold_sum) %in% summary_cols] <- sprintf(
          "%s_%s_%02dm_%s", summary_cols, threshold, window, weighting
        )

        window_summary <- window_summary %>%
          left_join(one_month_threshold_sum, by = c("climate_country", "region_id", "year"))
      }
    }
  }
}


# -----------------------------
# One-month drought episodes
# -----------------------------

# -------- 5. Runs of at least two dry months --------

# Build episode summaries separately for each threshold and weighting
episode_summary <- annual_keys

for (weighting in WEIGHTINGS) {
  for (threshold in THRESHOLDS) {
    dry_col <- sprintf("%s_01m_%s", threshold, weighting)
    pct_col <- sprintf("percentile_01m_%s", weighting)
    deficit_col <- sprintf("deficit_mm_01m_%s", weighting)

    # Episodes use the 1-month drought indicator and require at least two
    # consecutive dry months
    episode_months <- monthly %>%
      transmute(
        climate_country, region_id, year, month_index,
        dry = .data[[dry_col]] == 1,
        percentile = .data[[pct_col]],
        deficit_mm = .data[[deficit_col]]
      ) %>%
      arrange(climate_country, region_id, month_index) %>%
      group_by(climate_country, region_id) %>%
      mutate(
        # Runs continue across December-January. Missing calendar months break the run
        month_is_next = month_index == lag(month_index) + 1,
        dry_for_run = coalesce(dry, FALSE),
        new_run = row_number() == 1 | !month_is_next | dry_for_run != lag(dry_for_run),
        run_id = cumsum(new_run)
      ) %>%
      ungroup()

    # Keep only dry spells that last at least two consecutive months
    run_lengths <- episode_months %>%
      filter(dry == TRUE) %>%
      group_by(climate_country, region_id, run_id) %>%
      summarise(
        run_length = n(),
        start_year = min(year),
        end_year = max(year),
        .groups = "drop"
      ) %>%
      filter(run_length >= 2)


    # Mark each monthly row that belongs to a qualifying episode
    episode_months <- episode_months %>%
      left_join(run_lengths, by = c("climate_country", "region_id", "run_id")) %>%
      mutate(in_episode = !is.na(run_length))

    # A November-February episode is one four-month episode
    # Annual summaries count the months that fall in each year, while episode_full_longest_run
    # keeps the full run length
    episodes <- episode_months %>%
      group_by(climate_country, region_id, year) %>%
      summarise(
        has_episode = any(in_episode, na.rm = TRUE),
        episode_months = as.integer(sum(in_episode, na.rm = TRUE)),
        episode_any = as.integer(has_episode),
        episode_longest_run = longest_true_run(in_episode),
        episode_full_longest_run = if (has_episode) max(run_length[in_episode], na.rm = TRUE) else 0,
        episode_cross_year = as.integer(any(in_episode & start_year != end_year, na.rm = TRUE)),
        episode_worst_percentile = if (has_episode) min(percentile[in_episode], na.rm = TRUE) else NA_real_,
        episode_deficit_mm_sum = if (has_episode) sum(deficit_mm[in_episode], na.rm = TRUE) else NA_real_,
        .groups = "drop"
      ) %>%
      select(-has_episode)

    # Name columns by threshold and weighting
    summary_cols <- setdiff(names(episodes), c("climate_country", "region_id", "year"))
    names(episodes)[names(episodes) %in% summary_cols] <- sprintf("%s_%s_01m_%s", summary_cols, threshold, weighting)

    # Add this episode summary to the annual file
    episode_summary <- episode_summary %>%
      left_join(episodes, by = c("climate_country", "region_id", "year"))
  }
}


# -----------------------------
# Rocha-Soares measure
# -----------------------------

# -------- 6. Annual summaries --------

# Build Rocha-Soares summaries separately for pop and area weighting
rs_summary <- annual_keys

for (weighting in WEIGHTINGS) {
  drought_col <- sprintf("rs_drought_12m_%s", weighting)
  logdev_col <- sprintf("rs_logdev_12m_%s", weighting)
  pctdev_col <- sprintf("rs_pctdev_12m_%s", weighting)

  # The monthly file already has the rolling 12-month Rocha-Soares measure
  rs_state <- monthly %>%
    transmute(
      climate_country, region_id, year,
      rs_drought = .data[[drought_col]],
      rs_logdev = .data[[logdev_col]],
      rs_pctdev = .data[[pctdev_col]]
    ) %>%
    group_by(climate_country, region_id, year) %>%
    summarise(
      usable_months = sum(!is.na(rs_drought)),
      has_rs_drought = any(rs_drought == 1, na.rm = TRUE),
      # Number of ending months below the RS threshold
      rs_drought_months = if (usable_months == 12) as.integer(sum(rs_drought == 1, na.rm = TRUE)) else NA_integer_,
      rs_any_drought = if (usable_months == 12) as.integer(has_rs_drought) else NA_integer_,
      rs_longest_run = if (usable_months == 12) longest_true_run(rs_drought == 1) else NA_integer_,
      # Most negative deviations within the calendar year
      rs_min_logdev = if (usable_months == 12 && any(!is.na(rs_logdev))) min(rs_logdev, na.rm = TRUE) else NA_real_,
      rs_min_pctdev = if (usable_months == 12 && any(!is.na(rs_pctdev))) min(rs_pctdev, na.rm = TRUE) else NA_real_,
      .groups = "drop"
    ) %>%
    select(-usable_months, -has_rs_drought)

  # Name columns by weighting.
  summary_cols <- setdiff(names(rs_state), c("climate_country", "region_id", "year"))
  names(rs_state)[names(rs_state) %in% summary_cols] <- sprintf("%s_12m_%s", summary_cols, weighting)

  # Add this Rocha-Soares summary to the annual file
  rs_summary <- rs_summary %>%
    left_join(rs_state, by = c("climate_country", "region_id", "year"))
}


# -----------------------------
# Final annual file
# -----------------------------

# -------- 7. Assemble output --------

# Combine the four groups of measures and attach the admin IDs
drought_annual <- annual_wide %>%
  full_join(window_summary, by = c("climate_country", "region_id", "year")) %>%
  full_join(episode_summary, by = c("climate_country", "region_id", "year")) %>%
  full_join(rs_summary, by = c("climate_country", "region_id", "year")) %>%
  left_join(admin_info, by = c("climate_country", "region_id")) %>%
  relocate(
    climate_country, region_id,
    any_of(c("ID_0", "ID_1", "ID_2", "UNID")),
    unsupported_baseline_region,
    any_of(c(
      "drought_baseline_type",
      "drought_fixed_baseline_start", "drought_fixed_baseline_end",
      "drought_rolling_baseline_years",
      "drought_rs_baseline_start", "drought_rs_baseline_end"
    )),
    year
  ) %>%
  mutate(no_drought_baseline = unsupported_baseline_region)

# Keep dropped regions in the annual panel, but set drought measures to missing
drought_measure_prefixes <- c(
  "annual_rain_", "drought_months_", "drought_any_",
  "drought_longest_run_", "worst_z_", "deficit_mm_max_",
  "below_baseline_min_months_", "z_belownormal_sum_",
  "deficit_mm_sum_", "episode_", "rs_"
)
drought_measure_cols <- drought_annual %>%
  select(starts_with(drought_measure_prefixes)) %>%
  names()
drought_annual[drought_annual$no_drought_baseline, drought_measure_cols] <- NA

drought_annual <- drought_annual %>%
  arrange(climate_country, region_id, year)

# -------- 8. Final checks --------

if (drought_annual %>% count(climate_country, region_id, year) %>% filter(n > 1) %>% nrow() > 0) {
  stop("Final annual drought rows are not unique", call. = FALSE)
}

# Quick run summary printed to the console or sbatch log
summary_table <- drought_annual %>%
  group_by(climate_country) %>%
  summarise(
    first_year = min(year),
    last_year = max(year),
    admin_units = n_distinct(region_id),
    rows = n(),
    .groups = "drop"
  )

print(summary_table)


# -----------------------------
# Write output
# -----------------------------

if (write_output) {
  output_dir <- file.path(DROUGHT_DIR, "annual")
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  output_file <- file.path(output_dir, paste0("era5land_admin_drought_annual", output_suffix, ".rds"))
  saveRDS(drought_annual, output_file)

  message("wrote: ", output_file)
}
