# ==============================================================================
# 2g_add_drought_terms.R
#
# Drought terms on the panel's admin units, ERA5-Land and CHIRPS, at t, t-1 and
# t+1, plus the precip poly at t-1 and t+1
# Runs the functions of 06_admin_drought_terms.R on the panel's own monthly rain,
# so each product gets its own SPI fit. SPI fit on 1981-2010, plus spi12_dry_roll30 
#  (against the 30 years before) for ERA5-Land only
# CHIRPS starts in 1981, s rolling baseline would include the year itself for most years
# Both products use the ERA5-Land temperature normals for the drought x temp terms
# All climate years are read before joining mortality, so the first and last
# mortality years still get t-1 and t+1
# Also adds the 1981-2010 annual rainfall baseline (mean and CV) and writes
# checks on the baselines
# ==============================================================================

# ------------------
# Packages and paths
# ------------------

library(dplyr)
library(readr)

build_dir <- getwd()
source(file.path(build_dir, "paths.R"))
source(file.path(build_dir, "checks.R"))
source(file.path(build_dir, "climate_inputs.R"))
l
# Load the drought functions of 06 panel script in climate aggregation pipeline
# (its own old-panel file isn't built when loaded this way)
source(file.path(repo_dir, "1_data/climate_data/climate_aggregation_global/era5land_admin/panel/06_admin_drought_terms.R"))

# Number of baseline years (1981-2010, set in that 06 script)
n_base <- length(baseline_years)

# 06 returns short names (for ex spi12_dry), saved here with the product after them (spi12_dry_ERA5LAND)
# The product comes before _lag1/_lead1, as for the precip poly (spi12_dry_ERA5LAND_lag1)
formula_terms <- c("spi12_dry", "dry_wsum", "dry_sum", "mckee",
                   "dry_x_normal_rolling", "dry_x_normal_fixed")

# Kept for ERA5-Land only
era5land_only_terms <- "spi12_dry_roll30"

# All the columns this adds to the panel
drought_terms <- c(paste0(c(formula_terms, era5land_only_terms), "_ERA5LAND"), paste0(formula_terms, "_CHIRPS"))
normal_terms <- c("normal_rolling", "normal_fixed")
prcp_terms <- c(paste0("prcp_poly_", 1:5, "_ERA5LAND"), paste0("prcp_poly_", 1:5, "_CHIRPS"))
shift_terms <- c(drought_terms, prcp_terms)
added_terms <- c(drought_terms, normal_terms,
                 paste0(shift_terms, "_lag1"), paste0(shift_terms, "_lead1"))
baseline_vars <- c("baseline_prcp_mm", "baseline_prcp_cv", "baseline_prcp_n",
                   "baseline_prcp_mm_CHIRPS", "baseline_prcp_cv_CHIRPS", "baseline_prcp_n_CHIRPS")

# ---------------------------
# Monthly climate and drought
# ---------------------------

# One table per country for each product, and the monthly baseline checks
drought_parts <- list()
chirps_parts <- list()
baseline_checks <- list()

