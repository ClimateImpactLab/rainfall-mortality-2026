import cdsapi
import xarray as xr
import rioxarray

outdir = "/project/cil/gcp/climate/taudem_conus/geo_working"

# Download ERA5-Land orography at 0.1° (static field — any date works)
client = cdsapi.Client()
client.retrieve(
    "reanalysis-era5-land",
    {
        "variable": "geopotential",
        "year": "2000",
        "month": "01",
        "day": "01",
        "time": "00:00",
        "data_format": "netcdf",
        "download_format": "unarchived",
    },
    f"{outdir}/era5_land_orography_01deg.nc",
)

ds = xr.open_dataset(f"{outdir}/era5_land_orography_01deg.nc")

gravity = 9.80665
dem_meters = ds["z"] / gravity

# Shift longitude from [0, 360] to [-180, 180]
dem_meters = dem_meters.assign_coords(
    longitude=(((dem_meters.longitude + 180) % 360) - 180)
)
dem_meters = dem_meters.sortby("longitude")

# Drop time dimension (static field)
if "valid_time" in dem_meters.dims:
    dem_meters = dem_meters.isel(valid_time=0).drop_vars("valid_time")
elif "time" in dem_meters.dims:
    dem_meters = dem_meters.isel(time=0).drop_vars("time")

dem_meters = dem_meters.rio.write_crs("EPSG:4326")
dem_meters.rio.to_raster(f"{outdir}/composite_01deg.tif")
print(f"Written: {outdir}/composite_01deg.tif  shape={dem_meters.shape}")
