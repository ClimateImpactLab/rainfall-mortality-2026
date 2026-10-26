# ============================================================
# 02_rain_vs_flow_maps.R
#
# County maps for the rainfall vs rainfall_flow comparison, lower 48 states
#
# Reads the tables written by 01_rain_vs_flow_figures.R and draws:
#   figure 1: mean rainfall, mean flow, upstream ratio and correlation
#   figure 5: shift from the rainfall peak month to the flow peak month
#   figure 6: each flood's rainfall and flow percentile
#
# Inputs:
#   output/data/hydro/rain_vs_flow/
#     county_summary.csv      from 01
#     event_percentiles.csv   from 01, every county
#     event_ranks.csv         from 01, case-study counties
#   norgay/.../Countries/USA/Shapefile/
#     tl_2016_us_county_mortality.shp   the county shapes behind the admin weights
#     tl_2016_us_state_mortality.shp    state outlines
#
# Outputs (output/figures/hydro/rain_vs_flow/, each as .pdf and .png):
#   1_county_maps      levels, upstream ratio and correlation, by county
#   5_peak_shift_map   months from the rainfall peak to the flow peak
#   6_event_maps       percentile of each flood's months, rainfall vs flow
#
# Dependencies: dplyr, readr, ggplot2, sf, patchwork
#
# Run from this folder on Midway, after 01_rain_vs_flow_figures.R:
#   Rscript 02_rain_vs_flow_maps.R
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)
library(sf)
library(patchwork)

theme_set(theme_void(base_size = 10))


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

fig_dir <- file.path(DIR_FIGURE, "hydro", "rain_vs_flow")
table_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "hydro", "rain_vs_flow")

# Shapefiles behind the USA admin weights (era5land_admin/settings.py). There
# is no paths.R global for norgay, so the folder is written out here, as it
# is in settings.py.
shape_dir <- "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/USA/Shapefile"


# -----------------------------
# Settings
# -----------------------------

# Lower 48 and DC only: Alaska, Hawaii and the territories would shrink the map.
# ID_1 is the state FIPS code.
outside_lower48 <- c("02", "15", "60", "66", "69", "72", "78")

ink <- "#0b0b0b"
ink_2 <- "#52514e"
muted <- "#898781"
rule <- "#c3c2b7"
# Darker than the diverging scale's near-white midpoint (below), so "no data"
# stays visually distinct from "zero" instead of blending into it. Most
# counties have no peak shift at all (see 5_peak_shift_map), so this matters.
no_data <- "#a9a79d"

# Sequential blue ramp and the blue-red diverging pair from the dataviz
# reference palette
blue_light <- "#cde2fb"
blue_dark <- "#0d366b"
diverging_low <- "#e34948"
diverging_mid <- "#f0efec"
diverging_high <- "#1c5cab"

theme_update(
  plot.title = element_text(colour = ink, face = "bold", size = 10, margin = margin(b = 8)),
  plot.caption = element_text(colour = muted, hjust = 0),
  plot.caption.position = "plot",
  strip.text = element_text(colour = ink, face = "bold", hjust = 0, margin = margin(b = 2)),
  legend.title = element_text(colour = ink_2, size = 8),
  legend.text = element_text(colour = ink_2, size = 8)
)

# Save each figure as a PDF (for slides and papers) and a PNG (for the HTML report)
# theme_void has no background, so it is set to white here
save_figure <- function(name, plot, width, height) {
  ggsave(file.path(fig_dir, paste0(name, ".pdf")), plot, width = width, height = height, bg = "white")
  ggsave(file.path(fig_dir, paste0(name, ".png")), plot, width = width, height = height, dpi = 200, bg = "white")
}


# -----------------------------
# Shapes
# -----------------------------

