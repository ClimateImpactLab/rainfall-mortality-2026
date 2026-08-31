# ============================================================
# 01_plot_main_response.R
#
# Plot the main rainfall and temperature response functions
#
# This script reads the response-function CSV written by
# `regressions/01_main_response.R`
#
# It makes two kinds of figures:
# 1. full rainfall and temperature response curves
# 2. point estimates at selected rainfall and temperature values
#
# These options must match the regression run being plotted
#   --outcome_model = levels | poisson
#   --response = precip | temp | both
#   --spec_set = main_two | four_spec
#   --weighted = true | false
#   --prcp_order = 2 | 3 | 4 | 5
#   --wind_control = none | windmax | winddays | both
#   --daily_overlap_control = none | rain100 | rain200 | both
#   --daily_overlap_exclusion = none | rain100 | rain200
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
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
outcome_model <- get_arg("outcome_model", "levels")  # levels or Poisson
response <- get_arg("response", "both")              # rainfall, temperature, or both
spec_set <- get_arg("spec_set", "main_two")          # main specs or four-spec comparison
weighted_arg <- tolower(get_arg("weighted", "true")) # use population weights
prcp_order <- as.integer(get_arg("prcp_order", "3")) # rainfall polynomial order
wind_control <- get_arg("wind_control", "none")      # annual wind controls
daily_overlap_control <- get_arg("daily_overlap_control", "none")     # rain-wind overlap controls
daily_overlap_exclusion <- get_arg("daily_overlap_exclusion", "none") # drop rain-wind overlap years

weighted <- weighted_arg %in% c("true", "t", "1", "yes")   # true/t/1/yes all mean weighted
log_mort <- outcome_model == "poisson"                     # Poisson runs use the log-link model
weight_label <- if (weighted) "weighted" else "unweighted" # used in output file names


# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")


# -----------------------------
# Input and output paths
# -----------------------------

# Match the run ID used by the regression script
run_id <- paste(spec_set, outcome_model, paste0("p", prcp_order), weight_label, sep = "_")

if (wind_control != "none") {
  run_id <- paste(run_id, wind_control, sep = "_")
}
if (daily_overlap_control != "none") {
  run_id <- paste(run_id, paste0("overlapctl_", daily_overlap_control), sep = "_")
}
if (daily_overlap_exclusion != "none") {
  run_id <- paste(run_id, paste0("exclude_overlap_", daily_overlap_exclusion), sep = "_")
}

rf_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf",
  "analysis-panel", "main-response"
)

fig_dir <- file.path(
  DIR_FIGURE, "regs", "analysis-panel", "main-response",
  spec_set, outcome_model, weight_label
)

rf_file <- file.path(rf_dir, paste0("rf.main_response.", run_id, ".csv"))

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

# `dy` is the response estimate, `lo` and `hi` are the confidence interval
rf_main <- read_csv(rf_file, show_col_types = FALSE)


# -----------------------------
# Plot settings
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")
age_palette <- met.brewer("Hokusai3", n = length(unique(rf_main$agegroup)))

# Use the fixed-effect labels saved by the regression script
spec_labels <- rf_main %>%
  distinct(spec_id, spec_label) %>%
  { setNames(.$spec_label, .$spec_id) }

# Default y-axis label, replaced below by the rainfall or temperature reference
y_axis_label <- if (log_mort) {
  expression(atop(Delta~deathrate, "relative to reference"))
} else {
  "Change in annual deaths per 100,000\nrelative to reference"
}

# Caption for the two main specifications or the four-spec comparison
spec_caption <- if (spec_set == "main_two") {
  paste(
    "Main FE: age x admin unit and age x country x year.",
    "Saturated FE additionally includes age x ADM1 x year."
  )
} else {
  "Four fixed-effect specifications shown in panel titles."
}

# Add the annual wind-control choice to the figure caption
wind_caption <- switch(
  wind_control,
  none = "No annual wind control",
  windmax = "Controls for annual population-weighted extreme wind",
  winddays = "Controls for annual population-weighted high-wind days",
  both = "Controls for annual extreme wind and annual high-wind days"
)

spec_caption <- paste(spec_caption, wind_caption)


# -----------------------------
# Plot functions
# -----------------------------

# Plot the full rainfall or temperature response curve
plot_response_curves <- function(rf_data, xlab, ylab, file_stub,
                                 nrow = 1, width = 12, height = 5.8) {
  
  plot_df <- rf_data %>%
    mutate(age_label = recode(as.character(agegroup), !!!age_labels))
  
  # Use the full specification labels for the four-spec comparison
  facet_layer <- if (spec_set == "four_spec") {
    facet_wrap(
      ~ spec_id,
      nrow = nrow,
      labeller = labeller(spec_id = spec_labels)
    )
  } else {
    facet_wrap(~ spec_short, nrow = nrow)
  }
  
  # Plot the response estimate and confidence interval
  p <- ggplot(plot_df, aes(x, dy, color = age_label, fill = age_label)) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.16, color = NA) +
    geom_line(linewidth = 1) +
    facet_layer +
    scale_color_manual(values = age_palette) +
    scale_fill_manual(values = age_palette) +
    labs(
      x = xlab,
      y = ylab,
      color = "Age group",
      fill = "Age group",
      caption = spec_caption
    ) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "bottom",
      legend.title = element_text(face = "bold"),
      strip.text = element_text(
        face = "bold",
        size = if (spec_set == "four_spec") 10.5 else 12
      ),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 9, color = "grey35", hjust = 0),
      plot.margin = margin(8, 12, 8, 12),
      panel.spacing = unit(1.2, "lines")
    ) +
    guides(fill = "none")
  
  ggsave(
    file.path(fig_dir, paste0(file_stub, ".pdf")),
    p,
    width = width,
    height = height
  )
}

