import xarray as xr
import rioxarray

ds = xr.open_dataset('/project/cil/gcp/climate/taudem_conus/geo_working/era5_land_orography.nc')

# Convert Geopotential (z) to Elevation in Meters
gravity = 9.80665
dem_meters = ds['z'] / gravity

# Shift longitude from [0, 360] to standard [-180, 180]
dem_meters = dem_meters.assign_coords(longitude=(((dem_meters.longitude + 180) % 360) - 180))
dem_meters = dem_meters.sortby('longitude')

# Squeeze out the time dimension if it exists to make it a 2D spatial grid
dem_meters = dem_meters.isel(time=0).drop_vars('time')

# Set the coordinate reference system (WGS84 / EPSG:4326)
dem_meters = dem_meters.rio.write_crs("EPSG:4326")

dem_meters.rio.to_raster("/project/cil/gcp/climate/taudem_conus/geo_working/composite.tif")
