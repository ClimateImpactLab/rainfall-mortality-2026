# =============================================================================
# 00_prep_analysis_panel.R
#
# Prepare the rainfall-mortality panel for analysis
#
# `admin_id` identifies the admin unit used in the regressions. The level varies
# across countries: ADM1 or ADM2 in most countries, ADM3 in the Philippines,
# NUTS regions in Europe, and SA3 in Australia
#
# The regression scripts load this file to prepare the panel before estimation
# It creates the regression IDs, drops the all-age group, winsorizes death rates,
# adds weights, and selects the climate variables used in the regressions
#
# Input:
#   /project/cil/gcp/estimation/rainfall-mortality/mortality_data/
#   panel_build/combined_panel/new_mortality_panel_urban.csv
#
# ===========================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(glue)


# -----------------------------
# Paths
# -----------------------------

panel_urban_path <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/",
  "panel_build/combined_panel/new_mortality_panel_urban.csv"
)


# -----------------------------
# Regression IDs and outcome
# -----------------------------

# IDs used for fixed effects, clustering, and plotting
# `admin_code` is the final analysis unit, `adm1_code` is kept separately for
# specifications that cluster or absorb fixed effects at ADM1
add_regression_ids <- function(panel) {
  panel %>%
    mutate(
      adm0_code = iso,
      adm1_code = paste(iso, adm1_id, sep = "_"),
      admin_code = paste(iso, admin_id, sep = "_"),
      adm1_agegrp_code = paste(adm1_code, agegroup, sep = "_"),
      agegroup = as.factor(agegroup)
    )
}

# 99th-percentile winsorized death rate used in the Carleton et al. (2022)
# levels regressions
# The cutoff is calculated separately by country and age group
add_winsorized_deathrate <- function(panel) {
  panel %>%
    group_by(iso, agegroup) %>%
    mutate(
      deathrate_w99 = pmin(
        deathrate,
        quantile(deathrate, 0.99, na.rm = TRUE, type = 2)
      )
    ) %>%
    ungroup()
}


# -----------------------------
# Climate variables
# -----------------------------

# Regression scripts use names without the dataset suffix, such as `prcp_poly_1`
# and `tavg_poly_1`, copy the selected climate variables to those names
use_climate_product <- function(panel,
                                prcp_product = "ERA5LAND",
                                temp_product = "ERA5LAND",
                                max_order = 5) {
  
  for (order in seq_len(max_order)) {
    prcp_source <- paste0("prcp_poly_", order, "_", prcp_product)
    tavg_source <- paste0("tavg_poly_", order, "_", temp_product)
    tmax_source <- paste0("tmax_poly_", order, "_", temp_product)
    
    prcp_target <- paste0("prcp_poly_", order)
    tavg_target <- paste0("tavg_poly_", order)
    tmax_target <- paste0("tmax_poly_", order)
    
    # Precipitation and average temperature are required for the main models
    if (!prcp_source %in% names(panel)) {
      stop("Missing column: ", prcp_source)
    }
    
    if (!tavg_source %in% names(panel)) {
      stop("Missing column: ", tavg_source)
    }
    
    panel[[prcp_target]] <- panel[[prcp_source]]
    panel[[tavg_target]] <- panel[[tavg_source]]
    
    # Maximum temperature is only used in some specifications
    if (tmax_source %in% names(panel)) {
      panel[[tmax_target]] <- panel[[tmax_source]]
    }
  }
  
  panel
}


# -----------------------------
# Read panel
# -----------------------------

load_new_panel <- function(path = panel_urban_path,
                           prcp_product = "ERA5LAND",
                           temp_product = "ERA5LAND",
                           max_order = 5,
                           require_urban = FALSE) {
  
  panel <- read_csv(path, show_col_types = FALSE)
  
  panel <- add_regression_ids(panel)
  
  # Drop the all-age groupss, response functions are estimated separately by age group
  panel <- panel %>%
    filter(agegroup != 0) %>%
    mutate(agegroup = droplevels(agegroup))
  
  panel <- add_winsorized_deathrate(panel)
  
  # Add regression weights
  panel <- get_weights(panel)
  
  # Choose the precp and temp variables used in the regressions
  panel <- use_climate_product(
    panel,
    prcp_product = prcp_product,
    temp_product = temp_product,
    max_order = max_order
  )
  
  # Urban heterogeneity regs require non-missing urban share
  if (require_urban) {
    panel <- panel %>%
      filter(!is.na(urban_share))
  }
  
  panel
}


# -----------------------------
# Regression sample
# -----------------------------

# Keep observations with non-missing values for all variables required by the reg
# Additional controls or profile variables can be passed in `extra_vars`
filter_regression_sample <- function(panel,
                                     tavg_order = 2,
                                     prcp_order = 3,
                                     require_urban = FALSE,
                                     extra_vars = character()) {
  
  required_vars <- c(
    "deathrate_w99", "population", "weight", "agegroup", "year",
    "adm0_code", "adm1_code", "admin_code",
    paste0("tavg_poly_", seq_len(tavg_order)),
    paste0("prcp_poly_", seq_len(prcp_order)),
    extra_vars
  )
  
  if (require_urban) {
    required_vars <- c(required_vars, "urban_share")
  }
  
  # Stop if a requested reg var is missing
  missing_vars <- setdiff(required_vars, names(panel))
  
  if (length(missing_vars) > 0) {
    stop("Missing required columns: ", paste(missing_vars, collapse = ", "))
  }
  
  panel %>%
    filter(if_all(all_of(required_vars), ~ !is.na(.)))
}


# -----------------------------
# Fixed effects
# -----------------------------

# Fixed effects used in the response-function regressions
# The saturated specification also includes age-specific ADM1-by-year fixed effects
new_panel_specs <- tibble::tribble(
  ~spec_id, ~spec_short, ~spec_label, ~fe,
  
  "main",
  "Main FE",
  "Main FE: age x admin unit; age x country x year",
  list(c(
    "admin_code^agegroup",
    "adm0_code^year^agegroup"
  )),
  
  "saturated",
  "Saturated FE",
  "Saturated FE: age x admin unit; age x country x year; age x ADM1 x year",
  list(c(
    "admin_code^agegroup",
    "adm0_code^year^agegroup",
    "adm1_code^year^agegroup"
  ))
)