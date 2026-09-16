# Brazil Drought Measures

Build rainfall-based drought measures from existing ERA5-Land ADM2 monthly rainfall and summarize them for the mortality analysis.

The current work uses Brazil to compare alternative drought definitions and annual summaries before deciding which measures to carry forward.

## Main choices

* Rainfall windows: 1, 3, 6, and 12 months
* Main baseline: previous 20 years, matched by ADM2 and ending calendar month
* Low-rainfall thresholds: 10th and 5th percentiles
* Extreme measure: rainfall below all 20 prior comparison values
* Population- and area-weighted rainfall
* [Rocha-Soares-style](https://doi.org/10.1016/j.jdeveco.2014.10.003) rolling 12-month rainfall measure as a separate comparison

For example, a July-ending 6-month rainfall total is compared with July-ending 6-month totals for the same ADM2 over the previous 20 years. The current year is excluded.

## Files

### `01_build_monthly_drought_measures.R`

Builds the ADM2-month drought measures from the existing ERA5-Land monthly rainfall files.

The output includes rolling rainfall totals, prior-baseline percentiles and z-scores, low-rainfall indicators, rainfall deficits, and the separate Rocha-Soares 12-month measures.

Unsupported ADM2s remain in the file, with drought measures left missing.

### `02_build_annual_drought_summaries.R`

Aggregates the monthly measures to one ADM2-year row for later use in the mortality analysis.

The annual summaries capture different dimensions of drought, including duration, severity, one-month drought episodes, annual rainfall, rolling-window extremes, and Rocha-Soares measures.

For rolling rainfall windows, the year is defined by the ending month.

### `03_drought_pilot.Rmd`

R Markdown file, rendered to HTML, used to work through the different drought measures and the main choices around how to define and summarize them.

It compares rainfall windows, baseline choices, thresholds, severity and duration measures, monthly-to-annual aggregation, and selected historical Brazil drought events.

`03_drought_pilot.html` is the rendered version of this file. GitHub will show the
HTML source rather than the rendered page, so download the HTML file and open it
in a browser to read it properly.

## Sbatch

```text
sbatch/run_01_monthly_drought_bra.sbatch
sbatch/run_02_annual_drought_bra.sbatch
```

Run from the repository root:

```bash
sbatch 2_analysis/drought/sbatch/run_01_monthly_drought_bra.sbatch
sbatch 2_analysis/drought/sbatch/run_02_annual_drought_bra.sbatch
```

The annual job expects the monthly file from the first job:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/monthly/era5land_admin_drought_monthly_bra.rds
```

## Outputs

Outputs are written under:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/
```

Current Brazil files:

```text
monthly/era5land_admin_drought_monthly_bra.rds
annual/era5land_admin_drought_annual_bra.rds
```
