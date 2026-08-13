import os
import numpy as np
import xarray as xr

regions = ['asia_east', 'australia', 'brazil', 'europe', 'india', 'latam', 'mexico_south', 'usa']

outdir = "/project/cil/gcp/climate/ERA5-LAND/processed/monthly"

for region in regions:
    if os.path.exists(os.path.join(outdir, f"{region}_monthly_ttp.nc4")):
        continue
    print(region)
    
    indir = "/project/cil/gcp/climate/ERA5-LAND/raw/daily/" + region
    ds_tmean = xr.open_mfdataset(
        os.path.join(indir, f"tmean/era5land_{region}_tmean_*.nc4"),
        combine="by_coords",        # typical for ERA5-like files
        parallel=True,              # use dask for parallel IO/compute
        chunks={"valid_time": 31}
    )
    ds_tp = xr.open_mfdataset(
        os.path.join(indir, f"tp_total/era5land_{region}_tp_total_*.nc4"),
        combine="by_coords",        # typical for ERA5-like files
        parallel=True,              # use dask for parallel IO/compute
        chunks={"valid_time": 31}
    )

    tp_ms = ds_tp.tp_total.resample(valid_time="1MS").sum()
    tp_ms.name = "tp"
    tmean_ms = ds_tmean.tmean.resample(valid_time="1MS").mean()
    tmean_ms.name = "tmean"

    ds_out = xr.merge([tp_ms, tmean_ms])
    ds_out.to_netcdf(os.path.join(outdir, f"{region}_monthly_ttp.nc4"))
