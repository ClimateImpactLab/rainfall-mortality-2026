#========================================================================================#
#' Young-Hsiang mortality regressions with native (LICRICE) and ERA5-Land wind
#'
#' Two things happen here:
#'
#'   1. Replicate the Young-Hsiang main result. Their headline specification is a
#'      distributed lag of state-month TC wind (`maxs`) over 0-240 monthly lags on
#'      the all-cause monthly mortality rate, with a heavy fixed-effect structure
#'      (scripts/02-run-regressions.do in the young_hsiang_tc_mortality repo).
#'
#'   2. Swap `maxs` for the ERA5-Land wind variables added to the same panel, and
#'      run the two measures head to head (separately and in a horse race).
#'
#' The Stata original is
#'   areg Y _iy_* _imt* _mi_* _iT_* _LL*_maxs, absorb(modate)
#' where the xi-expanded blocks are
#'   _mi_  i.stfips*i.month           state-by-calendar-month FE
#'   _iy_  i.stfips*modate^(1..8)     state-specific 8th-order polynomial in time
#'   _imt  i.(stfips#month)*modate    state-by-month-specific linear trend
#'   _iT_  i.stfips*(tavg, tavg^2)    state-specific quadratic in temperature
#' and absorb(modate) is a month-of-sample FE. The fixest translation used below is
#'   | modate + stfips^month[t1] + stfips[t2..t8, tavg, tavg2]
#' which spans the same column space: stfips^month[t1] delivers _mi_ and _imt
#' jointly, and stfips[t2..t8] delivers _iy_ net of the t1 term already carried by
#' the state-by-month trend. `areg` reports iid standard errors (no vce() in their
#' code), so iid is the default here, with state-clustered SEs as a robustness.
#'
#' Inputs:
#'   young_hsiang_state_month_era5land_wind_1950_2015.csv   (built by coauthor;
#'   see README.md in this directory)
#'
#' Outputs (all consumed by ../../output/slides/wind_tc_validation.tex):
#'   output/data/wind_tc_validation/*.csv     cumulative lag profiles
#'   output/figures/wind_tc_validation/*.png  figures
#'   output/tables/wind_tc_validation/*.tex   results table + \newcommand facts
#'
#' Run:  Rscript adhoc/wind_tc_validation/02_young_hsiang_regressions_era5.R
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

# ---------------------------------------------------------------------------
# 4. Replication of the Young-Hsiang main result
# ---------------------------------------------------------------------------
message("\n=== 4. replication ===")

rep_main <- fit_dl("maxs", L_MAIN, label = "maxs, YH replication")

write_csv(rep_main$cum, file.path(DIR_DATA, "cum_replication.csv"))

hl <- filter(rep_main$cum, lag == LAG_REF)
message(sprintf("  headline: cumulative at lag %d = %.3f (iid se %.3f, t %.2f; clustered se %.3f)",
                LAG_REF, hl$cum, hl$cum_se, hl$cum / hl$cum_se, hl$cum_se_cl))

# ---------------------------------------------------------------------------
# 5. Horizon and sample sensitivity
# ---------------------------------------------------------------------------
# ERA5-Land wind starts in 1950, so a 240-lag model in ERA5 wind cannot use an
# outcome observation before 1970. Re-estimating `maxs` on that shorter sample is
# the diagnostic for whether the 20-year lag window survives the loss of data.
message("\n=== 5. horizon / sample sensitivity ===")

ERA5_YEAR_MIN <- min(filter(d, !is.na(windmax_area_month))$year)
yr_min_long   <- ERA5_YEAR_MIN + L_MAIN / 12
yr_min_short  <- ERA5_YEAR_MIN + L_SHORT / 12

sens <- bind_rows(list(
  fit_dl("maxs", L_MAIN,  year_min = yr_min_long,
         label = "maxs, ERA5-feasible sample")$cum,
  fit_dl("windmax_area_month", L_MAIN, year_min = yr_min_long,
         label = "ERA5 area-wt, 240 lags")$cum
))
write_csv(sens, file.path(DIR_DATA, "cum_sensitivity.csv"))

# ---------------------------------------------------------------------------
# 6. Head to head on a 5-year lag window
# ---------------------------------------------------------------------------
# The short window is the honest common ground: it keeps 1955-2012 for every
# measure and is far better identified than 241 lags on 43 years of outcome.
message("\n=== 6. head to head, L = ", L_SHORT, " ===")

h2h <- bind_rows(lapply(names(MEASURES), function(x)
  fit_dl(x, L_SHORT, year_min = yr_min_short, label = x)$cum))

# The same race over a 1-year window. Fewest lags, longest sample, least
# collinearity between lags - so this is the best-identified comparison of the
# three, at the cost of only capturing the near-term response.
message("\n=== 6b. head to head, L = ", L_YEAR, " ===")
yr_min_year <- ERA5_YEAR_MIN + L_YEAR / 12
h2h_yr <- bind_rows(lapply(names(MEASURES), function(x)
  fit_dl(x, L_YEAR, year_min = yr_min_year, label = x)$cum))

