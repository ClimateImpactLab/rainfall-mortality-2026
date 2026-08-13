import os
import numpy as np
import xarray as xr

regions = ['asia_east', 'australia', 'brazil', 'europe', 'india', 'latam', 'mexico_south', 'usa']

outdir = "/project/cil/gcp/climate/ERA5-LAND/processed/monthly"

for region in regions:
    if os.path.exists(os.path.join(outdir, f"{region}_monthly.nc4")):
        continue
    print(region)
    
    indir = "/project/cil/gcp/climate/ERA5-LAND/raw/daily/" + region
    ds_swe = xr.open_mfdataset(
        os.path.join(indir, f"swe_mean/era5land_{region}_swe_mean_*.nc4"),
        combine="by_coords",        # typical for ERA5-like files
        parallel=True,             # use dask for parallel IO/compute
        chunks={"valid_time": 31}
    )
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

    # Construct rainfall and melt variables

    snowchange = ds_swe.swe_mean.diff(dim="valid_time") # mm

    zero_slice = ds_swe.swe_mean.isel(valid_time=0) * 0
    
    snowchange_full = xr.concat([zero_slice, snowchange], dim="valid_time")
    snowchange_full = snowchange_full.assign_coords(valid_time=ds_swe.valid_time)
    
    rainfall = ds_tp["tp_total"] - snowchange_full
    melt = -snowchange_full * (snowchange_full < 0)

    rainfall_ms = rainfall.resample(valid_time="1MS").sum()
    rainfall_ms.name = "rainfall"
    era5melt_ms = melt.resample(valid_time="1MS").sum()
    era5melt_ms.name = "era5melt"
    tempmelt = (ds_swe.swe_mean > 0) * ds_tmean.tmean * (ds_tmean.tmean > 0)
    tempmelt_ms = tempmelt.resample(valid_time="1MS").sum()
    tempmelt_ms.name = "tempmelt"

    ds_out = xr.merge([rainfall_ms, era5melt_ms, tempmelt_ms])
    ds_out.to_netcdf(os.path.join(outdir, f"{region}_monthly.nc4"))

allds = [xr.open_dataset(os.path.join(outdir, f"{region}_monthly.nc4")) for region in regions]

all_lats = np.unique(xr.concat([ds.latitude for ds in allds], dim="tmp_lat", coords='minimal'))
all_lons = np.unique(xr.concat([ds.longitude for ds in allds], dim="tmp_lon", coords='minimal'))

all_lats = all_lats[np.logical_not(np.isnan(all_lats))]
all_lons = all_lons[np.logical_not(np.isnan(all_lons))]

allds_full = [ds.reindex(latitude=all_lats, longitude=all_lons) for ds in allds]
ds_all = xr.merge(allds_full, coords='minimal')

ds_all.to_netcdf(os.path.join(outdir, f"globe_monthly.nc4"))

