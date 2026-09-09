#========================================================================================#
#' Shared setup for the Young-Hsiang / ERA5-Land wind analysis.
#'
#' Sourced by all three analysis scripts in this directory so the panel, the
#' variable construction and the estimator stay identical between them:
#'   02_young_hsiang_regressions_era5.R   replication + head-to-head results
#'   03_era5_diagnostics.R                why the ERA5 coefficients come out large
#'   04_lag_window_sweep.R                how the answer moves with the lag window
#'
#' Defines: PANEL_CSV, L_MAIN/L_SHORT/L_YEAR/LAG_REF, OUTCOME, FE, the panel `d`,
#'          MEASURES, FAMILY/FAMILY_LEVELS, SHORT_LAB, PARENT, sd_scale_of(),
#'          cached(), fmt(), fit_dl(), SDS.
#'
#' Assumes adhoc/_common.R has already been sourced (REPO_ROOT, out_dirs(), ...).
#========================================================================================#

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(purrr)
  library(rlang)
  library(fixest)
  library(ggplot2)
  library(patchwork)
})
theme_set(theme_classic())

# Single-threaded on purpose: 03 and 04 fork with mclapply(), and forking a
# process that already holds a live OpenMP pool is a known hang/corruption risk.
# Parallelism in this project is across model fits, not inside them.
setFixest_nthreads(1)

#' Format a number for a slide or table.
#' Three decimals by default: the wind coefficients are small and the deck
#' quotes them directly.
fmt <- function(x, d = 3) formatC(x, format = "f", digits = d, big.mark = ",")

# ---------------------------------------------------------------------------
# 0. Paths
# ---------------------------------------------------------------------------
# input panel: env var wins, then cluster location, then the local mirror
PANEL_CSV <- Sys.getenv("YH_TC_PANEL_CSV", unset = NA_character_)
if (is.na(PANEL_CSV)) {
  .cand <- file.path(
    c(# the shared copy on the cluster
      "/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/processed",
      # a local copy, for working off-server (local_data/ is gitignored)
      file.path(REPO_ROOT, "local_data", "wind_tc_validation")),
    "young_hsiang_state_month_era5land_wind_1950_2015.csv"
  )
  .hit <- .cand[file.exists(.cand)]
  if (!length(.hit)) stop("panel not found; set YH_TC_PANEL_CSV")
  PANEL_CSV <- .hit[1]
}
message("panel: ", PANEL_CSV)

DIRS <- out_dirs("wind_tc_validation")
DIR_DATA <- DIRS$data; DIR_FIG <- DIRS$fig; DIR_TAB <- DIRS$tab

# ---------------------------------------------------------------------------
# 1. Settings
# ---------------------------------------------------------------------------
L_MAIN  <- 240   # Young-Hsiang lag window: 20 years of monthly lags
L_SHORT <- 60    # 5-year window used for the head-to-head (see section 5)
L_YEAR  <- 12    # 1-year window: the near-term response, best identified of all
LAG_REF <- 172   # the lag Young and Hsiang report their headline cumulative at
OUTCOME <- "tdths_ttpop"   # all-cause monthly deaths per 100,000

FE <- "modate + stfips^month[t1] + stfips[t2,t3,t4,t5,t6,t7,t8,tavg,tavg2]"

# ---------------------------------------------------------------------------
# 2. Read and prepare
# ---------------------------------------------------------------------------
d <- read_csv(PANEL_CSV, show_col_types = FALSE) %>% arrange(stfips, modate)

stopifnot(!anyDuplicated(select(d, stfips, modate)))
# balanced and gap-free for EVERY state: the lag construction depends on it
.shape <- d %>%
  group_by(stfips) %>%
  summarise(gapless = all(diff(modate) == 1), n = n(), .groups = "drop")
stopifnot(all(.shape$gapless), n_distinct(.shape$n) == 1)

# Time polynomial. Young and Hsiang centre modate on the estimation sample; the
# rescaling by 120 is numerical only (modate^8 overflows double precision at raw
# scale) and spans the identical column space, so coefficients on the wind lags
# are unaffected.
.ctr <- mean(filter(d, year >= 1950)$modate)
d <- d %>% mutate(t1 = (modate - .ctr) / 120, tavg2 = tavg^2)
for (k in 2:8) d[[paste0("t", k)]] <- d$t1^k

# ERA5-Land wind is a *monthly maximum of daily maximum* wind, so it is strictly
# positive in every state-month and dominated by ordinary synoptic weather. `maxs`
# is TC-only and exactly zero in 93% of state-months. A raw level comparison is
# therefore not like-for-like; we also build an exceedance measure that mimics the
# sparse, tail-driven structure of `maxs`. The threshold is state-by-calendar-month
# so that both the cross-state climatology and the (strongly anti-TC-seasonal)
# within-year wind cycle are differenced out. The threshold is computed on the
# ERA5 era only, then applied to every row of the state-month cell.
d <- d %>%
  group_by(stfips, month) %>%
  mutate(q_sm = quantile(windmax_area_month[year >= 1950], 0.95, na.rm = TRUE)) %>%
  ungroup() %>%
  mutate(w_exc = pmax(0, windmax_area_month - q_sm))