race_raw <- fit_dl(c("maxs", "windmax_area_month"), L_SHORT, year_min = yr_min_short,
                   label = "horse race: maxs + ERA5 raw")$cum
race_exc <- fit_dl(c("maxs", "w_exc"), L_SHORT, year_min = yr_min_short,
                   label = "horse race: maxs + ERA5 exceedance")$cum

write_csv(bind_rows(h2h, h2h_yr, race_raw, race_exc),
          file.path(DIR_DATA, "cum_head_to_head.csv"))

# ---------------------------------------------------------------------------
# 7. Figures: replication
# ---------------------------------------------------------------------------
message("\n=== 7. figures ===")


lag_axis <- list(
  scale_x_continuous(breaks = seq(0, 240, 48)),
  geom_hline(yintercept = 0, colour = "black", linewidth = 0.3),
  labs(x = "Months since tropical cyclone")
)

# panel (a): the lag-by-lag coefficients, panel (b): the running sum, as in
# Young-Hsiang Figure 2.
cum_l <- rep_main$cum

p_a <- ggplot(cum_l, aes(lag, beta)) +
  geom_ribbon(aes(ymin = beta - 1.96 * beta_se, ymax = beta + 1.96 * beta_se),
              fill = GREEN, alpha = 0.20) +
  geom_line(colour = GREEN, linewidth = 0.4) +
  lag_axis +
  labs(y = "Monthly mortality rate\n(per 100,000 per m/s)",
       title = "(a) Lag-by-lag coefficients")

p_b <- ggplot(cum_l, aes(lag, cum)) +
  geom_ribbon(aes(ymin = cum - 1.96 * cum_se, ymax = cum + 1.96 * cum_se),
              fill = GREEN, alpha = 0.20) +
  geom_line(colour = GREEN, linewidth = 0.6) +
  geom_vline(xintercept = LAG_REF, linetype = "dashed", colour = GREY, linewidth = 0.3) +
  annotate("text", x = LAG_REF, y = -Inf, label = paste0(" ", LAG_REF, " months"),
           hjust = 0, vjust = -0.6, size = 3, colour = GREY) +
  lag_axis +
  labs(y = "Cumulative mortality rate\n(per 100,000 per m/s)",
       title = "(b) Cumulative effect")

save_fig("replication_main.png", p_a / p_b,
       width = 7.5, height = 6)

# ---------------------------------------------------------------------------
# 8. Figures: horizon / sample sensitivity
# ---------------------------------------------------------------------------
lab_full  <- paste0("(1) maxs, full sample (", rep_main$est_years[1], "-)")
lab_short <- paste0("(2) maxs, same spec, ERA5-feasible sample (",
                    filter(sens, spec == "maxs, ERA5-feasible sample")$year_lo[1], "-)")
lab_era5  <- "(3) ERA5-Land area-wt wind, same sample as (2)"

sens_plot <- bind_rows(
  rep_main$cum %>% transmute(spec = lab_full, measure, lag, cum, cum_se),
  sens %>% filter(spec == "maxs, ERA5-feasible sample") %>%
    transmute(spec = lab_short, measure, lag, cum, cum_se),
  sens %>% filter(spec == "ERA5 area-wt, 240 lags") %>%
    transmute(spec = lab_era5, measure, lag, cum, cum_se))
# In SD units: curve (3) is a different variable from (1) and (2), so per m/s the
# three are not on a comparable scale.
sens_plot <- sens_plot %>%
  mutate(sd_scale = sd_scale_of(measure),
         cum      = cum * sd_scale,
         cum_se   = cum_se * sd_scale,
         spec     = factor(spec, levels = c(lab_full, lab_short, lab_era5)))

p_sens <- ggplot(sens_plot, aes(lag, cum, colour = spec, fill = spec)) +
  geom_ribbon(aes(ymin = cum - 1.96 * cum_se, ymax = cum + 1.96 * cum_se),
              alpha = 0.15, colour = NA) +
  geom_line(linewidth = 0.6) +
  geom_hline(yintercept = 0, linewidth = 0.3) +
  geom_vline(xintercept = LAG_REF, linetype = "dashed", colour = GREY, linewidth = 0.3) +
  scale_colour_manual(values = c(GREEN, ORANGE, BLUE)) +
  scale_fill_manual(values = c(GREEN, ORANGE, BLUE)) +
  scale_x_continuous(breaks = seq(0, 240, 48)) +
  guides(colour = guide_legend(nrow = 3)) +
  labs(x = "Months since wind exposure",
       y = "Cumulative mortality rate\n(per 100,000 per SD)",
       colour = NULL, fill = NULL) +
  theme(legend.position = c(0.02, 0.98), legend.justification = c(0, 1),
        legend.background = element_blank())

