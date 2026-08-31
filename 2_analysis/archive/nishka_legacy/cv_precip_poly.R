# ============================================================================
# Cross-validation of the precipitation polynomial order
# ----------------------------------------------------------------------------
# Strategy (Frisch-Waugh-Lovell + leave-one-country-out), run independently
# per age group so the chosen precip order can differ by age:
#   1. Within each age group, residualise the outcome and all regressors
#      against the fixed effects (fixest::demean, population-weighted).
#   2. On the residualised data, run weighted OLS leaving one country out at a
#      time, predict the held-out country, accumulate out-of-sample sq. error.
#   3. Compare leave-one-country-out RMSE across precip orders, per age group;
#      the order with the lowest OOS RMSE is preferred for that age.
#
# Why per-age works: the model is fully interacted with agegroup (both the FE
# and the slopes), so it block-diagonalises -- each age group is an independent
# regression. Aggregating the per-age squared errors back up recovers the
# pooled "common order across ages" RMSE.
#
# Notes
#  * LINEAR selection exercise (FWL residualisation is OLS-only): the outcome is
#    log_deathrate_w99, not the Poisson model used for the response curves.
#    Switch LHS to "deathrate_w99" to compare in levels.
#  * The FE are estimated on the full age-group sample before the folds, so each
#    fold's residualisation "sees" the held-out country. This follows the
#    residualise-first-then-CV recipe; it is a (mild) optimistic approximation.
# ============================================================================

library(dplyr)
library(tidyr)
library(readr)
library(stringr)
library(glue)
library(purrr)
library(fixest)
library(ggplot2)
theme_set(theme_classic())

# set paths
USER <- Sys.getenv("USER")
REPO <- "~/repos/"
source(glue("{REPO}/rainfall-mortality-2026/0_utils/paths.R"))
source(glue("{REPO}/rainfall-mortality-2026/0_utils/functions.R"))

# ---- load mortality panel (no urban merge needed here) ---------------------
df <- paste0(DATA_DIR, "/cleaned/global_rainfall-mortality_panel.csv") %>%
  read_csv(show_col_types = FALSE) %>%
  get_weights() %>%
  mutate(log_deathrate_w99 = log(deathrate_w99))

# ============================================================================
# CV configuration
# ============================================================================
LHS         <- "log_deathrate_w99"   # linear outcome for FWL
TAVG_ORDER  <- 2                     # held fixed across the comparison
PRCP_ORDERS <- 2:4                   # precip orders to compare
FE_TERMS    <- c("adm2_code^agegroup", "adm0_code^year^agegroup")
FOLD_VAR    <- "adm0_code"           # leave-one-country-out unit
WEIGHT_VAR  <- "weight"

# ============================================================================
# Helpers
# ============================================================================

# Build one interaction factor per FE term: "a^b^c" -> interaction(a, b, c).
# Within a single age group the agegroup component is constant, so this also
# correctly collapses e.g. adm2_code^agegroup -> adm2_code.
make_fe_factors <- function(data, fe_terms) {
  fac <- lapply(fe_terms, function(t) {
    parts <- str_split(t, "\\^")[[1]]
    do.call(interaction, c(data[parts], list(drop = TRUE)))
  })
  stats::setNames(as.data.frame(fac), fe_terms)
}

# ============================================================================
# Assemble the CV sample
# ============================================================================
max_p     <- max(PRCP_ORDERS)
tavg_vars <- paste0("tavg_poly_", seq_len(TAVG_ORDER))
prcp_vars <- paste0("prcp_poly_", seq_len(max_p))
base_vars <- c(tavg_vars, prcp_vars)

fe_cols <- unique(unlist(str_split(FE_TERMS, "\\^")))
needed  <- c(LHS, base_vars, WEIGHT_VAR, FOLD_VAR, "agegroup", fe_cols)
miss    <- setdiff(needed, names(df))
if (length(miss)) stop("missing columns: ", paste(miss, collapse = ", "))

cv_df <- df %>% filter(if_all(all_of(needed), ~ !is.na(.)))
message(glue("CV sample: {nrow(cv_df)} rows | ",
             "{n_distinct(cv_df[[FOLD_VAR]])} countries | ",
             "{nlevels(droplevels(cv_df$agegroup))} agegroups"))

# ============================================================================
# Per-age-group leave-one-country-out CV
# ============================================================================

