#========================================================================================#
#' Residualise-then-LASSO: disciplined selection over a wide heterogeneity space
#'
#' PROTOTYPE on the PHL panel. The point is to build and stress-test the
#' machinery on data we understand before the multi-country panel arrives.
#'
#' Design:
#'   1. Build a WIDE interaction space: each precipitation polynomial term x age
#'      x each candidate vulnerability variable (levels and squares).
#'   2. Partial out the high-dimensional fixed effects by Frisch-Waugh
#'      (fixest::demean), so the LASSO never sees them.
#'   3. LASSO over the interactions with the CORE exposure terms UNPENALISED
#'      (penalty.factor = 0), so the objects of interest are never shrunk.
#'   4. Choose lambda by CLUSTER-BLOCKED cross-validation (folds = provinces),
#'      because iid CV underpenalises badly under spatial correlation.
#'   5. Re-estimate the selected model by fepois for the reported coefficients.
#'
#' Known approximations, stated plainly:
#'   - FWL is exact for linear models. The final estimator is Poisson, so
#'     residualisation here uses the linear analogue: selection happens in the
#'     linear model, estimation in the Poisson one. Defensible (selection need
#'     not use the estimation likelihood) but not exact.
#'   - Post-selection inference from a single LASSO pass is NOT valid. This
#'     script reports selection frequencies under bootstrap resampling instead
#'     of naive p-values; valid inference needs cross-fitting or PDS (see deck).
#'
#' Run: Rscript adhoc/phl/prototype/lasso_heterogeneity.R
#========================================================================================#

suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(readr); library(fixest)
  library(glmnet); library(ggplot2); library(stringr); library(purrr)
  library(MetBrewer)
})
theme_set(theme_classic())
set.seed(20260803)

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
# 1. Data (mirrors 01_phl_response_functions.R prep)
# ---------------------------------------------------------------------------
# Sample definition, scaling and weights come from _phl_common.R, so this
# prototype sits on exactly the panel 01_phl_response_functions.R estimates on.
df <- prep_phl_panel(read_phl_panel(), poly_k = 5)

# coastal exposure, if 00_phl_coastal.R has run
cf <- file.path(DIR_DATA, "phl_coastal.csv")
if (file.exists(cf)) {
  df <- df %>% left_join(
    read_csv(cf, col_types = cols(adm3_id = col_character(), .default = col_guess())) %>%
      select(adm3_id, coast_share), by = "adm3_id")
} else df$coast_share <- NA_real_

# ---------------------------------------------------------------------------
# 2. The candidate vulnerability space
# ---------------------------------------------------------------------------
# Deliberately wide. Each enters standardised, in levels and squares, so the
# LASSO can express non-monotone heterogeneity (e.g. damage peaking at
# intermediate urbanisation) rather than only monotone gradients.
z <- function(x) as.numeric(scale(x))

df <- df %>%
  mutate(
    v_urban   = z(urban_share),
    v_coast   = z(coast_share),
    v_income  = z(loggdppc_adm1_avg),
    v_lrprcp  = z(lr_prcp_ERA5LAND_adm1_avg),
    v_lrtemp  = z(lr_tavg_ERA5LAND_adm1_avg),
    v_pop     = z(log(population)),
    v_smod    = z(settlement_type)
  )
V_VARS <- grep("^v_", names(df), value = TRUE)
df <- df %>% filter(if_all(all_of(V_VARS), ~ !is.na(.x)))
message("estimation rows: ", nrow(df), " | vulnerability vars: ", length(V_VARS))

CORE <- c(paste0("prcp_poly_", 1:3, "_ERA5LAND"),
          paste0("tavg_poly_", 1:3, "_ERA5LAND"))
AGES <- c("1", "2", "3")   # AGE_LABS comes from _phl_common.R

# Build the wide design: core terms x age, plus core-precip x age x V (level
# and square). Age interactions are explicit columns so nothing is penalised
# that shouldn't be.
X <- list()
for (a in AGES) {
  ia <- as.numeric(df$agegroup == a)
  for (cc in CORE) X[[paste0("core:", cc, ":age", a)]] <- ia * df[[cc]]
  for (k in 1:3) {
    pk <- df[[paste0("prcp_poly_", k, "_ERA5LAND")]]
    for (v in V_VARS) {
      X[[paste0("het:P", k, ":age", a, ":", v)]]      <- ia * pk * df[[v]]
      X[[paste0("het:P", k, ":age", a, ":", v, "_sq")]] <- ia * pk * df[[v]]^2
    }
  }
}
# do.call(cbind, .) preserves the colon-delimited names; as.data.frame() would
# run them through make.names() and silently break the core/penalised split
X <- do.call(cbind, X)
stopifnot(any(startsWith(colnames(X), "core:")))
is_core <- startsWith(colnames(X), "core:")
message("design: ", ncol(X), " columns (", sum(is_core), " core, ",
        sum(!is_core), " penalised interactions)")

# ---------------------------------------------------------------------------
# 3. Partial out the fixed effects (Frisch-Waugh)
# ---------------------------------------------------------------------------
FE <- df %>% transmute(
  fe1 = paste(adm3_code, agegroup, covid_period, sep = "_"),
  fe2 = paste(adm2_code, year, agegroup, sep = "_"))
