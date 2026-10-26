# ============================================================
# 04_global_figures.R
#
# Global maps and tables for the rainfall vs rainfall_flow comparison
#
# Reads the box statistics from 03_global_cell_stats.py. Each 0.5-degree box
# (5 x 5 ERA5-Land cells) plays the role of a county in
# 01_rain_vs_flow_figures.R: its rainfall (tp_total) and flow (rainfall_flow)
# are weighted means over its cells, and the drought and flood measures are
# the box's annual mean and annual max of monthly values. Two weightings:
# population (pop, what the US comparison used) and GPW land area (area).
#
# Inputs:
#   DATA_DIR/climate_data/ERA5-LAND-GLOBAL/GLOBAL/hydro/rain_vs_flow_boxes/
#     box_stats_band{0..7}.csv       from 03, one row per box with land
#     band_summary_band{0..7}.csv    from 03, cell, box, population and area counts
#   output/data/hydro/rain_vs_flow/group_summary.csv
#     the US upstream-ratio thirds, from 01_rain_vs_flow_figures.R
#
# Outputs:
#   output/figures/hydro/rain_vs_flow_global/  (each as .pdf and .png)
#     G1_upstream_ratio       mean flow / mean rainfall, by box
#     G2_drought_flood        where the drought and flood measures differ:
#                             correlation of flow with rainfall, by box
#     G3_peak_shift           months from the rainfall peak to the flow peak
#   The maps use the population weights, like the US maps.
#   output/data/hydro/rain_vs_flow_global/
#     coverage.csv            cells, boxes, population and land area in the comparison
#     group_summary.csv       boxes by upstream-ratio third, both weightings
#     snow_summary.csv        boxes in the low third, by snow share, both weightings
#   These tables are read by rain_vs_flow_global_report.Rmd.
#
# Dependencies: dplyr, readr, tidyr, ggplot2
#
# Run from this folder on Midway, after 03_global_cell_stats.py has run for
# every band:
#   Rscript 04_global_figures.R
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(tidyr)
library(ggplot2)

theme_set(theme_void(base_size = 10))


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

box_dir <- file.path(DATA_DIR, "climate_data", "ERA5-LAND-GLOBAL", "GLOBAL", "hydro", "rain_vs_flow_boxes")
us_table_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "hydro", "rain_vs_flow")

fig_dir <- file.path(DIR_FIGURE, "hydro", "rain_vs_flow_global")
table_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "hydro", "rain_vs_flow_global")

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Settings
# -----------------------------

# Latitude bands of the global grid, one 03_global_cell_stats.py task each
bands <- 0:7

weightings <- c("pop", "area")

# Snow-share groups for the snow test. Cuts are judgment calls: under 1% is
# effectively no snow, over 30% means much of the year's precipitation waits
# in the snowpack. Alternative: thirds of the snow share.
snow_breaks <- c(0, 0.01, 0.10, 0.30, Inf)
snow_labels <- c("Under 1%", "1-10%", "10-30%", "Over 30%")

ink <- "#0b0b0b"
ink_2 <- "#52514e"
muted <- "#898781"
# Land boxes without comparison data (no people); ocean is left white
no_data <- "#a9a79d"

# Same ramps as 02_rain_vs_flow_maps.R, from the dataviz reference palette
blue_light <- "#cde2fb"
blue_dark <- "#0d366b"
diverging_low <- "#e34948"
diverging_mid <- "#f0efec"
diverging_high <- "#1c5cab"

theme_update(
  plot.title = element_text(colour = ink, face = "bold", size = 10, margin = margin(b = 4)),
  plot.caption = element_text(colour = muted, hjust = 0),
  plot.caption.position = "plot",
  strip.text = element_text(colour = ink, face = "bold", hjust = 0, margin = margin(b = 2)),
  legend.title = element_text(colour = ink_2, size = 8),
  legend.text = element_text(colour = ink_2, size = 8),
  legend.position = "bottom",
  legend.title.position = "top",
  legend.key.width = unit(2.5, "cm"),
  legend.key.height = unit(0.25, "cm")
)

# Save each figure as a PDF (for slides and papers) and a PNG (for the HTML report)
save_figure <- function(name, plot, width, height) {
  ggsave(file.path(fig_dir, paste0(name, ".pdf")), plot, width = width, height = height, bg = "white")
  ggsave(file.path(fig_dir, paste0(name, ".png")), plot, width = width, height = height, dpi = 300, bg = "white")
}


# -----------------------------
# Read the box statistics
# -----------------------------

read_band <- function(band, stem) {
  read_csv(file.path(box_dir, paste0(stem, "_band", band, ".csv")), show_col_types = FALSE, progress = FALSE)
}

boxes <- bind_rows(lapply(bands, read_band, stem = "box_stats"))
band_summary <- bind_rows(lapply(bands, read_band, stem = "band_summary"))

