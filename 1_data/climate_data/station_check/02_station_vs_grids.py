# ============================================================================
# 02_station_vs_grids.py
#
# Rain gauges vs ERA5-Land and CHIRPS daily precip, 1981-2010. Every GHCND gauge
# in the panel countries, compared with the ERA5-Land cell and the CHIRPS cell it
# sits in, on the same days 
# (the days the gauge has a value that passed GHCND's quality checks):
#   - yearly total: mean daily precip x 365
#   - typical wettest day: mean of the yearly max day, over the years the
#     gauge has data
#
# Needs the 30 yearly cell files from 01_cells_by_year.py. Run from this
# folder (run_station_check.sbatch):
#   python 02_station_vs_grids.py
#
# Output:
#   /project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check/
#     station_vs_grids_1981_2010.csv (one row per gauge)
# ============================================================================

import importlib
import os
from datetime import date
from multiprocessing import Pool

import numpy as np
import pandas as pd


# -----------------------------
# Paths and options
# -----------------------------

# Station list, cell lookup, grid paths, baseline years and the cell
# folder from 01 (its name starts with a digit, so it's imported by name)
cells = importlib.import_module("01_cells_by_year")
GHCND, ERA5L, CHIRPS, CELL_DIR = cells.GHCND, cells.ERA5L, cells.CHIRPS, cells.CELL_DIR
FIRST, LAST, START, N_DAYS, YEAR_OF_DAY = cells.FIRST, cells.LAST, cells.START, cells.N_DAYS, cells.YEAR_OF_DAY

# Where the comparison is saved
OUT_DIR = "/project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check"


# -----------------------------
# Gauges
# -----------------------------

# One station's daily precip 1981-2010 in mm (tenths of mm in the file), only
# values without a quality flag: day number and value.
# Each line of the file is one month, with 31 day slots (value, then 3 flags).
# Canada: the station list has NOAA's new IDs (CAN0 + Environment Canada
# climate ID), the lab copy of the data (2019) the old ones (CA00 + the same climate ID) 
def station_days(sid):
    fid = "CA00" + sid[4:] if sid.startswith("CAN0") else sid
    path = os.path.join(GHCND, "ghcnd_all", fid + ".dly")
    if not os.path.exists(path):
        return None
    idx, val = [], []
    with open(path) as f:
        for line in f:
            # Keep precip lines (the files also have temperature, snow, ...)
            # for 1981-2010 only
            if line[17:21] != "PRCP":
                continue
            y, m = int(line[11:15]), int(line[15:17])
            if not FIRST <= y <= LAST:
                continue
            # Missing days are -9999, slots past the end of a month (30 Feb)
            # have no date
            for d in range(31):
                v = int(line[21 + 8 * d:26 + 8 * d])
                if v == -9999 or line[27 + 8 * d].strip():
                    continue
                try:
                    k = date(y, m, d + 1).toordinal() - START
                except ValueError:
                    continue
                idx.append(k)
                val.append(v / 10)
    # A station with no usable day in 1981-2010 drops
    if not idx:
        return None
    return sid, np.array(idx, dtype=np.int32), np.array(val, dtype=np.float32)


# -----------------------------
# Gauge vs cell on the gauge's days
# -----------------------------

# Yearly total (mean x 365) and typical wettest day (mean of the yearly max)
# for the gauge and one product, on the gauge's days. Product missing on any
# of those days (sea cell, outside CHIRPS) gives missing
def summarize(idx, gauge, cell):
    # Yearly totals: gauge always, cell only if it has a value on every
    # gauge day
    out = {"annual": 365 * gauge.mean(), "cell_annual": np.nan, "wettest": np.nan, "cell_wettest": np.nan}
    cvals = cell[idx]
    cell_ok = not np.isnan(cvals).any()
    if cell_ok:
        out["cell_annual"] = 365 * cvals.mean()
    # Typical wettest day: max day of each year the gauge has data, averaged
    # over those years
    years = YEAR_OF_DAY[idx]
    ys = np.unique(years)
    out["wettest"] = np.mean([gauge[years == y].max() for y in ys])
    if cell_ok:
        out["cell_wettest"] = np.mean([cvals[years == y].max() for y in ys])
    out["n_years"] = len(ys)
    return out


# -----------------------------
# Run
# -----------------------------

if __name__ == "__main__":
    # Cells of every listed station on both grids, same as in 01
    stations = cells.read_stations().reset_index(drop=True)
    c_lat, c_lon = cells.grid_coords(CHIRPS.format(y=1990))
    _, e_which = cells.station_cells(*cells.grid_coords(ERA5L.format(y=1990, m=1)), stations)
    _, c_which = cells.station_cells(c_lat, c_lon, stations)

    # The gauges with data, read on all cores
    with Pool(int(os.environ.get("SLURM_CPUS_PER_TASK", 4))) as pool:
        found = [r for r in pool.map(station_days, stations["id"], chunksize=200) if r is not None]
    print(len(found), "stations with precip data", flush=True)

    # Where each gauge with data sits in the station list, to find its cell
    pos = pd.Series(stations.index, index=stations["id"]).loc[[r[0] for r in found]].values
    keep = stations.loc[pos].reset_index(drop=True)

    # The 30 years of cells, all days. CHIRPS: stations beyond 50N/50S (more
    # than half a cell past the grid edge) get missing
    years = [np.load(os.path.join(CELL_DIR, f"cells_{y}.npz")) for y in range(FIRST, LAST + 1)]
    era5l = np.concatenate([f["era5l"] for f in years])
    chirps = np.concatenate([f["chirps"] for f in years])
    outside_chirps = (keep["lat"].values > c_lat.max() + 0.03) | (keep["lat"].values < c_lat.min() - 0.03)

    # One row per gauge: gauge, ERA5-Land and CHIRPS on the gauge's days
    rows = []
    for j, (sid, idx, val) in enumerate(found):
        c_cell = np.full(N_DAYS, np.nan) if outside_chirps[j] else chirps[:, c_which[pos[j]]]
        e, c = summarize(idx, val, era5l[:, e_which[pos[j]]]), summarize(idx, val, c_cell)
        rows.append({
            "id": sid, "n_days": len(idx), "n_years": e["n_years"],
            "station_annual_mm": e["annual"], "era5l_annual_mm": e["cell_annual"], "chirps_annual_mm": c["cell_annual"],
            "station_wettest_mm": e["wettest"], "era5l_wettest_mm": e["cell_wettest"], "chirps_wettest_mm": c["cell_wettest"],
        })

    # Station info next to the results, mm rounded to 0.1
    out = keep[["id", "iso", "state", "name", "lat", "lon", "elev"]].merge(pd.DataFrame(rows), on="id")
    mm = [c for c in out.columns if c.endswith("_mm")]
    out[mm] = out[mm].round(1)
    os.makedirs(OUT_DIR, exist_ok=True)
    out.to_csv(os.path.join(OUT_DIR, "station_vs_grids_1981_2010.csv"), index=False)
    print("wrote", len(out), "stations", flush=True)
