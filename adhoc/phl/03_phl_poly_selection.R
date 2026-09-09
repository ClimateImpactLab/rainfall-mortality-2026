#========================================================================================#
#' Which precipitation polynomial order fits best?
#'
#' Compares orders 1-5 by (a) in-sample AIC/BIC and (b) K-fold cross-validated
#' out-of-sample Poisson deviance, holding the default specification fixed.
#'
#' SEPARATE FROM THE MAIN SCRIPT ON PURPOSE: this refits the model
#' (K folds + 1) x 5 times and takes several minutes, so it is not part of the
#' every-run pipeline. Its outputs are consumed by the deck.
#'
#' Cross-validation design: folds are random at the observation level, NOT
#' blocked by municipality or year. That is deliberate -- both fixed-effect
#' dimensions (adm3 x age x era, adm2 x year x age) must remain identified on
#' the training fold in order to predict the held-out rows at all. The cost is
#' that this measures functional-form fit, not forecasting skill into new
#' municipalities or years; every order faces the same handicap, so the
#' comparison across orders remains valid.
#'
#' Run: Rscript adhoc/phl/03_phl_poly_selection.R
#' Outputs: output/tables/phl/poly_selection.tex
#'          output/data/phl/poly_selection.csv
#'          output/figures/phl/poly_selection.png
#========================================================================================#

suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(readr); library(fixest)
  library(ggplot2); library(purrr); library(stringr); library(MetBrewer)
  library(patchwork)
})
theme_set(theme_classic())
setFixest_nthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = "1")))

.adhoc <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a) == 1) dirname(normalizePath(sub("^--file=", "", a))) else normalizePath(getwd())
  while (!file.exists(file.path(d, "_common.R")) && dirname(d) != d) d <- dirname(d)
  d
})
source(file.path(.adhoc, "_common.R"))
source(file.path(.adhoc, "phl", "_phl_common.R"))

DIRS <- out_dirs("phl")
DIR_DATA <- DIRS$data; DIR_FIG <- DIRS$fig; DIR_TAB <- DIRS$tab

# ---------------------------------------------------------------------------
# Data prep: identical to 01_phl_response_functions.R
# ---------------------------------------------------------------------------
MAX_ORDER  <- 5
K_FOLDS    <- 5
SEED       <- 20260731

# Sample definition and scaling come from _phl_common.R, so this script and
# 01_phl_response_functions.R cannot drift apart.
df <- prep_phl_panel(read_phl_panel(), poly_k = 5)
message("estimation sample: ", nrow(df), " rows")

FE  <- "adm3_code^agegroup^covid_period + adm2_code^year^agegroup"
fml <- function(K) as.formula(paste(
  "deathrate_w99 ~",
  paste(c(paste0("i(agegroup, tavg_poly_", 1:3, "_ERA5LAND)"),
          paste0("i(agegroup, prcp_poly_", seq_len(K), "_ERA5LAND)")),
        collapse = " + "),
  "|", FE))

# ---------------------------------------------------------------------------
# 1. In-sample information criteria
# ---------------------------------------------------------------------------
message("\n=== in-sample AIC / BIC ===")
# Two variants. The weighted fit is the estimation default, but its
# quasi-likelihood is on the scale of the weights (population SHARES, summing
# to 1 within each year x age cell), so the total log-likelihood is ~-750 for
# 84k rows and AIC's 2k penalty swamps any likelihood difference -- the
# criteria degenerate into parameter counting. The unweighted fit puts the
# likelihood on a per-observation scale, where AIC/BIC mean what they usually
# mean. Both are reported; the unweighted one is the informative comparison.
ic <- map_dfr(1:MAX_ORDER, function(K) {
  fw <- fepois(fml(K), data = df, weights = ~weight, lean = FALSE, notes = FALSE)
  fu <- fepois(fml(K), data = df, lean = FALSE, notes = FALSE)
  tibble(order = K,
         aic_w = AIC(fw), bic_w = BIC(fw), loglik_w = as.numeric(logLik(fw)),
         aic   = AIC(fu), bic   = BIC(fu), loglik   = as.numeric(logLik(fu)),
         n_prcp_par = 3 * K)
})
print(as.data.frame(ic), digits = 8)
message("weighted-AIC gap order1->2: ", round(ic$aic_w[2] - ic$aic_w[1], 3),
        "  (2 x 3 params = 6, i.e. essentially all penalty)")

