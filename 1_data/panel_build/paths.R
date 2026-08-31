# ============================================================
# paths.R
#
# Shared paths for the panel build.
#
# Every script in scripts/ reads this file
# Keeping the main paths here avoids hard-coding the same path
# locations in every script
# ============================================================

# -----------------------------
# User and repo paths
# -----------------------------

user_name <- Sys.getenv("USER", unset = Sys.info()[["user"]])

repo_dir <- Sys.getenv("RAINFALL_MORTALITY_REPO")
if (repo_dir == "") {
  repo_dir <- file.path(
    "/project/cil/home_dirs", user_name, "repos/rainfall-mortality-2026"
  )
}

# -----------------------------
# Input panel from the old Carleton data
# -----------------------------

old_panel_file <- file.path(
  "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data",
  "0_data_cleaning/3_final/global_mortality_panel_era5.dta"
)

# -----------------------------
# Panel output folders
# -----------------------------

out_dir <- "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build"

old_panel_dir <- file.path(out_dir, "old_panel")
new_country_dir <- file.path(out_dir, "new_countries")
panel_dir <- file.path(out_dir, "combined_panel")
check_dir <- file.path(out_dir, "checks")

# -----------------------------
# Climate inputs
# -----------------------------

climate_root <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data"
era5land_dir <- file.path(climate_root, "ERA5-LAND")
chirps_dir <- file.path(climate_root, "CHIRPS")

# -----------------------------
# Income inputs
# -----------------------------

income_dir <- "/project/cil/gcp/estimation/rainfall-mortality/income_data/carleton"
income_file <- file.path(income_dir, "output/new_country_income_adm1_year.csv")

# -----------------------------
# Elevation inputs
# -----------------------------

elevation_file <- file.path(
  "/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data",
  "elevation_data/output/admin_elevation_exposure_fabdem_landscan2011.csv"
)

# -----------------------------
# Population density inputs
# -----------------------------

pop_density_dir <- file.path(
  "/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data",
  "pop_density"
)

admin_density_file <- file.path(pop_density_dir, "admin_density.csv")
landscan_density_file <- file.path(pop_density_dir, "landscan_density.csv")
ghsl_density_file <- file.path(pop_density_dir, "ghsl_density.csv")

# -----------------------------
# Create output folders if needed
# -----------------------------

dir.create(old_panel_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(new_country_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(check_dir, recursive = TRUE, showWarnings = FALSE)