save_fig("sensitivity_240lags.png", p_sens,
       width = 7.5, height = 4.2)

# ---------------------------------------------------------------------------
# 9. Figures: head to head
# ---------------------------------------------------------------------------
# Rescale each measure by its own within-state standard deviation so the curves
# are on one axis: "deaths per 100,000 per 1 SD of the wind measure".
#' Cumulative-effect curves for several wind measures on one axis, each rescaled
#' by its own within-state SD so the units are comparable across measures.
#' Left: cumulative-effect curves. Right: the same models' terminal cumulative
#' effect with 95\% intervals, one row per specification. Both panels are on the
#' same per-SD scale (masked measures use their parent's SD), so the right panel
#' is a readable cross-section of the left one at its final lag.
plot_h2h <- function(dt, brk) {
  dt <- dt %>%
    mutate(sd_scale  = sd_scale_of(measure),
           cum_sd    = cum * sd_scale,
           cum_sd_se = cum_se * sd_scale,
           family    = factor(FAMILY[measure], levels = FAMILY_LEVELS),
           masked    = factor(if_else(grepl("_tc$", measure),
                                      "zeroed outside TC months", "as measured"),
                              levels = c("as measured", "zeroed outside TC months")))
  PAL <- c(GREEN, ORANGE, "#e8a33d", BLUE)

  p_curve <- ggplot(dt, aes(lag, cum_sd, colour = family, fill = family,
                            linetype = masked)) +
    geom_ribbon(aes(ymin = cum_sd - 1.96 * cum_sd_se, ymax = cum_sd + 1.96 * cum_sd_se),
                alpha = 0.09, colour = NA) +
    geom_line(linewidth = 0.6) +
    geom_hline(yintercept = 0, linewidth = 0.3) +
    scale_colour_manual(values = PAL) + scale_fill_manual(values = PAL) +
    scale_linetype_manual(values = c("solid", "22")) +
    scale_x_continuous(breaks = brk) +
    labs(x = "Months since wind exposure",
         y = "Cumulative mortality rate\n(per 100,000 per SD)",
         colour = NULL, fill = NULL, linetype = NULL,
         subtitle = "(a) Cumulative effect by lag")

  # terminal estimate of each specification
  end <- dt %>% filter(lag == max(lag)) %>%
    mutate(slab = factor(SHORT_LAB[measure], levels = rev(SHORT_LAB)))
  p_end <- ggplot(end, aes(cum_sd, slab, colour = family, shape = masked)) +
    geom_vline(xintercept = 0, colour = GREY, linewidth = 0.3) +
    geom_pointrange(aes(xmin = cum_sd - 1.96 * cum_sd_se,
                        xmax = cum_sd + 1.96 * cum_sd_se), size = 0.4) +
    scale_colour_manual(values = PAL, guide = "none") +
    scale_shape_manual(values = c(16, 21), guide = "none") +
    labs(x = "Cumulative effect at the end\nof the window (per 100,000 per SD)",
         y = NULL, subtitle = sprintf("(b) At %d months", max(dt$lag)))

  (p_curve | p_end) + plot_layout(widths = c(1.9, 1), guides = "collect") &
    theme(legend.position = "bottom", legend.text = element_text(size = 8),
          legend.key.width = unit(1.4, "lines"),
          plot.subtitle = element_text(size = 10))
}

save_fig("head_to_head.png",
       plot_h2h(h2h, seq(0, L_SHORT, 12)), width = 11, height = 4.6)

save_fig("head_to_head_12.png",
       plot_h2h(h2h_yr, seq(0, L_YEAR, 2)), width = 11, height = 4.6)

# horse race: same measures, entered jointly
race <- bind_rows(race_raw, race_exc) %>%
  mutate(sd_scale  = sd_scale_of(measure),
         cum_sd    = cum * sd_scale,
         cum_sd_se = cum_se * sd_scale,
         panel     = ifelse(spec == "horse race: maxs + ERA5 raw",
                            "maxs + ERA5 raw wind", "maxs + ERA5 exceedance"),
         lab       = factor(FAMILY[measure], levels = FAMILY_LEVELS))

p_race <- ggplot(race, aes(lag, cum_sd, colour = lab, fill = lab)) +
  geom_ribbon(aes(ymin = cum_sd - 1.96 * cum_sd_se, ymax = cum_sd + 1.96 * cum_sd_se),
              alpha = 0.12, colour = NA) +
  geom_line(linewidth = 0.6) +
  geom_hline(yintercept = 0, linewidth = 0.3) +
  facet_wrap(~panel) +
  scale_colour_manual(values = c(GREEN, ORANGE, "#e8a33d", BLUE), drop = FALSE) +
  scale_fill_manual(values = c(GREEN, ORANGE, "#e8a33d", BLUE), drop = FALSE) +
  scale_x_continuous(breaks = seq(0, L_SHORT, 12)) +
  labs(x = "Months since wind exposure",
       y = "Cumulative mortality rate\n(per 100,000 per SD)",
       colour = NULL, fill = NULL) +
  theme(legend.position = "bottom", strip.background = element_blank())

