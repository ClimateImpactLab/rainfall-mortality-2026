# ============================================================
# 03_usa_cv_figures.R
#
# Figure of the USA precip-vs-flow cross-validation (loss differences)
# Usage: Rscript 03_usa_cv_figures.R [saturated|main]  (same spec as 01 and 02)
#
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)

theme_set(theme_classic())

# -----------------------------
# Project files
# -----------------------------

source("../../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY

K <- 5 # folds, as in 02_usa_cv_precip_vs_flow.R

FE_SPEC <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(FE_SPEC)) FE_SPEC <- "saturated"
stopifnot(FE_SPEC %in% c("saturated", "main"))
spec_dir <- if (FE_SPEC == "saturated") "cv_precip_vs_flow" else paste0("cv_precip_vs_flow_", FE_SPEC)

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual")
cv_dir <- file.path(OUTPUT_DIR, spec_dir)
figure_dir <- file.path(OUTPUT_DIR, "figures", spec_dir)
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

age_levels <- c("0-4", "5-64", "65+")
contrast_levels <- c("Precip - baseline", "Flow - baseline", "Precip - flow")

# -----------------------------
# Loss differences
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
    y = NULL, title = paste0(K, " folds, ", FE_SPEC, " FE")
  ) +
  theme(strip.background = element_blank(), strip.text = element_text(face = "bold"))

ggsave(file.path(figure_dir, paste0("fig_usa_cv_differences_k", K, ".pdf")), fig_diff, width = 10, height = 3, device = "pdf")

message("Wrote figures to: ", figure_dir)
