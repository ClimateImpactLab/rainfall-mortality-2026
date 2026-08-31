# ============================================================
# 02_plot_urban_heterogeneity.R
#
# Plot the urban-share heterogeneity response functions
#
# This script reads the response-function CSV written by
# `regressions/02_urban_heterogeneity.R`
#
# It makes three views for each urban-share grouping:
# 1. point estimates at selected rainfall values
# 2. heatmaps at 150, 200, and 300 mm
# 3. full rainfall response curves from 0 to 300 mm
#
# These options must match the regression run being plotted
#   --weighted = true | false
#   --outcome_model = levels | poisson
#   --urban_defs = all | equal_3,equal_4,equal_5,binary_50,binary_70
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(glue)
library(ggplot2)
library(MetBrewer)

theme_set(theme_classic())


# -----------------------------
# Options
# -----------------------------

args <- commandArgs(FALSE)

# Use the value passed by sbatch, or the default if nothing is passed
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# These options are usually set in the sbatch files
weighted_arg <- tolower(get_arg("weighted", "true")) # use population weights
outcome_model <- get_arg("outcome_model", "levels")  # levels or Poisson
urban_defs_arg <- get_arg("urban_defs", "all")       # urban-share groupings to plot

weighted <- weighted_arg %in% c("true", "t", "1", "yes")   # true/t/1/yes all mean weighted
log_mort <- outcome_model == "poisson"                     # Poisson runs use the log-link model
model_label <- outcome_model                               # used in output file names
weight_label <- if (weighted) "weighted" else "unweighted" # used in output file names

# The default weighted-levels run is kept in the main RF folder
# Other runs are separated by weight and model
out_suffix <- if (weighted && !log_mort) "" else file.path(weight_label, model_label)


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

# Keep these paths in step with `regressions/02_urban_heterogeneity.R`
rf_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf", out_suffix)
fig_dir <- file.path(DIR_FIGURE, "regs", "analysis-panel", "urban", out_suffix)
rf_file <- paste0(paste("urban_heterogeneity", model_label, weight_label, sep = "_"), ".csv")

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

# `dy` is the response estimate, `lo` and `hi` are the confidence interval
# Rows are split by age group, FE specification, and urban-share group
rf_urban <- read_csv(file.path(rf_dir, rf_file), show_col_types = FALSE)


# -----------------------------
# Plot settings
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

# Caption shared by all urban-share figures
spec_caption <- paste(
  paste0(if (weighted) "Population-weighted" else "Unweighted", " model."),
  if (log_mort) "Poisson/log-link response." else "Death-rate levels response.",
  "Main FE: age x admin unit and age x country x year;",
  "Saturated FE adds age x ADM1 x year."
)

y_axis_label <- if (log_mort) {
  "Delta deathrate\nrelative to 0 mm"
} else {
  "Change in annual deaths per 100,000\nrelative to 0 mm"
}

all_urban_defs <- c("equal_3", "equal_4", "equal_5", "binary_50", "binary_70")

# Plot all urban-share definitions or a comma-separated subset
urban_defs <- if (urban_defs_arg == "all") {
  all_urban_defs
} else {
  trimws(strsplit(urban_defs_arg, ",", fixed = TRUE)[[1]])
}

bad_defs <- setdiff(urban_defs, all_urban_defs)
if (length(bad_defs) > 0) {
  stop("Unknown urban_defs value(s): ", paste(bad_defs, collapse = ", "))
}

# Keep the urban groups in the same order across plots
# Each definition has its own group labels and ordering
order_urban_group <- function(data) {
  equal3_levels <- c("[0,33.3]", "(33.3,66.7]", "(66.7,100]")
  equal4_levels <- c("[0,25]", "(25,50]", "(50,75]", "(75,100]")
  equal5_levels <- c("[0,20]", "(20,40]", "(40,60]", "(60,80]", "(80,100]")
  bin50_levels <- c("Urban share <= 50%", "Urban share > 50%")
  bin70_levels <- c("Urban share <= 70%", "Urban share > 70%")
  
  data %>%
    mutate(
      urban_group = case_when(
        urban_def_id == "equal_3" ~ factor(urban_group, levels = equal3_levels),
        urban_def_id == "equal_4" ~ factor(urban_group, levels = equal4_levels),
        urban_def_id == "equal_5" ~ factor(urban_group, levels = equal5_levels),
        urban_def_id == "binary_50" ~ factor(urban_group, levels = bin50_levels),
        urban_def_id == "binary_70" ~ factor(urban_group, levels = bin70_levels),
        TRUE ~ factor(urban_group)
      )
    )
}


# -----------------------------
# Plot functions
# -----------------------------