# ---------------------------------------------------------------------------
# 2. K-fold cross-validation, out-of-sample Poisson deviance
# ---------------------------------------------------------------------------
# Deviance is the proper scoring rule for this model:
#   dev = 2 * sum w * [ y*log(y/mu) - (y - mu) ],  with y*log(y)=0 at y=0.
message("\n=== ", K_FOLDS, "-fold cross-validation ===")
set.seed(SEED)
df$fold <- sample(rep_len(1:K_FOLDS, nrow(df)))

pois_dev <- function(y, mu, w) {
  term <- ifelse(y > 0, y * log(y / mu), 0) - (y - mu)
  2 * sum(w * term)
}

cv <- map_dfr(1:MAX_ORDER, function(K) {
  map_dfr(1:K_FOLDS, function(k) {
    tr <- df[df$fold != k, ]; te <- df[df$fold == k, ]
    f  <- fepois(fml(K), data = tr, weights = ~weight, lean = FALSE, notes = FALSE)
    mu <- predict(f, newdata = te)
    ok <- is.finite(mu) & mu > 0          # rows whose FE cells exist in training
    tibble(order = K, fold = k,
           dev  = pois_dev(te$deathrate_w99[ok], mu[ok], te$weight[ok]),
           n_ok = sum(ok), n_te = nrow(te))
  }) %>% mutate(dev_per_obs = dev / n_ok)
})

cv_sum <- cv %>%
  group_by(order) %>%
  summarise(cv_dev = mean(dev_per_obs), cv_se = sd(dev_per_obs) / sqrt(n()),
            pred_rate = mean(n_ok / n_te), .groups = "drop")
print(as.data.frame(cv_sum), digits = 6)
message("predictable held-out rows: ",
        sprintf("%.1f%%", 100 * mean(cv_sum$pred_rate)))

# ---------------------------------------------------------------------------
# 3. Combine, report, plot
# ---------------------------------------------------------------------------
sel <- ic %>%
  left_join(cv_sum, by = "order") %>%
  mutate(d_aic = aic - min(aic), d_bic = bic - min(bic),
         d_cv  = cv_dev - min(cv_dev))
write_csv(sel, file.path(DIR_DATA, "poly_selection.csv"))
print(as.data.frame(select(sel, order, d_aic, d_bic, cv_dev, cv_se, d_cv)), digits = 5)
message('(AIC/BIC above are from the UNWEIGHTED fit; see aic_w/bic_w in the csv)')

best <- list(aic = sel$order[which.min(sel$aic)],
             bic = sel$order[which.min(sel$bic)],
             cv  = sel$order[which.min(sel$cv_dev)])
message(sprintf("\nbest order -- AIC: %d | BIC: %d | CV deviance: %d",
                best$aic, best$bic, best$cv))

star <- function(o, b) ifelse(o == b, "\\textbf{", "")
writeLines(c(
  "\\begin{tabular}{crrrr}",
  "\\toprule",
  "Precip. order & $\\Delta$AIC & $\\Delta$BIC & CV deviance & $\\Delta$CV \\\\",
  "\\midrule",
  sprintf("%d & %s & %s & %s & %s \\\\", sel$order,
          fmt(sel$d_aic), fmt(sel$d_bic), fmt(sel$cv_dev, 4), fmt(sel$d_cv, 4)),
  "\\bottomrule",
  "\\end{tabular}"
), file.path(DIR_TAB, "poly_selection.tex"))

p <- sel %>%
  select(order, `Delta AIC` = d_aic, `Delta BIC` = d_bic) %>%
  pivot_longer(-order) %>%
  ggplot(aes(order, value, colour = name)) +
  geom_line(linewidth = 0.8) + geom_point(size = 2) +
  scale_colour_manual(values = PAL3[c(1, 3)]) +
  labs(x = "Precipitation polynomial order", y = "Difference from best", colour = NULL,
       title = "Information criteria") +
  theme(legend.position = "bottom") |
  (ggplot(sel, aes(order, cv_dev)) +
     geom_ribbon(aes(ymin = cv_dev - cv_se, ymax = cv_dev + cv_se),
                 alpha = 0.2, fill = "grey40") +
     geom_line(linewidth = 0.8) + geom_point(size = 2) +
     labs(x = "Precipitation polynomial order",
          y = "Out-of-sample deviance per obs.",
          title = paste0(K_FOLDS, "-fold cross-validation")))
save_fig("poly_selection.png", p,
       width = 10, height = 4, bg = "white")

message("\nDone. -> ", DIR_TAB, " / ", DIR_FIG)
