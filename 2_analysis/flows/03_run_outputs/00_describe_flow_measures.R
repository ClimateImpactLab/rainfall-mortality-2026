# ============================================================
# 00_describe_flow_measures.R
#
# How the USA flow measures are built, and what they look like: the first two
# sections of the Overleaf document assembled by 02_make_overleaf_doc.R.
# Does not depend on any regression run.
#
#   - usa_flow_measures_section.tex: the steps from ERA5-Land rainfall to the
#     flow polynomial, the drought and flood measures, the z-scores, SPI and
#     bins, then the descriptive figures. Not a document on its own:
#     02_make_overleaf_doc.R pastes it in
#   - map of county mean flow, big-river counties outlined
#   - distributions of flow, the z-scores and SPI
#   - maps of the z-scores and SPI in 1988 and 1993
#   - big-river counties: mean flow vs mean precip, and their yearly flow
#     z-score and SPI next to local precip. Made but not in the document
#     (taken out of the Overleaf version on 2026-10-20)
#
# Sample: county-years 1970-2010 (the regression years) in the USA panel
# with non-missing flow measures and precip. One row per county-year: the
# measures repeat across age groups.
#
# Big-river counties: the 20 counties with the highest mean annual flow
# (flow_poly_1_pop) over 1970-2010. Flow is population-weighted, so these are
# the counties whose people live on cells that drain large areas.
#
# Map years: 1988 (drought) and 1993 (Great Flood), picked from the
# historical record, not from the data, as a check that the measures show
# known events.
#
# Maps: lower 48 states and DC, drawn as in
# 1_data/climate_data/climate_aggregation_global/hydro_era5land_admin/
# rain_vs_flow/02_rain_vs_flow_maps.R (no PROJ, longitude scaled by
# cos(38 degrees), shapes simplified for drawing).
#
# Inputs:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
#   flows/usa_annual/usa_annual_flow_regression_panel.rds
# /project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/
#   Countries/USA/Shapefile/tl_2016_us_{county,state}_mortality.shp
#   (the county shapes behind the admin weights, era5land_admin/settings.py)
#
# Outputs (output/data/flows/usa-annual/):
#   tables/descriptives/usa_flow_measures_section.tex
#   figures/descriptives/fig_usa_flow_mean_map.pdf
#                        fig_usa_flow_distributions.pdf
#                        fig_usa_flow_anomaly_maps.pdf
#                        fig_usa_big_river_flow_vs_prcp.pdf
#                        fig_usa_big_river_timeseries.pdf
#
# Dependencies: dplyr, tidyr, ggplot2, sf; ../../../0_utils/paths.R, so run
# this script from its own folder.
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(ggplot2)
library(sf)


# -----------------------------
# Project files and paths
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DATA_DIR, DIR_REPO_RAINFALL_MORTALITY

PANEL_FILE <- file.path(
  DATA_DIR, "climate_data", "ERA5-LAND", "flows", "usa_annual", "usa_annual_flow_regression_panel.rds"
)

# Shapefiles behind the USA admin weights (era5land_admin/settings.py). There
# is no paths.R global for norgay, so the folder is written out here, as in
# rain_vs_flow/02_rain_vs_flow_maps.R
SHAPE_DIR <- "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/USA/Shapefile"

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual")
table_dir <- file.path(OUTPUT_DIR, "tables", "descriptives")
figure_dir <- file.path(OUTPUT_DIR, "figures", "descriptives")
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Settings
# -----------------------------

FIRST_YEAR <- 1970  # regression years
LAST_YEAR <- 2010
N_BIG_RIVER <- 20   # big-river counties in the table, map and scatter
N_TIMESERIES <- 6   # big-river counties in the time series figure
MAP_YEARS <- c(1988, 1993) # drought and Great Flood years, from the historical record

# Lower 48 and DC only: Alaska, Hawaii and the territories would shrink the
# map. ID_1 is the state FIPS code
outside_lower48 <- c("02", "15", "60", "66", "69", "72", "78")

# Colors from rain_vs_flow/02_rain_vs_flow_maps.R
ink <- "#0b0b0b"
ink_2 <- "#52514e"
muted <- "#898781"
rule <- "#c3c2b7"
no_data <- "#a9a79d"
blue_light <- "#cde2fb"
blue_dark <- "#0d366b"
diverging_low <- "#e34948"
diverging_mid <- "#f0efec"
diverging_high <- "#1c5cab"

