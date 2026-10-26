# hydro

This folder builds the hydrological flow variables used in the rainfall-mortality analysis. The pipeline routes ERA5-Land precipitation through a river network to produce flow estimates, then validates those estimates against observed streamflow gauges.

## Overview

The pipeline has four stages:

1. **Build a DEM** from ERA5-Land orography and derive a flow-direction grid with TauDEM
2. **Transform** raw ERA5-Land daily data into monthly precipitation components by region
3. **Accumulate flow** by routing monthly precipitation through the D8 flow network
4. **Visualize** accumulated flow; optionally validate against GRDC gauge observations

Diagnostic scripts in `diagnostics/scripts/` check for data quality issues (ocean masking, negative rainfall, zero accumulated flow) and render a comparison report.

---

## Directory structure

```
hydro/
├── coarse/                   # Main processing pipeline
│   ├── getdem_01deg.py       # Download ERA5-Land orography via CDS API → composite_01deg.tif
│   ├── transform.py          # Daily ERA5-Land → monthly rainfall/melt (needed for flow)
│   ├── transform2.py         # Daily ERA5-Land → monthly total precip + tmean (gauge validation only)
│   ├── prepflow.py           # Route monthly variables through D8 flow network
│   ├── prepanal.py           # Compare model flow to GRDC gauge observations (optional)
│   ├── *.sh                  # SLURM submission wrappers for each script above
│   └── era5-land-example.nc4 # Example input file
│
├── diagnostics/              # Diagnostics and visualizations
│   ├── scripts/
│   │   ├── run_taudem.sh         # SLURM: pit removal + D8 flow direction (TauDEM)
│   │   ├── run_aread8.sh         # SLURM: D8 contributing area from the existing
│   │   │                         #   flow-direction grid (read-only diagnostic)
│   │   ├── diagnostics.py        # Ocean masking / negative rainfall / zero flow,
│   │   │                         #   run over both processing vintages
│   │   ├── diagnostics.sh        # SLURM wrapper (array: one task per vintage)
│   │   ├── vis_taudem.py         # Visualize TauDEM-derived accumulated rainfall flow
│   │   ├── vis_taudem.sh         # SLURM wrapper
│   │   └── report.Rmd            # Renders the two vintages side by side
│   ├── output/               # All generated output (see Diagnostics below)
│   └── logs/                 # SLURM job logs
│
└── tdprocess.sh              # TauDEM processing commands (reference/manual)
```

---

## Pipeline

```
coarse/getdem_01deg.py
  In:  CDS API (ERA5-Land geopotential)
  Out: composite_01deg.tif
       era5_land_orography_01deg.nc
          │
          ▼
diagnostics/scripts/run_taudem.sh
  In:  composite_01deg.tif
  Out: composite_01deg_fel.tif   (pit-filled DEM)
       compositep_01deg.tif      (D8 flow-direction codes 1–8)
          │
  ┌───────┴────────────────────────────────────────┐
  │                                                │
  ▼                                                │
coarse/transform.py / transform.sh                 │
  In:  raw daily ERA5-Land                         │
         swe_mean, tmean, tp_total                 │
  Out: {region}_monthly.nc4                        │
       globe_monthly.nc4                           │
         vars: rainfall, era5melt, tempmelt         │
  │                                                │
  ▼                                                ▼
coarse/prepflow.py / prepflow.sh        coarse/transform2.py / transform2.sh
  In:  {region}_monthly.nc4               In:  raw daily ERA5-Land
       compositep_01deg.tif                      tmean, tp_total
  Out: {region}_monthly_flow.nc4          Out: {region}_monthly_ttp.nc4
         vars: rainfall_flow,                    vars: tp, tmean
               era5melt_flow,
               tempmelt_flow              (only needed by prepanal.py below)
  │
  ├──────────────────────────────────────────────────┐
  ▼                                                  ▼
diagnostics/scripts/vis_taudem.py / .sh  diagnostics/scripts/diagnostics.py / .sh
  In:  usa_monthly_flow.nc4 (test)        In:  {region}_monthly.nc4
       composite_01deg_ad8.tif                 {region}_monthly_flow.nc4
  Out: output/taudem_flow/                     lsm.area-subset...nc
         usa_rainfall_flow_map.png        Out: output/{check}/{vintage}/
         flow_panel_{basin}.png                 summary csv + figures
                          │                            │
                          └──────────────┬─────────────┘
                                         ▼
                          diagnostics/scripts/report.Rmd
                            Out: output/report/report.html
```

Optional downstream steps:

