import os
from collections import defaultdict, deque
import xarray as xr
import rioxarray
import numpy as np

regions = ['asia_east', 'australia', 'brazil', 'europe', 'india', 'latam', 'mexico_south', 'usa']

outdir = "/project/cil/gcp/climate/ERA5-LAND/processed/monthly"

# Load rainfall from NetCDF
ds = xr.open_dataset("era5-land-example.nc4", chunks={'time': 1})  # or larger chunks as desired
rain = ds['ro']  # shape (time, y, x) or (y, x) if single snapshot

# Load TauDEM D8 directions
d8 = rioxarray.open_rasterio("compositep.tif")    # shape (1, y, x)
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
    for v in downstream[u:u+1]:  # actually, we’ll use downstream array later
        # we don’t need v here; we just consume upstream via in_degree
        pass
    for v in upstream_neighbors[u]:
        in_degree[v] -= 1
        if in_degree[v] == 0:
            queue.append(v)
            
# topo_order now lists cells from "most upstream" to "most downstream"
topo_order = np.array(topo_order, dtype=np.int64)

def accumulate_rain_single(rain_2d, downstream, topo_order):
    """
    rain_2d: 2D np.array (ny, nx)
    downstream: flattened int array of length ny*nx (-1 for sinks)
    topo_order: list of flattened indices, upstream→downstream
    """
    ny, nx = rain_2d.shape
    n = ny * nx
    rain_flat = rain_2d.ravel().astype(np.float64)
    acc = np.zeros_like(rain_flat)
    
    # Process cells upstream→downstream
    for i in topo_order:
        # Start with local rain
        acc[i] += rain_flat[i]
        j = downstream[i]
        if j >= 0:
            acc[j] += acc[i]
            
    return acc.reshape(ny, nx)

rain_snapshot = rain.isel(valid_time=0)  # or drop time if no time dim
cum = accumulate_rain_single(rain_snapshot.values, downstream, topo_order)

cum_da = xr.DataArray(
    cum,
    dims=rain_snapshot.dims,
    coords=rain_snapshot.coords,
    name="cumulative_rainfall",
)

def accumulate_rain_single(rain_2d, downstream, topo_order):
    ny, nx = rain_2d.shape
    n = ny * nx
    rain_flat = rain_2d.ravel().astype(np.float64)
    acc = np.zeros_like(rain_flat)
    
    for i in topo_order:
        acc[i] += rain_flat[i]
        j = downstream[i]
        if j >= 0:
            acc[j] += acc[i]
            
    return acc.reshape(ny, nx)

def accumulate_rain_timefirst(rain_3d, downstream, topo_order):
    t, ny, nx = rain_3d.shape
    out = np.empty_like(rain_3d, dtype=np.float64)
    for k in range(t):
        out[k] = accumulate_rain_single(rain_3d[k], downstream, topo_order)
    return out

# Process each region

for region in regions:
    sub = xr.open_dataset(f"/project/cil/gcp/climate/ERA5-LAND/processed/monthly/{region}_monthly.nc4")
    rain_sub = sub["rainfall"]  # (time, y, x)

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

    newvars = []
    for var in ["rainfall", "era5melt", "tempmelt"]:
        rain_sub = sub[var]  # (time, y, x)

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
    ds_out.to_netcdf(os.path.join(outdir, f"{region}_monthly_flow.nc4"))
    