save_fig("horse_race.png", p_race,
       width = 7.5, height = 4.2)

# ---------------------------------------------------------------------------
# 10. Diagnostics on the two wind measures
# ---------------------------------------------------------------------------
dd <- filter(d, year >= 1950)

# (a) seasonality. All measures are in m/s; each series is indexed to its own peak
# month so the timing is comparable despite levels differing by two orders of
# magnitude. Four statistics, because they do not agree and the disagreement is
# the substance: the single monthly MAXIMUM of raw ERA5 wind falls in August, but
# that is one observation (Rhode Island, August 1954). Every robust tail
# statistic - the 99th percentile, the mean - peaks in late winter instead, and
# only 31 of the 100 windiest state-months fall in Jun-Nov against 50 if timing
# were flat. The last panel repeats the mean on TC-exposed states only, to rule
# out a composition effect from the states that never see a cyclone.
# pivot_longer gives a character column; the levels are set explicitly so the
# colour order matches the column order, as data.table's melt() used to give.
SEAS_VARS <- c("Young-Hsiang maxs", "ERA5-Land wind (area-wt)", "ERA5-Land exceedance")

seas_by <- function(f, lab, x)
  x %>%
    group_by(month) %>%
    summarise(`Young-Hsiang maxs`        = f(maxs),
              `ERA5-Land wind (area-wt)` = f(windmax_area_month),
              `ERA5-Land exceedance`     = f(w_exc), .groups = "drop") %>%
    pivot_longer(-month, names_to = "variable", values_to = "value") %>%
    mutate(variable = factor(variable, levels = SEAS_VARS), stat = lab)

p99 <- function(v) quantile(v, 0.99)
STAT_LEVELS <- c("Maximum, all states", "99th percentile, all states",
                 "Mean, all states", "Mean, TC states only")
seas <- bind_rows(seas_by(max,  STAT_LEVELS[1], dd),
                  seas_by(p99,  STAT_LEVELS[2], dd),
                  seas_by(mean, STAT_LEVELS[3], dd),
                  seas_by(mean, STAT_LEVELS[4], filter(dd, tc_state))) %>%
  mutate(stat = factor(stat, levels = STAT_LEVELS)) %>%
  group_by(variable, stat) %>%
  mutate(index = value / max(value)) %>%
  ungroup()

p_seas <- ggplot(seas, aes(month, index, colour = variable)) +
  geom_line(linewidth = 0.5) +
  geom_point(size = 1.1) +
  facet_wrap(~stat, ncol = 4) +
  scale_x_continuous(breaks = c(1, 4, 7, 10),
                     labels = c("J", "A", "J", "O")) +
  scale_y_continuous(limits = c(0, 1.02)) +
  scale_colour_manual(values = c(GREEN, ORANGE, BLUE)) +
  labs(x = "Calendar month", colour = NULL,
       y = "Share of the series'\nown peak month",
       subtitle = "Each series indexed to its own peak month; all are in m/s") +
  theme(legend.position = "bottom", plot.subtitle = element_text(size = 9),
        strip.background = element_blank(), strip.text = element_text(hjust = 0, size = 9))

# (b) does ERA5 wind flag the TC months at all? The two densities almost coincide,
#     so on its own level the raw measure does not separate TC from non-TC months.
p_dens <- ggplot(filter(dd, tc_state), aes(windmax_area_month,
                         fill = ifelse(maxs > 0, "TC month", "non-TC month"))) +
  geom_density(alpha = 0.45, colour = NA) +
  scale_fill_manual(values = c(GREY, ORANGE)) +
  labs(x = "ERA5-Land wind, area-wt (m/s)", y = "Density", fill = NULL,
       subtitle = "TC-exposed states only") +
  theme(legend.position = c(0.98, 0.98), legend.justification = c(1, 1),
        legend.background = element_blank())

save_fig("diagnostics.png", p_seas / p_dens,
       width = 10.5, height = 6)

# ---------------------------------------------------------------------------
# 10b. Scatter and time series: are these the same variable?
# ---------------------------------------------------------------------------

# (a) every state-month. The wall of points at maxs == 0 is the whole story:
#     maxs is a spike train, ERA5-Land wind is an always-on series.
p_all <- ggplot(dd, aes(maxs, windmax_area_month)) +
  geom_point(alpha = 0.10, size = 0.5, colour = BLUE) +
  labs(x = "Young-Hsiang maxs (m/s)", y = "ERA5-Land wind, area-wt (m/s)",
       subtitle = sprintf("(a) all state-months (n = %s), r = %.2f",
                          format(nrow(dd), big.mark = ","),
                          cor(dd$maxs, dd$windmax_area_month)))

