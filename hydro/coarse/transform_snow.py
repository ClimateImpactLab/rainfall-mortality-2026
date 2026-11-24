# Copy of transform.py that builds snow and melt variables from daily tp_total,
# tmin and tmax instead of SWE. 
# Changes from transform.py are marked "Snow:".
#
# Input:  raw/daily/global/{tp_total,tmin,tmax}/ 
# Output: processed/monthly/test/snow/global_monthly_snow_band{0..7}.nc4 

import functools
import os
import dask
import numpy as np
import xarray as xr

region = 'global'

nthreads = int(os.environ.get("SLURM_CPUS_PER_TASK", 1))
dask.config.set(scheduler="threads", num_workers=nthreads)

CHUNKS = {"latitude": 200, "longitude": 200}

# The global run is too long for one 36-hour job, so each array task
# processes one latitude strip. 200 rows matches the 200 x 200 chunks 
# of the global files and the grid has 1472 rows (90 to -57.1).
LAT_ROWS = 1472
BAND_ROWS = 200
bands = list(range(int(np.ceil(LAT_ROWS / BAND_ROWS))))

task = os.environ.get("SLURM_ARRAY_TASK_ID")
bands_todo = bands if task is None else [bands[int(task)]]

outdir = "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/processed/monthly"

testdir = os.path.join(outdir, "test")
os.makedirs(testdir, exist_ok=True)

def normalize_raw(ds, band):
    ds = ds.drop_vars(["depthBelowLandLayer", "surface"], errors="ignore")
    for name, var in ds.data_vars.items():
        assert set(var.dims) == {"valid_time", "latitude", "longitude"}, \
            f"{name} has unexpected dims {var.dims}"
    lat = ds.latitude.values
    assert len(lat) == LAT_ROWS and np.all(np.diff(lat) < 0), \
        "latitude is not the 1472-row north-to-south global grid"
    ds = ds.isel(latitude=slice(band * BAND_ROWS, (band + 1) * BAND_ROWS))
    ds = ds.assign_coords(
        latitude=np.round(ds.latitude.values, 1),
        longitude=np.round(ds.longitude.values, 1),
    )
    for c in ("latitude", "longitude"):
        v = ds[c].values
        assert len(np.unique(v)) == len(v), \
            f"{c} has duplicate values after snapping to 0.1 deg -- grid is not 0.1 deg"
    # Sort both axes (latitude order is mixed across the archive)
    return ds.sortby(["latitude", "longitude"])

# Snow: outputs go in their own snow subfolder
snowdir = os.path.join(testdir, "snow")
os.makedirs(snowdir, exist_ok=True)

for band in bands_todo:
    # Snow: file name in test/snow/
    out_name = f"{region}_monthly_snow_band{band}.nc4"
    if os.path.exists(os.path.join(snowdir, out_name)):
        continue
    print(f"{region} latitude strip {band}")

    preprocess = functools.partial(normalize_raw, band=band)

    indir = "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/" + region
    # Snow: tp_total, tmin and tmax 
    ds_tp = xr.open_mfdataset(
        os.path.join(indir, f"tp_total/era5land_{region}_tp_total_*.nc4"),
        combine="by_coords",
        preprocess=preprocess,
        parallel=False,
        chunks=CHUNKS
    )
    ds_tmin = xr.open_mfdataset(
        os.path.join(indir, f"tmin/era5land_{region}_tmin_*.nc4"),
        combine="by_coords",
        preprocess=preprocess,
        parallel=False,
        chunks=CHUNKS
    )
    ds_tmax = xr.open_mfdataset(
        os.path.join(indir, f"tmax/era5land_{region}_tmax_*.nc4"),
        combine="by_coords",
        preprocess=preprocess,
        parallel=False,
        chunks=CHUNKS
    )

    # ERA5-LAND ocean cells are NaN
    land_mask = ds_tp["tp_total"].isel(valid_time=0).notnull()

    # Snow: construct snow and melt variables
    tp = ds_tp["tp_total"].astype("float64")
    tmin = ds_tmin["tmin"].astype("float64")
    tmax = ds_tmax["tmax"].astype("float64")

    # Each day follows T = M + A sin(phi) between tmin and tmax 
    M = (tmax + tmin) / 2
    A = (tmax - tmin) / 2

    # Share of the day below 0 C
    f_cross = np.arccos((M / A).clip(-1, 1)) / np.pi
    f_below = xr.where(tmin >= 0, 0.0, xr.where(tmax <= 0, 1.0, f_cross))

    # Degree-days above 0 C
    dd_cross = M * (1 - f_cross) + np.sqrt((-tmin * tmax).clip(min=0)) / np.pi
    dd = xr.where(tmin >= 0, M, xr.where(tmax <= 0, 0.0, dd_cross)).clip(min=0)

    # Days with tmin or tmax missing 
    valid = tmin.notnull() & tmax.notnull()
    f_below = f_below.where(valid)
    dd = dd.where(valid)

    solidtp = tp * f_below
    liquidtp = tp - solidtp
    tempmelt_dd = dd
    tempmelt_tpdd = tp * dd

    products = [
        ("solidtp", solidtp, "mm",
         "Monthly sum of daily tp_total x share of the day below 0 C "
         "(sine curve between tmin and tmax)"),
        ("liquidtp", liquidtp, "mm",
         "Monthly sum of daily tp_total - solidtp"),
        ("tempmelt_dd", tempmelt_dd, "degC day",
         "Monthly sum of daily degree-days above 0 C "
         "(single sine between tmin and tmax)"),
        ("tempmelt_tpdd", tempmelt_tpdd, "mm degC day",
         "Monthly sum of daily tp_total x daily degree-days above 0 C"),
    ]
    monthly = []
    for name, daily, units, long_name in products:
        ms = daily.resample(valid_time="1MS").sum().where(land_mask)
        ms = ms.transpose("valid_time", "latitude", "longitude").astype("float32")
        ms.name = name
        ms.attrs = {"units": units, "long_name": long_name}
        monthly.append(ms)

    ds_out = xr.merge(monthly)
    tmp_path = os.path.join(snowdir, f"{out_name}.partial")
    ds_out.to_netcdf(tmp_path)

    # Snow: check that months and grid match transform.py's strip
    with xr.open_dataset(tmp_path, engine="netcdf4", chunks=CHUNKS) as check:
        rain_path = os.path.join(testdir, f"{region}_monthly_band{band}.nc4")
        if os.path.exists(rain_path):
            with xr.open_dataset(rain_path) as rain:
                for c in ("valid_time", "latitude", "longitude"):
                    assert np.array_equal(check[c].values, rain[c].values), \
                        f"{c} differs from {rain_path}"
        else:
            print(f"  note: {rain_path} not found, grid not compared")

    os.replace(tmp_path, os.path.join(snowdir, out_name))
    print(f"  wrote {out_name}")

print("Done.")
