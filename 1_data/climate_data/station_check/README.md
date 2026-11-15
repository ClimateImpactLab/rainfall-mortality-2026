# Station check

While working on extreme precip heterogeneity analysis, I wanted to have an idea of the places receiving the highest rainfall yearly totals.
I also wanted to check what the support looked like for heavy rain days. 

Looking at yearly totals and the typical wettest day (mean of the yearly max day, 1981-2010) by admin unit, some Colombian units came out at 14,000-19,000 mm a year in ERA5-Land, above the wettest station on Earth (Mawsynram, India, about 11,900 mm).
For ex, Bucaramanga's admin unit has 16,517 mm a year while its airport gauge says 1,216 mm.

So I checked ERA5-Land, our main precip product, and CHIRPS, our robustness product (only 50S-50N), against rain gauges over 1981-2010, and then compared the two for our own admin units.

Gauges come from the Global Historical Climatology Network Daily (GHCND, NOAA).
A gauge is one point and a grid cell an area average (ERA5-Land 0.1 deg, CHIRPS 0.05 deg), so some gap is normal.
Large, systematic gaps are what we look for. ERA5-Land uses no rain gauges, so the check is independent for it.
CHIRPS is built with gauges, GHCN included, so for CHIRPS the check isn't independent: by design it's going to align with the gauges.

| Script | What it does |
|---|---|
| `01_cells_by_year.py` | daily ERA5-Land and CHIRPS precip at the cells the gauges sit in, one year per run (`--year=1990`) |
| `02_station_vs_grids.py` | every GHCND gauge in the panel countries (US without Hawaii) vs the ERA5-Land and CHIRPS cell it sits in, on the gauge's days: yearly total and typical wettest day (mean of the yearly max day) |
| `03_units_era5land_vs_chirps.R` | ERA5-Land vs CHIRPS mean yearly total 1981-2010 for each panel admin unit, with the unit's deaths and unit-years from the het panel |
| `04_tables_figures.R` | tables and figures for the write-up |

Canadian gauges have NOAA's new IDs in the station list and the old ones in the lab copy of the data, matched by their Environment Canada station number (in `02`).

Inputs:
- GHCND: `/project/cil/gcp/climate/GHCND/ghcnd_all/*.dly` and `ghcnd-stations.txt`
- raw ERA5-Land daily precip: `/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global/tp_total/`
- raw CHIRPS daily precip: `/project/cil/gcp/climate/CHIRPS/Raw_NetCDF_p05deg_by_p05deg/PRCP/`
- ERA5-Land and CHIRPS admin files (yearly): `climate_data/ERA5-LAND-GLOBAL/` and `climate_data/CHIRPS/`

Run order, from this folder:
1. `sbatch run_cells_by_year.sbatch`: daily ERA5-Land and CHIRPS precip at the gauge cells, one Slurm task per year (`01`), saved in `cells/` next to the outputs
2. `sbatch run_station_check.sbatch` once all years are done: gauges vs cells (`02`), then `03` and `04`

Or both at once, step 2 waiting for step 1:
```
jid=$(sbatch --parsable run_cells_by_year.sbatch)
sbatch --dependency=afterok:${jid} run_station_check.sbatch
```

Outputs in `/project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check/`:
- data: `station_vs_grids_1981_2010.csv` (one row per gauge), `units_era5land_vs_chirps_1981_2010.csv` (one row per admin unit)
- yearly cell files from `01`: `cells/` (30 files, about 6 GB)
- tables and figures: `summary/`