# Same measure colors as the coefficient plot in 01_usa_flow_reg_outputs.R
measure_labels <- c(
  flowmean_z_pop = "Annual mean flow z-score",
  flowmax_z_pop = "Annual max flow z-score",
  spi12_flow_pop = "Flow SPI"
)
measure_palette <- c(
  "Annual mean flow z-score" = "#0072B2",
  "Flow SPI" = "#009E73",
  "Local precip, standardized" = ink_2
)


# -----------------------------
# County-year measures
# -----------------------------

panel <- readRDS(PANEL_FILE)

# Panel counties with no flow at all (not among the flow files' counties)
counties_without_flow <- panel %>%
  group_by(admin_id, admin_name, adm1_name) %>%
  summarise(has_flow = any(!is.na(flowmean_pop_annual)), .groups = "drop") %>%
  filter(!has_flow)

# One row per county-year: the flow measures repeat across age groups
county_years <- panel %>%
  filter(year >= FIRST_YEAR, year <= LAST_YEAR) %>%
  distinct(admin_id, year, .keep_all = TRUE) %>%
  select(
    admin_id, admin_name, adm1_id, adm1_name, year, prcp_poly_1,
    flow_poly_1_pop, upstream_poly_1_pop, flowmean_z_pop, flowmax_z_pop,
    spi12_flow_pop, flow_clip_months_pop
  ) %>%
  filter(if_all(c(prcp_poly_1, flow_poly_1_pop, flowmean_z_pop, flowmax_z_pop, spi12_flow_pop), ~ !is.na(.x)))

if (anyDuplicated(county_years[c("admin_id", "year")]) > 0) {
  stop("County-year rows are not unique", call. = FALSE)
}

# County means over 1970-2010.
#   flow_month_mean: average month of flow (annual flow_poly_1 / 12), the
#     unit of the flow response curves
#   upstream_share: share of flow that fell upstream (both with negative
#     cells set to 0)
#   corr_flow_prcp: correlation of the county's annual flow and annual precip
county_summary <- county_years %>%
  group_by(admin_id, admin_name, adm1_id, adm1_name) %>%
  summarise(
    years = n(),
    flow_month_mean = mean(flow_poly_1_pop) / 12,
    prcp_year_mean = mean(prcp_poly_1),
    upstream_share = sum(upstream_poly_1_pop) / sum(flow_poly_1_pop),
    corr_flow_prcp = cor(flow_poly_1_pop, prcp_poly_1),
    .groups = "drop"
  ) %>%
  arrange(desc(flow_month_mean)) %>%
  mutate(flow_rank = row_number())

big_river <- county_summary %>%
  filter(flow_rank <= N_BIG_RIVER)

message(
  "Descriptive sample: ", nrow(county_years), " county-years, ",
  nrow(county_summary), " counties, ", FIRST_YEAR, "-", LAST_YEAR
)


# -----------------------------
# Shapes
# -----------------------------

# Same as rain_vs_flow/02_rain_vs_flow_maps.R. PROJ cannot open its database
# in the Midway R env, so the maps avoid PROJ: the coordinate system is
# dropped and longitude is scaled by cos(38 degrees), a plain
# longitude-latitude view of the lower 48 without east-west stretching.
# Shapes are simplified to about 0.02 degrees so the maps draw quickly. Both
# change how the maps look, not the data
lat_mid <- 38
read_shapes <- function(file) {
  shapes <- st_read(file.path(SHAPE_DIR, file), quiet = TRUE) %>%
    filter(!ID_1 %in% outside_lower48)
  st_crs(shapes) <- NA
  st_geometry(shapes) <- st_geometry(shapes) * diag(c(cos(lat_mid * pi / 180), 1))
  st_simplify(shapes, dTolerance = 0.02, preserveTopology = TRUE)
}

# The panel's admin_id is ID_1_ID_2 (state and county FIPS)
counties <- read_shapes("tl_2016_us_county_mortality.shp") %>%
  transmute(admin_id = paste(ID_1, ID_2, sep = "_"))