# For each climate country: monthly ERA5-Land rain and temp, matched to the
# panel's admin units
for (code in climate_maps$country) {
  message("Calculating drought: ", code)
  monthly <- read_climate_source(code, "monthly", c("prcp_pop_p1", "tmean_pop_p1"))
  monthly <- panel_climate_ids(monthly, c("prcp_pop_p1", "tmean_pop_p1"))

  # One region id per panel admin unit
  # An old US panel unit covers two climate regions, so their rain is combined
  # before the SPI fit (the average of two SPIs isn't that unit's SPI)
  monthly <- monthly %>% mutate(region_id = paste(iso, admin_id, sep = ":"))
  ids <- monthly %>% distinct(region_id, iso, admin_id)

  # The monthly data for each product: ERA5-Land, and CHIRPS where it exists
  monthly_sources <- list(ERA5LAND = monthly)
  if (code %in% chirps_maps$country) {
    rain <- read_climate_source(code, "monthly", "prcp_pop_p1", product = "CHIRPS")
    rain <- panel_climate_ids(rain, "prcp_pop_p1")
    missing_temp <- anti_join(distinct(rain, iso, admin_id), ids, by = c("iso", "admin_id"))
    if (nrow(missing_temp) > 0) stop(code, ": CHIRPS units lack ERA5-Land temperature rows.", call. = FALSE)

    # CHIRPS version: replace the rain only, and keep ERA5-Land temp from 1950
    # so the rolling normal has its full history
    # Rain before 1981 stays missing
    monthly_sources$CHIRPS <- monthly %>% select(-prcp_pop_p1) %>%
      left_join(rain, by = c("iso", "admin_id", "month"))
    stopifnot(nrow(monthly_sources$CHIRPS) == nrow(monthly))
  }

  # Drought terms for each product
  for (product in names(monthly_sources)) {
    message("Fitting ", product, " SPI: ", code)
    monthly_product <- monthly_sources[[product]]

    # Check: does each calendar month have all baseline years and a gamma fit?
    # No fit if the rain is always 0, or the same every rainy year
    baseline_checks[[paste(code, product)]] <- monthly_product %>%
      mutate(year = as.integer(substr(month, 1, 4)), month = substr(month, 6, 7)) %>%
      filter(year %in% baseline_years) %>% group_by(iso, admin_id, month) %>%
      summarize(
        baseline_n = sum(is.finite(prcp_pop_p1)),
        positive_n = sum(prcp_pop_p1 > 0, na.rm = TRUE),
        positive_variance = var(prcp_pop_p1[prcp_pop_p1 > 0], na.rm = TRUE),
        .groups = "drop"
      ) %>% mutate(product = product, gamma_fit_available = baseline_n == n_base & positive_n >= 2 &
                    is.finite(positive_variance) & positive_variance > 0)

    # Terms kept: the drought terms for both products, the rolling SPI-12 and the temp normals for ERA5-Land only
    # (the normals don't depend on the rain product, so they're stored once)
    source_terms <- c(formula_terms, if (product == "ERA5LAND") era5land_only_terms)
    keep <- c(source_terms, if (product == "ERA5LAND") normal_terms)
    annual_drought <- drought_country(code, monthly_product) %>% as_tibble() %>%
      inner_join(ids, by = "region_id") %>%
      select(iso, admin_id, year, all_of(keep)) %>%
      rename_with(~ paste0(.x, "_", product), all_of(source_terms))
    if (product == "ERA5LAND") {
      drought_parts[[code]] <- annual_drought
    } else {
      # Keep CHIRPS from 1981 (earlier rows were only there for the temp history)
      chirps_parts[[code]] <- filter(annual_drought, year >= 1981)
    }
  }
}

# All countries, ERA5-Land and CHIRPS side by side, saved on its own too
drought <- left_join(bind_rows(drought_parts), bind_rows(chirps_parts), by = c("iso", "admin_id", "year"))
write_csv(drought, drought_climate_file, na = "")
monthly_checks <- bind_rows(baseline_checks)

# -------------------------------------
# Current, previous and following years
# -------------------------------------

# Annual precip poly, ERA5-Land and CHIRPS
annual <- read_csv(
  annual_climate_file, show_col_types = FALSE,
  col_select = all_of(c("iso", "admin_id", "year", paste0("prcp_poly_", 1:5, "_ERA5LAND"))),
  col_types = cols(.default = col_double(), iso = col_character(), admin_id = col_character())
)
annual_chirps <- read_csv(annual_chirps_file, show_col_types = FALSE,
                          col_types = cols(.default = col_double(), iso = col_character(), admin_id = col_character()))
annual <- left_join(annual, annual_chirps, by = c("iso", "admin_id", "year"))

# Climate and drought together, keeping every year even if a drought value is missing
# Then t-1 and t+1 of each drought term and precip poly
climate <- full_join(annual, drought, by = c("iso", "admin_id", "year"))
climate <- add_climate_years(climate, shift_terms)
write_csv(climate, file.path(climate_input_dir, "climate_with_lags_leads.csv"), na = "")

