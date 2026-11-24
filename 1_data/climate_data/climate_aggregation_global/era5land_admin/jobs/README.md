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

### Rwanda

Rwanda uses 30 districts, with the same facility-location geography as the
supplied mortality data. Submit from the climate aggregation folder named at
the start of this note. Weights use four chunks:

```bash
sbatch --array=0-3%4 --cpus-per-task=2 --mem=8G --time=00:30:00 \
  era5land_admin/jobs/aggregation/01_weights.sbatch RWA 4
```

After all four chunks succeed, combine them, then test one climate year:

```bash
sbatch --cpus-per-task=2 --mem=8G --time=00:15:00 \
  era5land_admin/jobs/aggregation/01_combine_weights.sbatch RWA 4

sbatch --array=2000 --mem=6G --time=00:20:00 \
  era5land_admin/jobs/aggregation/02_prcp_temp.sbatch RWA
```

Submit each step once the previous one passes (or use
`--dependency=afterok:JOB_ID`). Check the 2000 results before running all
years:

```bash
sbatch --array=1950-2025%20 --mem=6G --time=00:20:00 \
  era5land_admin/jobs/aggregation/02_prcp_temp.sbatch RWA
```

The series check uses `--country RWA`, with no allowed missing IDs. Its
workbook is written to
`ERA5-LAND-GLOBAL/RWA/coverage_checks.xlsx` in the shared climate data folder.

All 30 districts have valid annual climate in every year (2,280 admin-year
rows). The mortality panel is 2019-2024, the longer climate series is for
baselines.

### Canada

Canada weights use 20 chunks. The years run with the usual country-year job:

```bash
sbatch --job-name=can_prcp_temp --array=1950-2025%20 --mem=12G --time=01:00:00 \
  era5land_admin/jobs/aggregation/02_prcp_temp.sbatch CAN
```

At most 20 years run at once. One year uses about 5.6 GiB, so 12 GiB per task
leaves room. Logs are written under
`logs/era5land_admin/CAN/` in the climate aggregation code folder.

`CAN_2401` stays missing, see
[the fallback decision](../cell_fallback/README.md#canada).

After the full array completes, run `diagnostics/check_country_series.py` on
a compute node with `--country CAN --allowed-missing-region-id CAN_2401`.
From the same climate aggregation folder, one submission is:

```bash
sbatch --account=cil --partition=cil --mem=4G --time=00:20:00 \
  --job-name=can_series_check \
  --output=logs/era5land_admin/CAN/series_check_%j.out \
  --wrap="env PYTHONPATH=$PWD/era5land_admin /project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python -B $PWD/era5land_admin/diagnostics/check_country_series.py --country CAN --allowed-missing-region-id CAN_2401"
```

It writes one coverage workbook to the shared climate data folder:

```text
ERA5-LAND-GLOBAL/CAN/coverage_checks.xlsx
```

Don't run the global combine to check Canada, it needs every country in
settings.py and overwrites the shared combined files.

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