# PROJ cannot open its database in the Midway R env ("proj_create_from_database:
# Open of .../share/proj failed"), so the maps avoid PROJ. st_read still warns
# about it, which is harmless here. The coordinate system is dropped and
# longitude is scaled by cos(38 degrees): a plain longitude-latitude view of
# the lower 48 without east-west stretching. Shapes are simplified to about
# 0.02 degrees (about 2 km) so the maps draw quickly. Both change how the maps
# look, not the data.
lat_mid <- 38
read_shapes <- function(file) {
  shapes <- st_read(file.path(shape_dir, file), quiet = TRUE) %>%
    filter(!ID_1 %in% outside_lower48)
  st_crs(shapes) <- NA
  st_geometry(shapes) <- st_geometry(shapes) * diag(c(cos(lat_mid * pi / 180), 1))
  st_simplify(shapes, dTolerance = 0.02, preserveTopology = TRUE)
}

counties <- read_shapes("tl_2016_us_county_mortality.shp") %>%
  transmute(region_id = paste("USA_244", ID_1, ID_2, sep = "_"))
states <- read_shapes("tl_2016_us_state_mortality.shp")

stopifnot(anyDuplicated(counties$region_id) == 0)

# Outlines as plain x-y coordinates, drawn with geom_polygon. geom_sf still
# calls PROJ when it draws, and fails in this env (C stack error). `part` is
# one polygon of a county; `ring` marks each ring, so holes draw as holes.
to_polygons <- function(shapes, id) {
  shapes <- st_cast(shapes, "MULTIPOLYGON")
  coords <- as.data.frame(st_coordinates(shapes))
  tibble(
    x = coords$X,
    y = coords$Y,
    id = shapes[[id]][coords$L3],
    part = paste(coords$L3, coords$L2),
    ring = paste(coords$L3, coords$L2, coords$L1)
  )
}

county_polygons <- to_polygons(counties, "region_id")
state_polygons <- to_polygons(states, "ID_1")

state_lines <- geom_polygon(
  data = state_polygons, aes(x, y, group = part, subgroup = ring),
  fill = NA, colour = rule, linewidth = 0.15, inherit.aes = FALSE
)


# -----------------------------
# Tables from 01
# -----------------------------

county_summary <- read_csv(file.path(table_dir, "county_summary.csv"), show_col_types = FALSE)
event_percentiles <- read_csv(file.path(table_dir, "event_percentiles.csv"), show_col_types = FALSE)
event_ranks <- read_csv(file.path(table_dir, "event_ranks.csv"), show_col_types = FALSE)

# Counties with no comparison data are drawn in gray
cat("Lower-48 counties on the map:", nrow(counties), "\n")
cat("Of which without comparison data:", sum(!counties$region_id %in% county_summary$region_id), "\n")

county_map <- left_join(county_polygons, county_summary, by = c("id" = "region_id"))


# -----------------------------
# Figure 1: levels, upstream ratio and correlation
# -----------------------------

# One small map per measure, each with its own legend under it
county_panel <- function(fill_column, title, fill_scale) {
  ggplot(county_map, aes(x, y, group = part, subgroup = ring, fill = .data[[fill_column]])) +
    geom_polygon(colour = NA) +
    state_lines +
    coord_fixed() +
    fill_scale +
    labs(title = title) +
    theme(
      legend.position = "bottom",
      legend.title.position = "top",
      legend.key.width = unit(1.2, "cm"),
      legend.key.height = unit(0.25, "cm")
    )
}

map_rain <- county_panel(
  "rain_mean", "Mean monthly rainfall",
  scale_fill_gradient(low = blue_light, high = blue_dark, na.value = no_data, name = "mm")
)

map_flow <- county_panel(
  "flow_mean", "Mean monthly rainfall_flow",
  scale_fill_gradient(
    low = blue_light, high = blue_dark, transform = "log10",
    labels = scales::label_comma(), na.value = no_data,
    name = "mm summed over upstream cells (log scale)"
  )
)

map_ratio <- county_panel(
  "upstream_ratio", "Upstream ratio: flow / rainfall",
  scale_fill_gradient(
    low = blue_light, high = blue_dark, transform = "log10",
    labels = scales::label_comma(), na.value = no_data,
    name = "Mean flow / mean rainfall (log scale)"
  )
)

# Reversed ramp, so darker = flow differs more from rainfall
map_corr <- county_panel(
  "corr", "Correlation of monthly rainfall and flow",
  scale_fill_gradient(low = blue_dark, high = blue_light, na.value = no_data, name = "Correlation")
)

