import functools
import os
import dask
import numpy as np
import xarray as xr

# One global domain from ERA5-LAND-GLOBAL, so flow routing is not cut at
# regional box edges. The earlier regional boxes were:
# regions = ['asia_east', 'australia', 'brazil', 'europe', 'india', 'latam', 'mexico_south', 'usa']
region = 'global'

nthreads = int(os.environ.get("SLURM_CPUS_PER_TASK", 1))
dask.config.set(scheduler="threads", num_workers=nthreads)

CHUNKS = {"latitude": 200, "longitude": 200}

# The global run is too long for one 36-hour job, so each array task
# processes one latitude strip. Every quantity below is computed per grid
# cell along time (SWE change, rainfall, melt, monthly sums, land mask), so
# strips give the same values as one global run. 200 rows matches the
# 200 x 200 chunks of the global files; the grid has 1472 rows (90 to -57.1).
LAT_ROWS = 1472
BAND_ROWS = 200
bands = list(range(int(np.ceil(LAT_ROWS / BAND_ROWS))))

task = os.environ.get("SLURM_ARRAY_TASK_ID")
# Previously one array task per region:
# regions_todo = regions if task is None else [regions[int(task)]]
bands_todo = bands if task is None else [bands[int(task)]]

# Regional outputs stay in /project/cil/gcp/climate/ERA5-LAND/processed/monthly
outdir = "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/processed/monthly"

testdir = os.path.join(outdir, "test")
os.makedirs(testdir, exist_ok=True)

def normalize_raw(ds, band):
    ds = ds.drop_vars(["depthBelowLandLayer", "surface"], errors="ignore")
    for name, var in ds.data_vars.items():
        assert set(var.dims) == {"valid_time", "latitude", "longitude"}, \
            f"{name} has unexpected dims {var.dims}"
    # Keep this task's latitude strip. Rows are counted in the files' own
    # north-to-south order, so check that order in every file first.
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
    # Sort both axes: latitude order is mixed across the archive, and longitude
    # is sorted defensively since the audit only endpoint-tested it per file.
    return ds.sortby(["latitude", "longitude"])

for band in bands_todo:
    # Previously one file per region: f"{region}_monthly.nc4"
    out_name = f"{region}_monthly_band{band}.nc4"
    if os.path.exists(os.path.join(testdir, out_name)):
        continue
    print(f"{region} latitude strip {band}")

    preprocess = functools.partial(normalize_raw, band=band)

    # Global files are one variable-month per file, e.g.
    # global/tp_total/era5land_global_tp_total_2000_01.nc4, so the globs below
    # read all months 1950-2025 in one run (SWE change stays continuous).
    # Regional input was /project/cil/gcp/climate/ERA5-LAND/raw/daily/<region>
    indir = "/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/" + region
    ds_swe = xr.open_mfdataset(
        os.path.join(indir, f"swe_mean/era5land_{region}_swe_mean_*.nc4"),
        combine="by_coords",
        preprocess=preprocess,
        parallel=False,
        chunks=CHUNKS
    )
    ds_tmean = xr.open_mfdataset(
        os.path.join(indir, f"tmean/era5land_{region}_tmean_*.nc4"),
        combine="by_coords",
        preprocess=preprocess,
        parallel=False,
        chunks=CHUNKS
    )
    ds_tp = xr.open_mfdataset(
        os.path.join(indir, f"tp_total/era5land_{region}_tp_total_*.nc4"),
        combine="by_coords",
        preprocess=preprocess,
        parallel=False,
        chunks=CHUNKS
    )

    # Construct rainfall and melt variables

    snowchange = ds_swe.swe_mean.diff(dim="valid_time") # mm

    zero_slice = ds_swe.swe_mean.isel(valid_time=0) * 0

    snowchange_full = xr.concat([zero_slice, snowchange], dim="valid_time")
    snowchange_full = snowchange_full.assign_coords(valid_time=ds_swe.valid_time)

    rainfall = ds_tp["tp_total"] - snowchange_full
    melt = -snowchange_full * (snowchange_full < 0)

    # ERA5-LAND ocean cells are consistently NaN; derive mask from first time step
    # so that .sum() (which returns 0 for all-NaN groups) is corrected back to NaN
    land_mask = ds_tp["tp_total"].isel(valid_time=0).notnull()

    rainfall_ms = rainfall.resample(valid_time="1MS").sum().where(land_mask)
    rainfall_ms.name = "rainfall"
    era5melt_ms = melt.resample(valid_time="1MS").sum().where(land_mask)
    era5melt_ms.name = "era5melt"
    tempmelt = (ds_swe.swe_mean > 0) * ds_tmean.tmean * (ds_tmean.tmean > 0)
    tempmelt_ms = tempmelt.resample(valid_time="1MS").sum().where(land_mask)
    tempmelt_ms.name = "tempmelt"

    ds_out = xr.merge([rainfall_ms, era5melt_ms, tempmelt_ms])
    tmp_path = os.path.join(testdir, f"{out_name}.partial")
    ds_out.to_netcdf(tmp_path)
    os.replace(tmp_path, os.path.join(testdir, out_name))
    print(f"  wrote {out_name}")

print("Done.")
