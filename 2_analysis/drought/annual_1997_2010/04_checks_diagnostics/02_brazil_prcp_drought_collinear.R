# ============================================================
# 02_brazil_prcp_drought_collinear.R
#
# Check whether the annual drought measures overlap with the annual precip
# poly terms in the Brazil regression panel, for the model with both.
#
# The question is whether, after FE and temp controls, the precip poly
# already explains most of a drought measure. If yes, the drought coef comes
# from a small leftover piece of variation and is hard to interpret.
#
# 2 diagnostics, by age group:
#
#   1. residual correlation
#      After FE + temp controls, how correlated is each drought measure with
#      each precip-poly term?
#
#   2. partial R2
#      After FE + temp controls, how much of each drought measure is explained
#      by all precip poly terms?
#
# Results are in the "Drought and precip poly overlap" section of the
# annual Overleaf project doc (hope it lives on for my cil rp descendants)
#
# Options:
#   --fe_spec=main | saturated
#   --weighted=true | false
#
# Output: output/data/drought/brazil-annual/precip-drought-collinearity/
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)
library(fixest)
library(glue)


# -----------------------------
# Options
# -----------------------------

# Options: main or saturated FE, weighted or not
args <- commandArgs(FALSE)

get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

fe_spec <- get_arg("fe_spec", "main")
weighted_arg <- tolower(get_arg("weighted", "true"))

# Defaults match the first Brazil annual reg checks
weighted <- weighted_arg %in% c("true", "t", "1", "yes")
weight_label <- if (weighted) "weighted" else "unweighted"

# Keep output names tied to the diagnostic version being run
run_id <- paste(fe_spec, weight_label, sep = "_")


# -----------------------------
# Paths
# -----------------------------

# paths.R gives DIR_REPO_RAINFALL_MORTALITY (the repo on RCC)
USER <- Sys.getenv("USER")
source("../../../../0_utils/paths.R")

PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds"
)

OUTPUT_DIR <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "drought",
  "brazil-annual", "precip-drought-collinearity"
)

figure_dir <- file.path(OUTPUT_DIR, "figures")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Variables and FE
# -----------------------------

# Same drought variables as the first Brazil annual regs
drought_vars <- tibble::tribble(
  ~variable, ~measure_label,
  "gs_neglog_annual_rain_pop",
  "-log annual rainfall",

  "rs_drought_months_12m_pop",
  "Rocha-Soares drought months",

  "rs_worst_logdev_severity_pop",
  "Worst Rocha-Soares log deviation",

  "rs_worst_pctdev_severity_pop",
  "Worst Rocha-Soares percent deviation",

  "drought_6m_low10_months_pop",
  "6-month windows below 10th percentile",

  "drought_6m_low05_months_pop",
  "6-month windows below 5th percentile",

  "drought_6m_worst_z_severity_pop",
  "Worst 6-month z-score severity",

  "deficit_mm_max_06m_pop",
  "Largest 6-month rainfall deficit"
)

# same poly orders as usual for temp and precip:
temp_vars <- paste0("tavg_poly_", 1:2)
prcp_vars <- paste0("prcp_poly_", 1:3)

# The mortality regs interact drought and precip with age group
# For this diagnostic, cleaner to run each age group separately.
# Within one age group, the main FE are ADM2 FE and country-year FE
fe_terms <- if (fe_spec == "main") {
  c("admin_code", "adm0_code^year")
} else if (fe_spec == "saturated") {
  c("admin_code", "adm0_code^year", "adm1_code^year")
} else {
  stop("fe_spec must be main or saturated", call. = FALSE)
}

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")


# -----------------------------
# Read Brazil panel
# -----------------------------

# Keep only IDs, controls, precip polynomial terms, and drought measures.
needed <- c(
  "admin_code", "adm0_code", "adm1_code", "year", "agegroup", "weight",
  temp_vars, prcp_vars, drought_vars$variable
)

# Use the same complete-case sample for all measures so comparisons line up.
df <- readRDS(PANEL_FILE) %>%
  mutate(agegroup = as.factor(agegroup)) %>%
  select(all_of(needed)) %>%
  filter(if_all(all_of(c("weight", temp_vars, prcp_vars, drought_vars$variable)), ~ !is.na(.x)))

# Print the sample while the diagnostic runs.
message(glue(
  "Collinearity diagnostic sample: {nrow(df)} rows | ",
  "{n_distinct(df$admin_code)} ADM2s | ",
  "{min(df$year)}-{max(df$year)}"
))


# -----------------------------
# Small math helpers
# -----------------------------

# Weighted moments keep this diagnostic on the same scale as the regss that use
# pop weights. If --weighted=false, every row gets weight 1.
weighted_mean <- function(x, w) {
  sum(w * x, na.rm = TRUE) / sum(w[!is.na(x)], na.rm = TRUE)
}

