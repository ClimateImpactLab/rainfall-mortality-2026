# ============================================================================
# 03_heterogeneity_figures.R
#
# Figures of the 02 results, dry-side SPI-12, 0-4 and all age groups
# Each plots est (% change per 1 SD drier year) at t, t-1, total (t + t-1) and
# placebo (t+1), with 95% CIs
#
# Figures, each for 0-4 (_0to4) and every age group (_allages):
#  - het_terciles: terciles of each het var over all admin units
#  - het_2x2: the 2 x 2 cells, each var cut at the median over all admin units
#  - het_quintiles: 5 groups of each het var, total and placebo only, to see
#    the shape of the effect
# Terciles and 2 x 2s also have a _within version, cut inside each country
# (02 with --cut=within)
#
# Input: the 02 results in output/data/drought/global-annual/het/
# Output: output/data/drought/global-annual/het/figures/
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)


# -----------------------------
# Paths and labels
# -----------------------------

# results_dir (from 02) and figures_dir
source("paths.R")

HET_VARS <- c(baseline_prcp_mm = "Baseline rainfall", 
              baseline_prcp_cv = "Rainfall variability",
              log_gdppc = "Income",
              cropland_share = "Cropland share (EarthStat)",
              irrigated_share = "Irrigated share (HID)",
              urban_share = "Urban share (GHSL)",
              irrigated_share_spam = "Irrigated share (SPAM)",
              rainfed_share_land = "Rainfed area / land (SPAM)")

# The SPAM ones are only in the all-ages figure
MAIN_HET_VARS <- HET_VARS[1:6]

# 2 x 2 cells named after what they are, for ex "poor, low irrig."
PAIRS_2X2 <- list(
  `cropland_share x irrigated_share` = c(lo_lo = "low cropland,\nlow irrig.",
                                         hi_lo = "high cropland,\nlow irrig.",
                                         lo_hi = "low cropland,\nhigh irrig.",
                                         hi_hi = "high cropland,\nhigh irrig."),
  
  `log_gdppc x irrigated_share` = c(lo_lo = "poor,\nlow irrig.",
                                    hi_lo = "rich,\nlow irrig.",
                                    lo_hi = "poor,\nhigh irrig.",
                                    hi_hi = "rich,\nhigh irrig."),
  
  `log_gdppc x urban_share` = c(lo_lo = "poor,\nrural",
                                hi_lo = "rich,\nrural",
                                lo_hi = "poor,\nurban",
                                hi_hi = "rich,\nurban"),
  
  `irrigated_share x urban_share` = c(lo_lo = "low irrig.,\nrural",
                                      hi_lo = "high irrig.,\nrural",
                                      lo_hi = "low irrig.,\nurban",
                                      hi_hi = "high irrig.,\nurban")
)
PAIR_LABELS <- c(`cropland_share x irrigated_share` = "Cropland x irrigated share",
                 `log_gdppc x irrigated_share` = "Income x irrigated share",
                 `log_gdppc x urban_share` = "Income x urban share",
                 `irrigated_share x urban_share` = "Irrigated x urban share")

AGES <- c(`1` = "0-4", `2` = "5-64", `3` = "65+")
WINDOWS <- c(t = "t", `t-1` = "t-1", `t + t-1` = "total (t + t-1)", `t+1` = "t+1 (placebo)")
# Drought colors: t sand, t-1 rust, total dark red, placebo grey -  shapes differ too
COLORS <- c("#d0a23a", "#d4622b", "#9b1d2e", "grey60")
SHAPES <- c(17, 15, 16, 1)


# -----------------------------
# Plot and read functions
# -----------------------------

# One point per group and window, one panel per age group x het var
effect_plot <- function(df, x_label) {
  ggplot(df, aes(x = group, y = est, color = window, shape = window)) +
    geom_hline(yintercept = 0, color = "grey50") +
    geom_pointrange(aes(ymin = est - 1.96 * se, ymax = est + 1.96 * se),
                    position = position_dodge(width = 0.7), size = 0.3) +
    scale_color_manual(values = setNames(COLORS, WINDOWS)) +
    scale_shape_manual(values = setNames(SHAPES, WINDOWS)) +
    facet_grid(rows = vars(agegroup), cols = vars(het_var), scales = "free") +
    labs(x = x_label, y = "% change in annual deaths\nper 1 SD drier year", color = NULL, shape = NULL) +
    theme_bw(base_size = 9) + theme(legend.position = "bottom")
}