# (b) TC months only, with the 45-degree line and the fitted slope. The fit is far
#     flatter than 45 degrees: ERA5-Land compresses the TC tail.
ols <- coef(lm(windmax_area_month ~ maxs, filter(dd, maxs > 0)))
bin_br <- seq(0, ceiling(max(dd$maxs) / 5) * 5, 5)
bin_m <- dd %>%
  filter(maxs > 0) %>%
  mutate(x = cut(maxs, breaks = bin_br)) %>%
  group_by(x) %>%
  summarise(y = mean(windmax_area_month), N = n(), .groups = "drop") %>%
  filter(!is.na(x)) %>%
  mutate(x_mid = bin_br[as.integer(x)] + 2.5)   # midpoint from the level, not position

p_tc <- ggplot(filter(dd, maxs > 0), aes(maxs, windmax_area_month)) +
  geom_point(alpha = 0.22, size = 0.6, colour = BLUE) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = GREY) +
  geom_smooth(method = "lm", se = FALSE, colour = ORANGE, linewidth = 0.7, formula = y ~ x) +
  geom_point(data = bin_m, aes(x_mid, y), colour = "black", size = 1.8, inherit.aes = FALSE) +
  labs(x = "Young-Hsiang maxs (m/s)", y = NULL,
       subtitle = sprintf("(b) TC months only, r = %.2f; slope = %.2f (dashed = 45\u00b0)",
                          cor(filter(dd, maxs > 0)$maxs, filter(dd, maxs > 0)$windmax_area_month), ols[2]))

save_fig("scatter_maxs_era5.png", p_all | p_tc,
       width = 9, height = 4.2)

# (c) one state, monthly. Florida has the most TC months in the panel.
ts_state <- "FL"; ts_lo <- 1990
FL_VARS <- c("Young-Hsiang maxs", "ERA5-Land wind (area-wt)",
             "ERA5-Land exceedance (p95)")
fl <- dd %>%
  filter(state_abbrev == ts_state, year >= ts_lo) %>%
  transmute(date = year + (month - 0.5) / 12,
            `Young-Hsiang maxs`          = maxs,
            `ERA5-Land wind (area-wt)`   = windmax_area_month,
            `ERA5-Land exceedance (p95)` = w_exc) %>%
  pivot_longer(-date, names_to = "variable", values_to = "value") %>%
  mutate(variable = factor(variable, levels = FL_VARS))

p_fl <- ggplot(fl, aes(date, value)) +
  geom_line(linewidth = 0.35, colour = BLUE) +
  facet_wrap(~variable, ncol = 1, scales = "free_y") +
  labs(x = NULL, y = "m/s",
       subtitle = sprintf("(a) %s, %d-%d: a spike train versus an always-on series",
                          ts_state, ts_lo, max(dd$year))) +
  theme(strip.background = element_blank(), strip.text = element_text(hjust = 0))

# (d) four event windows chosen to span the four corners of the comparison:
#     both measures fire, only maxs fires, only ERA5 fires.
events <- tibble(
  state = c("RI", "VT", "SC", "NE"),
  yr    = c(1954, 1979, 1989, 1968),
  mo    = c(9,    9,    9,    12),
  lab   = c("RI 1954m9: both fire", "VT 1979m9: maxs only",
            "SC 1989m9: both fire", "NE 1968m12: ERA5 only"))

win <- bind_rows(lapply(seq_len(nrow(events)), function(i) {
  e  <- events[i, ]
  c0 <- filter(dd, state_abbrev == e$state, year == e$yr, month == e$mo)$modate
  dd %>%
    filter(state_abbrev == e$state, modate >= c0 - 24, modate <= c0 + 24) %>%
    transmute(rel = modate - c0, lab = e$lab,
              `Young-Hsiang maxs`        = maxs,
              `ERA5-Land wind (area-wt)` = windmax_area_month) %>%
    pivot_longer(-c(rel, lab), names_to = "variable", values_to = "value") %>%
    mutate(variable = factor(variable, levels = SEAS_VARS[1:2]))
}))
win <- mutate(win, lab = factor(lab, levels = events$lab))

p_ev <- ggplot(win, aes(rel, value, colour = variable)) +
  geom_line(linewidth = 0.45) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = GREY, linewidth = 0.3) +
  facet_wrap(~lab, nrow = 1) +
  scale_colour_manual(values = c(ORANGE, BLUE)) +
  labs(x = "Months from event", y = "m/s", colour = NULL,
       subtitle = "(b) \u00b124-month windows around four state-months") +
  theme(legend.position = "bottom", strip.background = element_blank())

save_fig("timeseries.png",
       (p_fl / p_ev) + plot_layout(heights = c(1.35, 1)),
       width = 9, height = 7)

# facts for the "different objects" slide
top50   <- dd %>% arrange(desc(windmax_area_month)) %>% slice(1:50)
dd <- dd %>% group_by(stfips) %>%
  mutate(era5_pct = rank(windmax_area_month) / n()) %>% ungroup()
