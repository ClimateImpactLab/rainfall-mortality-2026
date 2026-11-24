# ============================================================
# paths.R
#
# Input and output paths for 01-05, set once here
# Run the scripts from this folder
# ============================================================

# The mortality panel from 1_data/panel_build: deaths, pop, climate, drought
# terms and the het vars (read by 01)
panel_file <- "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/annual/panel_update/combined_panel/03_panel_full.csv"

# Reg-ready panel (made by 01, read by 02 and 04)
het_panel_dir <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/global_annual"
het_panel_file <- file.path(het_panel_dir, "global_het_panel.rds")

# Old (August) panel, for --panel=old in 02
old_panel_file <- file.path(het_panel_dir, "global_drought_panel.rds")

# Reg results (made by 02 and 04, read by 03 and 05) and figures (made by 03
# and 05)
results_dir <- "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/output/data/drought/global-annual/het"
figures_dir <- file.path(results_dir, "figures")

# Make the output folders if they don't exist yet
for (dir in c(het_panel_dir, results_dir, figures_dir)) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
}