# Masked variants: the ERA5 measures forced to zero in every month Young and
# Hsiang record no tropical cyclone. windmax_area_month_tc is then positive in
# exactly the 7.5% of state-months maxs is, matching its sparsity. w_exc_tc is
# sparser still (positive in 1.1%), because the exceedance threshold and the TC
# mask only coincide part of the time - so it is NOT a like-for-like match to
# maxs on sparsity, and its standard deviation is not comparable to its parent's
# (see PARENT below). The complements (_notc) are the rest of the variable, so
# *_tc + *_notc recovers the parent exactly; 03 uses both halves.
d <- d %>% mutate(is_tc = maxs > 0)
for (.x in c("windmax_area_month", "w_exc")) {
  # Multiply rather than if_else(): NA * 0 is NA, so a month where the parent is
  # missing stays missing in both halves. if_else(is_tc, x, 0) would hand back a
  # hard 0 for every pre-1950 row, which would defeat the only thing stopping
  # fit_dl() from reaching back past the start of the ERA5 record - its rule that
  # an observation is dropped when its longest lag is NA.
  d[[paste0(.x, "_tc")]]   <- d[[.x]] * as.numeric(d$is_tc)
  d[[paste0(.x, "_notc")]] <- d[[.x]] * as.numeric(!d$is_tc)
}

# States that essentially never see a tropical cyclone (<1% of months). Shared so
# the placebo in 03 and the figures in 02 use one definition.
NO_TC_STATES <- d %>%
  filter(year >= 1950) %>%
  group_by(stfips) %>%
  summarise(s = mean(maxs > 0), .groups = "drop") %>%
  filter(s < 0.01) %>%
  pull(stfips)
d <- d %>% mutate(tc_state = !stfips %in% NO_TC_STATES)

# LaTeX labels for the results table
MEASURES <- c(
  maxs               = "\\texttt{maxs} (Young--Hsiang)",
  windmax_area_month = "ERA5 wind, area-weighted",
  windmax_pop_month  = "ERA5 wind, population-weighted",
  w_exc              = "ERA5 exceedance (state$\\times$month p95)",
  windmax_area_month_tc = "ERA5 wind, area-wt, zeroed outside TC",
  w_exc_tc              = "ERA5 exceedance, zeroed outside TC"
)

# ---------------------------------------------------------------------------
# Result cache
# ---------------------------------------------------------------------------
# The leave-one-out jackknives and the lag-window sweep are hundreds of model
# fits and dominate runtime. cached() stores each result as a CSV under
# output/data/wind_tc_validation/ and reuses it on later runs.
#
# Recomputation is OFF by default. To force it:
#   REFRESH=1 Rscript adhoc/wind_tc_validation/03_era5_diagnostics.R
# or delete the individual CSV.
#
# These caches are machine-local by construction: the signature below includes
# the panel's mtime and size, so a fresh checkout or a re-synced panel always
# recomputes. That is why they are gitignored rather than committed.
REFRESH <- tolower(Sys.getenv("REFRESH", unset = "")) %in% c("1", "true", "yes", "y")

#' Signature of everything a cached result depends on. A cache entry is only
#' reused when this matches exactly, so editing the estimator, the fixed effects,
#' the outcome, or the panel file invalidates it automatically. Callers pass
#' `key` for whatever else varies (lag window, sample floor, measure list).
.cache_sig <- function(key) {
  fi <- file.info(PANEL_CSV)
  paste(c(basename(PANEL_CSV), format(fi$mtime), fi$size, OUTCOME, FE,
          paste(deparse(key), collapse = " ")), collapse = " | ")
}

cached <- function(name, expr, key = NULL) {
  path  <- file.path(DIR_DATA, paste0(name, ".csv"))
  kpath <- file.path(DIR_DATA, paste0(name, ".key"))
  sig   <- .cache_sig(key)
  if (!REFRESH && file.exists(path) && file.exists(kpath) &&
      identical(readLines(kpath, warn = FALSE), sig)) {
    message("  [cache hit] ", name)
    return(read_csv(path, show_col_types = FALSE))
  }
  if (file.exists(path) && !REFRESH)
    message("  [cache stale] ", name, " - inputs changed, recomputing")
  res <- expr                       # lazily evaluated: only runs on a miss
  write_csv(res, path)
  writeLines(sig, kpath)
  message("  [cache write] ", name)
  res
}

