
# ===========================================================================
# GMFD/ERA5-Land pixel-level comparison CONUS
# ==========================================================================
#
# For a given year and variable:
# 1. Restrict datasets to CONUS
# 2. Convert units
# 3. Regrid ERA5-Land to the GMFD grid
# 4\. Compute ERA5-Land - GMFD differences and save outputs
# 5. Compute and save comparison stats
#
#  vars are:
#   - tmin
#    - tmax
#    - prcp
#
# use script like: 
#   - Rscript scripts/01_process_pixel_year.R tmin 1968
#   - or run as SLURM array job across years
#
# =======================================================================



# ========================================================
# 0. Setup
# ======================================================


# -------------------- packages ------------------------

# required packages
library(sf)
library(terra)
library(tidyverse)


# -------------------- input args checks ------------------------

# basic checks on the input arguments passed to the script
args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 2) {
  stop("Usage: Rscript scripts/01_process_pixel_year.R <variable> <year>")
}

variable <- args[1]
year <- as.integer(args[2])

if (!variable %in% c("tmin", "tmax", "prcp")) {
  stop("Variable must be one of: tmin, tmax, prcp")
}

# ERA5-Land uses a different variable name for precip
gmfd_var <- variable

if (variable == "prcp") {
  era5_var <- "tp_total"
} else {
  era5_var <- variable
}


# -------------------- paths ------------------------

repo_root <- "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality/climate_data/gmfd_era5land"
us_shp_path <- "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/USA/Shapefile/Ag_TIGER_shapefiles/tl_2016_us_county.shp"

#  -------------------- input files --------------------

gmfd_path <- file.path(
  "/project/cil/battuta_shares/gcp/climate/GMFD/Raw_NetCDF_p25deg_x_p25deg",
  gmfd_var,
  paste0(gmfd_var, "_0p25_daily_", year, "-", year, ".nc")
)

era5_path <- file.path(
  "/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa",
  era5_var,
  paste0("era5land_usa_", era5_var, "_", year, ".nc4")
)

# -------------------- output dirs --------------------

out_root <- file.path(repo_root, "data", "pixel_level")

out_processed_dir <- file.path(out_root, "processed", variable)
out_check_dir <- file.path(out_root, "yearly_checks", variable)
out_boundary_dir <- file.path(out_root, "boundary")

dir.create(out_processed_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_check_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_boundary_dir, recursive = TRUE, showWarnings = FALSE)


# --------------------  output files -------------------- 

gmfd_out_path <- file.path(
  out_processed_dir,
  paste0("gmfd_conus_", variable, "_", year, ".nc")
)

era5_out_path <- file.path(
  out_processed_dir,
  paste0("era5_on_gmfd_conus_", variable, "_", year, ".nc")
)

diff_out_path <- file.path(
  out_processed_dir,
  paste0("diff_era5_minus_gmfd_conus_", variable, "_", year, ".nc")
)

check_out_path <- file.path(
  out_check_dir,
  paste0("yearly_check_", variable, "_", year, ".csv")
)


# =======================================================
# 1. Restrict datasets to CONUS
# =========================================================

# -------------------- Build CONUS mask --------------------

# Bbox used to exclude Alaska, Hawaii, and other territories.
conus_bbox_vals <- c(xmin = -125, xmax = -66, 
                     ymin = 24, ymax = 50)

# Read county shapefile and convert to wgs84
us <- st_read(us_shp_path, quiet = TRUE) %>%
  st_transform(4326) %>%
  st_make_valid()

# convert bbox to an sf geometry object
conus_bbox <- st_as_sfc(
  st_bbox(conus_bbox_vals, crs = st_crs(us))
)

# keep only counties intersecting CONUS bbox
conus <- us %>%
  filter(lengths(st_intersects(geometry, conus_bbox)) > 0)

# merge counties into a single polygon for raster masking
conus_outer <- conus %>%
  summarise(geometry = st_union(geometry)) %>%
  st_make_valid()

# convert to a terra vector for crop() and mask().
conus_outer_v <- vect(conus_outer)


# -------------------- Read rasters --------------------

gmfd <- rast(gmfd_path)
era5 <- rast(era5_path)