# Results with labels: windows, age groups, and the het var of each row
# suffix: "" for the cross version, "_within" for the within-country one
read_results <- function(part, suffix) {
  read_csv(file.path(results_dir, paste0("het_", part, "_spi12_dry", suffix, ".csv")), show_col_types = FALSE) %>%
    filter(window %in% names(WINDOWS)) %>%
    mutate(agegroup = factor(AGES[as.character(agegroup)], levels = AGES),
           window = factor(WINDOWS[window], levels = WINDOWS))
}


# -----------------------------
# Figures
# -----------------------------

# Same figures for both cuts: over all admin units, then inside each country
CUTS <- list(cross = list(suffix = "", tercile = "Tercile (over all admin units)",
                          cell = "Cell (each var cut at the median over all admin units)"),
             within = list(suffix = "_within", tercile = "Within-country tercile",
                           cell = "Cell (each var cut at the country median)"))

for (cut in CUTS) {
  # Terciles: keep the 3 terciles, not low - high
  terciles <- read_results("terciles", cut$suffix) %>%
    filter(bin %in% c("1_low", "2_mid", "3_high")) %>%
    mutate(het_var = factor(HET_VARS[model], levels = HET_VARS),
           group = factor(sub("^[0-9]_", "", bin), levels = c("low", "mid", "high")))
  ggsave(file.path(figures_dir, paste0("het_terciles_0to4", cut$suffix, ".pdf")),
         effect_plot(filter(terciles, agegroup == "0-4", het_var %in% MAIN_HET_VARS), cut$tercile),
         width = 10.5, height = 3.3)
  ggsave(file.path(figures_dir, paste0("het_terciles_allages", cut$suffix, ".pdf")),
         effect_plot(terciles, cut$tercile), width = 13.5, height = 6)

  # 2 x 2 cells: keep the 4 cells, not the gap between cells
  cells <- read_results("two_by_two", cut$suffix) %>%
    filter(bin %in% c("lo_lo", "hi_lo", "lo_hi", "hi_hi")) %>%
    mutate(group = mapply(function(pair, bin) PAIRS_2X2[[pair]][[bin]], model, bin),
           group = factor(group, levels = unique(unlist(PAIRS_2X2))),
           het_var = factor(PAIR_LABELS[model], levels = PAIR_LABELS))
  ggsave(file.path(figures_dir, paste0("het_2x2_0to4", cut$suffix, ".pdf")),
         effect_plot(filter(cells, agegroup == "0-4"), cut$cell), width = 13, height = 3.5)
  ggsave(file.path(figures_dir, paste0("het_2x2_allages", cut$suffix, ".pdf")),
         effect_plot(cells, cut$cell), width = 13, height = 6)
}
# Quintiles (over all admin units): total and placebo only, to see the shape
# of the effect from the bottom (q1) to the top (q5) of each het var
quintiles <- read_results("quintiles", "") %>%
  filter(bin %in% paste0("q", 1:5), window %in% WINDOWS[c("t + t-1", "t+1")]) %>%
  mutate(het_var = factor(HET_VARS[model], levels = HET_VARS), group = factor(bin, levels = paste0("q", 1:5)))
x_label <- "Fifth of the het var over all admin units, q1 bottom to q5 top (urban share: q1 = 0, then 4 equal groups)"
ggsave(file.path(figures_dir, "het_quintiles_0to4.pdf"),
       effect_plot(filter(quintiles, agegroup == "0-4"), x_label), width = 15, height = 3.3)
ggsave(file.path(figures_dir, "het_quintiles_allages.pdf"), effect_plot(quintiles, x_label), width = 15, height = 6)
message("wrote: ", figures_dir)