# For plotting: colour by measure family, linetype by whether it is masked.
FAMILY <- c(maxs = "Young-Hsiang maxs", windmax_area_month = "ERA5 raw, area-wt",
            windmax_area_month_tc = "ERA5 raw, area-wt", windmax_pop_month = "ERA5 raw, pop-wt",
            w_exc = "ERA5 exceedance", w_exc_tc = "ERA5 exceedance")
FAMILY_LEVELS <- c("Young-Hsiang maxs", "ERA5 raw, area-wt", "ERA5 raw, pop-wt", "ERA5 exceedance")

# Per-SD rescaling: a masked variable is scaled by its PARENT's standard
# deviation, never its own. Its own SD is driven by the on/off switching of the
# mask rather than by wind - masking raw ERA5 wind actually RAISES the SD (1.15
# -> 1.57) while masking the exceedance measure lowers it (0.21 -> 0.13), neither
# of which means anything about wind. Using the parent's SD keeps one
# interpretable unit across the pair: "per 1 SD of ERA5-Land wind, counting only
# the months that carry a Young-Hsiang cyclone".
# Every derived variant maps to the measure it was built from, so all of them are
# rescaled by the parent's SD rather than their own. The _seas/_off entries are
# built in 03_era5_diagnostics.R.
PARENT <- c(
  windmax_area_month_tc   = "windmax_area_month", windmax_area_month_notc = "windmax_area_month",
  windmax_area_month_seas = "windmax_area_month", windmax_area_month_off  = "windmax_area_month",
  w_exc_tc = "w_exc", w_exc_notc = "w_exc", w_exc_seas = "w_exc", w_exc_off = "w_exc",
  maxs_seas = "maxs", maxs_off = "maxs")

# Compact labels for the endpoint coefficient panel, where the full names do not fit
SHORT_LAB <- c(maxs = "maxs", windmax_area_month = "ERA5 raw (area)",
               windmax_pop_month = "ERA5 raw (pop)", w_exc = "ERA5 exceedance",
               windmax_area_month_tc = "ERA5 raw, TC months",
               w_exc_tc = "ERA5 exc., TC months")
sd_scale_of <- function(m) SDS[ifelse(m %in% names(PARENT), PARENT[m], m)]

# ---------------------------------------------------------------------------
# 3. Estimation machinery
# ---------------------------------------------------------------------------

#' Add lag (or lead) columns for one variable, within state.
#'
#' One grouped pass builds the whole block, rather than one grouped mutate per
#' horizon: at L = 240 that is the difference between 1 regrouping and 241.
#' Names match the originals exactly: <x>_l0 .. <x>_lL and <x>_f1 .. <x>_fleads.
.add_shifts <- function(df, x, horizons, kind = c("lag", "lead")) {
  kind <- match.arg(kind)
  shift_fn <- if (kind == "lag") dplyr::lag else dplyr::lead
  tag <- if (kind == "lag") "l" else "f"
  fns <- setNames(
    lapply(horizons, function(j) { force(j); function(v) shift_fn(v, j) }),
    paste0(tag, horizons)
  )
  df %>%
    group_by(stfips) %>%
    mutate(across(all_of(x), fns, .names = "{.col}_{.fn}")) %>%
    ungroup()
}

