"""
prepflow_preview.py

TEMPORARY PREVIEW of prepflow.py, for a first look before all transform.py
latitude strips exist. Use prepflow.py (prepflow.sh) for the full global run.

The routing code is copied unchanged from prepflow.py. The differences are
marked "Preview:" below:
- reads only latitude strips 0-4 from transform.py (latitude 90.0 to -9.9)
- routes only the years in PREVIEW_YEARS
- pads the missing southern rows with NaN, so each output has the full
  ERA5-LAND-GLOBAL latitude grid expected by
  1_data/climate_data/climate_aggregation_global/hydro_era5land_admin/flow_common.py
- writes to test/preview_bands0-4/, never to the full-run folder

Limits of the preview:
- cells south of -9.9 are missing (NaN)
- rivers that flow north across -9.9 lose the flow from upstream of that line,
  because the southern edge is treated as an outlet (as the old regional
  boxes did)

Inputs:
- test/global_monthly_band{0..4}.nc4 from transform.py
- TauDEM D8 directions compositep_01deg.tif
- one raw ERA5-LAND-GLOBAL file, only for the full latitude grid

Outputs:
- test/preview_bands0-4/global_monthly_flow_{YYYY}.nc4

Run: sbatch hydro/coarse/prepflow_preview.sh
"""

import glob
import os
from collections import defaultdict, deque
import xarray as xr
import rioxarray
import numpy as np

# One global domain from ERA5-LAND-GLOBAL (see transform.py). Its grid is a
# row subset of the D8 grid below (same 0.1-degree cell centers), so the
# coordinate matching further down works unchanged. The earlier regional boxes were:
# regions = ['asia_east', 'australia', 'brazil', 'europe', 'india', 'latam', 'mexico_south', 'usa']
regions = ['global']

# Regional outputs stay in /project/cil/gcp/climate/ERA5-LAND/processed/monthly
outdir = "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/processed/monthly"
testdir = os.path.join(outdir, "test")
os.makedirs(testdir, exist_ok=True)

# Preview: finished strips only, all years 1950-2025 (was the 2000 pilot year
# only), and a separate output folder so preview files can never be mistaken
# for, or skip, the full run
PREVIEW_BANDS = [0, 1, 2, 3, 4]
# PREVIEW_YEARS = [2000]
PREVIEW_YEARS = list(range(1950, 2026))
previewdir = os.path.join(testdir, "preview_bands0-4")
os.makedirs(previewdir, exist_ok=True)

# Preview: any raw global file gives the full 1472-row latitude grid
RAW_GRID_FILE = (
    "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global/"
    "tp_total/era5land_global_tp_total_2000_01.nc4"
)

# Load rainfall from NetCDF
here = os.path.dirname(os.path.abspath(__file__))
ds = xr.open_dataset(os.path.join(here, "era5-land-example.nc4"), chunks={'time': 1})
rain = ds['ro']  # shape (time, y, x) or (y, x) if single snapshot

# Load TauDEM D8 directions
d8 = rioxarray.open_rasterio("/project/cil/gcp/climate/taudem_conus/geo_working/compositep_01deg.tif")    # shape (1, y, x)
d8 = d8.squeeze("band", drop=True)  # -> shape (y, x)

assert rain.shape[-2:] == d8.shape[-2:]

# Prepare TauDEM flow logic

d8_to_offset = {
    1:  (0, 1),
    2:  (-1, 1),
    3:  (-1, 0),
    4:  (-1, -1),
    5: (0, -1),
    6: (1, -1),
    7: (1, 0),
    8: (1, 1),
}

d8_data = d8.values  # (ny, nx)
ny, nx = d8_data.shape

# global flat index
full_idx = np.arange(ny * nx).reshape(ny, nx)

# Flatten indices for convenience
idx = np.arange(ny * nx).reshape(ny, nx)

# Initialize arrays for downstream index, -1 for sinks / NoData
downstream = np.full(ny * nx, -1, dtype=np.int64)

for code, (dy, dx) in d8_to_offset.items():
    mask = (d8_data == code)
    # destination row/col
    rr = np.where(mask)[0]
    cc = np.where(mask)[1]
    dr = rr + dy
    dc = cc + dx
    
    # Keep only valid destinations inside grid
    valid = (
        (dr >= 0) & (dr < ny) &
        (dc >= 0) & (dc < nx)
    )
    
    src_flat = idx[rr[valid], cc[valid]]
    dst_flat = idx[dr[valid], dc[valid]]
    downstream[src_flat] = dst_flat

