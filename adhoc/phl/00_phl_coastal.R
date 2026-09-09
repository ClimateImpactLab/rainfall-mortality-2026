#========================================================================================#
#' Coastal exposure of each Philippine municipality
#'
#' coast_share = fraction of a municipality's perimeter that is NOT shared with
#' another municipality, i.e. that faces the sea.
#'
#' Computed by SUBTRACTING shared borders rather than by unioning the landmass
#' and taking its boundary. The union route is fragile here: st_simplify does
#' not preserve topology BETWEEN polygons, so simplified neighbours no longer
#' share exact edges and the union leaves slivers that masquerade as coastline.
#' Neighbour subtraction on the full-resolution geometry is exact.
#'
#' SEPARATE SCRIPT, CACHED: reads the 211MB shapefile and does ~8k pairwise
#' boundary intersections, so it takes a few minutes. Run once.
#'
#' Input : the adm3 shapefile (PH_Adm3_MuniCities.shp.*; see _phl_common.R)
#' Output: output/data/phl/phl_coastal.csv  (adm3_id, coast_share, coast_km, ...)
#'
#' Run: Rscript adhoc/phl/00_phl_coastal.R
#========================================================================================#

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(sf); library(purrr)
})

.adhoc <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a) == 1) dirname(normalizePath(sub("^--file=", "", a))) else normalizePath(getwd())
  while (!file.exists(file.path(d, "_common.R")) && dirname(d) != d) d <- dirname(d)
  d
})
source(file.path(.adhoc, "_common.R"))
source(file.path(.adhoc, "phl", "_phl_common.R"))

DIRS <- out_dirs("phl")
DIR_DATA <- DIRS$data; DIR_FIG <- DIRS$fig; DIR_TAB <- DIRS$tab

SHP_DIR <- require_phl_shp()
OUT     <- file.path(DIR_DATA, "phl_coastal.csv")

message("reading full-resolution geometry...")
shp <- st_read(SHP_DIR, layer = PHL_SHP_LAYER, quiet = TRUE) %>%
  st_make_valid() %>%
  mutate(adm3_id = str_pad(as.character(adm3_psgc), 10, pad = "0"))
stopifnot(!st_is_longlat(shp))            # need a metric CRS for lengths
message(nrow(shp), " polygons | CRS: ", st_crs(shp)$input)

g   <- st_geometry(shp)
per <- as.numeric(st_length(st_boundary(g)))     # full perimeter, metres

message("finding neighbours...")
nb <- st_touches(g)
message("median neighbours: ", median(lengths(nb)),
        " | isolated polygons (islands): ", sum(lengths(nb) == 0))

message("measuring shared borders (this is the slow part)...")
shared <- vapply(seq_along(g), function(i) {
  j <- nb[[i]]
  if (!length(j)) return(0)
  # intersection of adjacent polygons is a line (occasionally a point)
  inter <- suppressWarnings(st_intersection(g[i], st_union(g[j])))
  if (!length(inter)) return(0)
  as.numeric(sum(st_length(inter)))
}, numeric(1))

coastal <- tibble(
  adm3_id     = shp$adm3_id,
  adm3_en     = shp$adm3_en,
  perim_km    = per / 1000,
  shared_km   = shared / 1000,
  coast_km    = pmax(per - shared, 0) / 1000,
  coast_share = pmax(pmin(1 - shared / per, 1), 0)
)

# --- validation ------------------------------------------------------------
cat("\n=== coast_share distribution ===\n")
print(round(quantile(coastal$coast_share, seq(0, 1, 0.1)), 3))
cat("\nlandlocked (share < 0.01):", sum(coastal$coast_share < 0.01),
    "| fully coastal (> 0.99):", sum(coastal$coast_share > 0.99),
    "| of", nrow(coastal), "\n")

# A correct measure must call inland Luzon municipalities landlocked and
# small-island municipalities fully coastal. Both are checked here; if the
# geometry were producing spurious coastline, landlocked count would collapse.
cat("\nexamples, most inland (share = 0):\n")
print(coastal %>% filter(coast_share < 0.001) %>% slice_head(n = 5) %>%
        select(adm3_en, perim_km, coast_share) %>% as.data.frame(), digits = 3)
cat("\nexamples, fully coastal:\n")
print(coastal %>% filter(coast_share > 0.999) %>% slice_head(n = 5) %>%
        select(adm3_en, perim_km, coast_share) %>% as.data.frame(), digits = 3)

stopifnot(sum(coastal$coast_share < 0.01) > 100,   # inland municipalities exist
          sum(coastal$coast_share > 0.99) > 20)    # islands exist

write_csv(coastal, OUT)
message("\nwrote ", nrow(coastal), " rows -> ", OUT)