# Weighted variance of the residualized variable
weighted_var <- function(x, w) {
  m <- weighted_mean(x, w)
  sum(w * (x - m)^2, na.rm = TRUE) / sum(w[!is.na(x)], na.rm = TRUE)
}

# Correlation between two residualized variables
# This is the usual covariance over the product of SDs, but using the same weights
# as the regs
weighted_cor <- function(x, y, w) {
  # Use the same non-missing rows for x, y, and weights.
  ok <- !is.na(x) & !is.na(y) & !is.na(w)
  x <- x[ok]
  y <- y[ok]
  w <- w[ok]

  # If either residualized var has no remaining variation, correlation is
  # not defined
  vx <- weighted_var(x, w)
  vy <- weighted_var(y, w)
  if (vx <= 0 || vy <= 0) return(NA_real_)

  mx <- weighted_mean(x, w)
  my <- weighted_mean(y, w)
  sum(w * (x - mx) * (y - my), na.rm = TRUE) / sum(w, na.rm = TRUE) / sqrt(vx * vy)
}


# -----------------------------
# Regression helpers
# -----------------------------

# Residualize one climate variable against FE and temp controls
# These residuals are the variation left for the precip/drought comparison
residualize_var <- function(data, variable) {
  f <- as.formula(sprintf(
    "%s ~ %s | %s",
    variable,
    paste(temp_vars, collapse = " + "),
    paste(fe_terms, collapse = " + ")
  ))

  fit <- feols(f, data = data, weights = if (weighted) ~weight else NULL, notes = FALSE)
  # Full-length residuals (NA for rows fixest drops, for ex singletons under
  # saturated FE), so they line up with the weights row by row
  residuals(fit, na.rm = FALSE)
}

# Partial R2 for the precip polynomial:
# base = drought ~ temp controls + FE
# full = drought ~ temp controls + precip poly + FE
# partial R2 = share of base residual variance removed by adding precip poly
partial_r2_prcp <- function(data, variable) {
  # Base model: drought variation left after temp controls and FE
  base_formula <- as.formula(sprintf(
    "%s ~ %s | %s",
    variable,
    paste(temp_vars, collapse = " + "),
    paste(fe_terms, collapse = " + ")
  ))

  # Full model: same base, plus annual precip polynomial terms.
  full_formula <- as.formula(sprintf(
    "%s ~ %s | %s",
    variable,
    paste(c(temp_vars, prcp_vars), collapse = " + "),
    paste(fe_terms, collapse = " + ")
  ))

  # Fit both auxiliary models on the same sample.
  base_fit <- feols(base_formula, data = data, weights = if (weighted) ~weight else NULL, notes = FALSE)
  full_fit <- feols(full_formula, data = data, weights = if (weighted) ~weight else NULL, notes = FALSE)

  # Partial R2 is based on how much residual variance falls after adding precip.
  w <- if (weighted) data$weight else rep(1, nrow(data))
  base_resid_var <- weighted_var(residuals(base_fit, na.rm = FALSE), w)
  full_resid_var <- weighted_var(residuals(full_fit, na.rm = FALSE), w)

  tibble(
    nobs = nobs(full_fit),
    base_within_r2 = as.numeric(fitstat(base_fit, "wr2")[[1]]),
    full_within_r2 = as.numeric(fitstat(full_fit, "wr2")[[1]]),
    delta_within_r2 = full_within_r2 - base_within_r2,
    partial_r2_prcp_poly = if_else(base_resid_var > 0, 1 - full_resid_var / base_resid_var, NA_real_),
    dropped_terms = if (is.null(full_fit$collin.var)) "none" else paste(full_fit$collin.var, collapse = ", ")
  )
}


# ------------------------------------------------------------
# 1. Residualized correlations
# ------------------------------------------------------------

# This is the pairwise check: one drought measure against one precip-poly term,
# after removing FE and temp controls
resid_correlations <- bind_rows(lapply(levels(df$agegroup), function(age) {
  # Work age group by age group to match the age-specific reg terms
  age_df <- df %>% filter(agegroup == age)
  w <- if (weighted) age_df$weight else rep(1, nrow(age_df))

  # Residualize each drought and precip variable once for this age group.
  residual_vars <- c(drought_vars$variable, prcp_vars)
  residuals_by_var <- setNames(
    lapply(residual_vars, function(variable) residualize_var(age_df, variable)),
    residual_vars
  )

  # Correlate every drought residual with each precip-poly residual
  bind_rows(lapply(drought_vars$variable, function(drought_var) {
    bind_rows(lapply(prcp_vars, function(prcp_var) {
      tibble(
        agegroup = age,
        age_label = age_labels[[as.character(age)]],
        variable = drought_var,
        prcp_var = prcp_var,
        resid_corr = weighted_cor(residuals_by_var[[drought_var]], residuals_by_var[[prcp_var]], w)
      )
    }))
  }))
})) %>%
  left_join(drought_vars, by = "variable")


# ------------------------------------------------------------
# 2. Partial R2
# ------------------------------------------------------------

