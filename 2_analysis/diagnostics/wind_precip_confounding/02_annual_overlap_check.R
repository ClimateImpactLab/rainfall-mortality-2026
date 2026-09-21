#============================================================
# 02_annual_overlap_check.R
#
# Check overlap between high-rain and high-wind admin-years
#
# This uses annual ERA5-Land wind and extreme-rain variables to see whether
# unusually wet admin-years also tend to be unusually windy.
#
# This is only an annual overlap check
# ERA5-Land wind can come from any weather system (not just TC)
#
# Outputs:
#   output/data/wind_precip_confounding/annual_precip_wind_overlap/
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(writexl)

# -----------------------------
# Paths
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R")

climate_dir <- file.path(DATA_DIR, "climate_data", "ERA5-LAND", "combined")
output_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "wind_precip_confounding",
  "annual_precip_wind_overlap"
)

wind_file <- file.path(climate_dir, "era5land_admin_wind_annual.csv")
precip_file <- file.path(climate_dir, "era5land_admin_precip_exposure_annual.csv")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

joined_file <- file.path(output_dir, "annual_precip_wind_joined.csv")
summary_file <- file.path(output_dir, "annual_precip_wind_checks.xlsx")

# -----------------------------
# Variables
# -----------------------------

id_vars <- c("climate_country", "region_id", "year")

wind_vars <- c(
  "windmax_pop_annual", "windmax_area_annual",
  "winddays_17p5_pop_annual", "winddays_17p5_area_annual"
)

rain_vars <- c(
  "prcp_pop_annual_max_ERA5LAND_admin", "prcp_pop_p99_ERA5LAND_admin",
  "prcp_pop_days_gt50_ERA5LAND_admin", "prcp_pop_days_gt100_ERA5LAND_admin",
  "prcp_pop_days_gt150_ERA5LAND_admin", "prcp_pop_days_gt200_ERA5LAND_admin"
)

top_shares <- c(0.01, 0.05, 0.10) # top 1%, 5%, and 10%

# Main rain and wind measures used in the overlap checks
rain_overlap_vars <- c(
  "prcp_pop_annual_max_ERA5LAND_admin",
  "prcp_pop_days_gt100_ERA5LAND_admin",
  "prcp_pop_days_gt200_ERA5LAND_admin"
)
wind_overlap_vars <- c("windmax_pop_annual", "winddays_17p5_pop_annual")

# -----------------------------
# Read annual files
# -----------------------------

wind <- read_csv(
  wind_file,
  col_select = all_of(c(id_vars, wind_vars)),
  show_col_types = FALSE
) %>%
  mutate(
    year = as.integer(year),
    climate_country = as.character(climate_country),
    region_id = as.character(region_id)
  )

rain <- read_csv(
  precip_file,
  col_select = all_of(c(id_vars, rain_vars)),
  show_col_types = FALSE
) %>%
  mutate(
    year = as.integer(year),
    climate_country = as.character(climate_country),
    region_id = as.character(region_id)
  )

# Join using the climate aggregation IDs
# These do not always match mortality admin_id
annual <- rain %>%
  left_join(wind, by = id_vars, relationship = "one-to-one")

# -----------------------------
# Top rain and wind flags
# -----------------------------

# Flag the top 1%, 5%, and 10% of admin-years for the main overlap measures
for (var in c(rain_overlap_vars, wind_overlap_vars)) {
  for (share in top_shares) {
    suffix <- as.integer(share * 100)
    cutoff <- quantile(annual[[var]], 1 - share, na.rm = TRUE)
    annual[[paste0(var, "_top", suffix)]] <- annual[[var]] >= cutoff
  }
}

# -----------------------------
# Overlap of top rain and top wind
# -----------------------------

