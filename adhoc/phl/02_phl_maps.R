#========================================================================================#
#' Maps of PHL climate, heterogeneity covariates, and mortality
#'
#' Joins the adm3 shapefile (PSA PSGC, post-2023 boundaries) to panel-derived
#' municipality covariates and draws the maps used in the Data section of
#' output/slides/phl_rainfall_mortality.tex.
#'
#' Join: shapefile adm3_psgc (9-digit numeric) zero-padded to 10 characters
#' matches the panel's adm3_id. This skips the cluster's crosswalk file, which
#' exists for harmonisation exceptions (BARMM SGA splits etc.); the match rate
#' is asserted below so silent mismatch cannot slip through.
#'
#' Inputs:  the adm3 shapefile (PH_Adm3_MuniCities.shp.*; see _phl_common.R)
#'          the PHL mortality panel (see _phl_common.R)
#' Outputs: output/figures/phl/map_climate.png
#'          output/figures/phl/map_covariates.png
#'          output/figures/phl/map_mortality.png
#'          output/data/phl/phl_adm3_simplified.rds  (geometry cache)
#'
#' Run: Rscript adhoc/phl/02_phl_maps.R
#========================================================================================#

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(ggplot2)
  library(sf)
  library(patchwork)
})
theme_set(theme_void())

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

SHP_DIR    <- require_phl_shp()
GEOM_CACHE <- file.path(DIR_DATA, "phl_adm3_simplified.rds")

# ---------------------------------------------------------------------------
# 1. Geometry: read once, simplify hard, cache
# ---------------------------------------------------------------------------
# The source geometry is 211MB for 1,642 polygons -- far more coastline detail
# than a half-page map can show. st_simplify (GEOS) with a 250m tolerance cuts
# it to ~1/50 the size. (rmapshaper::ms_simplify would preserve shared
# boundaries, but its embedded V8 engine runs out of heap on a file this
# size; with fills only and no polygon borders drawn, st_simplify slivers are
# invisible at deck scale.)
if (file.exists(GEOM_CACHE)) {
  message("reading cached simplified geometry: ", GEOM_CACHE)
  shp <- readRDS(GEOM_CACHE)
} else {
  message("reading full-resolution shapefile (211MB, takes a minute)...")
  shp <- st_read(SHP_DIR, layer = PHL_SHP_LAYER, quiet = TRUE) %>%
    select(adm3_psgc, adm3_en) %>%
    mutate(adm3_id = str_pad(as.character(adm3_psgc), 10, pad = "0"))
  message("simplifying...")
  shp <- shp %>%
    st_simplify(preserveTopology = TRUE, dTolerance = 250) %>%  # CRS is metric
    st_make_valid()
  saveRDS(shp, GEOM_CACHE)
  message("cached -> ", GEOM_CACHE)
}

# ---------------------------------------------------------------------------
# 2. Panel-derived adm3 covariates
# ---------------------------------------------------------------------------
raw <- read_phl_panel()

# climate + covariates are constant across age groups; use agegroup 1 rows
adm3_covar <- raw %>%
  filter(agegroup == 1) %>%
  group_by(adm3_id) %>%
  summarise(
    prcp_mean = mean(prcp_poly_1_ERA5LAND, na.rm = TRUE),
    prcp_cv   = 100 * sd(prcp_poly_1_ERA5LAND, na.rm = TRUE) /
                      mean(prcp_poly_1_ERA5LAND, na.rm = TRUE),
    tavg_mean = mean(tavg_poly_1_ERA5LAND, na.rm = TRUE) / 365,
    urban     = mean(urban_share, na.rm = TRUE),
    gdppc     = first(gdppc_adm1_avg),
    smod = {
      s <- case_when(settlement_type %in% c(10, 11, 12, 13) ~ "Rural",
                     settlement_type %in% c(21, 22)         ~ "Peri-urban",
                     settlement_type %in% c(23, 30)         ~ "Urban centre")
      names(sort(table(s), decreasing = TRUE))[1]   # modal class
    },
    .groups = "drop"
  ) %>%
  mutate(smod = factor(smod, levels = c("Rural", "Peri-urban", "Urban centre")))

# mortality: p99-winsorised within age (mirroring the analysis pipeline)
adm3_mort <- raw %>%
  filter(agegroup != 0, !is.na(deathrate)) %>%
  group_by(agegroup) %>%
  mutate(dr = pmin(deathrate, quantile(deathrate, 0.99, na.rm = TRUE, type = 2))) %>%
  group_by(adm3_id, agegroup) %>%
  summarise(dr = mean(dr), .groups = "drop") %>%
  mutate(age_lab = factor(AGE_LABS[as.character(agegroup)],
                          levels = unname(AGE_LABS)))

# ---------------------------------------------------------------------------
# 3. Join + match-rate guard
# ---------------------------------------------------------------------------
m <- shp %>% left_join(adm3_covar, by = "adm3_id")
match_rate <- mean(shp$adm3_id %in% adm3_covar$adm3_id)
panel_cover <- mean(adm3_covar$adm3_id %in% shp$adm3_id)
message(sprintf("shapefile polygons matched to panel: %.1f%% | panel adm3s found in shapefile: %.1f%%",
                100 * match_rate, 100 * panel_cover))
stopifnot(panel_cover > 0.97)   # panel municipalities must map; spare polygons are fine

