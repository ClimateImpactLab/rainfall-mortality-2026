# ============================================================
# 02_usa_cv_precip_vs_flow.R
#
# Does precip or flow better explain USA mortality? State blocks, 5-fold
# cross-validation (OLS) on the residualized panel of 01_usa_cv_residualize.R.
# Usage: Rscript 02_usa_cv_precip_vs_flow.R [saturated|main]  (same spec as 01)
#
# Models, each fit on the residuals (the FE, temperature and wind are already
# partialled out), separately for each age group:
#   baseline  no rain term
#   precip    residualized precip poly (order 3)
#   flow      residualized flow poly (order 3)
# Including the main reg's population weights 
#
# Design:
#   - Folds: ADM1 (state) blocks. States are shuffled at random and dealt into
#     K_FOLDS folds; all counties and age rows of a state stay together. Follows
#     the state-clustered SEs of the regs: errors are correlated within a state, 
#     so a state is never split between training and held-out rows
#   - K_FOLDS = 5, redrawn N_REPEATS = 20 times. Stability is reported two
#     ways: the SD across all K_FOLDS x N_REPEATS fold losses (sd_*), and the
#     SD across the N_REPEATS repeat means (sd_repeat_*)
#   - Loss: population-weighted out-of-sample RMSE of the residualized outcome,
#     per age group
#   - Paired comparison: in every fold, loss(model) - loss(baseline) and
#     loss(precip) - loss(flow)
#
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(tidyr)

# -----------------------------
# Settings
# -----------------------------

source("../../../0_utils/paths.R")

K_FOLDS <- 5
N_REPEATS <- 20
SEED <- 20261118       # the fold draw of repeat r uses SEED + r

FE_SPEC <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(FE_SPEC)) FE_SPEC <- "saturated"
stopifnot(FE_SPEC %in% c("saturated", "main"))
message("FE spec: ", FE_SPEC)

cv_dir <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual",
  if (FE_SPEC == "saturated") "cv_precip_vs_flow" else paste0("cv_precip_vs_flow_", FE_SPEC)
)
residual_file <- file.path(cv_dir, "usa_cv_residual_panel.rds")

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

# Regressors of each model
models <- list(
  baseline = character(),
  precip = paste0("prcp_res_", 1:3),
  flow = paste0("flow_res_", 1:3)
)

# -----------------------------
# Data
# -----------------------------

df <- readRDS(residual_file)

stopifnot(
  !anyNA(df[c("y_res", unlist(models), "weight", "adm1_code")]),
  all(df$weight > 0)
)

states <- sort(unique(df$adm1_code))
message("CV data: ", nrow(df), " rows | ", length(states), " states")
stopifnot(length(states) >= K_FOLDS)

# -----------------------------
# Folds
# -----------------------------

fold_draws <- lapply(seq_len(N_REPEATS), function(r) {
  set.seed(SEED + r)
  fold_of_state <- setNames(sample(rep_len(seq_len(K_FOLDS), length(states))), states)
  fold_of_state[df$adm1_code]
})

# Fold sizes: states and share of the total weight (3 age groups, each
# year x age sums to 1, so the share is the fold's share of the population)
fold_sizes <- bind_rows(lapply(seq_len(N_REPEATS), function(r) {
  df %>%
    mutate(fold = fold_draws[[r]]) %>%
    group_by(fold) %>%
    summarise(n_states = n_distinct(adm1_code), weight_share = sum(weight), .groups = "drop") %>%
    mutate(weight_share = weight_share / sum(weight_share), cv_repeat = r, .before = 1)
}))
print(fold_sizes, n = Inf)

# -----------------------------
# Cross-validation
# -----------------------------

# Weighted RMSE: square root of the weighted mean squared error, in the units
# of the death rate. Taken within each held-out fold (or state)
weighted_rmse <- function(y, pred, w) sqrt(sum(w * (y - pred)^2) / sum(w))

# Held-out predictions of every model; the losses are taken from them below
predictions <- list()

