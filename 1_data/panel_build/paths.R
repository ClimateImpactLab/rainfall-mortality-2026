# ==============================================================================
# paths.R
#
# Paths shared by every script in scripts/, so each input and output
# location is set once, here.
# Also creates the output folders. Every script loads this file first.
# ==============================================================================

# -------------
# Repo
# -------------

# Repo folder, from RAINFALL_MORTALITY_REPO if set
# Otherwise the user's repos folder
user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])

repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") {
  repo_dir <- file.path(
    "/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026"
  )
}

# --------------------
# Old Carleton panel
# --------------------

# ERA5-Land version of the old global mortality panel (input of 1a)
old_panel_file <- file.path(
  "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data",
  "0_data_cleaning/3_final/global_mortality_panel_era5.dta"
)

# ------------------------
# Where the build writes
# ------------------------

mortality_data_dir <- "/project/cil/gcp/estimation/rainfall-mortality/mortality_data"
out_dir <- file.path(mortality_data_dir, "annual", "panel_update")

# The annual panel build writes under panel_update
# Monthly checks and panels are separate from the annual files.
monthly_dir <- file.path(mortality_data_dir, "monthly")

# One folder per stage output
old_panel_dir <- file.path(out_dir, "old_panel")
new_country_dir <- file.path(out_dir, "new_countries")
panel_dir <- file.path(out_dir, "combined_panel")

# Three cumulative datasets: mortality (stage 1), climate (stage 2)
# and full (stage 3)
# Later stages never write to an earlier one.
mortality_panel_file <- file.path(panel_dir, "01_panel_mortality.csv")
climate_panel_file <- file.path(panel_dir, "02_panel_climate.csv")
full_panel_file <- file.path(panel_dir, "03_panel_full.csv")
check_dir <- file.path(out_dir, "checks")

# Rwanda mortality is not ready
# It is excluded even if it reappears in an input list
excluded_countries <- "RWA"

# -------------
# Climate
# -------------

climate_root <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data"
era5land_dir <- file.path(climate_root, "ERA5-LAND")
era5land_global_dir <- file.path(climate_root, "ERA5-LAND-GLOBAL")
chirps_dir <- file.path(climate_root, "CHIRPS")

# Annual climate tables made by stage 2, separate from older combined outputs
climate_input_dir <- file.path(out_dir, "climate_inputs")
annual_climate_file <- file.path(climate_input_dir, "annual_climate.csv")
annual_chirps_file <- file.path(climate_input_dir, "annual_chirps.csv")
annual_wind_file <- file.path(climate_input_dir, "annual_wind.csv")
drought_climate_file <- file.path(climate_input_dir, "annual_drought.csv")
# Lists of the current admin maps and climate folders for ERA5-Land and CHIRPS
climate_maps_file <- file.path(
  repo_dir, "1_data/climate_data/climate_aggregation_global/era5land_admin/shapefiles_current.csv"
)
chirps_maps_file <- file.path(
  repo_dir, "1_data/climate_data/climate_aggregation_global/chirps_admin/shapefiles_chirps.csv"
)

# -------------
# Het vars
# -------------

het_dir <- "/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data"

# Carleton income, country_files.csv selects the mortality panels used here
income_dir <- "/project/cil/gcp/estimation/rainfall-mortality/income_data/carleton"
income_release_dir <- file.path(income_dir, "output/current_2026_11_15_v2")
income_file <- file.path(income_release_dir, "new_country_income_adm1_year.csv")
income_overrides_file <- file.path(income_release_dir, "new_country_income_admin_overrides.csv")

# Kummu income (aggregated to our admin units)
# Admin units known to be missing from Kummu are listed in the second file
kummu_dir <- "/project/cil/gcp/estimation/rainfall-mortality/income_data/kummu/output/constant_2021_2026_11_21"
kummu_missing_units_file <- file.path(repo_dir,
  "1_data/heterogeniety_data/1_data_cleaning/Income/kummu/config/known_missing_panel_units.csv")

# GHSL urban share
ghsl_file <- file.path(het_dir, "ghsl/current_boundaries/ghsl_urban.csv")
ghsl_built_file <- file.path(het_dir, "ghsl/current_boundaries/ghsl_built.csv")

# Elevation
elevation_file <- file.path(
  het_dir, "elevation_data/output/new_boundary/admin_elevation_exposure_fabdem_landscan2011.csv"
)

# Population density
pop_density_dir <- file.path(het_dir, "pop_density/current_boundaries")
admin_density_file <- file.path(pop_density_dir, "admin_density.csv")
landscan_density_file <- file.path(pop_density_dir, "landscan_density.csv")
ghsl_density_file <- file.path(pop_density_dir, "ghsl_density.csv")

# Cropland, irrigation and SPAM (one folder per source, then per country)
ag_land_dir <- het_dir

# -------------------------
# Make the output folders
# -------------------------

# Create any output folder that doesn't exist yet
for (dir in c(old_panel_dir, new_country_dir, panel_dir, check_dir, climate_input_dir)) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
}