fig_maps <- (map_rain + map_flow) / (map_ratio + map_corr) +
  plot_annotation(caption = paste0(
    "Lower 48 states, raw monthly values 1950-2025. Gray: no comparison data.\n",
    "Correlation: each county's monthly rainfall and flow series, seasonal cycle included."
  ))

save_figure("1_county_maps", fig_maps, width = 6.5, height = 5.6)


# -----------------------------
# Figure 5: shift in the peak month
# -----------------------------

# Months from the rainfall peak to the flow peak (-5 to 6, positive = flow
# peaks later), from each county's mean seasonal cycle
fig_shift <- ggplot(county_map, aes(x, y, group = part, subgroup = ring, fill = peak_shift)) +
  geom_polygon(colour = NA) +
  state_lines +
  coord_fixed() +
  scale_fill_gradient2(
    low = diverging_low, mid = diverging_mid, high = diverging_high,
    midpoint = 0, limits = c(-6, 6), breaks = seq(-6, 6, by = 2), na.value = no_data,
    name = "Months from the rainfall peak to the flow peak (positive = flow peaks later)"
  ) +
  labs(
    title = "Does rainfall_flow peak in the same month as rainfall?",
    caption = paste0(
      "Peak month: the calendar month with the highest 1950-2025 mean, for each series.\n",
      "Near-white: same peak month. Gray: no comparison data."
    )
  ) +
  theme(
    legend.position = "bottom",
    legend.title.position = "top",
    legend.key.width = unit(2.5, "cm"),
    legend.key.height = unit(0.3, "cm")
  )

save_figure("5_peak_shift_map", fig_shift, width = 6.5, height = 4.6)


# -----------------------------
# Figure 6: flood maps
# -----------------------------

# Panels in the order of the events table in 01: each event, rainfall then flow
event_order <- unique(event_ranks$event)
event_names <- distinct(event_percentiles, event, event_short) %>%
  arrange(match(event, event_order))
panel_levels <- as.vector(t(outer(event_names$event_short, c("Rainfall", "rainfall_flow"), paste, sep = ": ")))

# Each county's outline repeated for every event and series (one panel each)
event_map <- county_polygons %>%
  inner_join(event_percentiles, by = c("id" = "region_id"), relationship = "many-to-many") %>%
  mutate(panel = factor(paste0(event_short, ": ", series), levels = panel_levels))

# Outline the case-study counties in their own event's panels
case_outlines <- county_polygons %>%
  inner_join(distinct(event_ranks, event, region_id, series), by = c("id" = "region_id"), relationship = "many-to-many") %>%
  left_join(event_names, by = "event") %>%
  mutate(panel = factor(paste0(event_short, ": ", series), levels = panel_levels))

fig_events <- ggplot(event_map, aes(x, y, group = part, subgroup = ring, fill = percentile)) +
  geom_polygon(colour = NA) +
  state_lines +
  geom_polygon(
    data = case_outlines, aes(x, y, group = part, subgroup = ring),
    fill = NA, colour = ink, linewidth = 0.3, inherit.aes = FALSE
  ) +
  coord_fixed() +
  facet_wrap(~ panel, ncol = 2) +
  scale_fill_gradient2(
    low = diverging_low, mid = diverging_mid, high = diverging_high,
    midpoint = 50, limits = c(0, 100),
    name = "Percentile of the flood months in the event year (100 = wettest of 1950-2025)"
  ) +
  labs(
    title = "Each flood in rainfall and in rainfall_flow, by county",
    caption = paste0(
      "Each county's total over the flood months in the event year, ranked against 1950-2025 in that county.\n",
      "Black outlines: case-study counties. Flood months are from the historical record, not from data."
    )
  ) +
  theme(
    legend.position = "bottom",
    legend.title.position = "top",
    legend.key.width = unit(2.5, "cm"),
    legend.key.height = unit(0.3, "cm")
  )

save_figure("6_event_maps", fig_events, width = 6.5, height = 9.5)

cat("\nMaps written to:", fig_dir, "\n")
