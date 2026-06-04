# ============================================================================
# Cross-validation of the precipitation polynomial order
# ----------------------------------------------------------------------------
# Strategy (Frisch-Waugh-Lovell + leave-one-country-out):
#   1. Residualise the outcome and ALL regressors against the fixed effects,
#      once, on the full sample (fixest::demean, population-weighted).
#   2. On the residualised data, run weighted OLS leaving one country out at a
#      time, predict the held-out country, and accumulate out-of-sample
#      squared error.
#   3. Compare the leave-one-country-out RMSE across precip polynomial orders;
#      the order with the lowest OOS RMSE is preferred.
#
# Notes
#  * This is a LINEAR selection exercise (FWL residualisation is OLS-only), so
#    the outcome is log_deathrate_w99, not the Poisson model used for the
#    response curves. Switch LHS to "deathrate_w99" to compare in levels.
#  * Regressors are age-group-interacted, mirroring fit_response(): both the FE
#    and the slopes vary by agegroup, so this design matches the fitted model.
#  * The FE are estimated on the full sample before the folds, so each fold's
#    residualisation "sees" the held-out country. This follows the requested
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

# Age-group-interacted design columns: base_var * 1{agegroup == g}.
# Mirrors i(agegroup, poly) in fit_response(): one slope per agegroup.
make_interacted <- function(data, base_vars, agelvls) {
  age  <- as.character(data$agegroup)
  cols <- list()
  for (v in base_vars) {
    z <- data[[v]]
    for (g in agelvls) cols[[paste0(v, ":age=", g)]] <- z * (age == g)
  }
  as.matrix(as.data.frame(cols, check.names = FALSE))
}

# Build one interaction factor per FE term: "a^b^c" -> interaction(a, b, c).
make_fe_factors <- function(data, fe_terms) {
  fac <- lapply(fe_terms, function(t) {
    parts <- str_split(t, "\\^")[[1]]
    do.call(interaction, c(data[parts], list(drop = TRUE)))
  })
  stats::setNames(as.data.frame(fac), fe_terms)
}

# ============================================================================
# Build + residualise the full design once (precip up to the max order)
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

agelvls <- levels(droplevels(cv_df$agegroup))
Y       <- cv_df[[LHS]]
w       <- cv_df[[WEIGHT_VAR]]
folds   <- cv_df[[FOLD_VAR]]

Xfull  <- make_interacted(cv_df, base_vars, agelvls)
fe_fac <- make_fe_factors(cv_df, FE_TERMS)

# Residualise outcome + all regressors against the FE (population-weighted).
res    <- demean(cbind(y = Y, Xfull), f = fe_fac, weights = w)
Yr     <- res[, "y"]
Xr     <- res[, setdiff(colnames(res), "y"), drop = FALSE]
prefix <- sub(":age=.*$", "", colnames(Xr))   # base var behind each column

# ============================================================================
# Leave-one-country-out CV
# ============================================================================
ufolds <- unique(folds)

# columns to keep for a given precip order (all tavg terms + prcp 1..p)
cols_for_order <- function(p) {
  keep <- c(tavg_vars, paste0("prcp_poly_", seq_len(p)))
  which(prefix %in% keep)
}

# weighted RMSE over the held-out countries
loo_rmse <- function(p) {
  Xp  <- Xr[, cols_for_order(p), drop = FALSE]
  num <- 0; den <- 0
  for (f in ufolds) {
    te <- folds == f
    tr <- !te
    b  <- lm.wfit(x = Xp[tr, , drop = FALSE], y = Yr[tr], w = w[tr])$coefficients
    b[is.na(b)] <- 0                              # drop collinear columns
    e  <- Yr[te] - as.numeric(Xp[te, , drop = FALSE] %*% b)
    num <- num + sum(w[te] * e^2)
    den <- den + sum(w[te])
  }
  sqrt(num / den)
}

# in-sample weighted RMSE, for reference
insample_rmse <- function(p) {
  Xp <- Xr[, cols_for_order(p), drop = FALSE]
  b  <- lm.wfit(x = Xp, y = Yr, w = w)$coefficients
  b[is.na(b)] <- 0
  e  <- Yr - as.numeric(Xp %*% b)
  sqrt(sum(w * e^2) / sum(w))
}

cv_results <- map_dfr(PRCP_ORDERS, function(p) {
  message(glue("== precip order {p} =="))
  tibble(prcp_order    = p,
         loo_rmse      = loo_rmse(p),
         insample_rmse = insample_rmse(p))
})

print(cv_results)

best <- cv_results$prcp_order[which.min(cv_results$loo_rmse)]
message(glue("Lowest leave-one-country-out RMSE at precip order {best}"))

# ============================================================================
# Plot
# ============================================================================
cv_results %>%
  pivot_longer(c(loo_rmse, insample_rmse),
               names_to = "type", values_to = "rmse") %>%
  ggplot(aes(prcp_order, rmse, color = type)) +
  geom_line(linewidth = 1) +
  geom_point(size = 2) +
  scale_x_continuous(breaks = PRCP_ORDERS) +
  labs(x = "Precip polynomial order", y = "Weighted RMSE",
       color = NULL,
       title = "Leave-one-country-out CV: precip polynomial order")