# Residualise one age group's data and return weighted LOO + in-sample SSE for
# each precip order. Keeps raw SSE pieces so ages can be aggregated later.
cv_one_age <- function(adf) {
  Y      <- adf[[LHS]]
  w      <- adf[[WEIGHT_VAR]]
  folds  <- adf[[FOLD_VAR]]
  Xmat   <- as.matrix(adf[, base_vars])
  fe_fac <- make_fe_factors(adf, FE_TERMS)

  # residualise outcome + regressors against the FE (population-weighted)
  res    <- demean(cbind(y = Y, Xmat), f = fe_fac, weights = w)
  Yr     <- res[, "y"]
  Xr     <- res[, base_vars, drop = FALSE]
  ufolds <- unique(folds)

  cols_for_order <- function(p) c(tavg_vars, paste0("prcp_poly_", seq_len(p)))

  one_order <- function(p) {
    Xp <- Xr[, cols_for_order(p), drop = FALSE]

    # leave-one-country-out
    num <- 0; den <- 0
    for (f in ufolds) {
      te <- folds == f; tr <- !te
      b  <- lm.wfit(x = Xp[tr, , drop = FALSE], y = Yr[tr], w = w[tr])$coefficients
      b[is.na(b)] <- 0                              # drop collinear columns
      e  <- Yr[te] - as.numeric(Xp[te, , drop = FALSE] %*% b)
      num <- num + sum(w[te] * e^2); den <- den + sum(w[te])
    }

    # in-sample, for reference
    b_is <- lm.wfit(x = Xp, y = Yr, w = w)$coefficients; b_is[is.na(b_is)] <- 0
    e_is <- Yr - as.numeric(Xp %*% b_is)

    tibble(prcp_order    = p,
           loo_sse       = num,            # raw pieces, for cross-age aggregation
           sse_w         = den,
           loo_rmse      = sqrt(num / den),
           insample_rmse = sqrt(sum(w * e_is^2) / sum(w)))
  }

  map_dfr(PRCP_ORDERS, one_order)
}

# run each age group independently
cv_by_age <- cv_df %>%
  group_split(agegroup) %>%
  map_dfr(function(adf) {
    age <- as.character(adf$agegroup[1])
    message(glue("== agegroup {age} =="))
    cv_one_age(adf) %>% mutate(agegroup = age, .before = 1)
  })

# best precip order per age (ties -> lowest order, for parsimony)
best_by_age <- cv_by_age %>%
  group_by(agegroup) %>%
  slice_min(loo_rmse, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  select(agegroup, best_order = prcp_order, best_loo_rmse = loo_rmse)

# ============================================================================
# Summaries
# ============================================================================
cat("\nLOO RMSE by age group and precip order:\n")
cv_by_age %>%
  select(agegroup, prcp_order, loo_rmse, insample_rmse) %>%
  arrange(agegroup, prcp_order) %>%
  print(n = Inf)

cat("\nBest precip order per age group:\n")
print(best_by_age)

# overall RMSE if every age uses the SAME order (== the pooled comparison)
common_order <- cv_by_age %>%
  group_by(prcp_order) %>%
  summarise(overall_loo_rmse = sqrt(sum(loo_sse) / sum(sse_w)), .groups = "drop")
cat("\nOverall LOO RMSE, common order across ages:\n")
print(common_order)

# overall RMSE for the MIXED model (each age at its own best order)
mixed_loo_rmse <- cv_by_age %>%
  semi_join(best_by_age %>% rename(prcp_order = best_order),
            by = c("agegroup", "prcp_order")) %>%
  summarise(rmse = sqrt(sum(loo_sse) / sum(sse_w))) %>%
  pull(rmse)
cat(glue("\nOverall LOO RMSE, mixed (best-per-age) order: ",
         "{round(mixed_loo_rmse, 6)}\n\n"))

# ============================================================================
# Plot: LOO RMSE vs order, one panel per age, best order highlighted
# ============================================================================
cv_by_age %>%
  ggplot(aes(prcp_order, loo_rmse)) +
  geom_line(linewidth = 1) +
  geom_point(size = 2) +
  geom_point(data = best_by_age, aes(best_order, best_loo_rmse),
             color = "red", size = 3) +
  facet_wrap(~ agegroup, scales = "free_y") +
  scale_x_continuous(breaks = PRCP_ORDERS) +
  labs(x = "Precip polynomial order",
       y = "Leave-one-country-out weighted RMSE",
       title = "CV by age group (red = best order per age)")
