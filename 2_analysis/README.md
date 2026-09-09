# Rainfall-Mortality Analysis

This folder contains the analysis scripts for the rainfall-mortality panel.

The scripts read the panel files built under `1_data/panel_build/` and write regression outputs, diagnostics, and figures under the repo-level `output/` folder.

## Shared files

Most scripts source a few common files:

```text
../0_utils/paths.R
  Main repo and output paths

../0_utils/functions.R
  Regression and response-function functions:
  `fit_response()`, `make_coef_names()`, `poly_response()`, and
  `build_response()`

regressions/00_prep_analysis_panel.R
  Panel loading and filtering functions:
  `load_new_panel()` and `filter_regression_sample()`
```

## Related: ad-hoc studies

Two self-contained side studies live outside this folder, in
[`adhoc/`](../adhoc/README.md): the Philippines municipality-level response
functions (`adhoc/phl/`) and the Young-Hsiang ERA5-Land wind validation
(`adhoc/wind_tc_validation/`). They are organised by question rather than by
stage — each script runs its own regressions, figures and tables end to end —
and each backs a deck in `output/slides/`, so they do not fit the
regressions/figures/diagnostics split used here.

## Folder layout

```text
regressions/
  Prepare the analysis sample, run regressions, and save
  response-function data

figures/
  Read saved regression outputs and make figures

diagnostics/
  Panel checks and profile-selection diagnostics

sbatch/
  Slurm scripts for longer or repeated runs

archive/
  Older scripts kept for reference
```

## Regression scripts

* `regressions/00_prep_analysis_panel.R`: reads the mortality panel, creates the analysis variables, drops the all-age group, winsorizes death rates, adds weights, and applies the regression-sample restrictions

* `regressions/01_main_response.R`: runs the main rainfall and temperature response regressions and saves response-function CSVs for plotting

* `regressions/02_urban_heterogeneity.R`: runs rainfall response regressions by urban-share group and saves response-function files for each grouping

* `regressions/03_subsample_profiles.R`: runs interacted regressions for the original Mumbai-profile definitions based on urban share, population, ADM1 income, and long-run rainfall

* `regressions/04_profile4_leave_one_admin_unit_out.R`: re-runs the Profile 4 regression while dropping one admin unit at a time to check whether the result is driven by a single place

* `regressions/05_wind_control_coefficients.R`: estimates coefficients on annual wind controls and daily rain-wind overlap controls. The outputs are used to compare the different wind controls and to compare TC-prone and non-TC-prone countries

## Figure scripts

* `figures/01_plot_main_response.R`: plots the main rainfall and temperature response functions from `01_main_response.R`

* `figures/02_plot_urban_heterogeneity.R`: plots the urban-share heterogeneity response functions from `02_urban_heterogeneity.R`

* `figures/03_plot_subsample_profiles.R`: plots response functions for the original Mumbai-profile regressions from `03_subsample_profiles.R`

* `figures/04_make_urban_overleaf_panels.R`: combines the urban-share figures into larger panels for Overleaf

* `figures/05_compare_main_wind_controls.R`: compares the main response functions with and without annual wind controls

* `figures/06_compare_main_daily_overlap.R`: compares the main response functions with daily rain-wind overlap controls and exclusions

* `figures/07_plot_wind_control_coefficients.R`: plots wind and rain-wind overlap coefficients from `05_wind_control_coefficients.R`

## Diagnostic scripts

* `diagnostics/01_panel_diagnostics.R`: checks panel keys, country coverage, admin levels, urban share, income, and large death-rate values

* `diagnostics/02_deathrate_zero_diagnostics.R`: checks zero death-rate rows by age group, country-age group, and admin unit

* `diagnostics/profile_selection/01_profile_selection_diagnostics.R`: checks how much sample remains under the original Mumbai-profile definitions and builds the profile score based on urban share, population, ADM1 income, and long-run rainfall

* `diagnostics/profile_selection/02_income_cutoff_sensitivity.R`: varies the ADM1 income cutoff in the original profile definitions and counts how many rows, admin units, and countries remain

* [`diagnostics/wind_precip_confounding/`](diagnostics/wind_precip_confounding/README.md): checks whether high-wind events overlap with extreme rainfall and whether this matters for the rainfall regressions

## Slurm jobs

Use the scripts in `sbatch/` for longer or repeated runs:

* `sbatch/01_run_main_response.sbatch`: runs `regressions/01_main_response.R`, then `figures/01_plot_main_response.R`

* `sbatch/02_run_urban_heterogeneity.sbatch`: runs `regressions/02_urban_heterogeneity.R`, then `figures/02_plot_urban_heterogeneity.R`

* `sbatch/03_run_subsample_profiles.sbatch`: runs `regressions/03_subsample_profiles.R`, then `figures/03_plot_subsample_profiles.R`

* `sbatch/04_run_compare_main_wind_controls.sbatch`: runs `figures/05_compare_main_wind_controls.R`

* `sbatch/05_run_compare_main_daily_overlap.sbatch`: runs `figures/06_compare_main_daily_overlap.R`

* `sbatch/06_run_profile4_leave_one_admin_unit_out.sbatch`: runs `regressions/04_profile4_leave_one_admin_unit_out.R`

* `sbatch/07_run_wind_control_coefficients.sbatch`: runs `regressions/05_wind_control_coefficients.R`, then `figures/07_plot_wind_control_coefficients.R`

Examples:

```bash
sbatch sbatch/01_run_main_response.sbatch
sbatch sbatch/02_run_urban_heterogeneity.sbatch
sbatch sbatch/03_run_subsample_profiles.sbatch
```

Some Slurm scripts can also be controlled with environment variables:

```bash
OUTCOME_MODEL=poisson WEIGHTED=true sbatch sbatch/01_run_main_response.sbatch
```

Logs are written to the repo-level `logs/` folder.
