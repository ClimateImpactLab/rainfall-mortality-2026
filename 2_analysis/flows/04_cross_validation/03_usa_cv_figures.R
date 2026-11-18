# ============================================================
# 03_usa_cv_figures.R
#
# Figures of the USA precip-vs-flow cross-validation
#
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)
library(sf)

theme_set(theme_classic())

# -----------------------------
# Project files
# -----------------------------

source("../../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY

K <- 5 # folds, as in 02_usa_cv_precip_vs_flow.R
MAP_CAP <- 0.3 # percent, color cap of the state map (display only)

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual")
cv_dir <- file.path(OUTPUT_DIR, "cv_precip_vs_flow")
figure_dir <- file.path(OUTPUT_DIR, "figures", "cv_precip_vs_flow")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

SHAPE_DIR <- "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/USA/Shapefile"

age_levels <- c("0-4", "5-64", "65+")
contrast_levels <- c("Precip - baseline", "Flow - baseline", "Precip - flow")
precip_col <- "#2166AC" # precip predicts better
flow_col <- "#D6604D"   # flow predicts better

# -----------------------------
# Shapes
# -----------------------------

outside_lower48 <- c("02", "15", "60", "66", "69", "72", "78")
lat_mid <- 38

states <- st_read(file.path(SHAPE_DIR, "tl_2016_us_state_mortality.shp"), quiet = TRUE) %>%
  filter(!ID_1 %in% outside_lower48)
st_crs(states) <- NA
st_geometry(states) <- st_geometry(states) * diag(c(cos(lat_mid * pi / 180), 1))
states <- st_simplify(states, dTolerance = 0.02, preserveTopology = TRUE)

# Polygons as plain data frames: geom_sf needs PROJ, which fails in this R environment
state_polygons <- {
  s <- st_cast(states, "MULTIPOLYGON")
  coords <- as.data.frame(st_coordinates(s))
  tibble(
    x = coords$X, y = coords$Y, id = s$ID_1[coords$L3],
    part = paste(coords$L3, coords$L2), ring = paste(coords$L3, coords$L2, coords$L1)
  )
}

# -----------------------------
# Figure 1: loss differences
# -----------------------------

diffs <- read_csv(file.path(cv_dir, paste0("usa_cv_diff_summary_k", K, ".csv")), show_col_types = FALSE) %>%
  mutate(
    age_label = factor(age_label, levels = age_levels),
    contrast_label = factor(contrast_label, levels = rev(contrast_levels))
  )

fig_diff <- ggplot(diffs, aes(x = diff, y = contrast_label)) +
  geom_vline(xintercept = 0, linewidth = 0.3, colour = "grey40") +
  geom_pointrange(aes(xmin = diff - se_diff, xmax = diff + se_diff), size = 0.35) +
  facet_wrap(~age_label, scales = "free_x", nrow = 1) +
  labs(
    x = "Difference in out-of-sample weighted RMSE (negative = first model predicts better); bars: +-1 SE",
    y = NULL, title = paste0(K, " folds")
  ) +
  theme(strip.background = element_blank(), strip.text = element_text(face = "bold"))

ggsave(file.path(figure_dir, paste0("fig_usa_cv_differences_k", K, ".pdf")), fig_diff, width = 10, height = 3, device = "pdf")

# -----------------------------
# Figure 2: state map
# -----------------------------

state_diff <- read_csv(
  file.path(cv_dir, paste0("usa_cv_state_losses_k", K, ".csv")),
  show_col_types = FALSE, col_types = cols(adm1_id = col_character())
) %>%
  mutate(
    age_label = factor(age_label, levels = age_levels),
    pct_precip_vs_flow = 100 * (precip - flow) / flow
  )

map_data <- state_polygons %>%
  inner_join(state_diff %>% select(id = adm1_id, age_label, pct_precip_vs_flow), by = "id", relationship = "many-to-many")

fig_map <- ggplot() +
  geom_polygon(data = state_polygons, aes(x, y, group = part, subgroup = ring), fill = "grey90", colour = NA) +
  geom_polygon(
    data = map_data, aes(x, y, group = part, subgroup = ring, fill = pct_precip_vs_flow),
    colour = "white", linewidth = 0.15
  ) +
  scale_fill_gradient2(
    low = precip_col, mid = "white", high = flow_col, midpoint = 0, limits = c(-MAP_CAP, MAP_CAP), oob = scales::squish,
    name = paste0("(Precip - flow) / flow,\nout-of-sample RMSE, %\nblue: precip better\norange: flow better\n(colors capped at +-", MAP_CAP, "%)")
  ) +
  facet_wrap(~age_label, ncol = 1) +
  coord_equal() +
  labs(title = paste0(K, " folds")) +
  theme_void() +
  theme(strip.text = element_text(face = "bold"), legend.position = "right")

ggsave(file.path(figure_dir, paste0("fig_usa_cv_state_map_k", K, ".pdf")), fig_map, width = 7, height = 11, device = "pdf")

message("Wrote figures to: ", figure_dir)