states <- read_shapes("tl_2016_us_state_mortality.shp")

if (anyDuplicated(counties$admin_id) > 0) {
  stop("County shapes are not unique by admin_id", call. = FALSE)
}

# Outlines as plain x-y coordinates, drawn with geom_polygon (geom_sf calls
# PROJ when it draws). `part` is one polygon of a county; `ring` marks each
# ring, so holes draw as holes
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

county_polygons <- to_polygons(counties, "admin_id")
state_polygons <- to_polygons(states, "ID_1")

state_lines <- geom_polygon(
  data = state_polygons, aes(x, y, group = part, subgroup = ring),
  fill = NA, colour = rule, linewidth = 0.15, inherit.aes = FALSE
)

# Gray base layer, so counties with no data stay visible
no_data_layer <- geom_polygon(
  data = county_polygons, aes(x, y, group = part, subgroup = ring),
  fill = no_data, colour = NA, inherit.aes = FALSE
)

map_theme <- theme_void(base_size = 10) +
  theme(
    plot.title = element_text(colour = ink, face = "bold", size = 10, margin = margin(b = 8)),
    plot.caption = element_text(colour = muted, hjust = 0),
    plot.caption.position = "plot",
    strip.text = element_text(colour = ink, face = "bold", margin = margin(b = 2, t = 2)),
    legend.position = "bottom",
    legend.title.position = "top",
    legend.title = element_text(colour = ink_2, size = 8),
    legend.text = element_text(colour = ink_2, size = 8),
    legend.key.width = unit(2.5, "cm"),
    legend.key.height = unit(0.3, "cm")
  )


# -----------------------------
# Figure: map of mean flow
# -----------------------------

mean_map <- inner_join(county_polygons, county_summary, by = c("id" = "admin_id"))
big_river_outlines <- filter(county_polygons, id %in% big_river$admin_id)

fig_mean_map <- ggplot(mean_map, aes(x, y, group = part, subgroup = ring, fill = flow_month_mean)) +
  no_data_layer +
  geom_polygon(colour = NA) +
  state_lines +
  geom_polygon(
    data = big_river_outlines, aes(x, y, group = part, subgroup = ring),
    fill = NA, colour = ink, linewidth = 0.35, inherit.aes = FALSE
  ) +
  coord_fixed() +
  scale_fill_gradient(
    low = blue_light, high = blue_dark, transform = "log10",
    labels = scales::label_comma(), na.value = no_data,
    name = "Average month of flow (mm summed over the cell and upstream cells, log scale)"
  ) +
  labs(
    title = "County mean flow, 1970-2010 (flow_poly_1 / 12)",
    caption = paste0(
      "Population-weighted county mean of monthly cell flow, averaged over 1970-2010.\n",
      "Black outlines: the ", N_BIG_RIVER, " big-river counties (highest mean flow). Gray: no data."
    )
  ) +
  map_theme

ggsave(file.path(figure_dir, "fig_usa_flow_mean_map.pdf"), fig_mean_map, width = 6.5, height = 4.8, bg = "white")


# -----------------------------
# Figure: distributions
# -----------------------------

distribution_levels <- c("Average month of flow (log10)", unname(measure_labels))

distributions <- county_years %>%
  transmute(
    `Average month of flow (log10)` = log10(flow_poly_1_pop / 12),
    `Annual mean flow z-score` = flowmean_z_pop,
    `Annual max flow z-score` = flowmax_z_pop,
    `Flow SPI` = spi12_flow_pop
  ) %>%
  pivot_longer(everything(), names_to = "measure", values_to = "value") %>%
  mutate(measure = factor(measure, levels = distribution_levels))

fig_distributions <- ggplot(distributions, aes(value)) +
  geom_histogram(bins = 60, fill = diverging_high, colour = NA) +
  facet_wrap(~ measure, scales = "free", nrow = 2) +
  labs(
    x = NULL,
    y = "County-years",
    caption = paste0(
      "One row per county-year, ", FIRST_YEAR, "-", LAST_YEAR, ". Flow on a log10 scale ",
      "(mm summed over the cell and upstream cells);\nthe z-scores and SPI are unitless."
    )
  ) +
  theme_classic(base_size = 11) +
  theme(
    strip.background = element_blank(),
    strip.text = element_text(face = "bold"),
    plot.caption = element_text(colour = muted, hjust = 0)
  )

