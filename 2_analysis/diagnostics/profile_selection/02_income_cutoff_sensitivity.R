# ===========================================================================
# 02_income_cutoff_sensitivity.R
#
# Check how sensitive the first-pass Mumbai-like profiles are to the ADM1
# income cutoff. 
#
# The profile definitions use urban share, population, long-run rainfall,
# and ADM1 income.
# This is the older version of the profile work, before adding the newer
# Kummu income variables. 
#
# For each profile definition, compare ADM1 income cutoffs of $15k, $20k,
# $25k, $30k, $40k, and no income cutoff. 
#
# The output reports regression rows, admin units, and countries for each
# profile definition and income cutoff
# ===========================================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)

# -----------------------------
# Paths
# -----------------------------

args <- commandArgs(FALSE)
file_arg <- args[grepl("^--file=", args)]

# Start from this folder so the relative source paths below work
# This matters when the script is run from sbatch
script_dir <- if (length(file_arg) > 0) {
  dirname(normalizePath(sub("^--file=", "", file_arg[[1]])))
} else {
  getwd()
}
setwd(script_dir)

USER <- Sys.getenv("USER")

# Load repo paths and the functions that read and filter the analysis panel
source("../../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY
source("../../regressions/00_prep_analysis_panel.R") # load_new_panel(), filter_regression_sample()

# Save with the other subsample diagnostics
diag_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "data", "diagnostics", "subsamples"
)
dir.create(diag_dir, recursive = TRUE, showWarnings = FALSE)

# -----------------------------
# Regression sample
# -----------------------------

# Use the same basic sample restrictions as the regressions
# The extra variables are needed for the first-pass profile definitions
df <- load_new_panel(
  prcp_product = "ERA5LAND",
  temp_product = "ERA5LAND",
  require_urban = TRUE
) %>%
  filter_regression_sample(
    tavg_order = 2,
    prcp_order = 3,
    require_urban = TRUE,
    extra_vars = c("gdppc_adm1_avg", "lr_prcp_ERA5LAND_adm1_avg", "prcp_poly_1")
  )

# -----------------------------
# Admin-unit measures
# -----------------------------

# Population is age-specific in the regression panel
# Sum across age groups before using it as an admin-year population measure
admin_year_pop <- df %>%
  group_by(admin_code, year) %>%
  summarize(admin_year_population = sum(population, na.rm = TRUE), .groups = "drop")

# Collapse the year-age panel to one row per admin unit
# These variables determine whether an admin unit is included in a profile
admin_static <- df %>%
  left_join(admin_year_pop, by = c("admin_code", "year")) %>%
  group_by(iso, admin_code) %>%
  summarize(
    urban_share = mean(urban_share, na.rm = TRUE),
    ghsl_population = mean(ghsl_population, na.rm = TRUE),
    mortality_population = mean(admin_year_population, na.rm = TRUE),
    gdppc_adm1_avg = mean(gdppc_adm1_avg, na.rm = TRUE),
    lr_prcp_adm1 = mean(lr_prcp_ERA5LAND_adm1_avg, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(analysis_population = coalesce(ghsl_population, mortality_population))

# -----------------------------
# Profile definitions
# -----------------------------

# First-pass profile definitions
# This script varies only the income cutoff
defs <- tibble::tribble(
  ~definition, ~urban_cutoff, ~pop_cutoff, ~prcp_cutoff,
  "Urban wet", 50, 100000, 1000,
  "High-urban wet", 70, 250000, 1000,
  "Very-wet urban", 50, 250000, 1500,
  "Narrow megacity wet", 70, 500000, 1500
)

# Income cutoffs to compare with no income cutoff
income_cutoffs <- c(15000, 20000, 25000, 30000, 40000, Inf)

# -----------------------------
# Income-cutoff checks
# -----------------------------

# Try each income cutoff for each profile definition
# Each output row corresponds to one profile definition and income cutoff
rows <- list()
idx <- 1

for (i in seq_len(nrow(defs))) {
  for (income_cutoff in income_cutoffs) {
    
    # Keep admin units that meet the profile definition
    selected <- admin_static %>%
      filter(
        urban_share >= defs$urban_cutoff[[i]],
        analysis_population >= defs$pop_cutoff[[i]],
        gdppc_adm1_avg <= income_cutoff,
        lr_prcp_adm1 >= defs$prcp_cutoff[[i]]
      )
    
    # Count the regression rows, admin units, and countries in the selected sample
    rows[[idx]] <- tibble(
      definition = defs$definition[[i]],
      urban_cutoff = defs$urban_cutoff[[i]],
      pop_cutoff = defs$pop_cutoff[[i]],
      income_cutoff = income_cutoff,
      income_label = ifelse(
        is.infinite(income_cutoff),
        "No income cutoff",
        paste0("<= $", format(income_cutoff, big.mark = ","))
      ),
      prcp_cutoff = defs$prcp_cutoff[[i]],
      rows = sum(df$admin_code %in% selected$admin_code),
      admin_units = n_distinct(selected$admin_code),
      countries = n_distinct(selected$iso)
    )
    
    idx <- idx + 1
  }
}

out <- bind_rows(rows)

write_csv(
  out,
  file.path(diag_dir, "new_panel_subsample_income_sensitivity_table.csv")
)

print(out, n = Inf)