top_maxs <- dd %>% arrange(desc(maxs)) %>% slice(1:50)

# ---------------------------------------------------------------------------
# 11. Tables
# ---------------------------------------------------------------------------
message("\n=== 11. tables ===")


#' One row of the results table: the cumulative effect at the end of the lag
#' window, in native units and per within-state SD.
row_of <- function(dt, measure_name, spec_label) {
  r <- dt %>% filter(measure == measure_name) %>% filter(lag == max(lag))
  sprintf("%s & %s & %s & %s & (%s) & %s & %s \\\\",
          spec_label, MEASURES[measure_name], fmt(r$nobs, 0),
          fmt(r$cum), fmt(r$cum_se), fmt(r$cum / r$cum_se, 2),
          fmt(r$cum * sd_scale_of(measure_name), 3))
}

tab <- c(
  "\\begin{tabular}{llccccc}",
  "\\toprule",
  " & & $N$ & Cumulative & (s.e.) & $t$ & Per SD \\\\",
  "\\midrule",
  "\\multicolumn{7}{l}{\\textit{Panel A: replication, full Young--Hsiang sample}} \\\\",
  row_of(filter(rep_main$cum, lag <= LAG_REF), "maxs", sprintf("At lag %d", LAG_REF)),
  row_of(rep_main$cum, "maxs", "At lag 240"),
  "\\midrule",
  "\\multicolumn{7}{l}{\\textit{Panel B: 240 lags, ERA5-feasible sample}} \\\\",
  row_of(filter(sens, spec == "maxs, ERA5-feasible sample"), "maxs", "At lag 240"),
  row_of(filter(sens, spec == "ERA5 area-wt, 240 lags"), "windmax_area_month", "At lag 240"),
  "\\midrule",
  sprintf("\\multicolumn{7}{l}{\\textit{Panel C: %d lags, common sample}} \\\\", L_YEAR),
  row_of(h2h_yr, "maxs",               sprintf("At lag %d", L_YEAR)),
  row_of(h2h_yr, "windmax_area_month", sprintf("At lag %d", L_YEAR)),
  row_of(h2h_yr, "windmax_pop_month",  sprintf("At lag %d", L_YEAR)),
  row_of(h2h_yr, "w_exc",              sprintf("At lag %d", L_YEAR)),
  row_of(h2h_yr, "windmax_area_month_tc", sprintf("At lag %d", L_YEAR)),
  row_of(h2h_yr, "w_exc_tc",              sprintf("At lag %d", L_YEAR)),
  "\\midrule",
  sprintf("\\multicolumn{7}{l}{\\textit{Panel D: %d lags, common sample}} \\\\", L_SHORT),
  row_of(h2h, "maxs",               sprintf("At lag %d", L_SHORT)),
  row_of(h2h, "windmax_area_month", sprintf("At lag %d", L_SHORT)),
  row_of(h2h, "windmax_pop_month",  sprintf("At lag %d", L_SHORT)),
  row_of(h2h, "w_exc",              sprintf("At lag %d", L_SHORT)),
  row_of(h2h, "windmax_area_month_tc", sprintf("At lag %d", L_SHORT)),
  row_of(h2h, "w_exc_tc",              sprintf("At lag %d", L_SHORT)),
  "\\midrule",
  sprintf("\\multicolumn{7}{l}{\\textit{Panel E: horse races, %d lags (both measures entered jointly)}} \\\\", L_SHORT),
  row_of(race_raw, "maxs",               "Race 1"),
  row_of(race_raw, "windmax_area_month", "Race 1"),
  row_of(race_exc, "maxs",               "Race 2"),
  row_of(race_exc, "w_exc",              "Race 2"),
  "\\bottomrule",
  "\\end{tabular}"
)
writeLines(tab, file.path(DIR_TAB, "results.tex"))

# facts referenced on the slides
hl240 <- filter(rep_main$cum, lag == max(lag))
sens_maxs <- sens %>% filter(spec == "maxs, ERA5-feasible sample") %>% filter(lag == max(lag))
sens_era  <- sens %>% filter(spec == "ERA5 area-wt, 240 lags") %>% filter(lag == max(lag))