stopifnot(
  setequal(band_summary$band, bands),
  anyDuplicated(boxes[c("box_row", "box_col")]) == 0,
  nrow(boxes) == sum(band_summary$n_boxes),
  sum(boxes$n_cells) == sum(band_summary$n_cells_complete)
)

# One row per box and weighting, with the statistics in plain column names
stat_columns <- c(
  "rain_mean", "flow_mean", "upstream_ratio", "corr_month", "corr_drought",
  "corr_flood", "rain_peak_month", "flow_peak_month", "peak_shift", "snow_share"
)

boxes_long <- bind_rows(lapply(weightings, function(w) {
  boxes %>%
    select(box_row, box_col, lat, lon, n_cells, pop, land_area_km2, all_of(paste0(stat_columns, "_", w))) %>%
    rename_with(~ sub(paste0("_", w, "$"), "", .x), all_of(paste0(stat_columns, "_", w))) %>%
    mutate(weights = w, .before = 1)
}))

# Boxes in the comparison: people in them, as every US county has, so both
# weightings use the same boxes; a positive upstream ratio (for the log
# scale) and all three correlations, as for counties in
# 01_rain_vs_flow_figures.R
boxes_long <- boxes_long %>%
  mutate(compared = pop > 0 & is.finite(upstream_ratio) & upstream_ratio > 0 &
           is.finite(corr_month) & is.finite(corr_drought) & is.finite(corr_flood))

cat("Boxes with land:", nrow(boxes), "\n")
cat("In the comparison:\n")
print(table(boxes_long$weights, boxes_long$compared))


# -----------------------------
# Coverage
# -----------------------------

# pop_total is LandScan 2011 on the ERA5-Land grid rows (57S to 84N), ocean
# cells included, so the shares show how much the comparison covers
compared_pop <- filter(boxes_long, weights == "pop", compared)

coverage <- tibble(
  n_cells_complete = sum(band_summary$n_cells_complete),
  n_boxes = nrow(boxes),
  n_boxes_compared = nrow(compared_pop),
  pop_total = sum(band_summary$pop_total),
  pop_compared = sum(compared_pop$pop),
  land_area_total_km2 = sum(band_summary$land_area_total_km2),
  land_area_compared_km2 = sum(compared_pop$land_area_km2)
) %>%
  mutate(
    pop_compared_share = pop_compared / pop_total,
    land_area_compared_share = land_area_compared_km2 / land_area_total_km2
  )

write_csv(coverage, file.path(table_dir, "coverage.csv"))
cat("\nCoverage:\n")
print(as.data.frame(coverage))


# -----------------------------
# Upstream-ratio thirds
# -----------------------------

# Three equal-size groups by upstream ratio, as for US counties, within each
# weighting. The cuts differ from the US ones and are kept in the table.
compared <- boxes_long %>%
  filter(compared) %>%
  group_by(weights) %>%
  mutate(group = as.character(ntile(upstream_ratio, 3))) %>%
  ungroup()

summarise_boxes <- function(rows, all_rows) {
  tibble(
    n_boxes = nrow(rows),
    pop_share = sum(rows$pop) / sum(all_rows$pop),
    ratio_min = min(rows$upstream_ratio),
    ratio_median = median(rows$upstream_ratio),
    ratio_max = max(rows$upstream_ratio),
    corr_month = median(rows$corr_month),
    corr_drought = median(rows$corr_drought),
    corr_flood = median(rows$corr_flood),
    share_peak_shifted = mean(rows$peak_shift != 0)
  )
}

group_summary <- bind_rows(lapply(weightings, function(w) {
  rows_w <- filter(compared, weights == w)
  bind_rows(
    lapply(c("1", "2", "3"), function(g) {
      summarise_boxes(filter(rows_w, group == g), rows_w) %>% mutate(group = g, .before = 1)
    }),
    summarise_boxes(rows_w, rows_w) %>% mutate(group = "all", .before = 1)
  ) %>%
    mutate(weights = w, .before = 1)
}))

write_csv(group_summary, file.path(table_dir, "group_summary.csv"))
cat("\nBoxes by upstream-ratio third (medians):\n")
print(as.data.frame(group_summary))


# -----------------------------
# Snow test
# -----------------------------

# Among boxes with little upstream water (the low third), differences between
# flow and rainfall cannot come from routing. If snow drives them, as it does
# in the US, the correlations should fall and the peak month shift more often
# as the snow share rises.
snow_summary <- compared %>%
  filter(group == "1") %>%
  mutate(snow = cut(snow_share, breaks = snow_breaks, labels = snow_labels, right = FALSE)) %>%
  filter(!is.na(snow)) %>%
  group_by(weights, snow) %>%
  summarise(
    n_boxes = n(),
    corr_month = median(corr_month),
    corr_drought = median(corr_drought),
    corr_flood = median(corr_flood),
    share_peak_shifted = mean(peak_shift != 0),
    .groups = "drop"
  )