# ---------------------------------------------------------------------------
# 4. Maps
# ---------------------------------------------------------------------------
map_of <- function(d, var, title, option = "viridis", direction = 1,
                   labels = scales::label_number(), trans = "identity") {
  ggplot(d) +
    geom_sf(aes(fill = .data[[var]]), colour = NA) +
    scale_fill_viridis_c(option = option, direction = direction,
                         labels = labels, trans = trans, na.value = "grey85") +
    labs(title = title, fill = NULL) +
    theme(plot.title = element_text(size = 11, hjust = 0.5),
          legend.position = "right",
          legend.key.height = grid::unit(1.1, "cm"),
          legend.key.width  = grid::unit(0.35, "cm"))
}

p_clim <- map_of(m, "prcp_mean", "Mean annual precipitation (mm)", option = "mako",
                 direction = -1) +
  map_of(m, "prcp_cv", "Interannual CV of annual precip (%)", option = "viridis") +
  map_of(m, "tavg_mean", "Mean daily temperature (°C)", option = "rocket", direction = -1) +
  plot_layout(nrow = 1)
save_fig("map_climate.png", p_clim,
       width = 12, height = 5.4, bg = "white")

p_cov <- map_of(m, "urban", "Urban population share (%)") +
  (ggplot(m) +
     geom_sf(aes(fill = smod), colour = NA) +
     scale_fill_manual(values = c("Rural" = "#88a76a", "Peri-urban" = "#e7b34c",
                                  "Urban centre" = "#9f3b3b"), na.value = "grey85") +
     labs(title = "Modal settlement class (GHSL SMOD)", fill = NULL) +
     theme(plot.title = element_text(size = 11, hjust = 0.5),
           legend.position = "right")) +
  (ggplot(m %>% mutate(gdppc_f = factor(scales::comma(round(gdppc)),
                                        levels = scales::comma(sort(unique(round(gdppc))))))) +
     # only 7 distinct regional values, so a discrete scale, not a ramp
     geom_sf(aes(fill = gdppc_f), colour = NA) +
     scale_fill_viridis_d(option = "cividis", na.value = "grey85") +
     labs(title = "GDP per capita, region (USD)", fill = NULL) +
     theme(plot.title = element_text(size = 11, hjust = 0.5),
           legend.position = "right")) +
  plot_layout(nrow = 1)
save_fig("map_covariates.png", p_cov,
       width = 12, height = 5.4, bg = "white")

# one panel per age with its OWN fill scale: 65+ rates are ~20x the other
# groups, so a shared scale washes two panels flat
p_mort <- lapply(unname(AGE_LABS), function(a) {
  shp %>%
    left_join(filter(adm3_mort, age_lab == a), by = "adm3_id") %>%
    map_of("dr", paste0("Ages ", a), option = "magma", direction = -1)
}) %>%
  patchwork::wrap_plots(nrow = 1) +
  plot_annotation(caption = "Mean p99-winsorised deaths per 100,000, 2006-2024; independent colour scales")
save_fig("map_mortality.png", p_mort,
       width = 12, height = 5.4, bg = "white")

# ---------------------------------------------------------------------------
# 4b. Coastal exposure map (validation of 00_phl_coastal.R)
# ---------------------------------------------------------------------------
COASTAL <- file.path(REPO_ROOT, "output", "data", "phl", "phl_coastal.csv")
if (file.exists(COASTAL)) {
  cs <- read_csv(COASTAL, col_types = cols(adm3_id = col_character(),
                                           .default = col_guess()))
  mc <- shp %>% left_join(select(cs, adm3_id, coast_share), by = "adm3_id")
  p_coast <- ggplot(mc) +
    geom_sf(aes(fill = coast_share), colour = NA) +
    scale_fill_viridis_c(option = "mako", direction = -1,
                         labels = scales::percent, na.value = "grey85") +
    labs(title = "Share of perimeter facing the sea", fill = NULL) +
    theme(plot.title = element_text(size = 11, hjust = 0.5),
          legend.key.height = grid::unit(1.1, "cm"),
          legend.key.width  = grid::unit(0.35, "cm"))
  save_fig("map_coastal.png", p_coast,
         width = 6.5, height = 6.5, bg = "white")
  message("coastal map written")
}

# ---------------------------------------------------------------------------
# 5. Residual map (only if 01_phl_response_functions.R has produced the file)
# ---------------------------------------------------------------------------
RESID <- file.path(REPO_ROOT, "output", "data", "phl", "resid_adm3.csv")
if (file.exists(RESID)) {
  rs <- read_csv(RESID, show_col_types = FALSE)
  mres <- shp %>% left_join(rs, by = "adm3_id")
  lim <- quantile(abs(mres$mean_rel), 0.99, na.rm = TRUE)  # clip 1% tail
  p_res <- ggplot(mres) +
    geom_sf(aes(fill = mean_rel), colour = NA) +
    scale_fill_gradient2(low = "#2166ac", mid = "white", high = "#b2182b",
                         limits = c(-lim, lim), oob = scales::squish,
                         labels = scales::percent, na.value = "grey85") +
    labs(fill = "Mean relative\nerror") +
    theme(legend.key.height = grid::unit(1.1, "cm"),
          legend.key.width  = grid::unit(0.35, "cm"))
  save_fig("map_residuals.png", p_res,
         width = 7, height = 6.5, bg = "white")
  message("residual map written")
} else {
  message("no resid_adm3.csv yet; run 01_phl_response_functions.R first")
}

message("maps -> ", DIR_FIG)