# This is the combined check: how much does the full precip polynomial explain
# after the FE and temp controls are already partialled out?
partial_r2 <- bind_rows(lapply(levels(df$agegroup), function(age) {
  # Same age-specific split as above
  age_df <- df %>% filter(agegroup == age)

  # Run one partial-R2 check per drought measure
  bind_rows(lapply(seq_len(nrow(drought_vars)), function(i) {
    variable <- drought_vars$variable[[i]]

    partial_r2_prcp(age_df, variable) %>%
      mutate(
        agegroup = age,
        age_label = age_labels[[as.character(age)]],
        variable = variable,
        measure_label = drought_vars$measure_label[[i]]
      )
  }))
})) %>%
  left_join(
    # Add the largest pairwise residual correlation as a compact second check
    resid_correlations %>%
      group_by(agegroup, variable) %>%
      summarise(max_abs_resid_corr = max(abs(resid_corr), na.rm = TRUE), .groups = "drop"),
    by = c("agegroup", "variable")
  ) %>%
  select(
    agegroup, age_label, variable, measure_label, nobs,
    base_within_r2, full_within_r2, delta_within_r2,
    partial_r2_prcp_poly, max_abs_resid_corr, dropped_terms
  )


# -----------------------------
# Write CSVs
# -----------------------------

write_csv(resid_correlations, file.path(OUTPUT_DIR, paste0("resid_corr_", run_id, ".csv")))
write_csv(partial_r2, file.path(OUTPUT_DIR, paste0("partial_r2_", run_id, ".csv")))


# -----------------------------
# Figure settings
# -----------------------------

# Shared plot style for both diagnostic heatmaps
theme_set(
  theme_bw(base_size = 11) +
    theme(
      panel.grid = element_blank(),
      strip.background = element_rect(fill = "grey92", color = NA),
      strip.text = element_text(face = "bold"),
      plot.title = element_text(face = "bold", size = 11),
      plot.subtitle = element_text(size = 9)
    )
)

# Keep measure order and precip labels readable in the figures.
measure_levels <- rev(drought_vars$measure_label)
prcp_labels <- c(
  prcp_poly_1 = "prcp poly 1",
  prcp_poly_2 = "prcp poly 2",
  prcp_poly_3 = "prcp poly 3"
)


# ------------------------------------------------------------
# Figure 1. Residual correlations
# ------------------------------------------------------------

resid_corr_plot_data <- resid_correlations %>%
  mutate(
    measure_label = factor(measure_label, levels = measure_levels),
    prcp_label = recode(prcp_var, !!!prcp_labels),
    age_label = factor(age_label, levels = c("0-4", "5-64", "65+")),
    label = sprintf("%.2f", resid_corr)
  )

# Heatmap: each cell is one residualized drought x precip-poly correlation
resid_corr_plot <- ggplot(resid_corr_plot_data, aes(x = prcp_label, y = measure_label, fill = resid_corr)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 2.9) +
  facet_wrap(~age_label, nrow = 1) +
  scale_fill_gradient2(
    low = "#3B6EA8", mid = "white", high = "#B64A3A",
    midpoint = 0, limits = c(-1, 1),
    name = "Residual\ncorrelation"
  ) +
  labs(
    x = NULL,
    y = NULL,
    title = "Residual correlation with precip polynomial",
    subtitle = "FE and temperature controls removed first"
  ) +
  theme(axis.text.x = element_text(angle = 25, hjust = 1))

ggsave(
  file.path(figure_dir, paste0("fig_resid_corr_", run_id, ".pdf")),
  resid_corr_plot,
  width = 10.5,
  height = 5.8,
  bg = "white"
)


# ------------------------------------------------------------
# Figure 2. Partial R2
# ------------------------------------------------------------

partial_r2_plot_data <- partial_r2 %>%
  mutate(
    measure_label = factor(measure_label, levels = measure_levels),
    age_label = factor(age_label, levels = c("0-4", "5-64", "65+")),
    label = sprintf("%.2f", partial_r2_prcp_poly)
  )

# Heatmap: each cell is the share of residual drought variation explained by precip poly.
partial_r2_plot <- ggplot(partial_r2_plot_data, aes(x = age_label, y = measure_label, fill = partial_r2_prcp_poly)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = label), size = 2.9) +
  scale_fill_gradient(
    low = "white", high = "#1F5C8B",
    limits = c(0, max(partial_r2_plot_data$partial_r2_prcp_poly, na.rm = TRUE)),
    name = "Partial R2\nfrom prcp poly"
  ) +
  labs(
    x = NULL,
    y = NULL,
    title = "Partial R2 from precip polynomial",
    subtitle = "Share of residual drought variation explained"
  )

ggsave(
  file.path(figure_dir, paste0("fig_partial_r2_", run_id, ".pdf")),
  partial_r2_plot,
  width = 8.1,
  height = 5.8,
  bg = "white"
)

message("Wrote collinearity diagnostics to: ", OUTPUT_DIR)
