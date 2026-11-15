# ============================================================================
# 01_cells_by_year.py
#
# Daily ERA5-Land and CHIRPS precip at the cells the rain gauges sit in, for
# one year. Gauges: every GHCND station in the panel countries. 
# Reading 30 years of global grids is the slow part, so it runs one Slurm task 
# per year 1981-2010 (run_cells_by_year.sbatch), for ex:
#   python 01_cells_by_year.py --year=1990
#
# 02_station_vs_grids.py imports the station list and the cell lookup from
# here, so both scripts use the same cells.
#
# Output:
#   /project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check/
#     cells/cells_1990.npz
# ============================================================================

import argparse
import os
from datetime import date

import numpy as np
import pandas as pd
import xarray as xr


# -----------------------------
# Paths and options
# -----------------------------

# GHCND station list and daily files, raw ERA5-Land daily (one file per
# month), raw CHIRPS daily (one file per year)
GHCND = "/project/cil/gcp/climate/GHCND"
ERA5L = "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global/tp_total/era5land_global_tp_total_{y}_{m:02d}.nc4"
CHIRPS = "/project/cil/gcp/climate/CHIRPS/Raw_NetCDF_p05deg_by_p05deg/PRCP/chirps-v2.0.{y}.days_p05.nc"

# Where the yearly cell files are saved
CELL_DIR = "/project/cil/gcp/estimation/rainfall-mortality/climate_data/station_check/cells"

# Baseline years, number of days, and the year of each day (day 0 = 1 Jan 1981)
FIRST, LAST = 1981, 2010
START = date(FIRST, 1, 1).toordinal()
N_DAYS = date(LAST, 12, 31).toordinal() - START + 1
YEAR_OF_DAY = np.array([date.fromordinal(START + i).year for i in range(N_DAYS)])

# GHCND country codes (first 2 letters of the station ID) of the panel countries
COUNTRIES = {
    "AR": "ARG", "AS": "AUS", "BR": "BRA", "BC": "BWA", "CA": "CAN", "CI": "CHL", "CH": "CHN", "CO": "COL",
    "CV": "CPV", "CS": "CRI", "EC": "ECU", "JA": "JPN", "KS": "KOR", "MX": "MEX", "PE": "PER", "RP": "PHL",
    "RW": "RWA", "TH": "THA", "US": "USA", "IN": "IND",
    "AU": "AUT", "BE": "BEL", "BU": "BGR", "SZ": "CHE", "CY": "CYP", "EZ": "CZE", "GM": "DEU", "DA": "DNK",
    "SP": "ESP", "EN": "EST", "FI": "FIN", "FR": "FRA", "UK": "GBR", "GR": "GRC", "HR": "HRV", "HU": "HUN",
    "EI": "IRL", "IC": "ISL", "IT": "ITA", "LS": "LIE", "LH": "LTU", "LU": "LUX", "LG": "LVA", "MK": "MKD",
    "MT": "MLT", "MJ": "MNE", "NL": "NLD", "NO": "NOR", "PL": "POL", "PO": "PRT", "RO": "ROU", "LO": "SVK",
    "SI": "SVN", "SW": "SWE", "TU": "TUR",
}


# -----------------------------
# Gauges
# -----------------------------

# Station list: ID, coordinates, elevation, US state, name. Panel countries
# only, and no Hawaii (islands, not the mainland US of the panel)
def read_stations():
    # Fixed-width file: each column sits at the same character positions on every line
    st = pd.read_fwf(os.path.join(GHCND, "ghcnd-stations.txt"), header=None,
                     colspecs=[(0, 11), (12, 20), (21, 30), (31, 37), (38, 40), (41, 71)],
                     names=["id", "lat", "lon", "elev", "state", "name"])
    # Country from the first 2 letters of the ID (US, CO, ...). Codes outside the panel get no iso and drop
    st["iso"] = st["id"].str[:2].map(COUNTRIES)
    return st[st["iso"].notna() & ~((st["iso"] == "USA") & (st["state"] == "HI"))]


# -----------------------------
# Grid cells
# -----------------------------

# Nearest grid line (latitude or longitude) to each station
def nearest(grid, values):
    # Sort the grid (ERA5-Land latitudes run north to south), find the grid
    # lines just below and above each station, keep the closer one
    grid = np.asarray(grid)
    order = np.argsort(grid)
    pos = np.clip(np.searchsorted(grid[order], values), 1, len(grid) - 1)
    left, right = order[pos - 1], order[pos]
    return np.where(np.abs(grid[left] - values) <= np.abs(grid[right] - values), left, right)


# Distinct cells the stations sit in on one grid, and which of them each
# station uses. 01 and 02 use the same station list, so the yearly files
# and the comparison line up
def station_cells(lat_grid, lon_grid, stations):
    ilat, ilon = nearest(lat_grid, stations["lat"].values), nearest(lon_grid, stations["lon"].values)
    # Several stations can share a cell: each cell is read once
    cells, which = np.unique(np.stack([ilat, ilon], 1), axis=0, return_inverse=True)
    return cells, which.ravel()


# One year's daily precip at the cells, days x cells. read_days(y) gives the
# year's daily grids a block of days at a time
def year_at_cells(read_days, y, cells):
    return np.concatenate([block[:, cells[:, 0], cells[:, 1]] for block in read_days(y)])


# ERA5-Land, month by month
def era5l_days(y):
    for m in range(1, 13):
        with xr.open_dataset(ERA5L.format(y=y, m=m)) as ds:
            yield ds["tp_total"].values


# CHIRPS, 20 days at a time (the file is stored in 20-day chunks)
def chirps_days(y):
    with xr.open_dataset(CHIRPS.format(y=y), mask_and_scale=True) as ds:
        for s in range(0, ds.sizes["time"], 20):
            yield ds["precip"].isel(time=slice(s, s + 20)).values


def grid_coords(path):
    with xr.open_dataset(path) as ds:
        return ds["latitude"].values, ds["longitude"].values


# -----------------------------
# Run
# -----------------------------

if __name__ == "__main__":
    # Read one option from the command line, for ex --year=1990 gives 1990
    parser = argparse.ArgumentParser()
    parser.add_argument("--year", type=int, required=True)
    year = parser.parse_args().year

    # Cells of every listed station (with or without data) on both grids.
    # Coordinates from one file of each product, the grid is the same every year
    stations = read_stations().reset_index(drop=True)
    e_cells, _ = station_cells(*grid_coords(ERA5L.format(y=1990, m=1)), stations)
    c_cells, _ = station_cells(*grid_coords(CHIRPS.format(y=1990)), stations)

    # One year of both grids at the cells
    os.makedirs(CELL_DIR, exist_ok=True)
    np.savez(os.path.join(CELL_DIR, f"cells_{year}.npz"),
             era5l=year_at_cells(era5l_days, year, e_cells), chirps=year_at_cells(chirps_days, year, c_cells))
    print("wrote cells for", year, flush=True)
