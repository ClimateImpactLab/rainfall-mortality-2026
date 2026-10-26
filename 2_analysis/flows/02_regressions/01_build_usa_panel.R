# ============================================================================
# 01_build_usa_panel.R
#
# USA annual mortality + rainfall flow panel for the regs. One row per
# county x age group x year.
#
# Mortality: our mortality panel, USA rows, with the same prep as the main
# annual regs (IDs, winsorized death rate, ERA5-Land temp and precip poly).
# Weights are population shares within USA x year x age.
#
# Flow (same value for every age group of a county-year), pop-weighted, from
# 01_measures/01_build_flow_measures.R:
#   - flow polynomial: annual sums of monthly flow, flow^2 and flow^3, with
#     negative cell flow set to 0
#   - upstream polynomial: the same for upstream inflow (flow minus the
#     cell's own rainfall)
#   - drought (annual mean) and flood (annual max), raw flow
#   - their z-scores vs the previous 20 years
#   - SPI of calendar-year flow (1981-2010 gamma fit)
#   - percentile bins vs the county's 20 previous years, with the Brazil
#     cutoffs: dry bins of the annual mean, wet bins of the annual max
#     (built here)
#
# Options:
#   --write    save the RDS output
#
# Inputs:
# /project/cil/gcp/estimation/rainfall-mortality/mortality_data/
#   panel_build/combined_panel/new_mortality_panel.rds
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
#   flows/annual/era5land_admin_flow_annual_usa.rds
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# flows/usa_annual/usa_annual_flow_regression_panel.rds
#
# Dependencies: dplyr, tidyr; ../../../0_utils/paths.R, ../../../0_utils/functions.R
# and ../../regressions/00_prep_analysis_panel.R, so run this script from its
# own folder.
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)


# -----------------------------
# Paths and settings
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DATA_DIR

# Mortality panel named for this analysis (no urban variables)
PANEL_FILE <- file.path(
  DATA_DIR, "mortality_data", "panel_build", "combined_panel", "new_mortality_panel.rds"
)

# Annual USA flow measures from 01_measures/01_build_flow_measures.R
FLOW_FILE <- file.path(
  DATA_DIR, "climate_data", "ERA5-LAND", "flows", "annual", "era5land_admin_flow_annual_usa.rds"
)

# Where the panel is saved
OUTPUT_DIR <- file.path(DATA_DIR, "climate_data", "ERA5-LAND", "flows", "usa_annual")
OUTPUT_FILE <- file.path(OUTPUT_DIR, "usa_annual_flow_regression_panel.rds")

# The panel is saved only with --write
write_output <- "--write" %in% commandArgs(trailingOnly = TRUE)

# Flow vars carried into the panel (pop-weighted, like prcp_poly_*_ERA5LAND)
FLOW_VARS <- c(
  "flow_poly_1_pop",
  "flow_poly_2_pop",
  "flow_poly_3_pop",
  "upstream_poly_1_pop",
  "upstream_poly_2_pop",
  "upstream_poly_3_pop",
  "flowmean_pop_annual",
  "flowmax_pop_annual",
  "flowmean_z_pop",
  "flowmax_z_pop",
  "spi12_flow_pop",
  "flow_clip_months_pop",
  "flowmean_pct_pop",
  "flowmax_pct_pop",
  "flowmean_bin_p00_10_pop",
  "flowmean_bin_p10_25_pop",
  "flowmax_bin_p75_90_pop",
  "flowmax_bin_p90_100_pop"
)


# -----------------------------
# Existing regression prep
# -----------------------------

# The same functions as the main annual regressions:
#   * add_regression_ids(): creates admin_code, adm1_code, adm0_code
#   * add_winsorized_deathrate(): creates deathrate_w99
#   * use_climate_product(): uses ERA5-Land temp/precip polynomial columns
#   * get_weights(): population weights within year x age group

source("../../../0_utils/functions.R")
source("../../regressions/00_prep_analysis_panel.R")


# -----------------------------
# Read USA mortality panel
# -----------------------------

# Keep the USA first, so get_weights() gives shares of USA population in each
# year x age, not of the multi-country panel. Winsorizing is by country x age,
# so its cutoffs are the same either way. Drop the all-age group.
panel <- readRDS(PANEL_FILE) %>%
  filter(iso == "USA") %>%
  add_regression_ids() %>%
  filter(agegroup != 0) %>%
  mutate(agegroup = droplevels(agegroup)) %>%
  add_winsorized_deathrate() %>%
  use_climate_product(prcp_product = "ERA5LAND", temp_product = "ERA5LAND") %>%
  get_weights()