# Point estimates at selected rainfall values
plot_thresholds <- function(rf_data, def_id, file_stub,
                            mm_values = c(100, 150, 200, 300),
                            ylim = NULL, suffix = "thresholds") {
  plot_df <- rf_data %>%
    filter(urban_def_id == def_id, x %in% mm_values) %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      precip = factor(paste0(x, " mm"), levels = paste0(mm_values, " mm"))
    ) %>%
    order_urban_group()
  
  pal <- met.brewer("Hokusai3", n = n_distinct(plot_df$urban_group))
  
  # Each point is one response estimate with its confidence interval
  p <- ggplot(plot_df, aes(precip, dy, ymin = lo, ymax = hi, color = urban_group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.45) +
    geom_pointrange(position = position_dodge(width = 0.62), linewidth = 0.38) +
    facet_grid(age_label ~ spec_short) +
    scale_color_manual(values = pal) +
    labs(x = "Daily precipitation", y = y_axis_label,
         color = "Urban group", caption = spec_caption) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "bottom",
      legend.title = element_text(face = "bold"),
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 9, color = "grey35", hjust = 0)
    )
  
  if (!is.null(ylim)) {
    p <- p + coord_cartesian(ylim = ylim)
  }
  
  ggsave(file.path(fig_dir, paste0(file_stub, "_", suffix, ".pdf")),
         p, width = 12, height = 8)
}


# Heatmap at one rainfall value across age and urban-share groups
plot_heatmap <- function(rf_data, def_id, file_stub, mm = 200) {
  plot_df <- rf_data %>%
    filter(urban_def_id == def_id, x == mm) %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      ci_clear = lo > 0 | hi < 0,
      label_color = if_else(ci_clear, "clear", "uncertain")
    ) %>%
    order_urban_group()
  
  # Dark outlines mark estimates whose confidence interval does not cross zero
  p <- ggplot(plot_df, aes(urban_group, age_label, fill = dy)) +
    geom_tile(color = "white", linewidth = 0.8) +
    geom_tile(data = filter(plot_df, ci_clear), fill = NA,
              color = "grey10", linewidth = 0.95) +
    geom_text(aes(label = sprintf("%.1f", dy), color = label_color), size = 3.2) +
    facet_wrap(~spec_short, nrow = 1) +
    scale_fill_gradient2(
      low = "#3B6EA8", mid = "white", high = "#B64A3A",
      midpoint = 0, name = "Deaths per\n100,000"
    ) +
    scale_color_manual(
      values = c("clear" = "black", "uncertain" = "grey45"),
      guide = "none"
    ) +
    labs(
      x = "Urban group", y = "Age group",
      caption = glue(
        "{mm} mm precipitation day, relative to 0 mm. ",
        "Dark outlines mark cells with 95% CI excluding zero. {spec_caption}"
      )
    ) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "right",
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      axis.text.x = element_text(angle = 25, hjust = 1),
      plot.caption = element_text(size = 8.5, color = "grey35", hjust = 0),
      plot.margin = margin(8, 12, 8, 12)
    )
  
  ggsave(file.path(fig_dir, paste0(file_stub, "_heatmap_", mm, "mm.pdf")),
         p, width = 12.5, height = 5.8)
}


# Full rainfall response curve from 0 to 300 mm
plot_curves <- function(rf_data, def_id, file_stub) {
  plot_df <- rf_data %>%
    filter(urban_def_id == def_id) %>%
    mutate(age_label = recode(as.character(agegroup), !!!age_labels)) %>%
    order_urban_group()
  
  pal <- met.brewer("Hokusai3", n = n_distinct(plot_df$urban_group))
  
  # Confidence intervals are shown around each urban-share response curve
  p <- ggplot(plot_df, aes(x, dy, color = urban_group, fill = urban_group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.45) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.10, color = NA) +
    geom_line(linewidth = 0.8) +
    facet_grid(age_label ~ spec_short) +
    scale_color_manual(values = pal) +
    scale_fill_manual(values = pal) +
    labs(x = "Daily precipitation (mm)", y = y_axis_label,
         color = "Urban group", fill = "Urban group", caption = spec_caption) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "bottom",
      legend.title = element_text(face = "bold"),
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 9, color = "grey35", hjust = 0)
    ) +
    guides(fill = "none")
  
  ggsave(file.path(fig_dir, paste0(file_stub, "_curves.pdf")),
         p, width = 12, height = 8)
}


# -----------------------------
# Figures
# -----------------------------

# Make selected-effect plots, heatmaps, and full curves for each urban definition
for (def_id in urban_defs) {
  plot_thresholds(rf_urban, def_id, paste0("urban_", def_id))
  
  plot_thresholds(
    rf_urban, def_id, paste0("urban_", def_id),
    mm_values = c(100, 150, 200), ylim = c(-30, 30),
    suffix = "thresholds_core_zoom"
  )
  
  plot_heatmap(rf_urban, def_id, paste0("urban_", def_id), mm = 150)
  plot_heatmap(rf_urban, def_id, paste0("urban_", def_id), mm = 200)
  plot_heatmap(rf_urban, def_id, paste0("urban_", def_id), mm = 300)
  plot_curves(rf_urban, def_id, paste0("urban_", def_id))
}

message("Wrote urban figures to: ", fig_dir)
