# Coarse Hydrology Processing

Scripts in this folder form the main processing pipeline: DEM download, daily-to-monthly aggregation, flow accumulation, and gauge validation. See the [parent README](../README.md) for the full pipeline diagram.

---

## getdem_01deg.py

Downloads ERA5-Land geopotential from the Copernicus CDS API (`reanalysis-era5-land`), converts to elevation in meters (g = 9.80665), shifts longitude from [0, 360] to [-180, 180], and writes a GeoTIFF at 0.1° resolution.

**Input:** CDS API — ERA5-Land geopotential (2000-01-01 00:00, static field)

**Output:**
- `era5_land_orography_01deg.nc` — raw download
- `composite_01deg.tif` — elevation in meters, EPSG:4326

Run directly (no SLURM wrapper): `python coarse/getdem_01deg.py`

> **Note:** `getdem.py` is superseded by this script — it produced `composite.tif` at a different resolution and is no longer used.

---

## transform.py / transform.sh

Processes ERA5-LAND daily data into monthly rainfall and melt variables, then assembles a global output file.

**Input:** Raw daily ERA5-Land per region:
- `swe_mean/era5land_{region}_swe_mean_*.nc4`
- `tmean/era5land_{region}_tmean_*.nc4`
- `tp_total/era5land_{region}_tp_total_*.nc4`

**Per-region loop** (8 regions: asia_east, australia, brazil, europe, india, latam, mexico_south, usa):

1. Opens the three daily variables lazily with dask (`chunks={"valid_time": 31}`)
2. Computes:
   - `snowchange`: day-to-day SWE difference (positive = accumulation, negative = melt)
   - `rainfall`: total precip minus snow accumulation (`tp_total - snowchange`)
   - `era5melt`: snowmelt only (negative snowchange days)
   - `tempmelt`: temperature-weighted melt proxy (SWE > 0 and tmean > 0)
3. Resamples each to monthly sums and writes: `{outdir}/{region}_monthly.nc4`

**Global assembly** (runs after all regional files exist):
Assembles all 8 regional files into `globe_monthly.nc4` covering the union lat/lon/time grid; cells outside a region's coverage are NaN.

**Output:**

| File | Variables | Description |
|------|-----------|-------------|
| `{region}_monthly.nc4` | rainfall, era5melt, tempmelt | Monthly sums per region |
| `globe_monthly.nc4` | rainfall, era5melt, tempmelt | All regions on a common grid |

Global grid: ~900 time steps × 2375 lats × 4847 lons.

**Running:**
```bash
sbatch hydro/coarse/transform.sh   # --mem=20G, --time=06:00:00
```

Per-region files are skipped if they already exist. The global file is always recreated.

### Implementation notes

**NaN preservation for ocean cells:** `.resample().sum()` converts all-NaN months (ocean cells) to 0 by default (`skipna=True`). A static land mask from the first time step of `tp_total` is applied after each resample:

```python
land_mask = ds_tp["tp_total"].isel(valid_time=0).notnull()
rainfall_ms = rainfall.resample(valid_time="1MS").sum().where(land_mask)
```

**Global assembly memory:** The original approach used `xr.reindex` + `xr.merge`, loading all 8 regions expanded to the full union grid (~100–150 GB peak). The replacement writes a lazy NaN-filled template to disk with `dask.array.full`, then patches each region in via `netCDF4` slice writes, 12 months at a time. Peak memory stays under 500 MB.

---

## transform2.py / transform2.sh

Simpler monthly aggregation without snow decomposition. **Only needed as input to `prepanal.py` (gauge validation). Not required for flow visualization.**

**Input:** Raw daily ERA5-Land per region: `tmean`, `tp_total`

**Output:** `{region}_monthly_ttp.nc4`
- `tp` — monthly total precipitation
- `tmean` — monthly mean temperature

**Running:**
```bash
sbatch hydro/coarse/transform2.sh   # --mem=50G, --time=08:00:00, caslake partition
```

---

## prepflow.py / prepflow.sh

Routes monthly precipitation through the D8 flow-direction network to produce upstream-accumulated flow at every grid cell.

**Input:**
- `{region}_monthly.nc4` — from `transform.py`
- `compositep_01deg.tif` — TauDEM D8 flow directions (from `run_taudem.sh`)

**Algorithm (per region):**
1. Loads the global D8 grid; builds a flat downstream index array
2. Runs Kahn's topological sort on the full global graph
3. Projects sub-region cells onto the global coordinate system; builds a local flow graph clipped to the sub-region boundary
4. Calls `accumulate_rain_timefirst` for each variable: traverses the topological order and propagates each cell's value to its downstream neighbor

**Output:** `{region}_monthly_flow.nc4`
- `rainfall_flow` — upstream-accumulated liquid precip (mm)
- `era5melt_flow` — upstream-accumulated snowmelt (mm)
- `tempmelt_flow` — upstream-accumulated temperature-weighted melt

**Running:**
```bash
sbatch hydro/coarse/prepflow.sh   # --mem=120G, --time=08:00:00
```

---

## prepanal.py / prepanal.sh

Compares model flow outputs to observed monthly discharge from the Global Runoff Data Centre (GRDC). **Optional — not part of the visualization pipeline.**

**Input:**
- `grdd-meta.csv` — GRDC station metadata (station_id, lat, lon, country)
- `grdd-data.csv` — monthly discharge observations
- `{region}_monthly_ttp.nc4` — from `transform2.py`
- `{region}_monthly.nc4` — from `transform.py`
- `{region}_monthly_flow.nc4` — from `prepflow.py`

**Output:** `streamflow_model_monthly_combined.csv`

Columns: `station_id`, `country`, `lat`, `lon`, `year`, `month`, `discharge`, `tp`, `tmean`, `rainfall`, `era5melt`, `tempmelt`, `rainfall_flow`, `era5melt_flow`, `tempmelt_flow`.

Results are appended station-by-station; already-processed stations are skipped on re-runs.

**Running:**
```bash
sbatch hydro/coarse/prepanal.sh   # --mem=50G, --time=08:00:00, caslake partition
```
