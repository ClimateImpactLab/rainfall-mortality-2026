# Cell Fallback

This folder handles a small ERA5-Land land mask problem in the admin
aggregation.

Normally, each admin unit gets climate values from the ERA5-Land grid cells
inside or near its polygon. Those grid cells already have population and area
weights from
[01_make_weights.py](../aggregation_scripts/01_make_weights.py).

For a few small coastal or island units, the weighted ERA5-Land cells exist but
are masked by the ERA5-Land land mask. ERA5-Land masks water and ocean cells,
so small islands can end up attached to cells with missing precipitation and
temperature. Without fallback, those admin units would be missing climate data
even though valid ERA5-Land land cells are nearby.

The fallback works like this:

1. Find admin units that are missing in the climate outputs and matter for the
   mortality panel.
2. Record those `region_id` values in
   [step_01_make_fallback_ids.py](step_01_make_fallback_ids.py).
3. Run the fallback check with that CSV. The check reads the listed IDs, tests
   their weighted cells against the raw ERA5-Land land mask, and writes a
   detailed check CSV.
4. Read the detailed check CSV. It shows the original weighted cells, the
   nearest valid ERA5-Land cells, and the distance to those cells.
5. If the nearby cell is acceptable, run the apply step with the same fallback
   ID CSV. The script moves the unit's weight to the nearest valid ERA5-Land
   cell, but only if that cell is close enough.
6. Keep the detailed check CSV. It shows which cells were checked, moved, or
   left alone.

The point is to keep reviewed small coastal or island units from being dropped
only because their original ERA5-Land cells are masked.

## Files

```text
step_01_make_fallback_ids.py
step_02_apply_fallback.py
step_03_summarize_checks.py
```

[step_01_make_fallback_ids.py](step_01_make_fallback_ids.py) writes the
reviewed `region_id` lists used by the check and apply runs.

[step_02_apply_fallback.py](step_02_apply_fallback.py) has two modes. `--check`
writes the detailed check CSV without changing weights. `--apply` writes the
same report and moves weights to nearby valid land cells.

[step_03_summarize_checks.py](step_03_summarize_checks.py) turns the detailed
check CSVs into one row per admin unit and weight type.

Fallback ID CSVs are stored outside the repo here: 

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/cell_fallback_ids/
```

A fallback ID file is a small CSV with one column, `region_id`. The reviewed
IDs are written by
[step_01_make_fallback_ids.py](step_01_make_fallback_ids.py). To change which
units are checked or moved, edit that script and rerun it.

## Rule

Use fallback only when all of this is true:

- the admin unit is needed in the mortality panel
- all normal weighted cells are missing climate data
- there is a nearby cell with valid climate data
- the nearby cell is within the distance limit
- the admin unit is listed in the fallback ID CSV

For precipitation and temperature, the distance limit is:

```text
0.5 degrees
```

## Run

Submit from `1_data/climate_data/climate_aggregation_global`. Write the
fallback ID CSVs, or use `--country CAN` to write only Canada's list:

```bash
sbatch era5land_admin/jobs/fallback/01_make_fallback_ids.sbatch
sbatch era5land_admin/jobs/fallback/01_make_fallback_ids.sbatch --country CAN
```

Check first:

```bash
sbatch era5land_admin/jobs/fallback/02_apply_fallback.sbatch COUNTRY /path/to/fallback_ids.csv check 0.5 YEAR
```

Apply only after reading the detailed check CSV:

```bash
sbatch era5land_admin/jobs/fallback/02_apply_fallback.sbatch COUNTRY /path/to/fallback_ids.csv apply 0.5 YEAR
```

The arguments are:

- `COUNTRY`: country code, for example `CHL`
- `/path/to/fallback_ids.csv`: reviewed `region_id` list from step 01
- `check` or `apply`: write the check CSV only, or also move the weights
- `0.5`: maximum allowed distance in degrees
- `YEAR`: year used to check the raw ERA5-Land land mask

Detailed check CSVs go here:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/cell_fallback_checks/<COUNTRY>/
```

After applying fallback weights, rerun the affected climate outputs.

## Canada

The 2000 pilot has missing precipitation and temperature for one of Canada's
293 census divisions:

```text
CAN_2401  Communaute maritime des Iles-de-la-Madeleine
```

The unit has population and area weights, but all positively weighted cells
are missing in the raw January reference fields. In 1950, 2000 and 2025
the nearest valid cells are 0.825 to 1.170 degrees (82 to 126 km) away, past
the 0.5-degree cutoff for both weights.

