#!/usr/bin/env Rscript
# ==============================================================================
# Build ERA5-Land Download Domains
#
# Builds the project-specific spatial domains and rectangular bounding boxes
# used for ERA5-Land regional downloads.
#
# Inputs are country, HydroBASINS, NUTS, and Brazil ADM2 shapefiles.
#
# Outputs are domain files, bbox files, and check plots in:
# /project/cil/gcp/estimation/rainfall-mortality/era5land_domains
#
# `domains/` stores the shapes used to decide coverage. `bbox/` stores the
# rectangles passed to CDS/DestinE as north, west, south, east.
#
# Safe to rerun: yes. Existing domain, bbox, and check-plot outputs are replaced.
# ==============================================================================


default_proj <- "/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/share/proj"
if (Sys.getenv("PROJ_LIB") == "" && file.exists(file.path(default_proj, "proj.db"))) {
  Sys.setenv(PROJ_LIB = default_proj)
}

library(sf)
library(dplyr)
library(ggplot2)

sf_use_s2(FALSE)

# =============================================================================
# 1. Paths
# =============================================================================

data_root <- Sys.getenv(
  "ERA5LAND_DOMAIN_DATA",
  "/project/cil/gcp/estimation/rainfall-mortality/era5land_domains/data"
)

plot_root <- Sys.getenv(
  "ERA5LAND_DOMAIN_PLOTS",
  "/project/cil/gcp/estimation/rainfall-mortality/era5land_domains/plots"
)

europe_nuts_path <- Sys.getenv(
  "EUROPE_NUTS_SHP",
  "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/EU/Shapefile/NUTS2_RG_60M_2013_mortality.shp"
)

brazil_adm2_path <- Sys.getenv(
  "BRAZIL_ADM2_SHP",
  "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/BRA/Shapefile/BRA_adm2.shp"
)

# `raw_shapefiles` holds source shapefiles copied to the project output folder.
# `domains` keeps the irregular project domains used to decide coverage.
# `bbox` keeps the rectangular boxes passed to ERA5-Land download scripts.
raw_dir <- file.path(data_root, "raw_shapefiles")
basins_dir <- file.path(data_root, "basins")
domains_dir <- file.path(data_root, "domains")
bbox_dir <- file.path(data_root, "bbox")
plot_dir <- file.path(plot_root, "original_bbox_plots")