message("demeaning ", ncol(X) + 1, " columns on ",
        n_distinct(FE$fe1), " + ", n_distinct(FE$fe2), " fixed effects...")

dm <- fixest::demean(X = cbind(y = df$deathrate_w99, X), f = FE,
                     weights = df$weight)
y_r <- dm[, 1]; X_r <- dm[, -1, drop = FALSE]

# ---------------------------------------------------------------------------
# 4. LASSO with unpenalised core terms, cluster-blocked CV
# ---------------------------------------------------------------------------
# Folds are whole PROVINCES: iid folds would let the same municipality inform
# both training and validation and choose a far-too-small lambda.
prov  <- df$adm2_code
folds <- match(prov, sample(unique(prov)))
folds <- ((folds - 1) %% 10) + 1
pf <- ifelse(is_core, 0, 1)     # core exposure terms never shrunk

cv <- cv.glmnet(X_r, y_r, weights = df$weight, alpha = 1,
                penalty.factor = pf, foldid = folds, standardize = TRUE)
message("lambda.min = ", signif(cv$lambda.min, 3),
        " | lambda.1se = ", signif(cv$lambda.1se, 3))

sel_at <- function(lam) {
  b <- as.matrix(coef(cv, s = lam))[-1, 1]
  names(b)[abs(b) > 0 & !is_core]
}
sel_min <- sel_at(cv$lambda.min); sel_1se <- sel_at(cv$lambda.1se)
message("interactions selected: ", length(sel_min), " at lambda.min, ",
        length(sel_1se), " at lambda.1se (of ", sum(!is_core), ")")
# if the 1-s.e. rule keeps nothing, that is itself the headline: bootstrap at
# lambda.min instead, so stability is measured where terms actually enter
LAM <- if (length(sel_1se) >= 3) cv$lambda.1se else cv$lambda.min
message("bootstrapping at lambda = ", signif(LAM, 3),
        if (length(sel_1se) < 3) "  (lambda.min: 1se rule kept <3 terms)" else "")

# ---------------------------------------------------------------------------
# 5. Stability: how often is each interaction selected under resampling?
# ---------------------------------------------------------------------------
# A single LASSO pass gives no valid inference. Selection frequency over
# province-block bootstraps is an honest summary of what is robust.
B <- 40
provs <- unique(prov)
stab <- map_dfr(seq_len(B), function(b) {
  keep <- prov %in% sample(provs, length(provs), replace = TRUE)
  if (sum(keep) < 1000) return(tibble(term = character()))
  fit <- glmnet(X_r[keep, , drop = FALSE], y_r[keep], weights = df$weight[keep],
                alpha = 1, penalty.factor = pf, lambda = LAM,
                standardize = TRUE)
  bb <- as.matrix(coef(fit))[-1, 1]
  tibble(term = names(bb)[abs(bb) > 0 & !is_core])
})
freq <- stab %>% count(term, name = "times") %>%
  mutate(freq = times / B) %>% arrange(desc(freq))

parse_term <- function(x) {
  tibble(term = x,
         order = str_match(x, "het:P(\\d)")[, 2],
         age   = AGE_LABS[str_match(x, ":age(\\d)")[, 2]],
         vuln  = str_replace(str_match(x, ":age\\d:(.*)$")[, 2], "^v_", ""))
}
freq <- freq %>% left_join(parse_term(freq$term), by = "term")
write_csv(freq, file.path(DIR_DATA, "lasso_stability.csv"))

cat("\n=== most stably selected interactions (province bootstrap, B =", B, ") ===\n")
print(freq %>% slice_head(n = 15) %>%
        select(vuln, order, age, freq) %>% as.data.frame(), digits = 2)

# aggregate to the vulnerability dimension: how often does ANY term
# involving this variable survive?
by_v <- stab %>%
  mutate(vuln = str_replace(str_match(term, ":age\\d:(.*)$")[, 2], "^v_", "")) %>%
  distinct() %>% count(vuln, name = "times") %>%
  mutate(freq = pmin(times / B, 1)) %>% arrange(desc(freq))
cat("\n=== selection frequency by vulnerability dimension ===\n")
print(as.data.frame(by_v), digits = 2)
write_csv(by_v, file.path(DIR_DATA, "lasso_stability_by_var.csv"))

save_fig("lasso_stability.png",
       freq %>% filter(freq > 0.05) %>%
         mutate(lbl = paste0(vuln, "  (P", order, ", ", age, ")")) %>%
         slice_head(n = 20) %>%
         ggplot(aes(reorder(lbl, freq), freq, fill = age)) +
         geom_col() + coord_flip() +
         geom_hline(yintercept = 0.5, linetype = "dashed", colour = "grey40") +
         scale_fill_manual(values = PAL3) +
         scale_y_continuous(labels = scales::percent) +
         labs(x = NULL, y = "Selection frequency across province bootstraps",
              fill = "Age"),
       width = 9, height = 5.5, bg = "white")

# CV curve
png(file.path(DIR_FIG, "lasso_cv.png"), width = 1800, height = 1200, res = 200)
plot(cv); dev.off()

message("\ndone. outputs -> ", DIR_FIG, " and ", DIR_DATA)
