# ============================================================
# 07_plot_wind_control_coefficients.R
#
# Plot the coefficients on the wind controls
#
# This script reads the coefficient CSV written by
# `regressions/05_wind_control_coefficients.R`. 
#
# Output:
#   output/figures/regs/analysis-panel/wind-control-coefficients/
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(glue)
library(ggplot2)
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

# These options should match the coefficient script
scope <- get_arg("scope", "both")
outcome_model <- get_arg("outcome_model", "poisson")
spec_set <- get_arg("spec_set", "main_two")
weighted_arg <- tolower(get_arg("weighted", "true"))
prcp_order <- as.integer(get_arg("prcp_order", "3"))
income_screen <- get_arg("income_screen", "p25")
control_set <- get_arg("control_set", "all")
country_group <- get_arg("country_group", "none")

weighted <- weighted_arg %in% c("true", "t", "1", "yes")
weight_label <- if (weighted) "weighted" else "unweighted"


# -----------------------------
# Paths
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")

data_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY,
  "output", "data", "diagnostics", "wind_control_coefficients"
)

fig_dir <- file.path(
  DIR_FIGURE,
  "regs", "analysis-panel", "wind-control-coefficients"
)

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

coef_file <- paste(
  "wind_control_coefficients",
  scope,
  outcome_model,
  spec_set,
  paste0("p", prcp_order),
  weight_label,
  income_screen,
  sep = "_"
)
if (control_set != "all") {
  coef_file <- paste(coef_file, control_set, sep = "_")
}
if (country_group != "none") {
  coef_file <- paste(coef_file, paste0("by_", country_group), sep = "_")
}
coef_file <- paste0(coef_file, ".csv")


# -----------------------------
# Read coefficients
# -----------------------------

coef_df <- read_csv(file.path(data_dir, coef_file), show_col_types = FALSE)

if (!"country_group_label" %in% names(coef_df)) {
  coef_df <- coef_df %>%
    mutate(country_group_label = "All countries")
}

current_control_runs <- c(
  "windmax",
  "winddays",
  "annual_both",
  "overlap_rain100",
  "overlap_rain200"
)

coef_df <- coef_df %>%
  # Keep only the coefficient runs used by the current script
  filter(control_run %in% current_control_runs) %>%
  mutate(
    sample = factor(sample, levels = c("Main", "Profile 4")),
    age_label = factor(age_label, levels = c("0-4", "5-64", "65+")),
    country_group_label = factor(
      country_group_label,
      levels = c(
        "All countries", "Other countries", "TC-prone countries",
        "AUS", "CHN", "IND", "JPN", "KOR", "MEX", "PHL", "USA"
      )
    ),
    control_panel = case_when(
      control_label == "High-wind days" ~ "High-wind\ndays",
      control_label == "Annual max wind" ~ "Annual\nmax wind",
      control_label == "Annual max wind + high-wind days" ~ "Annual max wind\n+ high-wind days",
      control_label == "Rain >=100mm + high wind" ~ "Rain >=100mm\n+ high wind",
      control_label == "Rain >=200mm + high wind" ~ "Rain >=200mm\n+ high wind",
      TRUE ~ control_label
    ),
    control_panel = factor(
      control_panel,
      levels = c(
        "High-wind\ndays",
        "Annual\nmax wind",
        "Annual max wind\n+ high-wind days",
        "Rain >=100mm\n+ high wind",
        "Rain >=200mm\n+ high wind"
      )
    ),
    control_var_label = factor(
      control_var_label,
      levels = c(
        "High-wind days",
        "Annual max wind",
        "Rain >=100mm + high wind",
        "Rain >=200mm + high wind"
      )
    )
  )


# -----------------------------
# Figure settings
# -----------------------------

control_palette <- c(
  "High-wind days" = "#D55E00",
  "Annual max wind" = "#0072B2",
  "Rain >=100mm + high wind" = "#009E73",
  "Rain >=200mm + high wind" = "#CC79A7"
)

country_group_palette <- c(
  "Other countries" = "#666666",
  "TC-prone countries" = "#0072B2",
  "AUS" = "#0072B2",
  "CHN" = "#D55E00",
  "IND" = "#009E73",
  "JPN" = "#CC79A7",
  "KOR" = "#56B4E9",
  "MEX" = "#E69F00",
  "PHL" = "#332288",
  "USA" = "#882255"
)

y_axis_label <- if (outcome_model == "poisson") {
  "Wind coefficient"
} else {
  "Deaths per 100,000"
}

tc_prone_note <- "TC-prone countries: AUS, CHN, IND, JPN, KOR, MEX, PHL, USA"


# -----------------------------
# Figures
# -----------------------------

for (sample_name in levels(coef_df$sample)) {
  plot_df <- coef_df %>%
    filter(sample == sample_name)

  if (nrow(plot_df) == 0) {
    next
  }

  sample_stub <- tolower(gsub(" ", "_", sample_name))

  # This figure answers Tom's question directly:
  # what sign do the wind controls have, and how noisy are they?
  color_var <- if (country_group == "none") "control_var_label" else "country_group_label"
  color_values <- if (country_group == "none") control_palette else country_group_palette
  plot_title <- if (country_group == "tc_prone_country") {
    glue("{sample_name}: wind coefficients by TC-prone country")
  } else if (country_group == "tc_prone") {
    glue("{sample_name}: wind coefficients by TC-prone country group")
  } else {
    glue("{sample_name}: wind-control coefficients")
  }
  fig_file <- if (country_group == "tc_prone_country") {
    paste0(sample_stub, "_wind_coefs_by_tc_country.pdf")
  } else if (country_group == "tc_prone") {
    paste0(sample_stub, "_wind_coefs_by_tc_prone.pdf")
  } else {
    paste0(sample_stub, "_wind_coefs.pdf")
  }

  plot_caption <- if (country_group %in% c("tc_prone", "tc_prone_country")) {
    tc_prone_note
  } else {
    NULL
  }

  make_plot <- function(free_y = FALSE) {
    facet_scales <- if (free_y) "free_y" else "fixed"
    
    p <- ggplot(
      plot_df,
      aes(age_label, estimate, ymin = lo, ymax = hi, color = .data[[color_var]])
    ) +
      geom_hline(yintercept = 0, color = "grey75", linewidth = 0.5) +
      geom_pointrange(position = position_dodge(width = 0.55), linewidth = 0.55) +
      facet_grid(control_panel ~ spec_short, scales = facet_scales) +
      scale_color_manual(values = color_values) +
      labs(
        x = "Age group",
        y = y_axis_label,
        color = NULL,
        title = plot_title,
        caption = plot_caption
      ) +
      theme_classic(base_size = 13) +
      theme(
        legend.position = "bottom",
        strip.text = element_text(face = "bold"),
        strip.text.y.right = element_text(angle = 0, lineheight = 0.95),
        axis.title = element_text(face = "bold"),
        plot.title = element_text(face = "bold"),
        plot.caption = element_text(hjust = 0, color = "grey25")
      )

    if (!free_y) {
      y_max <- max(abs(c(plot_df$lo, plot_df$hi)), na.rm = TRUE)
      p <- p + coord_cartesian(ylim = c(-y_max, y_max))
    }

    p
  }

  ggsave(
    file.path(fig_dir, fig_file),
    make_plot(free_y = FALSE),
    width = 12,
    height = 9
  )

  ggsave(
    file.path(fig_dir, sub("\\.pdf$", "_free_y.pdf", fig_file)),
    make_plot(free_y = TRUE),
    width = 12,
    height = 9
  )
}

message("Wrote wind coefficient figures to: ", fig_dir)