#' Fit the Young-Hsiang distributed-lag model for one or more wind measures.
#'
#' xs        character vector of wind variables to enter simultaneously
#' L         number of monthly lags (0..L)
#' year_min  optional floor on the estimation sample
#' leads     number of leads to include (Young-Hsiang use 72 in their Figure 2)
#' est_filter a quoted/defused expression restricting the estimation sample,
#'            applied after lag construction (used by the leave-one-out
#'            diagnostics). Build it with rlang::expr(), e.g. expr(stfips != !!s).
#'
#' Returns the fit plus, for each measure, the cumulative-effect path
#' B(h) = sum_{j=0}^{h} beta_j with delta-method standard errors.
fit_dl <- function(xs, L, year_min = NULL, leads = 0, label = NULL,
                   est_filter = NULL) {

  dd <- d
  lag_names <- lead_names <- list()
  for (x in xs) {
    dd <- .add_shifts(dd, x, 0:L, "lag")
    lag_names[[x]] <- paste0(x, "_l", 0:L)
    if (leads > 0) {
      dd <- .add_shifts(dd, x, 1:leads, "lead")
      lead_names[[x]] <- paste0(x, "_f", 1:leads)
    }
  }

  # The estimation sample is whatever survives the outcome, the temperature
  # control and the longest lag/lead. Dropping on the longest lag only is enough:
  # the panel is balanced and gap-free, so shorter lags are non-missing wherever
  # the longest one is.
  est <- dd %>% filter(!is.na(.data[[OUTCOME]]), !is.na(tavg))
  if (!is.null(year_min)) est <- filter(est, year >= year_min)
  # est_filter drops rows from the ESTIMATION SAMPLE only. It is applied here,
  # after the lags are built on the full panel, so that dropping (say) a single
  # year for a jackknife does not put a gap in the lag structure of the years
  # either side of it.
  if (!is.null(est_filter)) est <- filter(est, !!est_filter)
  for (x in xs) {
    est <- filter(est, !is.na(.data[[lag_names[[x]][L + 1]]]))
    if (leads > 0) est <- filter(est, !is.na(.data[[lead_names[[x]][leads]]]))
  }

  rhs <- paste(c(unlist(lead_names), unlist(lag_names)), collapse = " + ")
  m <- feols(as.formula(paste(OUTCOME, "~", rhs, "|", FE)), data = est, vcov = "iid")

  # cumulative sums: B = R b, Var(B) = R V R'
  R <- matrix(0, L + 1, L + 1)
  R[lower.tri(R, diag = TRUE)] <- 1

  # Leads enter the plot at negative lag. Young and Hsiang accumulate them
  # backwards from zero, B(-h) = -sum_{j=1}^{h} beta_{F_j}, so that the placebo
  # branch is on the same footing as the lag branch.
  lead_cum <- function(x) {
    if (!leads) return(NULL)
    fn <- lead_names[[x]]
    b  <- coef(m)[fn]
    V  <- vcov(m)[fn, fn]
    Rl <- matrix(0, leads, leads)
    Rl[lower.tri(Rl, diag = TRUE)] <- -1
    tibble(measure = x, lag = -(1:leads), beta = as.vector(b),
           beta_se = sqrt(diag(V)), cum = as.vector(Rl %*% b),
           cum_se = sqrt(diag(Rl %*% V %*% t(Rl))), cum_se_cl = NA_real_)
  }

  cum <- bind_rows(lapply(xs, function(x) {
    ln <- lag_names[[x]]
    # fixest drops perfectly collinear regressors, so a lag may be absent from
    # the fit (e.g. tavg at lag 0 is already spanned by the state-specific tavg
    # slopes in the fixed effects). A dropped regressor is constrained to exactly
    # zero with zero variance, which is how it must enter the running sums.
    keep <- ln %in% names(coef(m))
    if (!all(keep)) message("    (", sum(!keep), " collinear term(s) dropped: ",
                            paste(utils::head(ln[!keep], 3), collapse = ", "), ")")
    b <- setNames(numeric(length(ln)), ln)
    b[keep] <- coef(m)[ln[keep]]
    V <- matrix(0, length(ln), length(ln), dimnames = list(ln, ln))
    V[keep, keep] <- vcov(m)[ln[keep], ln[keep], drop = FALSE]
    # Carried for reference only. There are 36 states, so the clustered VCOV has
    # rank <= 36 against 241 lag coefficients and fixest reports it as fixed-up
    # non-PSD. Do not lean on cum_se_cl for the long-lag models; Young and Hsiang
    # use randomization inference here, which we do not reproduce.
    Vc <- matrix(0, length(ln), length(ln), dimnames = list(ln, ln))
    Vc[keep, keep] <- vcov(m, cluster = ~stfips)[ln[keep], ln[keep], drop = FALSE]
    bind_rows(
      tibble(
        measure   = x,
        lag       = 0:L,
        beta      = as.vector(b),
        beta_se   = sqrt(diag(V)),
        cum       = as.vector(R %*% b),
        cum_se    = sqrt(diag(R %*% V  %*% t(R))),
        cum_se_cl = sqrt(diag(R %*% Vc %*% t(R)))
      ),
      lead_cum(x)
    )
  }))

  cum <- cum %>%
    arrange(measure, lag) %>%
    mutate(spec       = label %||% paste(xs, collapse = "+"),
           n_measures = length(xs),
           L          = L,
           nobs       = nobs(m),
           year_lo    = min(est$year),
           year_hi    = max(est$year))

  message(sprintf("  %-34s L=%3d n=%5d %d-%d", label %||% xs[1], L,
                  nobs(m), min(est$year), max(est$year)))
  list(fit = m, cum = cum, est_years = range(est$year), nobs = nobs(m))
}

# within-state SD of each measure on the common ERA5 sample, for rescaling the
# head-to-head onto a comparable "one standard deviation" axis
SDS <- d %>%
  filter(year >= 1950) %>%
  group_by(stfips) %>%
  summarise(across(all_of(names(MEASURES)), sd), .groups = "drop") %>%
  summarise(across(all_of(names(MEASURES)), mean)) %>%
  unlist()
message("within-state SDs: ",
        paste(sprintf("%s=%.4f", names(SDS), SDS), collapse = "  "))