# Annual rainfall baseline: mean and CV over 1981-2010, NA unless all the years are there
baseline <- annual %>% filter(year %in% baseline_years) %>%
  group_by(iso, admin_id) %>% summarize(
    baseline_prcp_n = sum(is.finite(prcp_poly_1_ERA5LAND)),
    baseline_prcp_mm = if (baseline_prcp_n == n_base) mean(prcp_poly_1_ERA5LAND) else NA_real_,
    baseline_prcp_cv = if (baseline_prcp_n == n_base && baseline_prcp_mm > 0)
      sd(prcp_poly_1_ERA5LAND) / baseline_prcp_mm else NA_real_,
    baseline_prcp_n_CHIRPS = sum(is.finite(prcp_poly_1_CHIRPS)),
    baseline_prcp_mm_CHIRPS = if (baseline_prcp_n_CHIRPS == n_base) mean(prcp_poly_1_CHIRPS) else NA_real_,
    baseline_prcp_cv_CHIRPS = if (baseline_prcp_n_CHIRPS == n_base && baseline_prcp_mm_CHIRPS > 0)
      sd(prcp_poly_1_CHIRPS) / baseline_prcp_mm_CHIRPS else NA_real_,
    .groups = "drop"
  )

# Checks: how many admin units and admin-months have a full baseline, by country and product
annual_checks <- bind_rows(
  baseline %>% select(iso, admin_id, baseline_prcp_n, baseline_prcp_mm, baseline_prcp_cv) %>%
    mutate(product = "ERA5LAND"),
  baseline %>% transmute(iso, admin_id, baseline_prcp_n = baseline_prcp_n_CHIRPS,
                         baseline_prcp_mm = baseline_prcp_mm_CHIRPS,
                         baseline_prcp_cv = baseline_prcp_cv_CHIRPS, product = "CHIRPS")
)
annual_baseline_coverage <- annual_checks %>% group_by(iso, product) %>% summarize(
  annual_admins = n(),
  incomplete_annual_baseline = sum(is.na(baseline_prcp_n) | baseline_prcp_n != n_base),
  missing_annual_rainfall = sum(!is.finite(baseline_prcp_mm)),
  missing_annual_cv = sum(!is.finite(baseline_prcp_cv)), .groups = "drop"
)
monthly_baseline_coverage <- monthly_checks %>% group_by(iso, product) %>% summarize(
  monthly_admins = n_distinct(admin_id), admin_months = n(),
  incomplete_monthly_baseline = sum(is.na(baseline_n) | baseline_n != n_base),
  unavailable_gamma_fit = sum(is.na(gamma_fit_available) | !gamma_fit_available),
  .groups = "drop"
)
baseline_coverage <- full_join(annual_baseline_coverage, monthly_baseline_coverage, by = c("iso", "product"))

# And the list of admin units and calendar months where the baseline can't be used
rainfall_baseline_gaps <- annual_checks %>% filter(
  is.na(baseline_prcp_n) | baseline_prcp_n != n_base |
    !is.finite(baseline_prcp_mm) | !is.finite(baseline_prcp_cv)
)
spi_baseline_gaps <- monthly_checks %>% filter(
  is.na(baseline_n) | baseline_n != n_base | is.na(gamma_fit_available) | !gamma_fit_available
)
write_checks(list(baseline_coverage = baseline_coverage,
                  rainfall_baseline_gaps = rainfall_baseline_gaps,
                  spi_baseline_gaps = spi_baseline_gaps))

# -----------------------------------------
# Add terms without changing mortality rows
# -----------------------------------------

# Read the panel, drop these columns if they're already there (rerun), add them by admin unit and year
panel <- read_csv(climate_panel_file, show_col_types = FALSE,
                  col_types = cols(.default = col_character(), year = col_integer()))
updated <- panel %>% select(-any_of(c(added_terms, baseline_vars))) %>%
  left_join(climate %>% select(iso, admin_id, year, all_of(added_terms)),
            by = c("iso", "admin_id", "year")) %>%
  left_join(baseline, by = c("iso", "admin_id"))
stopifnot(nrow(updated) == nrow(panel))
write_csv(updated, climate_panel_file, na = "")
message("Updated panel: ", climate_panel_file)

# Check: missing values of each added term, by country and year (once per admin unit-year, not per age group)
coverage <- updated %>% distinct(iso, admin_id, year, across(all_of(added_terms))) %>%
  group_by(iso, year) %>% summarize(admins = n(), across(
    all_of(added_terms), ~ sum(!is.finite(.x)), .names = "{.col}_missing"
  ), .groups = "drop")
write_checks(list(climate_terms_coverage = coverage))