# Convert GMFD longitudes from 0-360 to -180-180 if needed.
if (xmin(gmfd) >= 0 && xmax(gmfd) > 180) {
  gmfd <- rotate(gmfd)
}


# -------------------- Crop and mask to CONUS --------------------

gmfd_conus <- gmfd %>%
  crop(conus_outer_v) %>%
  mask(conus_outer_v)

era5_conus <- era5 %>%
  crop(conus_outer_v) %>%
  mask(conus_outer_v)


# =============================================================================
# 2. Convert units
# =============================================================================

if (variable %in% c("tmin", "tmax")) {
  
  # GMFD temp stored in kelvin
  # ERA5-Land temp already in celsius
  gmfd_conus <- gmfd_conus - 273.15
  
  # output units for processed rasters and difference rasters
  out_unit <- "C"
  diff_unit <- "C"
  
} else if (variable == "prcp") {
  
  # GMFD precip stored as a flux (kg m-2 s-1).\
  # For water, 1 kg m-2 = 1 mm, so multiplying by the number
  # of seconds in a day (86400) converts precipitation from
  # mm/s to mm/day.
  gmfd_conus <- gmfd_conus * 86400
  
  out_unit <- "mm/day"
  diff_unit <- "mm/day"
}

# =============================================================================
# 3. Regrid ERA5-Land to the GMFD grid
# =============================================================================

# -------------------- Select regridding method --------------------

if (variable %in% c("tmin", "tmax")) {
  
  # temp is continuous, so bilinear interpolation is appropriate
  regrid_method <- "bilinear"
  
} else if (variable == "prcp") {
  # ERA5-Land is finer than GMFD. use averaging when aggregating
  # precip to the coarser GMFD grid.
  regrid_method <- "average"
  
}


# -------------------- Regrid ERA5-Land --------------------

era5_on_gmfd <- resample(era5_conus, gmfd_conus, method = regrid_method)


# =============================================================================
# 4. Compute ERA5-Land - GMFD differences and save outputs
# =============================================================================

# difference
diff_era5_minus_gmfd <- era5_on_gmfd - gmfd_conus

# NetCDF outputs: 

writeCDF(gmfd_conus, filename = gmfd_out_path,
         overwrite = TRUE, varname = variable, 
         unit = out_unit)

writeCDF(era5_on_gmfd, filename = era5_out_path,
        overwrite = TRUE, varname = variable,
        unit = out_unit)

writeCDF(diff_era5_minus_gmfd, filename = diff_out_path,
         overwrite = TRUE, varname = paste0("diff_", variable),
         unit = diff_unit)


# =============================================================================
# 5. Compute and save comparison statistics
# =============================================================================

# extract raster values and keep complete pixel-day pairs
gmfd_vec <- as.vector(values(gmfd_conus))
era5_vec <- as.vector(values(era5_on_gmfd))

keep <- complete.cases(gmfd_vec, era5_vec)

# return missing stats if not enough valid obs
if (sum(keep) < 2) {
  corr_year <- NA_real_
  bias_year <- NA_real_
  mae_year <- NA_real_
  rmse_year <- NA_real_
} else {
  # summary stats comparing ERA5-Land and GMFD
  corr_year <- cor(gmfd_vec[keep], era5_vec[keep])
  bias_year <- mean(era5_vec[keep] - gmfd_vec[keep])
  mae_year <- mean(abs(era5_vec[keep] - gmfd_vec[keep]))
  rmse_year <- sqrt(mean((era5_vec[keep] - gmfd_vec[keep])^2))
}

# save stats and metadata for this variable-year combination
yearly_check <- tibble(
  variable = variable,
  year = year,
  n_layers = nlyr(gmfd_conus),
  n_complete_pixel_days = sum(keep),
  correlation = corr_year,
  bias_era5_minus_gmfd = bias_year,
  mae = mae_year,
  rmse = rmse_year,
  regrid_method = regrid_method,
  unit = out_unit,
  difference_definition = "ERA5-Land minus GMFD",
  gmfd_input = gmfd_path,
  era5_input = era5_path,
  gmfd_output = gmfd_out_path,
  era5_output = era5_out_path,
  diff_output = diff_out_path
)

write_csv(yearly_check, check_out_path)