write_csv(snow_summary, file.path(table_dir, "snow_summary.csv"))
cat("\nLow-third boxes by snow share (medians):\n")
print(as.data.frame(snow_summary))


# -----------------------------
# Maps (population weights)
# -----------------------------

# Every box with land; boxes outside the comparison (no people) are gray.
# Boxes are drawn by their row and column numbers, so the grid is exactly
# regular. Plain longitude-latitude, like the US maps, because PROJ does
# not work in the Midway R env (see 02_rain_vs_flow_maps.R).
map_boxes <- boxes_long %>%
  filter(weights == "pop") %>%
  mutate(
    across(c(upstream_ratio, corr_month, corr_drought, corr_flood, peak_shift), ~ ifelse(compared, .x, NA)),
    x = box_col,
    y = -box_row
  )

world <- coord_fixed(
  xlim = c(-0.5, max(boxes$box_col) + 0.5),
  ylim = c(-max(boxes$box_row) - 0.5, -min(boxes$box_row) + 0.5),
  expand = FALSE
)

# Figure G1: upstream ratio. Large river basins show as lines of high values.
# The scale stops at 10,000 (about the top of the US county range) and
# larger ratios are drawn darkest, so smaller rivers stay visible.
fig_ratio <- ggplot(map_boxes, aes(x, y, fill = upstream_ratio)) +
  geom_raster() +
  world +
  scale_fill_gradient(
    low = blue_light, high = blue_dark, transform = "log10",
    limits = c(1, 1e4), oob = scales::squish,
    labels = scales::label_comma(accuracy = 1), na.value = no_data,
    name = "Mean flow / mean rainfall (log scale; 10,000 and above drawn darkest)"
  ) +
  labs(
    title = "Upstream ratio: how much water flows in from outside the box",
    caption = paste0(
      "0.5-degree boxes, population-weighted means of ERA5-Land cells, 1950-2025. Rainfall: tp_total. ",
      "1 = no water from upstream.\nGray: land with no people (LandScan 2011). Ocean and Antarctica are left blank."
    )
  )

save_figure("G1_upstream_ratio", fig_ratio, width = 10, height = 5.4)

# Figure G2: the drought and flood measures, one panel each on one scale, so
# dark means the same thing in both. The few negative correlations are drawn
# as 0.
measure_labels <- c(
  corr_drought = "Drought measure (annual mean): correlation of flow with rainfall",
  corr_flood = "Flood measure (annual max): correlation of flow with rainfall"
)

drought_flood_long <- map_boxes %>%
  select(x, y, all_of(names(measure_labels))) %>%
  pivot_longer(all_of(names(measure_labels)), names_to = "measure", values_to = "corr") %>%
  mutate(measure = factor(measure_labels[measure], levels = measure_labels))

fig_drought_flood <- ggplot(drought_flood_long, aes(x, y, fill = corr)) +
  geom_raster() +
  world +
  facet_wrap(~ measure, ncol = 1) +
  scale_fill_gradient(
    low = blue_dark, high = blue_light, limits = c(0, 1), oob = scales::squish,
    na.value = no_data, name = "Correlation over 1950-2025 (darker = flow differs more from rainfall)"
  ) +
  labs(
    title = "Where the flow drought and flood measures differ from rainfall",
    caption = paste0(
      "Each box's annual mean and annual max of monthly values, flow against rainfall, correlated over 1950-2025.\n",
      "Population-weighted box means, built the same way for both series. Correlations below 0 are drawn as 0.\n",
      "Gray: land with no people (LandScan 2011)."
    )
  )

save_figure("G2_drought_flood", fig_drought_flood, width = 10, height = 10)

# Figure G3: shift in the peak month (-5 to 6, positive = flow peaks later)
fig_shift <- ggplot(map_boxes, aes(x, y, fill = peak_shift)) +
  geom_raster() +
  world +
  scale_fill_gradient2(
    low = diverging_low, mid = diverging_mid, high = diverging_high,
    midpoint = 0, limits = c(-6, 6), breaks = seq(-6, 6, by = 2), na.value = no_data,
    name = "Months from the rainfall peak to the flow peak (positive = flow peaks later)"
  ) +
  labs(
    title = "Does rainfall_flow peak in the same month as rainfall?",
    caption = paste0(
      "Peak month: the calendar month with the highest 1950-2025 mean, for each series, ",
      "population-weighted box means. Near-white: same peak month.\nGray: land with no people (LandScan 2011)."
    )
  )

save_figure("G3_peak_shift", fig_shift, width = 10, height = 5.4)

cat("\nFigures written to:", fig_dir, "\n")
cat("Tables written to:", table_dir, "\n")
