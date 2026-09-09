# ============================================================
# 04_make_urban_overleaf_panels.R
#
# Build large-format urban heterogeneity figure panels.
#
# This script makes larger versions of the urban-share figures and combines
# selected plots into multi-panel PDFs for Overleaf.
#
# The smaller standalone urban-share figures are made by
# `2_analysis/figures/02_plot_urban_heterogeneity.R`.
#
# These options control which panel files are made.
#   --outcome_model = levels | poisson
#   --make_panels = true | false
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(readr)
library(glue)
library(ggplot2)
library(MetBrewer)
library(grid)
library(gridExtra)


# -----------------------------
# Options
# -----------------------------

args <- commandArgs(FALSE)

# Use the value passed by sbatch, or the default if nothing is passed.
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# These options are usually set in the sbatch files
outcome_model <- get_arg("outcome_model", "levels")        # levels or Poisson
make_panels_arg <- tolower(get_arg("make_panels", "true")) # make combined Overleaf panels
make_panels <- make_panels_arg %in% c("true", "t", "1", "yes") # true/t/1/yes all mean make panels

weight_label <- "weighted" # this script only uses population-weighted urban responses

# The default weighted-levels run is kept in the older RF folder. Poisson output
# is stored under `weighted/poisson`.
out_suffix <- if (outcome_model == "levels") "" else file.path(weight_label, outcome_model)


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

# Keep this input path in step with `regressions/02_urban_heterogeneity.R`.
rf_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf", out_suffix)
rf_file <- paste("urban_heterogeneity", outcome_model, weight_label, sep = "_")
rf_file <- paste0(rf_file, ".csv")
rf_path <- file.path(rf_dir, rf_file)

fig_dir <- if (outcome_model == "poisson") {
  file.path(DIR_FIGURE, "regs", "urban", "poisson")
} else {
  file.path(DIR_FIGURE, "regs", "urban")
}

individual_dir <- file.path(fig_dir, "individual_figures")
panel_dir <- file.path(fig_dir, "final_panels")

dir.create(individual_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(panel_dir, recursive = TRUE, showWarnings = FALSE)

# In the RF file, `dy` is the estimate; `lo` and `hi` are low and high CI.
rf_urban <- read_csv(rf_path, show_col_types = FALSE)


# -----------------------------
# Plot settings
# -----------------------------

binary_defs <- c("binary_50", "binary_70")
categorical_defs <- c("equal_3", "equal_4", "equal_5")
urban_defs <- c(categorical_defs, binary_defs)

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

def_labels <- c(
  binary_50 = "Binary split: urban share <=50% vs >50%",
  binary_70 = "Binary split: urban share <=70% vs >70%",
  equal_3 = "3 urban-share bins",
  equal_4 = "4 urban-share bins",
  equal_5 = "5 urban-share bins"
)

spec_caption <- paste(
  if (outcome_model == "poisson") {
    "Population-weighted Poisson model."
  } else {
    "Population-weighted levels model."
  },
  "\nMain FE: age x admin unit and age x country x year;",
  "Saturated FE adds age x ADM1 x year."
)

y_axis_label <- if (outcome_model == "poisson") {
  expression(atop(Delta~deathrate, "relative to 0 mm"))
} else {
  "Change in annual deaths per 100,000\nrelative to 0 mm"
}

heatmap_fill_label <- if (outcome_model == "poisson") {
  expression(Delta~deathrate)
} else {
  "Deaths per\n100,000"
}

heatmap_number_format <- if (outcome_model == "poisson") "%.3f" else "%.1f"
core_zoom_ylim <- if (outcome_model == "poisson") c(-0.01, 0.03) else c(-30, 30)

# Keep urban-share groups in the same order across plots. The bin labels differ
# across the equal-bin and binary definitions, so each definition gets its own
# ordering.
order_urban_group <- function(data) {
  data %>%
    mutate(
      urban_group = case_when(
        urban_def_id == "equal_3" ~ factor(
          urban_group,
          levels = c("[0,33.3]", "(33.3,66.7]", "(66.7,100]")
        ),
        urban_def_id == "equal_4" ~ factor(
          urban_group,
          levels = c("[0,25]", "(25,50]", "(50,75]", "(75,100]")
        ),
        urban_def_id == "equal_5" ~ factor(
          urban_group,
          levels = c("[0,20]", "(20,40]", "(40,60]", "(60,80]", "(80,100]")
        ),
        urban_def_id == "binary_50" ~ factor(
          urban_group,
          levels = c("Urban share <= 50%", "Urban share > 50%")
        ),
        urban_def_id == "binary_70" ~ factor(
          urban_group,
          levels = c("Urban share <= 70%", "Urban share > 70%")
        ),
        TRUE ~ factor(urban_group)
      )
    )
}

# Larger text for the Overleaf panels.
large_theme <- function(base_size = 17) {
  theme_classic(base_size = base_size) +
    theme(
      legend.position = "bottom",
      legend.title = element_text(face = "bold", size = base_size),
      legend.text = element_text(size = base_size - 1),
      strip.text = element_text(face = "bold", size = base_size + 1),
      axis.title = element_text(face = "bold", size = base_size + 1),
      axis.text = element_text(size = base_size - 1),
      plot.caption = element_text(size = base_size - 3, color = "grey35", hjust = 0),
      plot.margin = margin(3, 6, 3, 6),
      panel.spacing = unit(0.8, "lines")
    )
}

save_pdf <- function(plot, file_stub, width, height, out_dir = individual_dir) {
  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")),
         plot, width = width, height = height)
}


