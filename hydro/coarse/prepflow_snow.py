# Copy of prepflow.py that routes the transform_snow.py variables (solidtp,
# liquidtp, tempmelt_dd, tempmelt_tpdd). 
# Changes from prepflow.py are marked "Snow:"
#
# Input:  test/snow/global_monthly_snow_band{0..7}.nc4 from transform_snow.py
# Output: test/snow/global_monthly_snowflow_{YYYY}.nc4

import glob
import os
from collections import defaultdict, deque
import xarray as xr
import rioxarray
import numpy as np

regions = ['global']

outdir = "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/processed/monthly"
testdir = os.path.join(outdir, "test")
os.makedirs(testdir, exist_ok=True)

# Snow: inputs and outputs are in test/snow/
snowdir = os.path.join(testdir, "snow")

# Load rainfall from NetCDF
here = os.path.dirname(os.path.abspath(__file__))
ds = xr.open_dataset(os.path.join(here, "era5-land-example.nc4"), chunks={'time': 1})
rain = ds['ro'] 

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
idx = np.arange(ny * nx).reshape(ny, nx)

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
    # Ocean NaNs would spread downstream, so treat as 0 and restore after
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

    # Snow: the bands from transform_snow.py are in test/snow/
    band_files = sorted(glob.glob(os.path.join(snowdir, f"{region}_monthly_snow_band*.nc4")))
    assert len(band_files) == 8, f"expected 8 latitude strips from transform_snow.py, found {len(band_files)}"
    sub = xr.open_mfdataset(band_files, combine="by_coords", chunks={"valid_time": 12},
                            drop_variables=["n_missing_input_days"])
    assert sub.sizes["latitude"] == 1472, "latitude strips do not cover the 1472-row global grid"
    # Snow: no rainfall in the snow strips; used here only for coordinates
    rain_sub = sub["solidtp"]  # (time, y, x)

    full_lat = d8["y"].values
    full_lon = d8["x"].values
    sub_lat = rain_sub["latitude"].values
    sub_lon = rain_sub["longitude"].values

    # Build maps
    y_index_map = {np.round(val, 1): i for i, val in enumerate(full_lat)}
    x_index_map = {np.round(val, 1): j for j, val in enumerate(full_lon)}

    sub_to_full_lat = np.array([y_index_map[val] for val in np.round(sub_lat, 1)], dtype=np.int64)
    sub_to_full_lon = np.array([x_index_map[val] for val in np.round(sub_lon, 1)], dtype=np.int64)

    ny_sub, nx_sub = len(sub_lat), len(sub_lon)

    full_flat_for_sub = full_idx[np.ix_(sub_to_full_lat, sub_to_full_lon)]  # (ny_sub, nx_sub)
    full_flat_for_sub_flat = full_flat_for_sub.ravel()

    inside_mask = np.zeros(ny * nx, dtype=bool)
    inside_mask[full_flat_for_sub_flat] = True

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

    # Too large to route in memory at once, so route and write one year at a time
    # Snow: 4 variables here instead of 3
    years = np.unique(sub["valid_time"].dt.year.values)

    for year in years:
        # Snow: file path to test/snow/
        out_path = os.path.join(snowdir, f"{region}_monthly_snowflow_{year}.nc4")

        # Skip finished years so a timed-out job can be resubmitted
        if os.path.exists(out_path):
            continue
        
        sub_year = sub.isel(valid_time=(sub["valid_time"].dt.year == year).values).load()

        newvars = []
        # Snow: the transform_snow.py variables
        for var in ["solidtp", "liquidtp", "tempmelt_dd", "tempmelt_tpdd"]:
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

        # Write to a temp file first so a killed job doesn't leave a partial year
        tmp_path = out_path + ".partial"
        ds_out.to_netcdf(tmp_path)
        os.replace(tmp_path, out_path)
        print(f"  Written: {out_path}")