# Plot point estimates at selected rainfall or temperature values
plot_selected_effects <- function(rf_data, selected_x, x_label, file_stub,
                                  ylab = y_axis_label, width = 12, height = 5.8) {
  
  plot_df <- rf_data %>%
    filter(x %in% selected_x) %>%
    mutate(
      age_label = recode(as.character(agegroup), !!!age_labels),
      x_bin = factor(
        paste0(x, " ", x_label),
        levels = paste0(selected_x, " ", x_label)
      )
    )
  
  # Use the same faceting as the full response curves
  facet_layer <- if (spec_set == "four_spec") {
    facet_wrap(
      ~ spec_id,
      nrow = 2,
      labeller = labeller(spec_id = spec_labels)
    )
  } else {
    facet_wrap(~ spec_short, nrow = 1)
  }
  
  # Plot each selected response estimate with its confidence interval
  p <- ggplot(
    plot_df,
    aes(x_bin, dy, ymin = lo, ymax = hi, color = age_label)
  ) +
    geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
    geom_pointrange(
      position = position_dodge(width = 0.55),
      linewidth = 0.45
    ) +
    facet_layer +
    scale_color_manual(values = age_palette) +
    labs(
      x = NULL,
      y = ylab,
      color = "Age group",
      caption = spec_caption
    ) +
    theme_classic(base_size = 12) +
    theme(
      legend.position = "bottom",
      legend.title = element_text(face = "bold"),
      strip.text = element_text(
        face = "bold",
        size = if (spec_set == "four_spec") 10.5 else 12
      ),
      axis.title = element_text(face = "bold"),
      plot.caption = element_text(size = 9, color = "grey35", hjust = 0),
      axis.text.x = element_text(
        angle = if (spec_set == "four_spec") 20 else 0,
        hjust = 1
      )
    )
  
  ggsave(
    file.path(fig_dir, paste0(file_stub, ".pdf")),
    p,
    width = width,
    height = height
  )
}


# -----------------------------
# Precipitation figures
# -----------------------------

if (response %in% c("precip", "both")) {
  precip_rf <- rf_main %>%
    filter(id == "Precipitation")
  
  # Full precipitation response from 0 to 300 mm, relative to 0 mm
  plot_response_curves(
    precip_rf,
    xlab = "Daily precipitation (mm)",
    ylab = if (log_mort) {
      expression(atop(Delta~deathrate, "relative to 0 mm"))
    } else {
      "Change in annual deaths per 100,000\nrelative to 0 mm"
    },
    file_stub = paste("precip_response", run_id, sep = "_"),
    nrow = if (spec_set == "four_spec") 2 else 1,
    width = if (spec_set == "four_spec") 13.5 else 12,
    height = if (spec_set == "four_spec") 9.5 else 5.8
  )
  
  # Point estimates at selected precipitation values
  plot_selected_effects(
    precip_rf,
    selected_x = c(100, 150, 200, 300),
    x_label = "mm",
    file_stub = paste("precip_selected_effects", run_id, sep = "_"),
    ylab = if (log_mort) {
      expression(atop(Delta~deathrate, "relative to 0 mm"))
    } else {
      "Change in annual deaths per 100,000\nrelative to 0 mm"
    },
    width = if (spec_set == "four_spec") 13.5 else 12,
    height = if (spec_set == "four_spec") 9.5 else 5.8
  )
}


# -----------------------------
# Temperature figures
# -----------------------------

if (response %in% c("temp", "both")) {
  temp_rf <- rf_main %>%
    filter(id == "Temperature")
  
  # Full temperature response relative to 27 C
  plot_response_curves(
    temp_rf,
    xlab = "Daily average temperature (C)",
    ylab = if (log_mort) {
      expression(atop(Delta~deathrate, "relative to 27 C"))
    } else {
      "Change in annual deaths per 100,000\nrelative to 27 C"
    },
    file_stub = paste("temperature_response", run_id, sep = "_"),
    nrow = if (spec_set == "four_spec") 2 else 1,
    width = if (spec_set == "four_spec") 13.5 else 12,
    height = if (spec_set == "four_spec") 9.5 else 5.8
  )
  
  # Point estimates at selected temperature values
  plot_selected_effects(
    temp_rf,
    selected_x = c(0, 10, 20, 30, 35, 40),
    x_label = "C",
    file_stub = paste("temperature_selected_effects", run_id, sep = "_"),
    ylab = if (log_mort) {
      expression(atop(Delta~deathrate, "relative to 27 C"))
    } else {
      "Change in annual deaths per 100,000\nrelative to 27 C"
    },
    width = if (spec_set == "four_spec") 13.5 else 12,
    height = if (spec_set == "four_spec") 9.5 else 5.8
  )
}

message("Wrote main response figures to: ", fig_dir)