# -----------------------------
# Individual figures
# -----------------------------

# Point estimates at selected rainfall values.
plot_thresholds <- function(def_id, mm_values = c(100, 150, 200, 300),
                            ylim = NULL, suffix = "thresholds") {
  plot_df <- rf_urban %>%
    filter(urban_def_id == def_id, x %in% mm_values) %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      precip = factor(paste0(x, " mm"), levels = paste0(mm_values, " mm"))
    ) %>%
    order_urban_group()
  
  pal <- met.brewer("Hokusai3", n = n_distinct(plot_df$urban_group))
  
  # Each point is one rainfall-response estimate with its confidence interval.
  p <- ggplot(plot_df, aes(precip, dy, ymin = lo, ymax = hi, color = urban_group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.55) +
    geom_pointrange(position = position_dodge(width = 0.70),
                    linewidth = 1.16, fatten = 5.2) +
    facet_grid(age_label ~ spec_short) +
    scale_color_manual(values = pal) +
    labs(x = "Daily precipitation", y = y_axis_label,
         color = "Urban group", caption = spec_caption) +
    large_theme()
  
  if (!is.null(ylim)) {
    p <- p + coord_cartesian(ylim = ylim)
  }
  
  file_stub <- paste0("urban_", def_id, "_", suffix)
  save_pdf(p, file_stub, width = 14.5, height = 9.8)
  
  p
}


# Full rainfall response curve from 0 to 300 mm.
plot_curves <- function(def_id) {
  plot_df <- rf_urban %>%
    filter(urban_def_id == def_id) %>%
    mutate(age_label = recode(as.character(agegroup), !!!age_labels)) %>%
    order_urban_group()
  
  pal <- met.brewer("Hokusai3", n = n_distinct(plot_df$urban_group))
  
  # Confidence intervals are shown around each urban-share response curve.
  p <- ggplot(plot_df, aes(x, dy, color = urban_group, fill = urban_group)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.55) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.13, color = NA) +
    geom_line(linewidth = 1.35) +
    facet_grid(age_label ~ spec_short) +
    scale_color_manual(values = pal) +
    scale_fill_manual(values = pal) +
    labs(x = "Daily precipitation (mm)", y = y_axis_label,
         color = "Urban group", fill = "Urban group", caption = spec_caption) +
    large_theme() +
    guides(fill = "none")
  
  file_stub <- paste0("urban_", def_id, "_curves")
  save_pdf(p, file_stub, width = 14.5, height = 9.8)
  
  p
}


# Heatmap at one rainfall value across age and urban-share groups.
plot_heatmap <- function(def_id, mm) {
  plot_df <- rf_urban %>%
    filter(urban_def_id == def_id, x == mm) %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      ci_clear = lo > 0 | hi < 0,
      label_color = if_else(ci_clear, "clear", "uncertain")
    ) %>%
    order_urban_group()
  
  # Dark outlines mark estimates whose confidence interval does not cross zero.
  p <- ggplot(plot_df, aes(urban_group, age_label, fill = dy)) +
    geom_tile(color = "white", linewidth = 0.9) +
    geom_tile(data = filter(plot_df, ci_clear), fill = NA,
              color = "grey10", linewidth = 1.1) +
    geom_text(aes(label = sprintf(heatmap_number_format, dy), color = label_color),
              size = 5.1) +
    facet_wrap(~spec_short, nrow = 1) +
    scale_fill_gradient2(
      low = "#3B6EA8", mid = "white", high = "#B64A3A",
      midpoint = 0, name = heatmap_fill_label
    ) +
    scale_color_manual(
      values = c("clear" = "black", "uncertain" = "grey10"),
      guide = "none"
    ) +
    labs(
      x = "Urban group", y = "Age group",
      caption = glue(
        "{mm} mm precipitation day, relative to 0 mm.\n",
        "Dark outlines mark cells with 95% CI excluding zero. {spec_caption}"
      )
    ) +
    large_theme() +
    theme(
      legend.position = "right",
      axis.text.x = element_text(angle = 25, hjust = 1, size = 14)
    )
  
  file_stub <- paste0("urban_", def_id, "_heatmap_", mm, "mm")
  save_pdf(p, file_stub, width = 14.5, height = 7.0)
  
  p
}


# Build the individual figures once and keep them for the combined panels.
plots <- list()