```
coarse/prepanal.py / prepanal.sh
  In:  {region}_monthly_ttp.nc4, {region}_monthly.nc4,
       {region}_monthly_flow.nc4, grdd-meta.csv, grdd-data.csv
  Out: streamflow_model_monthly_combined.csv

diagnostics/scripts/run_aread8.sh
  In:  compositep_01deg.tif
  Out: composite_01deg_ad8.tif   (upstream cell count, used by vis_taudem.py)
```

---

## Pipeline steps

### Step 1 — Build the DEM and flow-direction grid

**`coarse/getdem_01deg.py`**
Downloads ERA5-Land geopotential from the Copernicus CDS API (`reanalysis-era5-land`), converts to elevation in meters (dividing by g = 9.80665), shifts longitude from [0, 360] to [-180, 180], and writes `composite_01deg.tif`.

**`diagnostics/scripts/run_taudem.sh`** (SLURM, 4 MPI tasks)
Runs TauDEM on `composite_01deg.tif`:
- `pitremove` — fills sinks in the DEM → `composite_01deg_fel.tif`
- `d8flowdir` — computes D8 flow direction → `compositep_01deg.tif`

`compositep_01deg.tif` encodes the downstream neighbor for every grid cell using TauDEM's 1–8 directional codes. This is the flow-routing grid used in Step 3.

---

### Step 2 — Transform daily ERA5-Land to monthly

Processed outputs go to `/project/cil/gcp/climate/ERA5-LAND/processed/monthly/`.

Regions: `asia_east`, `australia`, `brazil`, `europe`, `india`, `latam`, `mexico_south`, `usa`.

**`coarse/transform.py`** → `{region}_monthly.nc4`, `globe_monthly.nc4`

Reads daily SWE, temperature, and total precipitation; constructs:
- `rainfall` = total precip − snow accumulation (precip not stored as snow)
- `era5melt` = daily SWE decrease (negative snow change only)
- `tempmelt` = temperature-weighted melt proxy (tmean × SWE > 0 × tmean > 0)

All three are aggregated to monthly totals and merged into per-region files. A global merge (`globe_monthly.nc4`) is also produced.

**`coarse/transform2.py`** → `{region}_monthly_ttp.nc4` *(gauge validation only)*

Produces simpler monthly aggregates without snow decomposition:
- `tp` = total monthly precipitation
- `tmean` = monthly mean temperature

Only needed as input to `prepanal.py`. Not required for flow visualization.

---

### Step 3 — Accumulate flow through the river network

**`coarse/prepflow.py`** → `{region}_monthly_flow.nc4`

Uses `compositep_01deg.tif` (D8 flow directions) to build a topological sort of the grid, then accumulates each monthly variable upstream-to-downstream using Kahn's algorithm. For each sub-region:

1. Maps sub-region grid cells to the global DEM coordinate system
2. Builds a local downstream index from the global flow graph
3. Runs `accumulate_rain_timefirst` over all time steps

Output variables: `rainfall_flow`, `era5melt_flow`, `tempmelt_flow` — each is the upstream-accumulated sum at every cell for every month.

---

### Step 4 — Visualize

**`diagnostics/scripts/vis_taudem.py`** (via `vis_taudem.sh`)

Reads the test-vintage `usa_monthly_flow.nc4`, computes mean and peak accumulated rainfall across all months, and writes to `output/taudem_flow/`:
- `usa_rainfall_flow_map.png` — full USA at 0.1°, log-scaled mean flow
- `flow_panel_{basin}.png` — one per basin window, showing mean flow, peak flow and TauDEM's own `aread8` upstream cell count side by side with gauge cities marked

Requires `composite_01deg_ad8.tif` from `run_aread8.sh`; it exits with a message if that file is absent. `run_aread8.sh` deliberately does **not** re-run `pitremove`/`d8flowdir` — it is read-only and must not rewrite the flow-direction grid that all existing pipeline outputs were built from.

---

### Step 5 (optional) — Validate against gauge observations

**`coarse/prepanal.py`** → `streamflow_model_monthly_combined.csv`

Reads GRDC station metadata (`grdd-meta.csv`) and monthly discharge observations (`grdd-data.csv`). For each station, it:
1. Identifies the containing region by bounding-box lookup
2. Extracts the nearest-grid-cell time series from the three monthly datasets (`*_monthly_ttp.nc4`, `*_monthly.nc4`, `*_monthly_flow.nc4`)
3. Writes results incrementally to CSV (skipping stations already processed)

Output columns: `station_id`, `country`, `lat`, `lon`, `year`, `month`, `discharge`, plus model variables `tp`, `tmean`, `rainfall`, `era5melt`, `tempmelt`, `rainfall_flow`, `era5melt_flow`, `tempmelt_flow`.

