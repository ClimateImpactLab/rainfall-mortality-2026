#========================================================================================#
#' How much does the answer depend on the lag window you pick?
#'
#' Estimates the Young-Hsiang distributed lag separately for L = 10, 20, ..., 240
#' lags and records the total cumulative effect B(L) = sum_{j=0}^{L} beta_j of
#' each model, with its delta-method standard error. Each point is therefore a
#' *different regression*, not a point along one model's lag profile.
#'
#' Two panels, because two things move with L and they need separating:
#'
#'   (a) `maxs` on its natural sample. `maxs` runs back to 1930 while the outcome
#'       starts in 1950, so every window from 10 to 240 lags is estimated on the
#'       SAME 1950-2012 rows. Changes across L are the horizon alone.
#'
#'   (b) All three measures on the fixed 1970-2012 sample, which is what 240 lags
#'       of ERA5-Land wind can support. Common rows for every L and every
#'       measure, so the curves are comparable to each other.
#'
#' Outputs: output/data/wind_tc_validation/lag_sweep.csv
#'          output/figures/wind_tc_validation/lag_sweep.png
#'          output/tables/wind_tc_validation/sweep_facts.tex
#'
#' Run:  Rscript adhoc/wind_tc_validation/04_lag_window_sweep.R
#========================================================================================#

# Packages, panel, settings, variable construction and fit_dl() all live in
# _wind_common.R, which every analysis script in this directory sources.
.adhoc <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a) == 1) dirname(normalizePath(sub("^--file=", "", a))) else normalizePath(getwd())
  while (!file.exists(file.path(d, "_common.R")) && dirname(d) != d) d <- dirname(d)
  d
})
source(file.path(.adhoc, "_common.R"))
source(file.path(.adhoc, "wind_tc_validation", "_wind_common.R"))

suppressPackageStartupMessages(library(parallel))


LAGS      <- seq(10, L_MAIN, 10)
ERA5_MIN  <- min(filter(d, !is.na(windmax_area_month))$year)
FIXED_MIN <- ERA5_MIN + L_MAIN / 12      # 1970: what 240 ERA5 lags can support

#' Total cumulative effect of one model, i.e. the endpoint of its lag profile.
sweep_one <- function(x, L, year_min, panel) {
  r <- try(fit_dl(x, L, year_min = year_min, label = sprintf("%s L=%d", x, L)),
           silent = TRUE)
  if (inherits(r, "try-error")) return(NULL)
  r$cum %>% filter(lag == L) %>%
    transmute(panel, measure = x, L, cum, cum_se,
              t = cum / cum_se, nobs, year_lo, year_hi)
}

sweep <- cached("lag_sweep", {
  # (a) maxs, natural sample: the horizon effect with the sample held fixed
  message("=== (a) maxs, natural sample ===")
  a <- bind_rows(mclapply(LAGS, function(L)
    sweep_one("maxs", L, year_min = NULL, panel = "a"), mc.cores = N_CORES))

  # (b) all three measures on the common 1970-2012 sample
  message("=== (b) fixed sample from ", FIXED_MIN, " ===")
  grid <- expand_grid(x = c("maxs", "windmax_area_month", "w_exc"), L = LAGS)
  b <- bind_rows(mclapply(seq_len(nrow(grid)), function(i)
    sweep_one(grid$x[i], grid$L[i], year_min = FIXED_MIN, panel = "b"),
    mc.cores = N_CORES))
  bind_rows(a, b)
}, key = list(lags = LAGS, fixed_min = FIXED_MIN,
              measures = c("maxs", "windmax_area_month", "w_exc")))

sweep_a <- filter(sweep, panel == "a")
sweep_b <- filter(sweep, panel == "b")

# sanity: panel (a) really is one sample throughout, panel (b) too
# Row counts first: a fit that errored would be dropped by rbindlist, vanish from
# the figure, and then silently delete its \newcommand line (sprintf on a
# zero-length value returns character(0), which c() drops without complaint).
stopifnot(nrow(sweep_a) == length(LAGS),
          nrow(sweep_b) == 3L * length(LAGS),
          n_distinct(sweep_a$nobs) == 1, n_distinct(sweep_b$nobs) == 1)
