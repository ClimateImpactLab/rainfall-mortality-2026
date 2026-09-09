# Analysis Sbatch Files

Slurm files used to run the main analysis jobs on RCC.

The analysis scripts can be run either through `sbatch` on RCC or directly in
RStudio.

## Run on RCC with sbatch

Use `sbatch` for jobs that should run on a compute node.

The sbatch files call the R scripts with command-line options. For example,
`01_run_main_response.sbatch` can pass options such as:

```text
--outcome_model=levels
--weighted=true
--wind_control=both
```

to `01_main_response.R`.

Run the default version with:

```bash
sbatch 01_run_main_response.sbatch
```

To change a run, either edit the default values inside the sbatch file or set
options right before the `sbatch` command. Setting options on the command line
only affects that submitted job.

```bash
OUTCOME_MODEL=poisson WEIGHTED=true sbatch 01_run_main_response.sbatch
```

The values set inside each sbatch file are the default RCC options.

Logs are written to:

```text
logs/
```

## Run directly in RStudio

The R scripts can also be run directly. I use this for quicker checks, editing,
debugging, or adding something like a new control.

Each script has default options near the top of the file. If no command-line
options are passed, those values are used.

To run a different version of the regressions in RStudio, change the default
values in the R script, set the working directory to the script folder, then run
the code. For example:

```r
setwd("2_analysis/regressions")
```

Most regression jobs, except the leave-one-out check, take a few minutes to
around 20 minutes. Use `sbatch` when you do not want to keep RStudio open or
when running the leave-one-out check. Plotting scripts and small checks are
usually fine to run directly in RStudio.

## Wind and overlap runs

The default main-response job uses:

```text
WIND_CONTROL=both
```

so the regression includes both annual max wind and high-wind days.

Daily rain-wind overlap variables are separate and are only included when
`DAILY_OVERLAP_CONTROL` or `DAILY_OVERLAP_EXCLUSION` is set.

### Annual wind controls

To compare the main response function across the annual wind-control options,
run:

```bash
WIND_CONTROL=none sbatch 01_run_main_response.sbatch
WIND_CONTROL=windmax sbatch 01_run_main_response.sbatch
WIND_CONTROL=winddays sbatch 01_run_main_response.sbatch
WIND_CONTROL=both sbatch 01_run_main_response.sbatch
```

Then make the comparison figure with:

```bash
sbatch 04_run_compare_main_wind_controls.sbatch
```

### Daily rain-wind overlap

Run the overlap-control and overlap-exclusion versions with:

```bash
OUTCOME_MODEL=poisson DAILY_OVERLAP_CONTROL=rain100 sbatch 01_run_main_response.sbatch
OUTCOME_MODEL=poisson DAILY_OVERLAP_CONTROL=rain200 sbatch 01_run_main_response.sbatch
OUTCOME_MODEL=poisson DAILY_OVERLAP_EXCLUSION=rain100 sbatch 01_run_main_response.sbatch
OUTCOME_MODEL=poisson DAILY_OVERLAP_EXCLUSION=rain200 sbatch 01_run_main_response.sbatch
```

Then make the comparison figure with:

```bash
sbatch 05_run_compare_main_daily_overlap.sbatch
```

## Files

* `01_run_main_response.sbatch`: main rainfall and temperature regressions, followed by the main response-function plots
* `02_run_urban_heterogeneity.sbatch`: urban-share regressions and response-function plots
* `03_run_subsample_profiles.sbatch`: Mumbai-profile regressions and response-function plots
* `04_run_compare_main_wind_controls.sbatch`: compares the main response functions across the annual wind-control specifications
* `05_run_compare_main_daily_overlap.sbatch`: compares the main response functions across the daily rain-wind overlap controls and exclusions
* `06_run_profile4_leave_one_admin_unit_out.sbatch`: Profile 4 leave-one-admin-unit-out regressions
* `07_run_wind_control_coefficients.sbatch`: wind-control coefficient regressions and coefficient plots

Files `01`, `02`, `03`, `06`, and `07` run regressions.

Files `04` and `05` only read saved regression results and make comparison
figures.