The reviewed ID is written to:

```text
ERA5-LAND-GLOBAL/cell_fallback_ids/can_mortality_required.csv
```

Check reports are under `ERA5-LAND-GLOBAL/cell_fallback_checks/CAN/` in the
shared climate data folder. They use the first January day of each reference
year.

`diagnostics/check_country_series.py` checks every annual file and saves the
cell reports, distances and missing units in
`ERA5-LAND-GLOBAL/CAN/coverage_checks.xlsx`. It stops if any unit other than
`CAN_2401` is missing.

Over 1950-2025, 292 of 293 units have valid annual climate in every year.
`CAN_2401` is the only missing unit (76 of 22,268 admin-year rows).

## Brazil

Brazil uses fallback for four nearby coastal cases:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/cell_fallback_ids/bra_global_nearby.csv
```

These units had weights on masked ERA5-Land cells, but valid cells were only
0.1 to 0.2 degrees away.

The stable Brazil geography is checked separately. Itaparica, Madre de Deus,
and Imbé use valid cells 0.1 degrees away. Fernando de Noronha stays missing
because the nearest valid land cell is more than 3.2 degrees away.

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/
ERA5-LAND-GLOBAL/BRA_STABLE/cell_fallback_applied.csv
```

## USA

The USA output leaves 13 small island or territory units missing in the
annual output. Most are overseas territories. We could apply fallback later if
we decide these units matter, but not important for now because they aren't used 
in the final analysis sample.

```text
USA_244_25_019  Nantucket County
USA_244_60_010  Eastern District, American Samoa
USA_244_60_020  Manu'a District, American Samoa
USA_244_60_030  Rose Island, American Samoa
USA_244_60_040  Swains Island, American Samoa
USA_244_60_050  Western District, American Samoa
USA_244_69_085  Northern Islands Municipality
USA_244_72_049  Culebra Municipio, Puerto Rico
USA_244_72_133  Santa Isabel Municipio, Puerto Rico
USA_244_72_147  Vieques Municipio, Puerto Rico
USA_244_78_010  St. Croix Island
USA_244_78_020  St. John Island
USA_244_78_030  St. Thomas Island
```

The weights file has full coverage for most of these units, but the attached
ERA5-Land climate cells are missing in the raw climate files. Since these units
are not in the final mortality panel, they are documented here rather
than added to a fallback ID file.

## Chile and Colombia

Chile moves two Chiloé island communes to nearby valid ERA5-Land cells:

```text
CHL_10_550  Quinchao
CHL_10_551  Puqueldón
```

Both communes sit on small islands. The nearest valid ERA5-Land cells were
within 0.5 degrees, so their weights were moved.

The pre-fallback weights were backed up here:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/weights/landscan2011/ERA5-LAND-GLOBAL/CHL/era5land_chl_adm2_segment_weights_landscan2011.before_valid_cell_fallback.csv
```

Colombia leaves two Caribbean island municipalities missing:

```text
COL_88001  San Andrés
COL_88564  Providencia
```

These islands are far from mainland Colombia. They were left missing instead
of being matched to a distant mainland or open-ocean cell. If they matter for
the final mortality sample, decide on them separately.

## Cabo Verde

The ERA5-Land land mask leaves all positively weighted cells missing for Sal
(`CPV_41`) and Brava (`CPV_91`), under both population and area weights.
All other 19 mortality units have complete precipitation and temperature for
1950-2025.

Nearest valid cells:

| Unit | Nearest valid cells overlap | Source-cell distance | Degree distance |
| --- | --- | --- | --- |
| Brava | Fogo | 22-34 km | 0.20-0.32 |
| Sal | Boa Vista | 44-77 km | 0.40-0.70 |

These are distances from the original weighted cell centres to replacement
cell centres, not from the island coastline. The ranges cover both weighting
methods. The candidates have valid precipitation, mean temperature, maximum
temperature, and wind on the first day of the 2000 reference files.

Brava passes the 0.5-degree cutoff for precip and temp. Sal fails it because
some of its cells are farther away, and a unit moves whole or not at all. Even
Brava would get another island's climate, so both stay missing for precip,
temp and wind.

The 1.6-degree wind rule would move both islands, so `wind_common.py` skips
it for CPV and wind has the same two missing units. The other 19 units have complete annual wind for
1950-2025.

Detailed weighted-cell coverage, replacement coordinates, distances, and
1981-2010 baseline counts are saved under:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/CPV/cell_checks/
```

The full-series check is saved beside that folder as `coverage_checks.xlsx`.