message("  (a) n = ", sweep_a$nobs[1], " for every L; (b) n = ", sweep_b$nobs[1])

# ---------------------------------------------------------------------------
# Figure
# ---------------------------------------------------------------------------
MLAB <- c(maxs = "Young-Hsiang maxs", windmax_area_month = "ERA5 raw, area-wt",
          w_exc = "ERA5 exceedance")

#' One facet per series, on a common vertical scale so the panels are directly
#' comparable. In SD units the long-lag divergence is large but not so large that
#' it flattens the other panels, which it would in raw m/s.
sweep_plot <- function(dt, brk, free_y = TRUE) {

  # Put every panel in units of one within-state SD of its own wind measure, so
  # the four panels are on a comparable footing rather than in raw m/s, where a
  # 1 m/s move means something very different for each series.
  dt <- dt %>% mutate(sd_scale = SDS[measure],
                      cum      = cum * sd_scale,
                      cum_se   = cum_se * sd_scale)
  a <- filter(dt, panel == "a"); b <- filter(dt, panel == "b")
  dt <- dt %>% mutate(
    mlab = factor(MLAB[measure], levels = MLAB),
    plab = factor(if_else(panel == "a", "a", paste0("b_", measure)),
      levels = c("a", paste0("b_", names(MLAB))),
      labels = c(sprintf("(a) maxs, natural sample (%d-%d, n = %s)",
                         a$year_lo[1], a$year_hi[1], format(a$nobs[1], big.mark = ",")),
                 sprintf("(b) %s, fixed sample (%d-%d, n = %s)", MLAB,
                         b$year_lo[1], b$year_hi[1], format(b$nobs[1], big.mark = ",")))))
  # Points and error bars only: every point is a separate regression, so neither a
  # band nor a connecting line would describe anything real between them.
  ggplot(dt, aes(L, cum, colour = mlab)) +
    geom_hline(yintercept = 0, linewidth = 0.3, colour = GREY) +
    geom_errorbar(aes(ymin = cum - 1.96 * cum_se, ymax = cum + 1.96 * cum_se),
                  width = 0, linewidth = 0.45) +
    geom_point(size = 1.2) +
    facet_wrap(~plab, ncol = 2, scales = if (free_y) "free_y" else "fixed") +
    scale_colour_manual(values = c(GREEN, ORANGE, BLUE), guide = "none") +
    scale_x_continuous(breaks = brk) +
    labs(x = "Number of monthly lags in the model (L)",
         y = "Total cumulative effect B(L),\nper 100,000 per SD of the wind measure") +
    theme(strip.background = element_blank(),
          strip.text = element_text(hjust = 0, size = 9))
}

p <- sweep_plot(sweep, seq(0, L_MAIN, 48), free_y = FALSE)
save_fig("lag_sweep.png", p, width = 9, height = 5.6)

# ---------------------------------------------------------------------------
# Same again over the first 100 lags only, at 5-lag resolution
# ---------------------------------------------------------------------------
# Identical samples to the full sweep (panel (a) unrestricted, panel (b) pinned
# to FIXED_MIN), so this is the same object at finer resolution rather than a
# different estimate. Short windows are cheap, hence the tighter grid.
LAGS_SHORT <- seq(5, 100, 5)

sweep_s <- cached("lag_sweep_short", {
  message("=== short grid: (a) maxs, natural sample ===")
  a <- bind_rows(mclapply(LAGS_SHORT, function(L)
    sweep_one("maxs", L, year_min = NULL, panel = "a"), mc.cores = N_CORES))
  message("=== short grid: (b) fixed sample from ", FIXED_MIN, " ===")
  g <- expand_grid(x = c("maxs", "windmax_area_month", "w_exc"), L = LAGS_SHORT)
  b <- bind_rows(mclapply(seq_len(nrow(g)), function(i)
    sweep_one(g$x[i], g$L[i], year_min = FIXED_MIN, panel = "b"),
    mc.cores = N_CORES))
  bind_rows(a, b)
}, key = list(lags = LAGS_SHORT, fixed_min = FIXED_MIN,
              measures = c("maxs", "windmax_area_month", "w_exc")))