# Mark TauDEM NoData as sinks (downstream = -1)
nodata = -32768  # or read from raster tags
nodata_mask = (d8_data == nodata) | np.isnan(d8_data)
downstream[idx[nodata_mask]] = -1

n = ny * nx

# Build list of upstream neighbors for each cell; also in-degrees
upstream_neighbors = [[] for _ in range(n)]
in_degree = np.zeros(n, dtype=np.int32)

for i in range(n):
    j = downstream[i]
    if j >= 0:
        upstream_neighbors[j].append(i)
        in_degree[j] += 1

# Kahn’s algorithm for topological sort: start with sources (in_degree == 0)
queue = deque([i for i in range(n) if in_degree[i] == 0])

topo_order = []
while queue:
    u = queue.popleft()
    topo_order.append(u)
    j = downstream[u]
    if j >= 0:
        in_degree[j] -= 1
        if in_degree[j] == 0:
            queue.append(j)

topo_order = np.array(topo_order, dtype=np.int64)


def accumulate_rain_single(rain_2d, downstream, topo_order):
    ny, nx = rain_2d.shape
    n = ny * nx
    rain_flat = rain_2d.ravel().astype(np.float64)
    # Ocean cells are NaN in the monthly files. Accumulating NaN propagates it to every 
    # cell downstream, so one ocean cell becomes a problem to the stream below it. 
    # Convert NaNs to 0s in loop and then reverts to missing 
    isnan = np.isnan(rain_flat)
    rain_flat = np.where(isnan, 0.0, rain_flat)
    acc = np.zeros_like(rain_flat)
    
    for i in topo_order:
        acc[i] += rain_flat[i]
        j = downstream[i]
        if j >= 0:
            acc[j] += acc[i]
    acc[isnan] = np.nan
    return acc.reshape(ny, nx)

def accumulate_rain_timefirst(rain_3d, downstream, topo_order):
    t, ny, nx = rain_3d.shape
    out = np.empty_like(rain_3d, dtype=np.float64)
    for k in range(t):
        out[k] = accumulate_rain_single(rain_3d[k], downstream, topo_order)
    return out

# Process each region