facts <- c(
  sprintf("\\newcommand{\\yhCumRef}{%s}",   fmt(hl$cum)),
  sprintf("\\newcommand{\\yhCumRefSe}{%s}", fmt(hl$cum_se)),
  sprintf("\\newcommand{\\yhCumRefT}{%s}",  fmt(hl$cum / hl$cum_se, 2)),
  sprintf("\\newcommand{\\yhLagRef}{%d}",   LAG_REF),
  sprintf("\\newcommand{\\yhCumEnd}{%s}",   fmt(hl240$cum)),
  sprintf("\\newcommand{\\yhNobs}{%s}",     fmt(rep_main$nobs, 0)),
  sprintf("\\newcommand{\\yhYearLo}{%d}",   rep_main$est_years[1]),
  sprintf("\\newcommand{\\yhYearHi}{%d}",   rep_main$est_years[2]),
  sprintf("\\newcommand{\\yhStates}{%d}",   n_distinct(d$stfips)),
  sprintf("\\newcommand{\\eraYearMin}{%d}", ERA5_YEAR_MIN),
  sprintf("\\newcommand{\\eraSampleLo}{%d}", filter(sens, spec == "ERA5 area-wt, 240 lags")$year_lo[1]),
  sprintf("\\newcommand{\\shortSampleLo}{%d}", h2h$year_lo[1]),
  sprintf("\\newcommand{\\shortLags}{%d}",  L_SHORT),
  sprintf("\\newcommand{\\yearLags}{%d}",   L_YEAR),
  sprintf("\\newcommand{\\yearSampleLo}{%d}", h2h_yr$year_lo[1]),
  sprintf("\\newcommand{\\yearNobs}{%s}",   fmt(h2h_yr$nobs[1], 0)),
  sprintf("\\newcommand{\\yrMaxsT}{%s}",
          fmt(with(filter(h2h_yr, measure == "maxs", lag == L_YEAR), cum / cum_se), 2)),
  sprintf("\\newcommand{\\yrEraRawT}{%s}",
          fmt(with(filter(h2h_yr, measure == "windmax_area_month", lag == L_YEAR), cum / cum_se), 2)),
  # per-SD effects at the 1-year horizon, masked vs as-measured
  sprintf("\\newcommand{\\yrMaxsSD}{%s}",
          fmt(with(filter(h2h_yr, measure == "maxs", lag == L_YEAR), cum) * SDS["maxs"], 3)),
  sprintf("\\newcommand{\\yrRawSD}{%s}",
          fmt(with(filter(h2h_yr, measure == "windmax_area_month", lag == L_YEAR), cum) * SDS["windmax_area_month"], 3)),
  sprintf("\\newcommand{\\yrExcSD}{%s}",
          fmt(with(filter(h2h_yr, measure == "w_exc", lag == L_YEAR), cum) * SDS["w_exc"], 3)),
  sprintf("\\newcommand{\\yrRawMaskSD}{%s}",
          fmt(with(filter(h2h_yr, measure == "windmax_area_month_tc", lag == L_YEAR), cum) * sd_scale_of("windmax_area_month_tc"), 3)),
  sprintf("\\newcommand{\\sweepExcMaskUnit}{%s}",
          fmt(with(filter(h2h_yr, measure == "w_exc_tc", lag == L_YEAR), cum), 3)),
  sprintf("\\newcommand{\\sdRawParent}{%s}", fmt(SDS["windmax_area_month"], 2)),
  sprintf("\\newcommand{\\sdRawMasked}{%s}", fmt(SDS["windmax_area_month_tc"], 2)),
  sprintf("\\newcommand{\\sdExcParent}{%s}", fmt(SDS["w_exc"], 2)),
  sprintf("\\newcommand{\\sdExcMasked}{%s}", fmt(SDS["w_exc_tc"], 2)),
  sprintf("\\newcommand{\\yrExcMaskSD}{%s}",
          fmt(with(filter(h2h_yr, measure == "w_exc_tc", lag == L_YEAR), cum) * sd_scale_of("w_exc_tc"), 3)),
  sprintf("\\newcommand{\\yrRawMaskT}{%s}",
          fmt(with(filter(h2h_yr, measure == "windmax_area_month_tc", lag == L_YEAR), cum / cum_se), 2)),
  sprintf("\\newcommand{\\yrExcMaskT}{%s}",
          fmt(with(filter(h2h_yr, measure == "w_exc_tc", lag == L_YEAR), cum / cum_se), 2)),
  sprintf("\\newcommand{\\shortExcMaskT}{%s}",
          fmt(with(filter(h2h, measure == "w_exc_tc", lag == L_SHORT), cum / cum_se), 2)),
  sprintf("\\newcommand{\\shortRawMaskT}{%s}",
          fmt(with(filter(h2h, measure == "windmax_area_month_tc", lag == L_SHORT), cum / cum_se), 2)),
  sprintf("\\newcommand{\\yrExcT}{%s}",
          fmt(with(filter(h2h_yr, measure == "w_exc", lag == L_YEAR), cum / cum_se), 2)),
  sprintf("\\newcommand{\\maxsShrZero}{%s}", fmt(100 * mean(dd$maxs == 0), 1)),
  sprintf("\\newcommand{\\corrTC}{%s}",      fmt(with(filter(dd, maxs > 0), cor(maxs, windmax_area_month)), 2)),
  sprintf("\\newcommand{\\peakMaxsMax}{%s}",
          month.name[(dd %>% group_by(month) %>% summarise(v = max(maxs), .groups = "drop") %>% slice(which.max(v)) %>% pull(month))]),
  sprintf("\\newcommand{\\peakRawPtile}{%s}",
          month.name[(dd %>% group_by(month) %>% summarise(v = quantile(windmax_area_month, .99), .groups = "drop") %>% slice(which.max(v)) %>% pull(month))]),
  sprintf("\\newcommand{\\topHundredSeason}{%d}",
          nrow(filter(slice(arrange(dd, desc(windmax_area_month)), 1:100), month %in% 6:11))),
  sprintf("\\newcommand{\\topHundredAug}{%d}",
          nrow(filter(slice(arrange(dd, desc(windmax_area_month)), 1:100), month == 8))),
  sprintf("\\newcommand{\\peakRawMax}{%s}",
          month.name[(dd %>% group_by(month) %>% summarise(v = max(windmax_area_month), .groups = "drop") %>% slice(which.max(v)) %>% pull(month))]),
  sprintf("\\newcommand{\\peakRawMean}{%s}",
          month.name[(dd %>% group_by(month) %>% summarise(v = mean(windmax_area_month), .groups = "drop") %>% slice(which.max(v)) %>% pull(month))]),
  sprintf("\\newcommand{\\peakExcMax}{%s}",
          month.name[(dd %>% group_by(month) %>% summarise(v = max(w_exc), .groups = "drop") %>% slice(which.max(v)) %>% pull(month))]),
  sprintf("\\newcommand{\\tcStates}{%d}", n_distinct(filter(dd, tc_state)$stfips)),
  sprintf("\\newcommand{\\tcMonthMean}{%s}",
          fmt(mean(filter(dd, tc_state, maxs > 0)$windmax_area_month), 2)),
  sprintf("\\newcommand{\\nonTcMonthMean}{%s}",
          fmt(mean(filter(dd, tc_state, maxs == 0)$windmax_area_month), 2)),
  sprintf("\\newcommand{\\corrAll}{%s}",     fmt(cor(dd$maxs, dd$windmax_area_month), 2)),
  sprintf("\\newcommand{\\olsSlope}{%s}",    fmt(ols[2], 2)),
  sprintf("\\newcommand{\\excShare}{%s}",    fmt(100 * mean(dd$w_exc > 0), 1)),
  sprintf("\\newcommand{\\excMeanPos}{%s}",  fmt(mean(filter(dd, w_exc > 0)$w_exc), 2)),
  sprintf("\\newcommand{\\maxsSharePos}{%s}", fmt(100 * mean(dd$maxs > 0), 1)),
  sprintf("\\newcommand{\\maxsMeanPos}{%s}", fmt(mean(filter(dd, maxs > 0)$maxs), 1)),
  sprintf("\\newcommand{\\eraMin}{%s}",      fmt(min(dd$windmax_area_month), 1)),
  sprintf("\\newcommand{\\eraMean}{%s}",     fmt(mean(dd$windmax_area_month), 1)),
  sprintf("\\newcommand{\\topEraTC}{%d}",    sum(top50$maxs > 0)),
  sprintf("\\newcommand{\\topMaxsPct}{%s}",  fmt(100 * median(top_maxs$era5_pct), 0)),
  sprintf("\\newcommand{\\sensMaxsEnd}{%s}", fmt(sens_maxs$cum)),
  sprintf("\\newcommand{\\sensMaxsEndT}{%s}", fmt(sens_maxs$cum / sens_maxs$cum_se, 2)),
  sprintf("\\newcommand{\\sensEraEnd}{%s}",  fmt(sens_era$cum)),
  sprintf("\\newcommand{\\sensEraEndSe}{%s}", fmt(sens_era$cum_se)),
  sprintf("\\newcommand{\\sensEraEndT}{%s}", fmt(sens_era$cum / sens_era$cum_se, 2)),
  sprintf("\\newcommand{\\sensEraLo}{%s}",   fmt(sens_era$cum - 1.96 * sens_era$cum_se)),
  sprintf("\\newcommand{\\sensEraHi}{%s}",   fmt(sens_era$cum + 1.96 * sens_era$cum_se)),
  sprintf("\\newcommand{\\seRatio}{%s}",     fmt(sens_era$cum_se / sens_maxs$cum_se, 1)),
  sprintf("\\newcommand{\\sensNobs}{%s}",    fmt(sens_maxs$nobs, 0)),
  sprintf("\\newcommand{\\raceMaxsT}{%s}",
          fmt(with(filter(race_exc, measure == "maxs", lag == L_SHORT), cum / cum_se), 2)),
  sprintf("\\newcommand{\\raceExcT}{%s}",
          fmt(with(filter(race_exc, measure == "w_exc", lag == L_SHORT), cum / cum_se), 2))
)
writeLines(facts, file.path(DIR_TAB, "facts.tex"))

message("\ndone. figures -> ", DIR_FIG)