for (def_id in urban_defs) {
  plots[[paste(def_id, "thresholds", sep = "__")]] <- plot_thresholds(def_id)
  
  plots[[paste(def_id, "thresholds_core_zoom", sep = "__")]] <- plot_thresholds(
    def_id, mm_values = c(100, 150, 200),
    ylim = core_zoom_ylim, suffix = "thresholds_core_zoom"
  )
  
  plots[[paste(def_id, "curves", sep = "__")]] <- plot_curves(def_id)
  
  for (mm in c(150, 200, 300)) {
    plots[[paste(def_id, paste0("heatmap_", mm, "mm"), sep = "__")]] <-
      plot_heatmap(def_id, mm)
  }
}


# -----------------------------
# Panel figures
# -----------------------------

# Add a short title above each plot before combining them.
plot_grob <- function(plot, title = NULL, title_size = 18) {
  body <- ggplotGrob(plot)
  
  if (is.null(title)) {
    body
  } else {
    arrangeGrob(
      textGrob(
        title, x = 0.08, y = 0.08, hjust = 0, vjust = 0,
        gp = gpar(fontface = "bold", fontsize = title_size)
      ),
      body,
      heights = unit.c(unit(0.32, "in"), unit(1, "null"))
    )
  }
}

# Save one combined PDF panel.
save_panel <- function(grob, file_stub, width, height) {
  pdf(file.path(panel_dir, paste0(outcome_model, "_", file_stub, ".pdf")),
      width = width, height = height, onefile = FALSE)
  
  grid.draw(grob)
  dev.off()
}

# Binary urban-share definitions: <=50% vs >50%, and <=70% vs >70%.
make_binary_panel <- function(suffix, file_stub, width = 22, height = 9.4) {
  grobs <- lapply(binary_defs, function(def) {
    plot_grob(plots[[paste(def, suffix, sep = "__")]], def_labels[[def]])
  })
  
  save_panel(arrangeGrob(grobs = grobs, ncol = 2),
             file_stub, width, height)
}

# Equal-bin urban-share definitions: three, four, and five bins.
make_categorical_panel <- function(suffix, file_stub, width = 22, height = 15.0) {
  grobs <- lapply(categorical_defs, function(def) {
    plot_grob(plots[[paste(def, suffix, sep = "__")]], def_labels[[def]])
  })
  
  body <- arrangeGrob(
    grobs = list(grobs[[1]], grobs[[2]], grobs[[3]], nullGrob(), nullGrob()),
    layout_matrix = rbind(c(1, 1, 2, 2), c(4, 3, 3, 5)),
    heights = c(1, 1)
  )
  
  save_panel(body, file_stub, width, height)
}

# Heatmap panels for the binary urban-share definitions.
make_binary_heatmap_panel <- function(mm_values, file_stub, width, height) {
  grobs <- list()
  
  for (def in binary_defs) {
    for (mm in mm_values) {
      grobs[[length(grobs) + 1]] <- plot_grob(
        plots[[paste(def, paste0("heatmap_", mm, "mm"), sep = "__")]],
        paste0(def_labels[[def]], " | ", mm, " mm"),
        title_size = 17
      )
    }
  }
  
  save_panel(arrangeGrob(grobs = grobs, ncol = length(mm_values)),
             file_stub, width, height)
}

# Heatmap panels for the equal-bin urban-share definitions.
make_categorical_heatmap_panel <- function(mm_values, file_stub, width, height) {
  row_grobs <- lapply(categorical_defs, function(def) {
    arrangeGrob(
      grobs = lapply(mm_values, function(mm) {
        plot_grob(
          plots[[paste(def, paste0("heatmap_", mm, "mm"), sep = "__")]],
          paste0(def_labels[[def]], " | ", mm, " mm"),
          title_size = 17
        )
      }),
      ncol = length(mm_values)
    )
  })
  
  save_panel(arrangeGrob(grobs = row_grobs, ncol = 1),
             file_stub, width, height)
}


# -----------------------------
# Write panels
# -----------------------------

# Individual figures are always written above. Combined Overleaf panels are
# optional.
if (make_panels) {
  make_binary_panel("thresholds", "urban_binary_panel_thresholds")
  make_binary_panel("thresholds_core_zoom", "urban_binary_panel_thresholds_core_zoom")
  make_binary_panel("curves", "urban_binary_panel_curves")
  
  make_categorical_panel("curves", "urban_bins_panel_curves")
  make_categorical_panel("thresholds", "urban_bins_panel_thresholds")
  make_categorical_panel("thresholds_core_zoom", "urban_bins_panel_thresholds_core_zoom")
  
  make_binary_heatmap_panel(
    c(150, 300), "urban_binary_panel_heatmaps_150_300",
    width = 22, height = 12.7
  )
  make_categorical_heatmap_panel(
    c(150, 300), "urban_bins_panel_heatmaps_150_300",
    width = 22, height = 18.8
  )
  make_binary_heatmap_panel(
    c(150, 200, 300), "urban_binary_panel_heatmaps_150_200_300",
    width = 28, height = 12.7
  )
  make_categorical_heatmap_panel(
    c(150, 200, 300), "urban_bins_panel_heatmaps_150_200_300",
    width = 28, height = 18.8
  )
}

message("Wrote individual urban figures to: ", individual_dir)

if (make_panels) {
  message("Wrote final urban panels to: ", panel_dir)
}