ggsave(file.path(figure_dir, "fig_usa_flow_distributions.pdf"), fig_distributions, width = 8, height = 6)


# -----------------------------
# Figure: z-score and SPI maps
# -----------------------------

anomalies <- county_years %>%
  filter(year %in% MAP_YEARS) %>%
  select(admin_id, year, all_of(names(measure_labels))) %>%
  pivot_longer(all_of(names(measure_labels)), names_to = "measure", values_to = "value") %>%
  mutate(measure = factor(unname(measure_labels[measure]), levels = unname(measure_labels)))

anomaly_map <- county_polygons %>%
  inner_join(anomalies, by = c("id" = "admin_id"), relationship = "many-to-many")

fig_anomaly_maps <- ggplot(anomaly_map, aes(x, y, group = part, subgroup = ring, fill = value)) +
  no_data_layer +
  geom_polygon(colour = NA) +
  state_lines +
  coord_fixed() +
  facet_grid(measure ~ year, switch = "y") +
  scale_fill_gradient2(
    low = diverging_low, mid = diverging_mid, high = diverging_high,
    midpoint = 0, limits = c(-3, 3), oob = scales::squish,
    name = "Dry (red) to wet (blue). z-scores in SDs of the previous 20 years; SPI on the standard normal scale. Capped at +/-3"
  ) +
  labs(
    title = "Flow z-scores and SPI in a drought year and a flood year",
    caption = paste0(
      "1988 drought and 1993 Great Flood, picked from the historical record, not from the data.\n",
      "Gray: no data."
    )
  ) +
  map_theme +
  theme(strip.text.y.left = element_text(angle = 90))

ggsave(file.path(figure_dir, "fig_usa_flow_anomaly_maps.pdf"), fig_anomaly_maps, width = 8, height = 8.5, bg = "white")


# -----------------------------
# Figure: big-river counties, flow vs precip
# -----------------------------

fig_flow_vs_prcp <- ggplot(county_summary, aes(prcp_year_mean, flow_month_mean)) +
  geom_point(colour = muted, alpha = 0.35, size = 0.8) +
  geom_point(data = big_river, colour = blue_dark, size = 1.6) +
  geom_text(data = big_river, aes(label = flow_rank), colour = blue_dark, size = 2.6, vjust = -0.7) +
  scale_y_log10(labels = scales::label_comma()) +
  labs(
    x = "Mean annual precipitation, 1970-2010 (mm)",
    y = "Average month of flow, 1970-2010\n(mm summed over upstream cells, log scale)",
    caption = paste0(
      "One point per county. Numbered: the ", N_BIG_RIVER,
      " big-river counties, by rank in the big-river table."
    )
  ) +
  theme_classic(base_size = 11) +
  theme(plot.caption = element_text(colour = muted, hjust = 0))

ggsave(file.path(figure_dir, "fig_usa_big_river_flow_vs_prcp.pdf"), fig_flow_vs_prcp, width = 7, height = 5)


# -----------------------------
# Figure: big-river county time series
# -----------------------------

# Local precip is standardized within each county over 1970-2010, only so it
# can share an axis with the flow z-score and SPI. It is not a reg variable
timeseries <- county_years %>%
  inner_join(
    big_river %>% filter(flow_rank <= N_TIMESERIES) %>% select(admin_id, flow_rank),
    by = "admin_id"
  ) %>%
  group_by(admin_id) %>%
  mutate(prcp_std = (prcp_poly_1 - mean(prcp_poly_1)) / sd(prcp_poly_1)) %>%
  ungroup() %>%
  mutate(county = paste0(flow_rank, ". ", admin_name, ", ", adm1_name)) %>%
  select(county, flow_rank, year, flowmean_z_pop, spi12_flow_pop, prcp_std) %>%
  pivot_longer(c(flowmean_z_pop, spi12_flow_pop, prcp_std), names_to = "measure", values_to = "value") %>%
  mutate(
    measure = recode(
      measure,
      flowmean_z_pop = "Annual mean flow z-score",
      spi12_flow_pop = "Flow SPI",
      prcp_std = "Local precip, standardized"
    ),
    measure = factor(measure, levels = names(measure_palette)),
    county = reorder(county, flow_rank)
  )