---

## Diagnostics

**`diagnostics/scripts/diagnostics.py`** (via `diagnostics.sh`)

The processed monthly files exist in two **vintages**: the original (`processed/monthly/`), which 0-fills cells with no ERA5-Land value, and the test vintage (`processed/monthly/test/`), which keeps them as `NaN`. `diagnostics.py` runs the identical code over both so any difference in the output is a difference in the data, not in the diagnostic. The vintage is selected by `SLURM_ARRAY_TASK_ID` (same convention as `coarse/transform.py`); with no task id set it runs both in series.

Three checks, each reporting prevalence and maps only — none of them tries to explain *why*:

1. **Ocean masking** — classifies every cell as all-NaN, always-zero, or has-data. `rainfall == 0` is `False` for `NaN`, so these are counted against an explicit valid-value count; without that, NaN ocean would silently land in "has data". This is the check that confirms the 0-fill fix.
2. **Negative rainfall** — frequency map and seasonality. Rainfall is the residual `tp_total - snowchange`, so it goes negative where snowpack growth outpaces precipitation; negatives are expected in snow-affected cells.
3. **Zero `rainfall_flow`** — prevalence, status map (never / episodic / always zero) and seasonality. 0-filled ocean cells sit on the D8 network and propagate zeros through the accumulation, so this check is sensitive to the vintage.

Output layout, one subfolder per check per vintage:

```
diagnostics/output/
├── missing_weather/{original,test}/     summary csv + cell_status, lsm_categories
├── negative_rainfall/{original,test}/   summary csv + frequency map, seasonal chart
├── zero_flow/{original,test}/           summary csv, by-month csv + 2 maps, seasonal
├── taudem_flow/                         from vis_taudem.py
└── report/                              rendered report.html
```

Figures are written as both `.pdf` and `.png`; `report.Rmd` embeds the `.png`s.

**`diagnostics/scripts/report.Rmd`**

Reads the summary CSVs and figures for both vintages and renders them side by side, computing the ocean-masking verdict from the CSVs at render time — no number in the report is hardcoded. It also flags regions whose two vintages cover a different number of months, since raw counts are not comparable across vintages in that case.

Requires `rmarkdown`, `knitr`, `kableExtra`, `dplyr`, `readr` and `pandoc`.

---

## Running on the cluster

All compute-heavy steps have SLURM wrappers. Submit with `sbatch`:

```bash
# Step 0: working directory
cd /project/cil/home_dirs/sarahmad/repos/rainfall-mortality-2026/hydro

# Step 1: DEM download (run directly, no SLURM wrapper)
python coarse/getdem_01deg.py

# Step 1: flow direction (TauDEM, 4 MPI tasks)
sbatch diagnostics/scripts/run_taudem.sh

# Step 2: monthly transforms
sbatch coarse/transform.sh     # rainfall/melt (required for flow)
sbatch coarse/transform2.sh    # tp/tmean (only for gauge validation)

# Step 3: flow accumulation
sbatch coarse/prepflow.sh

# Step 4: contributing area, then the flow visualization that needs it
sbatch diagnostics/scripts/run_aread8.sh
sbatch diagnostics/scripts/vis_taudem.sh

# Optional: gauge validation
sbatch coarse/prepanal.sh
```

### Diagnostics and report

Run from the repo root. Steps 1 and 2 are independent and can run concurrently; neither regenerates the `*_monthly.nc4` or `*_monthly_flow.nc4` inputs.

```bash
# 1. both vintages (array: task 0 = original, task 1 = test)
sbatch hydro/diagnostics/scripts/diagnostics.sh

# 2. accumulated flow figures
sbatch hydro/diagnostics/scripts/vis_taudem.sh

# 3. the report, after 1 and 2 have finished
Rscript -e 'rmarkdown::render("hydro/diagnostics/scripts/report.Rmd", \
  output_dir = "hydro/diagnostics/output/report")'
```

---

## Data paths

| Data | Path |
|---|---|
| ERA5-Land raw daily | `/project/cil/gcp/climate/ERA5-LAND/raw/daily/{region}/` |
| ERA5-Land processed monthly | `/project/cil/gcp/climate/ERA5-LAND/processed/monthly/` |
| DEM / flow direction | `/project/cil/gcp/climate/taudem_conus/geo_working/` |
| ERA5-Land LSM | `/project/cil/gcp/climate/taudem_conus/geo_working/lsm.area-subset.90.180.-90.-180.nc` |
| HydroSHEDS flow accumulation | `/project/cil/gcp/climate/taudem_conus/geo_working/hyd_na_acc_30s.tif` |