# -----------------------------
# Read USA flow measures
# -----------------------------

# USA mortality admin IDs are ID_1_ID_2 (for ex 01_001), so build that key
# before merging
flow <- readRDS(FLOW_FILE) %>%
  mutate(
    iso = "USA",
    admin_id = paste(ID_1, ID_2, sep = "_"),

    # Percentile bins vs the county's 20 previous years (the z-score
    # baseline, from 01_build_flow_measures.R), with the Brazil cutoffs
    # (drought/annual_1997_2010/02_regressions/01_build_brazil_panel.R).
    # With 20 baseline years each bin covers 3 of the 21 possible ranks, for
    # ex <= p10 = below all but at most 2 of the previous 20 years.
    # Drought bins come from the annual mean, flood bins from the annual max.
    # Each pair's omitted group is the rest of its own distribution, so the
    # reference year has mean flow above p25 and max flow below p75. A year
    # can be in a drought bin and a flood bin at once
    flowmean_bin_p00_10_pop = as.integer(flowmean_pct_pop <= 0.10),
    flowmean_bin_p10_25_pop = as.integer(flowmean_pct_pop > 0.10 & flowmean_pct_pop <= 0.25),
    flowmax_bin_p75_90_pop = as.integer(flowmax_pct_pop >= 0.75 & flowmax_pct_pop < 0.90),
    flowmax_bin_p90_100_pop = as.integer(flowmax_pct_pop >= 0.90)
  ) %>%
  select(iso, admin_id, year, all_of(FLOW_VARS))

if (anyDuplicated(flow[c("admin_id", "year")]) > 0) {
  stop("Flow measures are not unique by county-year", call. = FALSE)
}


# -----------------------------
# Merge
# -----------------------------

# Keep all mortality rows and attach the flow vars by county-year
reg_panel <- panel %>%
  left_join(flow, by = c("iso", "admin_id", "year"))


# -----------------------------
# Checks
# -----------------------------

# Flow is unique by county-year, so the merge cannot add rows
if (nrow(reg_panel) != nrow(panel)) {
  stop("The flow merge changed the number of panel rows", call. = FALSE)
}

# Two Alaska panel counties, 02_010 and 02_270, are not among the flow files'
# counties (tl_2016 county shapefile). They stay in the panel with missing flow.
unmatched <- setdiff(unique(panel$admin_id), unique(flow$admin_id))
message("Panel counties without flow: ", paste(unmatched, collapse = ", "))

if (!all(unmatched %in% c("02_010", "02_270"))) {
  stop("Unexpected panel counties without flow: ", paste(setdiff(unmatched, c("02_010", "02_270")), collapse = ", "), call. = FALSE)
}

# Weights should sum to 1 in each year x age
weight_sums <- tapply(reg_panel$weight, list(reg_panel$year, reg_panel$agegroup), sum, na.rm = TRUE)
if (any(abs(weight_sums - 1) > 1e-8)) {
  stop("USA weights do not sum to 1 in each year x age", call. = FALSE)
}

# Panel coverage and how many county-years had negative flow set to 0.
# Counted outside the summary below: a column named like one of these objects
# would mask it inside mutate()
county_years <- reg_panel %>%
  distinct(admin_id, year, flow_clip_months_pop)
n_county_years <- nrow(county_years)
n_county_years_clipped <- sum(county_years$flow_clip_months_pop > 0, na.rm = TRUE)

merge_summary <- reg_panel %>%
  summarise(
    rows = n(),
    first_year = min(year),
    last_year = max(year),
    counties = n_distinct(admin_id),
    counties_with_flow = n_distinct(admin_id[!is.na(flowmean_pop_annual)]),
    age_groups = n_distinct(agegroup),
    first_z_year = min(year[!is.na(flowmean_z_pop)])
  ) %>%
  mutate(
    county_years = n_county_years,
    county_years_with_negatives_set_to_0 = n_county_years_clipped
  )

# Variable-level check, easier to read if a measure has missing rows after the merge
var_summary <- reg_panel %>%
  summarise(across(all_of(FLOW_VARS), ~ sum(!is.na(.x)))) %>%
  tidyr::pivot_longer(everything(), names_to = "variable", values_to = "nonmissing_rows")

print(merge_summary, width = Inf)
print(var_summary)


# -----------------------------
# Write output
# -----------------------------

if (write_output) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(reg_panel, OUTPUT_FILE)
  message("wrote: ", OUTPUT_FILE)
}