fig_timeseries <- ggplot(timeseries, aes(year, value, colour = measure)) +
  geom_hline(yintercept = 0, colour = "grey75", linewidth = 0.4) +
  geom_line(linewidth = 0.6) +
  facet_wrap(~ county, ncol = 2) +
  scale_colour_manual(values = measure_palette) +
  labs(
    x = NULL,
    y = "SDs (z-score, local precip) or standard normal (SPI)",
    colour = NULL,
    caption = paste0(
      "The ", N_TIMESERIES, " counties with the highest mean flow. Local precip: annual ",
      "precipitation standardized within the county over ", FIRST_YEAR, "-", LAST_YEAR, ".\n",
      "The flow z-score uses the county's previous 20 years instead."
    )
  ) +
  theme_classic(base_size = 11) +
  theme(
    legend.position = "bottom",
    strip.background = element_blank(),
    strip.text = element_text(face = "bold"),
    plot.caption = element_text(colour = muted, hjust = 0)
  )

ggsave(file.path(figure_dir, "fig_usa_big_river_timeseries.pdf"), fig_timeseries, width = 8, height = 7.5)


# -----------------------------
# TeX helpers
# -----------------------------

fmt_count <- function(x) {
  format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
}

# Escape characters TeX would read as commands (_, %, &, ...)
latex_escape <- function(x) {
  x <- as.character(x)
  x <- gsub("\\\\", "\\\\textbackslash{}", x)
  x <- gsub("([#$%&_{}])", "\\\\\\1", x, perl = TRUE)
  x <- gsub("~", "\\\\textasciitilde{}", x)
  x <- gsub("\\^", "\\\\textasciicircum{}", x)
  x
}

# Same figure block as 02_make_overleaf_doc.R: figures/ is the folder next to
# the document, where 02_make_overleaf_doc.R copies the figures
figure_tex <- function(file, caption, label) {
  c(
    "\\begin{figure}[!htbp]",
    "\\centering",
    paste0("\\includegraphics[width=\\textwidth,height=0.8\\textheight,keepaspectratio]{figures/", file, "}"),
    paste0("\\caption{", caption, "}"),
    paste0("\\label{", label, "}"),
    "\\end{figure}",
    ""
  )
}


# -----------------------------
# Measures TeX
# -----------------------------

# Wording follows the Overleaf version edited on 2026-10-20 (shorter steps,
# no script names, no big-river table or figures). The scripts behind each
# step are named in the header of 01_measures/01_build_flow_measures.R

# Counties with no flow value in any year. 01_build_usa_panel.R checks which
# are missing from the flow files altogether (two Alaska counties); others can
# be in the files with missing flow, so no reason is given here
without_flow_text <- if (nrow(counties_without_flow) == 0) {
  "Every panel county has flow."
} else {
  paste0(
    nrow(counties_without_flow), " panel counties have no flow value in any year and are ",
    "dropped from the regressions: ",
    latex_escape(paste(
      paste0(counties_without_flow$admin_name, ", ", counties_without_flow$adm1_name),
      collapse = "; "
    )),
    "."
  )
}