dir.create(basins_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(domains_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(bbox_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)

target_crs <- 4326

paths <- list(
  hydro_na = file.path(raw_dir, "hybas_na_lev01_v1c/hybas_na_lev01_v1c.shp"),
  hydro_asia = file.path(raw_dir, "hybas_as_lev01_v1c/hybas_as_lev01_v1c.shp"),
  hydro_europe_l3 = file.path(raw_dir, "hybas_eu_lev03_v1c/hybas_eu_lev03_v1c.shp"),
  usa = file.path(raw_dir, "geoBoundaries-USA-ADM0-all/geoBoundaries-USA-ADM0_simplified.shp"),
  india = file.path(raw_dir, "geoBoundaries-IND-ADM0-all/geoBoundaries-IND-ADM0_simplified.shp"),
  world = file.path(raw_dir, "World_Countries_Generalized/World_Countries_Generalized.shp")
)

missing_inputs <- unlist(c(paths, europe_nuts_path, brazil_adm2_path))
missing_inputs <- missing_inputs[!file.exists(missing_inputs)]
if (length(missing_inputs) > 0) {
  stop("Missing input file(s):\n", paste(missing_inputs, collapse = "\n"))
}

# =============================================================================
# 2. Helpers
# =============================================================================

read_shape <- function(path) {
  st_read(path, quiet = TRUE) %>%
    st_transform(target_crs) %>%
    st_make_valid()
}

bbox_poly <- function(bbox, name) {
  st_as_sfc(bbox) %>%
    st_as_sf() %>%
    mutate(domain = name)
}

cds_area <- function(bbox) {
  c(
    north = bbox["ymax"],
    west = bbox["xmin"],
    south = bbox["ymin"],
    east = bbox["xmax"]
  )
}

write_layer <- function(object, path) {
  st_write(object, path, delete_dsn = TRUE, quiet = TRUE)
}

save_plot <- function(plot, filename, width = 11, height = 7) {
  ggsave(
    filename = file.path(plot_dir, filename),
    plot = plot,
    width = width,
    height = height,
    dpi = 200
  )
}

print_area <- function(name, bbox) {
  cat("\n", name, " [north, west, south, east]\n", sep = "")
  print(cds_area(bbox))
}

# =============================================================================
# 3. Read inputs
# =============================================================================

hydro_na <- read_shape(paths$hydro_na)
hydro_asia <- read_shape(paths$hydro_asia)
hydro_europe_l3 <- read_shape(paths$hydro_europe_l3)
usa <- read_shape(paths$usa)
india <- read_shape(paths$india)
world <- read_shape(paths$world)
europe_nuts <- read_shape(europe_nuts_path)

brazil_adm2 <- read_shape(brazil_adm2_path) %>%
  mutate(
    region_id = paste0(
      "BRA_",
      sprintf("%03d", as.integer(ID_0)),
      "_",
      sprintf("%02d", as.integer(ID_1)),
      "_",
      sprintf("%04d", as.integer(ID_2))
    )
  )

# =============================================================================
# 4. USA and Mexico south
# =============================================================================

# The USA download box was built from CONUS + Alaska plus intersecting
# HydroBASINS Level 1. This made the box much larger than the country border,
# but it was needed for the hydrology work.
usa_parts <- usa %>%
  st_cast("POLYGON")

usa_points <- st_coordinates(st_point_on_surface(usa_parts))

usa_clean <- usa_parts %>%
  mutate(lon = usa_points[, 1], lat = usa_points[, 2]) %>%
  filter(
    (lon > -130 & lon < -60 & lat > 20 & lat < 55) |
      (lon > -180 & lon < -130 & lat > 50 & lat < 72)
  )

usa_union <- usa_clean %>%
  st_union() %>%
  st_as_sf() %>%
  mutate(domain = "USA CONUS + Alaska") %>%
  st_make_valid()

usa_basins <- hydro_na[lengths(st_intersects(hydro_na, usa_union)) > 0, ]

usa_domain <- st_union(st_geometry(usa_basins), st_geometry(usa_union)) %>%
  st_as_sf() %>%
  mutate(domain = "USA country + HydroBASINS Level 1") %>%
  st_make_valid()

usa_bbox <- st_bbox(usa_domain)
usa_bbox["ymin"] <- max(usa_bbox["ymin"], 15)
usa_bbox_poly <- bbox_poly(usa_bbox, "usa")

# The USA box covered most of Mexico, but not the southern edge. This strip was
# added so Mexico climate aggregation would not miss cells.
mexico_south_bbox <- st_bbox(
  c(
    xmin = as.numeric(usa_bbox["xmin"]),
    ymin = 14.5,
    xmax = as.numeric(usa_bbox["xmax"]),
    ymax = 14.9
  ),
  crs = st_crs(target_crs)
)
mexico_south_bbox_poly <- bbox_poly(mexico_south_bbox, "mexico_south")

# =============================================================================
# 5. India and Asia east
# =============================================================================

# The India box was also built from the country plus intersecting HydroBASINS
# Level 1. I capped it at 120E so the first pull did not include a much larger
# East Asia/Pacific area before we knew it was needed.
india_union <- india %>%
  st_union() %>%
  st_as_sf() %>%
  mutate(domain = "India") %>%
  st_make_valid()

india_basins <- hydro_asia[lengths(st_intersects(hydro_asia, india_union)) > 0, ]

india_domain <- st_union(st_geometry(india_basins), st_geometry(india_union)) %>%
  st_as_sf() %>%
  mutate(domain = "India country + HydroBASINS Level 1") %>%
  st_make_valid()

india_bbox <- st_bbox(india_domain)
india_bbox["xmax"] <- min(india_bbox["xmax"], 120)
india_bbox_poly <- bbox_poly(india_bbox, "india")

# Other Asian countries were added later. This extension uses the same
# north/south bounds as India and starts at 120.1E to avoid duplicating the
# 120.0E grid column.
asia_east_bbox <- st_bbox(
  c(
    xmin = 120.1,
    ymin = as.numeric(india_bbox["ymin"]),
    xmax = 150.0,
    ymax = as.numeric(india_bbox["ymax"])
  ),
  crs = st_crs(target_crs)
)
asia_east_bbox_poly <- bbox_poly(asia_east_bbox, "asia_east")

# =============================================================================
# 6. Latin America and Brazil east
# =============================================================================

# The LATAM box was meant to cover Latin America and the Caribbean. France is
# included so French Guiana and French Caribbean territories are available, but
# the geometry is cropped to the Americas so mainland France is not kept.
latam_names <- c(
  "Belize", "Guatemala", "Honduras", "El Salvador", "Nicaragua",
  "Costa Rica", "Panama", "Cuba", "Dominican Republic", "Haiti",
  "Jamaica", "Trinidad and Tobago", "Puerto Rico", "Barbados",
  "The Bahamas", "Bahamas", "Argentina", "Bolivia", "Brazil", "Chile",
  "Colombia", "Ecuador", "Guyana", "Paraguay", "Peru", "Suriname",
  "Uruguay", "Venezuela", "France"
)

latam_raw <- world %>%
  filter(COUNTRY %in% latam_names)

latam_missing <- setdiff(latam_names, unique(world$COUNTRY))
latam_missing <- setdiff(latam_missing, c("The Bahamas", "Bahamas"))
if (length(latam_missing) > 0) {
  cat("\nLATAM names not found in local world shapefile:\n")
  print(latam_missing)
}

latam_crop_box <- st_bbox(
  c(xmin = -120, ymin = -60, xmax = -20, ymax = 40),
  crs = st_crs(target_crs)
)

latam <- st_crop(latam_raw, latam_crop_box) %>%
  st_make_valid()

latam_domain <- latam %>%
  st_union() %>%
  st_as_sf() %>%
  mutate(domain = "Latin America and Caribbean") %>%
  st_make_valid()

latam_bbox <- st_bbox(latam_domain)
latam_bbox_poly <- bbox_poly(latam_bbox, "latam")

# During Brazil aggregation, a small eastern coastal piece was outside the LATAM
# raster. The patch is built from the affected Brazil ADM2 polygons and padded
# slightly so edge coordinates are not missed.
brazil_east_partial_ids <- c(
  "BRA_032_17_3239", # Pernambuco, Igaracu
  "BRA_032_17_3233", # Pernambuco, Goiana
  "BRA_032_17_3274", # Pernambuco, Olinda
  "BRA_032_15_2638", # Paraiba, Joao Pessoa
  "BRA_032_15_2604", # Paraiba, Conde
  "BRA_032_17_3284", # Pernambuco, Paulista
  "BRA_032_17_3247", # Pernambuco, Itamaraca
  "BRA_032_15_2584", # Paraiba, Cabedelo
  "BRA_032_15_2690"  # Paraiba, Pitimbu
)

brazil_east_units <- brazil_adm2 %>%
  filter(region_id %in% brazil_east_partial_ids)

if (nrow(brazil_east_units) != length(brazil_east_partial_ids)) {
  stop("Brazil east patch: not all affected ADM2 IDs were found.")
}

brazil_east_raw <- st_bbox(brazil_east_units)
brazil_east_pad <- 0.2
brazil_east_bbox <- st_bbox(
  c(
    xmin = as.numeric(brazil_east_raw["xmin"]) - brazil_east_pad,
    ymin = as.numeric(brazil_east_raw["ymin"]) - brazil_east_pad,
    xmax = as.numeric(brazil_east_raw["xmax"]) + brazil_east_pad,
    ymax = as.numeric(brazil_east_raw["ymax"]) + brazil_east_pad
  ),
  crs = st_crs(target_crs)
)
brazil_east_bbox_poly <- bbox_poly(brazil_east_bbox, "brazil_east")

# =============================================================================
# 7. Europe
# =============================================================================

# Europe uses the target NUTS regions from the mortality data, not a generic
# continent box. French overseas NUTS regions are removed before adding
# intersecting HydroBASINS Level 3.
target_iso3 <- c(
  "AUT", "BEL", "BGR", "CHE", "CYP", "CZE", "DEU", "DNK", "ESP", "EST",
  "FIN", "FRA", "GBR", "GRC", "HRV", "HUN", "IRL", "ISL", "ITA",
  "LIE", "LTU", "LUX", "LVA", "MKD", "MLT", "MNE", "NLD", "NOR",
  "POL", "PRT", "ROU", "SVK", "SVN", "SWE", "TUR"
)

exclude_nuts <- c("FRA1", "FRA2", "FRA3", "FRA4", "FRA5")

iso_crosswalk <- tibble::tribble(
  ~iso3, ~iso2,
  "AUT", "AT", "BEL", "BE", "BGR", "BG", "CHE", "CH", "CYP", "CY",
  "CZE", "CZ", "DEU", "DE", "DNK", "DK", "ESP", "ES", "EST", "EE",
  "FIN", "FI", "FRA", "FR", "GBR", "UK", "GRC", "EL", "HRV", "HR",
  "HUN", "HU", "IRL", "IE", "ISL", "IS", "ITA", "IT", "LIE", "LI",
  "LTU", "LT", "LUX", "LU", "LVA", "LV", "MKD", "MK", "MLT", "MT",
  "MNE", "ME", "NLD", "NL", "NOR", "NO", "POL", "PL", "PRT", "PT",
  "ROU", "RO", "SVK", "SK", "SVN", "SI", "SWE", "SE", "TUR", "TR"
)

europe_nuts <- europe_nuts %>%
  filter(!NUTS_ID %in% exclude_nuts) %>%
  mutate(iso2 = substr(NUTS_ID, 1, 2))

coverage_check <- iso_crosswalk %>%
  filter(iso3 %in% target_iso3) %>%
  mutate(in_nuts = iso2 %in% unique(europe_nuts$iso2))

missing_europe <- coverage_check %>%
  filter(!in_nuts)
if (nrow(missing_europe) > 0) {
  cat("\nEurope target countries missing from NUTS file:\n")
  print(missing_europe)
}

europe_target <- europe_nuts %>%
  filter(iso2 %in% coverage_check$iso2[coverage_check$in_nuts])

europe_union <- europe_target %>%
  st_simplify(dTolerance = 0.01, preserveTopology = TRUE) %>%
  st_make_valid() %>%
  st_union() %>%
  st_as_sf() %>%
  mutate(domain = "Europe target NUTS regions") %>%
  st_make_valid()

europe_basins <- hydro_europe_l3[lengths(st_intersects(hydro_europe_l3, europe_union)) > 0, ]

europe_domain <- st_union(st_geometry(europe_basins), st_geometry(europe_union)) %>%
  st_as_sf() %>%
  mutate(domain = "Europe NUTS + HydroBASINS Level 3") %>%
  st_make_valid()

europe_bbox <- st_bbox(europe_domain)
europe_bbox_poly <- bbox_poly(europe_bbox, "europe")

# =============================================================================
# 8. Australia
# =============================================================================

# The Australia source geometry includes a small far-southern outlying polygon.
# Keeping it would pull a much taller box. The project box keeps mainland
# Australia and Tasmania.
australia <- world %>%
  filter(COUNTRY == "Australia") %>%
  st_make_valid()

if (nrow(australia) == 0) {
  stop("Could not find Australia in local world shapefile.")
}

australia_parts <- australia %>%
  st_cast("POLYGON") %>%
  st_make_valid()

australia_points <- st_coordinates(st_point_on_surface(australia_parts))

australia_clean <- australia_parts %>%
  mutate(lon = australia_points[, 1], lat = australia_points[, 2]) %>%
  filter(lat > -45)

australia_domain <- australia_clean %>%
  st_union() %>%
  st_as_sf() %>%
  mutate(domain = "Australia mainland + Tasmania") %>%
  st_make_valid()

australia_bbox <- st_bbox(australia_domain)
australia_bbox_poly <- bbox_poly(australia_bbox, "australia")

# =============================================================================
# 9. Print areas
# =============================================================================

print_area("USA", usa_bbox)
print_area("Mexico south", mexico_south_bbox)
print_area("India", india_bbox)
print_area("Asia east", asia_east_bbox)
print_area("LATAM", latam_bbox)
print_area("Brazil east", brazil_east_bbox)
print_area("Europe", europe_bbox)
print_area("Australia", australia_bbox)

# =============================================================================
# 10. Save domain and bbox files
# =============================================================================

write_layer(usa_basins, file.path(basins_dir, "usa_level1_intersecting_basins.shp"))
write_layer(india_basins, file.path(basins_dir, "india_level1_intersecting_basins.shp"))
write_layer(europe_basins, file.path(basins_dir, "europe_level3_intersecting_basins.gpkg"))

write_layer(usa_domain, file.path(domains_dir, "usa_country_plus_level1_basins_domain.gpkg"))
write_layer(india_domain, file.path(domains_dir, "india_country_plus_level1_basins_domain.gpkg"))
write_layer(latam, file.path(domains_dir, "latam_countries_cropped.gpkg"))
write_layer(latam_domain, file.path(domains_dir, "latam_country_union.gpkg"))
write_layer(europe_union, file.path(domains_dir, "europe_nuts_target_union.gpkg"))
write_layer(europe_domain, file.path(domains_dir, "europe_nuts_plus_level3_basins_domain.gpkg"))

all_bboxes <- bind_rows(
  usa_bbox_poly,
  mexico_south_bbox_poly,
  india_bbox_poly,
  asia_east_bbox_poly,
  latam_bbox_poly,
  brazil_east_bbox_poly,
  europe_bbox_poly,
  australia_bbox_poly
)

write_layer(all_bboxes, file.path(bbox_dir, "regional_era5land_bounding_boxes.gpkg"))
write_layer(latam_bbox_poly, file.path(bbox_dir, "latam_bounding_box.gpkg"))
write_layer(europe_bbox_poly, file.path(bbox_dir, "europe_level3_bounding_box.gpkg"))
write_layer(mexico_south_bbox_poly, file.path(bbox_dir, "mexico_south_extension_bbox.gpkg"))
write_layer(brazil_east_bbox_poly, file.path(bbox_dir, "brazil_east_extension_bbox.gpkg"))
write_layer(australia_bbox_poly, file.path(bbox_dir, "australia_bbox.gpkg"))

write.csv(as.data.frame(t(cds_area(latam_bbox))), file.path(bbox_dir, "latam_cds_area.csv"), row.names = FALSE)
write.csv(coverage_check, file.path(bbox_dir, "europe_nuts_country_coverage_check.csv"), row.names = FALSE)

# =============================================================================
# 11. Save check plots
# =============================================================================

p_usa <- ggplot() +
  geom_sf(data = usa_basins, fill = "lightblue", color = "white", linewidth = 0.2) +
  geom_sf(data = usa_union, fill = NA, color = "red", linewidth = 0.6) +
  geom_sf(data = usa_bbox_poly, fill = NA, color = "purple", linewidth = 0.8) +
  coord_sf(expand = FALSE) +
  labs(
    title = "USA country + intersecting HydroBASINS Level 1",
    subtitle = "Red = USA union; blue = intersecting basins; purple = capped bbox"
  ) +
  theme_minimal()
save_plot(p_usa, "usa_hydrobasins_l1_bbox.png")

p_india <- ggplot() +
  geom_sf(data = india_basins, fill = "lightblue", color = "white", linewidth = 0.2) +
  geom_sf(data = india_union, fill = NA, color = "red", linewidth = 0.6) +
  geom_sf(data = india_bbox_poly, fill = NA, color = "purple", linewidth = 0.8) +
  coord_sf(expand = FALSE) +
  labs(
    title = "India country + intersecting HydroBASINS Level 1",
    subtitle = "Purple bbox is capped at 120E"
  ) +
  theme_minimal()
save_plot(p_india, "india_hydrobasins_l1_bbox_capped_120E.png")

p_asia <- ggplot() +
  geom_sf(data = world, fill = "grey92", color = "grey70", linewidth = 0.2) +
  geom_sf(data = india_bbox_poly, fill = NA, color = "purple", linewidth = 0.9) +
  geom_sf(data = asia_east_bbox_poly, fill = NA, color = "red", linewidth = 0.9) +
  coord_sf(xlim = c(55, 152), ylim = c(0, 60), expand = FALSE) +
  labs(
    title = "India bbox and Asia east extension",
    subtitle = "Purple = original India/HydroBASINS box; red = later eastern extension"
  ) +
  theme_minimal()
save_plot(p_asia, "india_bbox_plus_asia_east_extension_150E.png", width = 12)

p_latam <- ggplot() +
  geom_sf(data = latam, fill = "grey85", color = "grey40", linewidth = 0.15) +
  geom_sf(data = latam_bbox_poly, fill = NA, color = "purple", linewidth = 0.8) +
  coord_sf(expand = FALSE) +
  labs(
    title = "Latin America and Caribbean bounding box",
    subtitle = "Brazil east patch is created separately"
  ) +
  theme_minimal()
save_plot(p_latam, "latam_bbox.png")

p_europe <- ggplot() +
  geom_sf(data = europe_basins, fill = "lightblue", color = "white", linewidth = 0.2) +
  geom_sf(data = europe_union, fill = NA, color = "red", linewidth = 0.6) +
  geom_sf(data = europe_bbox_poly, fill = NA, color = "purple", linewidth = 0.8) +
  coord_sf(expand = FALSE) +
  labs(
    title = "Europe NUTS regions + intersecting HydroBASINS Level 3",
    subtitle = "French overseas NUTS regions are removed"
  ) +
  theme_minimal()
save_plot(p_europe, "europe_nuts_hydrobasins_l3_bbox.png")

p_australia <- ggplot() +
  geom_sf(data = world, fill = "grey92", color = "grey75", linewidth = 0.2) +
  geom_sf(data = australia, fill = NA, color = "grey40", linewidth = 0.4) +
  geom_sf(data = australia_domain, fill = NA, color = "red", linewidth = 0.7) +
  geom_sf(data = australia_bbox_poly, fill = NA, color = "purple", linewidth = 1) +
  coord_sf(xlim = c(105, 165), ylim = c(-50, -5), expand = FALSE) +
  labs(
    title = "Australia bounding box",
    subtitle = "Red = kept geometry; purple = bbox"
  ) +
  theme_minimal()
save_plot(p_australia, "australia_country_bbox_cleaned.png")

p_global <- ggplot() +
  geom_sf(data = world, fill = "grey90", color = "grey60", linewidth = 0.2) +
  geom_sf(data = all_bboxes, aes(color = domain), fill = NA, linewidth = 1) +
  coord_sf(expand = FALSE) +
  labs(
    title = "ERA5-Land download domains",
    color = "Domain"
  ) +
  theme_minimal()
save_plot(p_global, "regional_era5land_bounding_boxes_global.png")

cat("\nDone. Domain files written to:\n")
cat(data_root, "\n")
cat("\nPlots written to:\n")
cat(plot_dir, "\n")