for (r in seq_len(N_REPEATS)) {
  fold <- fold_draws[[r]]

  for (k in seq_len(K_FOLDS)) {
    for (age in levels(df$agegroup)) {
      train <- df[fold != k & df$agegroup == age, ]
      test <- df[fold == k & df$agegroup == age, ]

      for (model_id in names(models)) {
        x_vars <- models[[model_id]]

        if (length(x_vars) == 0) {
          pred <- rep(0, nrow(test))
        } else {
          fit <- lm(reformulate(c("0", x_vars), "y_res"), data = train, weights = weight)
          pred <- as.numeric(as.matrix(test[x_vars]) %*% coef(fit))
        }

        stopifnot(all(is.finite(pred)))

        predictions[[length(predictions) + 1]] <- tibble(
          cv_repeat = r, fold = k, age_label = unname(age_labels[[age]]), model_id = model_id,
          adm1_code = test$adm1_code, adm1_id = test$adm1_id, y_res = test$y_res, weight = test$weight, pred = pred
        )
      }
    }
  }

  message("Finished repeat ", r, " of ", N_REPEATS)
}

predictions <- bind_rows(predictions)

# Loss per repeat, fold, age group and model
folds <- predictions %>%
  group_by(cv_repeat, fold, age_label, model_id) %>%
  summarise(wrmse = weighted_rmse(y_res, pred, weight), .groups = "drop")

# -----------------------------
# Summary
# -----------------------------

# mean_wrmse: mean over all held-out folds (K_FOLDS x N_REPEATS); sd_wrmse: SD
# of those fold losses; sd_repeat_wrmse: SD of the N_REPEATS repeat means
loss_summary <- folds %>%
  group_by(age_label, model_id) %>%
  summarise(
    mean_wrmse = mean(wrmse), sd_wrmse = sd(wrmse),
    sd_repeat_wrmse = sd(tapply(wrmse, cv_repeat, mean)), .groups = "drop"
  )

contrast_labels <- c(precip_vs_baseline = "Precip - baseline", flow_vs_baseline = "Flow - baseline", precip_vs_flow = "Precip - flow")

# Paired difference in every fold. 
diff_summary <- folds %>%
  pivot_wider(names_from = model_id, values_from = wrmse) %>%
  mutate(precip_vs_baseline = precip - baseline, flow_vs_baseline = flow - baseline, precip_vs_flow = precip - flow) %>%
  pivot_longer(all_of(names(contrast_labels)), names_to = "contrast_id", values_to = "diff") %>%
  mutate(reference = if_else(contrast_id == "precip_vs_flow", flow, baseline))

# SD of the paired difference across all K_FOLDS x N_REPEATS folds
diff_sd_folds <- diff_summary %>%
  group_by(age_label, contrast_id) %>%
  summarise(sd_fold = sd(diff), .groups = "drop")

diff_summary <- diff_summary %>%
  group_by(age_label, contrast_id, cv_repeat) %>%
  summarise(repeat_mean = mean(diff), repeat_se = sd(diff) / sqrt(n()), reference = mean(reference), .groups = "drop") %>%
  group_by(age_label, contrast_id) %>%
  summarise(
    diff = mean(repeat_mean), se_diff = mean(repeat_se), sd_repeat = sd(repeat_mean),
    repeat_min = min(repeat_mean), repeat_max = max(repeat_mean),
    reference_wrmse = mean(reference), .groups = "drop"
  ) %>%
  left_join(diff_sd_folds, by = c("age_label", "contrast_id")) %>%
  mutate(contrast_label = unname(contrast_labels[contrast_id]), .after = contrast_id) %>%
  mutate(pct_of_reference = 100 * diff / reference_wrmse)


# -----------------------------
# Write results
# -----------------------------

write_csv(folds, file.path(cv_dir, paste0("usa_cv_fold_losses_k", K_FOLDS, ".csv")))
write_csv(loss_summary, file.path(cv_dir, paste0("usa_cv_loss_summary_k", K_FOLDS, ".csv")))
write_csv(diff_summary, file.path(cv_dir, paste0("usa_cv_diff_summary_k", K_FOLDS, ".csv")))
write_csv(fold_sizes, file.path(cv_dir, paste0("usa_cv_fold_sizes_k", K_FOLDS, ".csv")))

print(loss_summary, n = Inf)
print(diff_summary, n = Inf, width = Inf)
message("Wrote the CV results to: ", cv_dir)