stopifnot(nrow(filter(sweep_s, panel == "a")) == length(LAGS_SHORT),
          nrow(filter(sweep_s, panel == "b")) == 3L * length(LAGS_SHORT),
          n_distinct(filter(sweep_s, panel == "a")$nobs) == 1,
          n_distinct(filter(sweep_s, panel == "b")$nobs) == 1)

save_fig("lag_sweep_short.png",
       sweep_plot(sweep_s, seq(0, 100, 20), free_y = FALSE), width = 9, height = 5.6)

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

# The figures are drawn in SD units, so the macros must be too, or the slide text
# will not match the plot it sits under.
sweep   <- mutate(sweep,   cum = cum * SDS[measure], cum_se = cum_se * SDS[measure])
sweep_s <- mutate(sweep_s, cum = cum * SDS[measure], cum_se = cum_se * SDS[measure])
a <- filter(sweep, panel == "a")
# NB: the lookup variable must not share a name with the column
gb <- function(m, LL) filter(sweep, panel == "b", measure == m, L == LL)

facts <- c(
  sprintf("\\newcommand{\\sweepStep}{%d}", LAGS[2] - LAGS[1]),
  sprintf("\\newcommand{\\sweepNobsA}{%s}", fmt(sweep_a$nobs[1], 0)),
  sprintf("\\newcommand{\\sweepNobsB}{%s}", fmt(sweep_b$nobs[1], 0)),
  sprintf("\\newcommand{\\sweepAmin}{%s}", fmt(min(a$cum))),
  sprintf("\\newcommand{\\sweepAmax}{%s}", fmt(max(a$cum))),
  sprintf("\\newcommand{\\sweepAmaxL}{%d}", a$L[which.max(a$cum)]),
  sprintf("\\newcommand{\\sweepAten}{%s}",  fmt(filter(a, L == 10)$cum)),
  sprintf("\\newcommand{\\sweepAfull}{%s}", fmt(filter(a, L == L_MAIN)$cum)),
  sprintf("\\newcommand{\\sweepAseMin}{%s}", fmt(min(a$cum_se))),
  sprintf("\\newcommand{\\sweepAseMax}{%s}", fmt(max(a$cum_se))),
  sprintf("\\newcommand{\\sweepBmaxsFull}{%s}", fmt(gb("maxs", L_MAIN)$cum)),
  sprintf("\\newcommand{\\sweepBmaxsSixty}{%s}", fmt(gb("maxs", 60)$cum)),
  sprintf("\\newcommand{\\sweepBrawFull}{%s}", fmt(gb("windmax_area_month", L_MAIN)$cum)),
  sprintf("\\newcommand{\\sweepBrawSixty}{%s}", fmt(gb("windmax_area_month", 60)$cum)),
  sprintf("\\newcommand{\\sweepBexcFull}{%s}", fmt(gb("w_exc", L_MAIN)$cum)),
  sprintf("\\newcommand{\\sweepShortMax}{%d}", max(LAGS_SHORT)),
  sprintf("\\newcommand{\\sweepShortStep}{%d}", LAGS_SHORT[2] - LAGS_SHORT[1]),
  sprintf("\\newcommand{\\sweepShortAhundred}{%s}",
          fmt(filter(sweep_s, panel == "a", L == 100)$cum)),
  sprintf("\\newcommand{\\sweepShortAhundredT}{%s}",
          fmt(with(filter(sweep_s, panel == "a", L == 100), cum / cum_se), 2)),
  sprintf("\\newcommand{\\sweepShortBexc}{%s}",
          fmt(filter(sweep_s, panel == "b", measure == "w_exc", L == 100)$cum)),
  sprintf("\\newcommand{\\sweepShortBraw}{%s}",
          fmt(filter(sweep_s, panel == "b", measure == "windmax_area_month", L == 100)$cum)),
  # the L at which each fixed-sample series stops being significant
  sprintf("\\newcommand{\\sweepRawLastSig}{%s}",
          { z <- filter(sweep, panel == "b", measure == "windmax_area_month", abs(t) > 1.96)
            if (nrow(z)) as.character(max(z$L)) else "none" })
)
writeLines(facts, file.path(DIR_TAB, "sweep_facts.tex"))

message("\ndone. sweep -> ", file.path(DIR_FIG, "lag_sweep.png"))