for region in regions:
    print(f"Processing {region}...")

    # transform.py writes the global domain as 8 latitude strips
    # (one per array task). Routing needs the whole grid, so open them together.
    # Previously one file per region:
    # sub = xr.open_dataset(os.path.join(testdir, f"{region}_monthly.nc4"))
    # Preview: open only the finished strips 0-4 instead of all 8
    band_files = [os.path.join(testdir, f"{region}_monthly_band{band}.nc4") for band in PREVIEW_BANDS]
    missing = [path for path in band_files if not os.path.exists(path)]
    assert not missing, f"missing preview strips: {missing}"
    # 12-month time chunks so each year below reads only its own months.
    # The strips are stored contiguously, so without this each strip variable
    # is one chunk of all months and every year would re-read the full files.
    sub = xr.open_mfdataset(band_files, combine="by_coords", chunks={"valid_time": 12})
    assert sub.sizes["latitude"] == 200 * len(PREVIEW_BANDS), "preview strips are not 200 rows each"
    rain_sub = sub["rainfall"]  # (time, y, x)

    # Preview: full latitude grid (south to north, like transform.py output)
    # for padding the missing southern rows with NaN before writing
    with xr.open_dataset(RAW_GRID_FILE) as grid_ds:
        global_lat = np.sort(grid_ds["latitude"].values.astype("float64"))
    assert len(global_lat) == 1472, "raw grid is not the 1472-row ERA5-LAND-GLOBAL grid"
    nearest_gap = np.abs(rain_sub["latitude"].values[:, None] - global_lat[None, :]).min(axis=1)
    assert (nearest_gap < 0.01).all(), "strip latitudes are not on the global grid"

    # Match sub coords to full coords
    full_lat = d8["y"].values
    full_lon = d8["x"].values
    sub_lat = rain_sub["latitude"].values
    sub_lon = rain_sub["longitude"].values

    # Build maps: for each sub y/x, find its index in full_lat/full_lon
    # This assumes exact equality (same grid definition).
    y_index_map = {np.round(val, 1): i for i, val in enumerate(full_lat)}
    x_index_map = {np.round(val, 1): j for j, val in enumerate(full_lon)}

    sub_to_full_lat = np.array([y_index_map[val] for val in np.round(sub_lat, 1)], dtype=np.int64)
    sub_to_full_lon = np.array([x_index_map[val] for val in np.round(sub_lon, 1)], dtype=np.int64)

    ny_sub, nx_sub = len(sub_lat), len(sub_lon)

    # full flat indices for each sub-cell
    full_flat_for_sub = full_idx[np.ix_(sub_to_full_lat, sub_to_full_lon)]  # (ny_sub, nx_sub)
    full_flat_for_sub_flat = full_flat_for_sub.ravel()

    # Mask: which global cells belong to this sub-region?
    inside_mask = np.zeros(ny * nx, dtype=bool)
    inside_mask[full_flat_for_sub_flat] = True

    # Local mapping: global flat index → local flat index (0..n_sub-1), or -1 if outside
    n_sub = ny_sub * nx_sub
    global_to_local = np.full(ny * nx, -1, dtype=np.int64)
    global_to_local[full_flat_for_sub_flat] = np.arange(n_sub, dtype=np.int64)

    # Build local downstream array
    downstream_local = np.full(n_sub, -1, dtype=np.int64)

    for local_idx, global_idx in enumerate(full_flat_for_sub_flat):
        global_down = downstream[global_idx]
        if global_down >= 0 and inside_mask[global_down]:
            downstream_local[local_idx] = global_to_local[global_down]
        else:
            # flow leaves the bounding box or is sink → treat as outlet
            downstream_local[local_idx] = -1

    # Filter global topo order to those within this subdomain
    inside_order_global = topo_order[inside_mask[topo_order]]

    # Map those global indices to local indices
    topo_order_local = global_to_local[inside_order_global]  # shape (n_sub,)

    # The global 1950-2025 record is too large to route in memory at once
    # (all months x 3 variables in float64), so route and write one year at
    # a time. Each month is accumulated on its own (accumulate_rain_timefirst),
    # so yearly files give the same values as a single run.
    years = np.unique(sub["valid_time"].dt.year.values)

    # Preview: route only the pilot years
    assert all(year in years for year in PREVIEW_YEARS), "a preview year is not in the strips"
    years = [year for year in years if year in PREVIEW_YEARS]

    for year in years:
        # Preview: write to the preview folder, never the full-run folder
        out_path = os.path.join(previewdir, f"{region}_monthly_flow_{year}.nc4")

        # Keep finished years so a timed-out job can be resubmitted
        # (same skip rule as transform.py)
        if os.path.exists(out_path):
            continue

        # Load the year into memory: the strips arrive as several dask chunks
        # along latitude, which apply_ufunc cannot take as a core dimension.
        sub_year = sub.isel(valid_time=(sub["valid_time"].dt.year == year).values).load()

        newvars = []
        for var in ["rainfall", "era5melt", "tempmelt"]:
            rain_sub = sub_year[var]  # (time, y, x)

            cum_rain_sub = xr.apply_ufunc(
                accumulate_rain_timefirst,
                rain_sub,
                input_core_dims=[['valid_time', 'latitude', 'longitude']],
                output_core_dims=[['valid_time', 'latitude', 'longitude']],
                vectorize=False,
                kwargs={
                    'downstream': downstream_local,
                    'topo_order': topo_order_local
                },
                dask='parallelized',
                output_dtypes=[np.float64],
            )

            cum_rain_sub.name = f"{var}_flow"
            newvars.append(cum_rain_sub)

        ds_out = xr.merge(newvars)

        # Preview: pad to the full latitude grid. Rows south of the strips
        # become NaN, which the admin aggregation treats as missing cells.
        ds_out = ds_out.reindex(latitude=global_lat, method="nearest", tolerance=0.01)

        # Write through a temporary file (as in transform.py) so a killed job
        # does not leave a partial year that the skip check above would keep
        tmp_path = out_path + ".partial"
        ds_out.to_netcdf(tmp_path)
        os.replace(tmp_path, out_path)
        print(f"  Written: {out_path}")
