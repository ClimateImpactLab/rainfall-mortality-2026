# ERA5-Land Slurm Jobs

Sbatch files for the ERA5-Land admin aggregation are grouped here by what they
run.

Submit jobs from the climate aggregation folder:

```bash
cd /path/to/rainfall-mortality-2026/1_data/climate_data/climate_aggregation_global
```

## aggregation

Main raster-to-admin jobs.

```text
aggregation/
├── 01_weights.sbatch
├── 01_combine_weights.sbatch
├── 02_prcp_temp.sbatch
├── 03_check_prcp_temp.sbatch
├── 04_combine_prcp_temp.sbatch
├── 05_annual_wind.sbatch
├── 06_combine_annual_wind.sbatch
└── 07_daily_wind.sbatch
```

The core precipitation/temperature run is:

```bash
sbatch --array=0-19%10 era5land_admin/jobs/aggregation/01_weights.sbatch BRA 20
sbatch era5land_admin/jobs/aggregation/01_combine_weights.sbatch BRA 20
sbatch --array=1950-2025%10 era5land_admin/jobs/aggregation/02_prcp_temp.sbatch BRA
sbatch era5land_admin/jobs/aggregation/04_combine_prcp_temp.sbatch
```

[aggregation/01_weights.sbatch](aggregation/01_weights.sbatch) is split by
polygon chunks, not years. For example, `BRA 20` means Brazil's admin polygons
are split into 20 chunks. `--array=0-19%10` runs those 20 chunks and lets at
most 10 run at the same time.

[aggregation/02_prcp_temp.sbatch](aggregation/02_prcp_temp.sbatch) is split by
years. For example, `--array=1950-2025%10` runs one country-year per task and
lets at most 10 years run at the same time.

Annual wind is separate from precipitation and temperature. Run it only when
wind controls or wind checks are needed.

## fallback

Small-cell fallback jobs.

```text
fallback/
├── 01_make_fallback_ids.sbatch
├── 02_apply_fallback.sbatch
└── 03_summarize_checks.sbatch
```

These are for small island or coastal units with weights but missing climate
cells. Check first, read the detailed check CSV, then apply only if the move
looks right.

```bash
sbatch era5land_admin/jobs/fallback/01_make_fallback_ids.sbatch
sbatch era5land_admin/jobs/fallback/02_apply_fallback.sbatch COUNTRY /path/to/fallback_ids.csv check 0.5 YEAR
sbatch era5land_admin/jobs/fallback/02_apply_fallback.sbatch COUNTRY /path/to/fallback_ids.csv apply 0.5 YEAR
```

## panel

Panel-side jobs.

```text
panel/
├── 01_panel_ready_climate.sbatch
├── 03_admin_precip_exposure.sbatch
├── 04_admin_precip_exposure_by_country.sbatch
├── 05_combine_admin_precip_exposure.sbatch
├── 06_merge_old_mortality_panel.sbatch
├── 08_daily_rain_event_wind_by_country.sbatch
└── 09_combine_daily_rain_event_wind.sbatch
```

These are not needed for the main precipitation/temperature aggregation. They
build panel-ready files and rain-event wind checks.

[panel/01_panel_ready_climate.sbatch](panel/01_panel_ready_climate.sbatch)
exports old-panel ids, links ERA5-Land annual climate to those ids, and writes
the old-panel climate file.

## Logs

Most logs go under:

```text
logs/era5land_admin/
```

Daily wind logs go under the shared climate log folder because those jobs can be
larger:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/logs/era5land_admin/
```