# Compare the upper tails of the rain and wind distributions
overlap_summary <- bind_rows(lapply(rain_overlap_vars, function(rain_var) {
  bind_rows(lapply(wind_overlap_vars, function(wind_var) {
    bind_rows(lapply(top_shares, function(share) {
      suffix <- as.integer(share * 100)
      
      # Use the same percentile cutoff for rain and wind
      rain_top <- annual[[paste0(rain_var, "_top", suffix)]]
      wind_top <- annual[[paste0(wind_var, "_top", suffix)]]
      overlap <- rain_top & wind_top
      
      tibble(
        rain_metric = rain_var,
        wind_metric = wind_var,
        top_share = share,
        
        # Number of admin-years in the rain tail, wind tail, and both
        rain_top_rows = sum(rain_top, na.rm = TRUE),
        wind_top_rows = sum(wind_top, na.rm = TRUE),
        overlap_rows = sum(overlap, na.rm = TRUE),
        
        # Overlap as a share of each tail
        share_of_rain_top_also_wind_top = sum(overlap, na.rm = TRUE) / sum(rain_top, na.rm = TRUE),
        share_of_wind_top_also_rain_top = sum(overlap, na.rm = TRUE) / sum(wind_top, na.rm = TRUE)
      )
    }))
  }))
}))

# -----------------------------
# Correlations and country summary
# -----------------------------

# Correlations for the same rain and wind measures used above
correlation_summary <- bind_rows(lapply(rain_overlap_vars, function(rain_var) {
  bind_rows(lapply(wind_overlap_vars, function(wind_var) {
    sample <- annual %>%
      filter(!is.na(.data[[rain_var]]), !is.na(.data[[wind_var]]))
    
    tibble(
      rain_metric = rain_var,
      wind_metric = wind_var,
      rows = nrow(sample),
      correlation = cor(sample[[rain_var]], sample[[wind_var]]),
      spearman = cor(sample[[rain_var]], sample[[wind_var]], method = "spearman")
    )
  }))
}))

# Coverage and largest annual values by country
country_summary <- annual %>%
  group_by(climate_country) %>%
  summarize(
    rows = n(),
    admin_units = n_distinct(region_id),
    first_year = min(year, na.rm = TRUE),
    last_year = max(year, na.rm = TRUE),
    missing_windmax_pop = mean(is.na(windmax_pop_annual)),
    max_windmax_pop_annual = max(windmax_pop_annual, na.rm = TRUE),
    max_winddays_17p5_pop_annual = max(winddays_17p5_pop_annual, na.rm = TRUE),
    max_prcp_pop_annual = max(prcp_pop_annual_max_ERA5LAND_admin, na.rm = TRUE),
    max_prcp_days_gt100 = max(prcp_pop_days_gt100_ERA5LAND_admin, na.rm = TRUE),
    max_prcp_days_gt200 = max(prcp_pop_days_gt200_ERA5LAND_admin, na.rm = TRUE),
    .groups = "drop"
  )

# -----------------------------
# Top admin-years
# -----------------------------

# Largest annual wind values
top_wind <- annual %>%
  arrange(desc(windmax_pop_annual)) %>%
  slice_head(n = 500)

# Largest annual max-rain values
top_rain <- annual %>%
  arrange(desc(prcp_pop_annual_max_ERA5LAND_admin)) %>%
  slice_head(n = 500)

# Admin-years in the top 10% for both annual max rain and annual max wind
wet_and_windy <- annual %>%
  filter(
    prcp_pop_annual_max_ERA5LAND_admin_top10,
    windmax_pop_annual_top10
  ) %>%
  arrange(desc(prcp_pop_annual_max_ERA5LAND_admin), desc(windmax_pop_annual)) %>%
  slice_head(n = 500)

# Admin-years in the top 1% for annual max rain but outside the top 10% for wind
high_rain_low_wind <- annual %>%
  filter(
    prcp_pop_annual_max_ERA5LAND_admin_top1,
    !coalesce(windmax_pop_annual_top10, FALSE)
  ) %>%
  arrange(desc(prcp_pop_annual_max_ERA5LAND_admin)) %>%
  slice_head(n = 500)

# -----------------------------
# Write outputs
# -----------------------------

# Full joined annual file
# Keep this as CSV in case another script needs the row-level annual data
write_csv(annual, joined_file)

# Summary tables in one workbook
write_xlsx(
  list(
    "Overlap summary" = overlap_summary,
    "Correlations" = correlation_summary,
    "Country summary" = country_summary,
    "Top wind years" = top_wind,
    "Top rain years" = top_rain,
    "Wet and windy" = wet_and_windy,
    "High rain low wind" = high_rain_low_wind
  ),
  summary_file
)

message("Wrote joined annual rain-wind file: ", joined_file)
message("Wrote annual rain-wind check workbook: ", summary_file)