construction_lines <- c(
  "\\section{Flow measures}",
  "",
  "\\noindent How I went from ERA5-Land rainfall to the measures in the regressions:",
  "\\begin{enumerate}",
  paste(
    "\\item \\textbf{Rainfall.} ERA5-Land daily total precipitation minus the daily",
    "change in snow water equivalent, aggregated to the monthly level on the",
    "0.1-degree grid. Snowfall that is stored as snow is removed and snowmelt is",
    "added on melt days. Because it is a residual, rainfall is negative where the",
    "snowpack grows faster than precipitation."
  ),
  paste(
    "\\item \\textbf{River network.} D8 flow directions from TauDEM",
    "(\\texttt{pit removal}, then \\texttt{d8flowdir}) on ERA5-Land orography at",
    "0.1 degrees: every cell drains into one of its eight neighbours."
  ),
  paste(
    "\\item \\textbf{Flow.} For each month, a cell's flow is its own rainfall plus the",
    "flow of every cell that drains into it, accumulated downstream over the global",
    "grid (\\path{hydro/coarse/prepflow.py}). Flow is measured in mm summed over cells."
  ),
  paste(
    "\\item \\textbf{Upstream inflow.} A cell's flow minus its own rainfall: the rain",
    "that fell upstream and flowed in."
  ),
  paste(
    "\\item \\textbf{County values.} Weighted means over each county's grid cells, with",
    "LandScan 2011 population weights on the 2016 TIGER county shapes."
  ),
  paste(
    "\\item \\textbf{Flow polynomial} Each cell's monthly flow, with negative values set",
    "to 0, raised to the power $k$, then the population-weighted county mean, summed",
    "over the 12 months of the year. This is similar to how the precip polynomial is",
    "built, except that its powers are taken on daily rather than monthly cell values.",
    "The upstream polynomial is built the same way from upstream inflow."
  ),
  "\\item \\textbf{Negative flow.} Negative cells are set to 0 for the polynomials only.",
  paste(
    "\\item \\textbf{Drought measure}: the annual mean of the county's 12 monthly flow",
    "values. \\textbf{Flood measure}: each cell's highest monthly flow in the year, then",
    "the population-weighted county mean."
  ),
  paste(
    "\\item \\textbf{z-scores} $Z^{\\text{mean}}_{it}$, $Z^{\\text{max}}_{it}$: the year's",
    "drought (flood) measure minus the mean of the county's 20 previous years, divided",
    "by their standard deviation. All 20 years are required and flow starts in 1950,",
    "so the first z-score is for 1970."
  ),
  paste(
    "\\item \\textbf{SPI}: the county's calendar-year mean flow, turned into a",
    "probability under a gamma distribution fitted to the county's 1981--2010 values,",
    "then put on the standard normal scale. Wet years are positive. Built like the",
    "Brazil SPI."
  ),
  # New with the bins regs (not in the 2026-10-20 Overleaf version)
  paste(
    "\\item \\textbf{Drought and flood bins}: where the year's drought (annual mean) and",
    "flood (annual max) measures fall among the county's 20 previous years (the",
    "z-score baseline), with the cutoffs of the Brazil rainfall bins. Drought: the",
    "driest 10\\% or the 10th--25th percentile of the annual mean. Flood: the",
    "75th--90th percentile or the wettest 10\\% of the annual max. With 20 baseline",
    "years, each bin covers 3 of the 21 possible ranks of a year among its 20 previous",
    "years: for example, the driest 10\\% is a year below all but at most 2 of them."
  ),
  paste(
    "\\item \\textbf{Merge.} The measures are merged into the USA mortality panel by",
    "county and year.",
    without_flow_text
  ),
  "\\end{enumerate}",
  ""
)

# -------- Descriptive section --------

descriptive_lines <- c(
  "\\section{The flow measures in the regression years}",
  "",
  paste0(
    "\\noindent One row per county-year, ", FIRST_YEAR, "--", LAST_YEAR, ": ",
    fmt_count(nrow(county_years)), " county-years in ", fmt_count(nrow(county_summary)),
    " counties. Flow depends on how much land drains into a county's populated cells, ",
    "so its level is mostly geography."
  ),
  "",
  figure_tex(
    "fig_usa_flow_mean_map.pdf",
    paste0("County mean flow, ", FIRST_YEAR, "--", LAST_YEAR, ". Black outlines: big-river counties."),
    "fig:usa-flow-mean-map"
  ),
  figure_tex(
    "fig_usa_flow_distributions.pdf",
    "Distributions of flow, the flow z-scores and the flow SPI, one row per county-year.",
    "fig:usa-flow-distributions"
  ),
  figure_tex(
    "fig_usa_flow_anomaly_maps.pdf",
    paste(
      "Flow z-scores and SPI in 1988 (drought, covered Midwest and High Plains) and",
      "1993 (Great Flood, upper Mississippi and Missouri River)."
    ),
    "fig:usa-flow-anomaly-maps"
  )
)

writeLines(
  c(construction_lines, descriptive_lines),
  file.path(table_dir, "usa_flow_measures_section.tex")
)

message("Wrote measures section to: ", table_dir)
message("Wrote descriptive figures to: ", figure_dir)
