# ============================================================================
# 03_figures.R
#
# Figures and tables for the precip poly regs (02_regs.R), one set per FE
# spec. Reads the saved coefs and vcov, reruns nothing.
#
#   fig_daily_response     one day with d mm of rainfall vs a dry day,
#                          summed over months 0-2, 3-5, 6-8, 9-11, 0-11, and
#                          the 6 leads (placebo)
#   fig_monthly_response   same for a month with M mm vs a median month
#   fig_lag_profile        month by month: a p99 and a p99.9 day
#   fig_temp_lags          month by month, temp this month only vs + 11 lags:
#                          p99 day, p10 month, SPI dry and wet
#   precip_monthly_windows.csv, precip_monthly_temp_lags_windows.csv
#                          the windows at the marked rainfall levels
#
# Effects are % change in monthly deaths. The marked rainfall levels are
# percentiles of daily and monthly rainfall across municipalities, 1997-2010.
#
# Output: output/data/precip-monthly/1997_2010/summary/
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)
library(data.table)


# -----------------------------
# Paths and settings
# -----------------------------

# Results of 02_regs.R. Figures and tables go in its summary/ folder
RESULTS_DIR <- "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/output/data/precip-monthly/1997_2010"
OUTPUT_DIR <- file.path(RESULTS_DIR, "summary")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Panel (for the monthly rainfall percentiles) and daily rainfall (for the
# daily percentiles)
PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/",
  "precip_monthly/brazil_precip_monthly_panel_1997_2010.rds"
)
DAILY_DIR <- "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/BRA_STABLE/daily"

# The season trend FE is a robustness check, drawn only if their results exist
FE_SPECS <- c("saturated", "main", "seasontrend")
FE_LABELS <- c(saturated = "saturated FE", main = "main FE", seasontrend = "season trend FE")
age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

# Months added up in each window. Lag 0 is the death month itself
windows <- list(
  "Months 0-2" = 0:2,
  "Months 3-5" = 3:5,
  "Months 6-8" = 6:8,
  "Months 9-11" = 9:11,
  "Months 0-11" = 0:11,
  "Leads 1-6 (placebo)" = -(1:6)
)
# Extra windows, only for checking the timing: 2-month and  1-month blocks
windows_2m <- c(setNames(lapply(seq(0, 10, 2), function(m) m:(m + 1)), paste0("Months ", seq(0, 10, 2), "-", seq(1, 11, 2))),
                list("Leads 1-6 (placebo)" = -(1:6)))
windows_1m <- c(setNames(as.list(0:11), paste0("Month ", 0:11)), list("Leads 1-6 (placebo)" = -(1:6)))

# Same look for every figure
theme_set(
  theme_bw(base_size = 10) +
    theme(
      panel.grid.minor = element_blank(),
      strip.background = element_rect(fill = "grey92", color = NA),
      strip.text = element_text(face = "bold"),
      legend.position = "bottom"
    )
)

# Figures are saved as PDF (for Overleaf)
save_fig <- function(plot, name, width, height) {
  ggsave(file.path(OUTPUT_DIR, paste0(name, ".pdf")), plot, width = width, height = height, bg = "white")
}


# -----------------------------
# Rain percentiles, 1997-2010
# -----------------------------

# Daily: every municipality-day
# Monthly: every municipality-month
daily_rain <- unlist(lapply(1997:2010, function(y) {
  fread(file.path(DAILY_DIR, paste0("era5land_bra_stable_adm2_daily_", y, ".csv")), select = "prcp_pop_p1")[[1]]
}))
daily_pct <- quantile(daily_rain, c(0.5, 0.9, 0.95, 0.99, 0.999), na.rm = TRUE)
rm(daily_rain)

# Monthly totals back in mm (the panel has them in cm)
panel <- readRDS(PANEL_FILE)
monthly_rain <- unique(panel[, c("admin_id", "year", "month", "rain_d1")])$rain_d1 * 10
monthly_pct <- quantile(monthly_rain, c(0.01, 0.05, 0.1, 0.5, 0.9, 0.95, 0.99), na.rm = TRUE)
rm(panel)

# Print and save the percentiles used to mark the figures
print(round(daily_pct, 1))
print(round(monthly_pct, 1))
write_csv(
  tibble(measure = c(rep("daily_mm", 5), rep("monthly_mm", 7)),
         percentile = c(names(daily_pct), names(monthly_pct)),
         value = c(daily_pct, monthly_pct)),
  file.path(OUTPUT_DIR, "precip_monthly_rain_percentiles.csv")
)


# -----------------------------
# Effects from the coefs
# -----------------------------

# Name of a rainfall term at lag l (l < 0 means lead), like rain_d2_lag3
term_at <- function(v, l) {
  if (l == 0) v else if (l > 0) paste0(v, "_lag", l) else paste0(v, "_lead", -l)
}

# Effect of a rainfall shock in %, with its 95% CI, for one age group.
# `weights` says how much the shock moves each rainfall term (a 3 cm day:
# rain_d1 + 3, rain_d2 + 9, rain_d3 + 27). 
# Each coef is multiplied by that and added up over the months in `lags`
effect_of <- function(res, age, weights, lags) {
  a <- setNames(rep(0, length(res$coef)), names(res$coef))
  for (l in lags) {
    for (v in names(weights)) a[paste0("agegroup::", age, ":", term_at(v, l))] <- weights[[v]]
  }
  est <- sum(a * res$coef)
  se <- sqrt(as.numeric(t(a) %*% res$vcov %*% a))
  tibble(effect = 100 * (exp(est) - 1), ci_low = 100 * (exp(est - 1.96 * se) - 1),
         ci_high = 100 * (exp(est + 1.96 * se) - 1), p_value = 2 * pnorm(-abs(est / se)))
}

# One day of d mm vs a dry day: daily terms change by d, d^2, d^3 (in cm),
# and the monthly total by d. Only the daily model's terms are used
day_weights <- function(d_mm) {
  d <- d_mm / 10
  c(rain_d1 = d, rain_d2 = d^2, rain_d3 = d^3)
}

# A month with M mm vs a month with the median total: the polynomial in
# monthly totals (in cm), relative to the median
month_weights <- function(m_mm) {
  m <- m_mm / 10
  ref <- monthly_pct[["50%"]] / 10
  c(rain_d1 = m - ref, rain_m2 = m^2 - ref^2, rain_m3 = m^3 - ref^3)
}

# Response curves for every window, age group and rainfall level
response_curves <- function(res, weight_fun, levels_mm, wins = windows) {
  bind_rows(lapply(names(age_labels), function(age) {
    bind_rows(lapply(names(wins), function(w) {
      bind_rows(lapply(levels_mm, function(x) {
        effect_of(res, age, weight_fun(x), wins[[w]]) %>% mutate(rain_mm = x, window = w, agegroup = age)
      }))
    }))
  })) %>%
    mutate(
      age_label = factor(age_labels[agegroup], levels = age_labels),
      window = factor(window, levels = names(wins)),
      placebo = grepl("placebo", window)
    )
}

# Effect vs rainfall level, one panel per window x age group, with 95% CI
plot_curves <- function(curves, marks, x_label, title) {
  # One strong colour for the lag windows, grey for the placebo
  ggplot(curves, aes(x = rain_mm, y = effect, color = placebo, fill = placebo)) +
    geom_hline(yintercept = 0, color = "grey50") +
    geom_vline(xintercept = marks, linetype = "dotted", color = "grey40") +
    geom_ribbon(aes(ymin = ci_low, ymax = ci_high), alpha = 0.25, color = NA) +
    geom_line(linewidth = 0.9) +
    facet_grid(window ~ age_label, scales = "free_y") +
    scale_color_manual(values = c(`FALSE` = "#1F5A85", `TRUE` = "grey40")) +
    scale_fill_manual(values = c(`FALSE` = "#1F5A85", `TRUE` = "grey50")) +
    labs(x = x_label, y = "% change in monthly deaths", title = title, color = NULL, fill = NULL) +
    theme(legend.position = "none")
}


# -----------------------------
# Figures and tables, by FE spec
# -----------------------------

# For each FE spec with results: response curves, lag profile, and the
# windows table (temp this month only)
window_table <- list()

for (fe in FE_SPECS) {
  if (!file.exists(file.path(RESULTS_DIR, paste0("precip_monthly_daily_", fe, "_temp-current.rds")))) next
  # Coefs and vcov of the daily and monthly-totals models
  daily <- readRDS(file.path(RESULTS_DIR, paste0("precip_monthly_daily_", fe, "_temp-current.rds")))
  monthly <- readRDS(file.path(RESULTS_DIR, paste0("precip_monthly_monthly_", fe, "_temp-current.rds")))
  fe_label <- FE_LABELS[[fe]]

  # Daily model: one day of rainfall, from 0 to the p99.9 day
  daily_curves <- response_curves(daily, day_weights, seq(0, daily_pct[["99.9%"]], length.out = 60))
  save_fig(
    plot_curves(daily_curves, daily_pct[c("95%", "99%", "99.9%")], "Rain on one day (mm), dotted lines at p95, p99, p99.9",
                paste0("One day of rain vs a dry day, daily cubic summed by month, ", fe_label)),
    paste0("fig_daily_response_", fe), 8, 11
  )
  # Extra timing check, saturated FE only: 2-month and single-month windows
  if (fe == "saturated") {
    grid_mm <- seq(0, daily_pct[["99.9%"]], length.out = 40)
    save_fig(plot_curves(response_curves(daily, day_weights, grid_mm, windows_2m), daily_pct[c("95%", "99%", "99.9%")],
                         "Rain on one day (mm)", "2-month windows, saturated FE"),
             "fig_daily_response_2month_saturated", 8, 13)
    save_fig(plot_curves(response_curves(daily, day_weights, grid_mm, windows_1m), daily_pct[c("95%", "99%", "99.9%")],
                         "Rain on one day (mm)", "Single months, saturated FE"),
             "fig_daily_response_1month_saturated", 8, 24)
  }

  # Monthly model: a month's total, from p1 to p99
  monthly_curves <- response_curves(monthly, month_weights,
                                    seq(monthly_pct[["1%"]], monthly_pct[["99%"]], length.out = 60))
  save_fig(
    plot_curves(monthly_curves, monthly_pct[c("10%", "50%", "90%")], "Rain in the month (mm), dotted lines at p10, p50, p90",
                paste0("A month's rain vs a median month, cubic in monthly totals, ", fe_label)),
    paste0("fig_monthly_response_", fe), 8, 8
  )

  # Lag profile: each month on its own, from 12 months before the death month
  # to 6 months after (placebo)
  profile_sets <- list(
    list(res = daily, w = day_weights(daily_pct[["99%"]]), label = "Heavy day (p99, 34 mm) vs dry day"),
    list(res = daily, w = day_weights(daily_pct[["99.9%"]]), label = "Very heavy day (p99.9, 70 mm) vs dry day")
  )
  profile <- bind_rows(lapply(profile_sets, function(s) {
    bind_rows(lapply(names(age_labels), function(age) {
      bind_rows(lapply(-6:11, function(l) {
        effect_of(s$res, age, s$w, l) %>% mutate(month_rel = -l, measure = s$label, agegroup = age)
      }))
    }))
  })) %>%
    mutate(age_label = factor(age_labels[agegroup], levels = age_labels),
           measure = factor(measure, levels = sapply(profile_sets, `[[`, "label")))

  # One point per month, months after the death month shaded (placebo)
  p <- ggplot(profile, aes(x = month_rel, y = effect)) +
    annotate("rect", xmin = 0.5, xmax = 6.5, ymin = -Inf, ymax = Inf, fill = "grey93") +
    geom_vline(xintercept = 0, color = "#7B1E2B", linewidth = 0.25, linetype = "dashed", alpha = 0.35) + # death month
    geom_hline(yintercept = 0, color = "grey50") +
    geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, color = "#2F6B8F") +
    geom_point(color = "#2F6B8F", size = 1.4) +
    facet_grid(measure ~ age_label, scales = "free_y", labeller = label_wrap_gen(22)) +
    scale_x_continuous(breaks = seq(-12, 6, 2)) +
    labs(x = "Month of the rain relative to the death month (grey = after, placebo)",
         y = "% change in monthly deaths", title = paste0("Lag profile, ", fe_label))
  save_fig(p, paste0("fig_lag_profile_", fe), 9, 6)

  # Windows at the marked rainfall levels, for the tables
  window_table[[fe]] <- bind_rows(
    response_curves(daily, day_weights, daily_pct[c("95%", "99%", "99.9%")]) %>%
      mutate(model = "daily", level = rep(c("p95 day", "p99 day", "p99.9 day"), length.out = n())),
    response_curves(monthly, month_weights, monthly_pct[c("5%", "10%", "90%", "95%")]) %>%
      mutate(model = "monthly", level = rep(c("p5 month", "p10 month", "p90 month", "p95 month"), length.out = n()))
  ) %>%
    mutate(fe_spec = fe)
}

# All windows at the marked rainfall levels, all FE specs, one CSV
write_csv(bind_rows(window_table) %>% select(fe_spec, model, level, rain_mm, age_label, window, effect, ci_low, ci_high, p_value),
          file.path(OUTPUT_DIR, "precip_monthly_windows.csv"))
message("wrote: ", OUTPUT_DIR)


# -----------------------------
# Temp this month only vs temp + 11 lags
# -----------------------------

# One shock per measure: a p99 day (daily model), a p10 month (monthly model),
# and a month 1 SD drier / wetter than normal (SPI)
shocks <- list(
  list(model = "daily", w = day_weights(daily_pct[["99%"]]), label = "Heavy day (p99) vs dry day"),
  list(model = "monthly", w = month_weights(monthly_pct[["10%"]]), label = "Dry month (p10) vs median"),
  list(model = "spi", w = c(spi_dryside = 1), label = "SPI dry side, 1 SD drier"),
  list(model = "spi", w = c(spi_wetside = 1), label = "SPI wet side, 1 SD wetter")
)
temp_labels <- c(current = "Temp this month only", lags = "Temp + 11 lags")

# For each FE spec with both temp versions: month-by-month profile of each
# shock, temp this month only vs + 11 lags, and the same windows as above
temp_windows <- list()
for (fe in FE_SPECS) {
  if (!file.exists(file.path(RESULTS_DIR, paste0("precip_monthly_daily_", fe, "_temp-lags.rds")))) next
  fe_label <- FE_LABELS[[fe]]
  profile <- list()
  for (tp in names(temp_labels)) {
    for (s in shocks) {
      res <- readRDS(file.path(RESULTS_DIR, paste0("precip_monthly_", s$model, "_", fe, "_temp-", tp, ".rds")))
      for (age in names(age_labels)) {
        profile[[length(profile) + 1]] <- bind_rows(lapply(-6:11, function(l) {
          effect_of(res, age, s$w, l) %>% mutate(month_rel = -l)
        })) %>% mutate(measure = s$label, temp = temp_labels[[tp]], agegroup = age)
        temp_windows[[length(temp_windows) + 1]] <- bind_rows(lapply(names(windows), function(w) {
          effect_of(res, age, s$w, windows[[w]]) %>% mutate(window = w)
        })) %>% mutate(fe_spec = fe, measure = s$label, temp = temp_labels[[tp]], age_label = age_labels[[age]])
      }
    }
  }
  profile <- bind_rows(profile) %>%
    mutate(age_label = factor(age_labels[agegroup], levels = age_labels),
           measure = factor(measure, levels = sapply(shocks, `[[`, "label")),
           temp = factor(temp, levels = temp_labels))

  # The two temp versions next to each other, one row per shock
  p <- ggplot(profile, aes(x = month_rel, y = effect, color = temp)) +
    annotate("rect", xmin = 0.5, xmax = 6.5, ymin = -Inf, ymax = Inf, fill = "grey93") +
    geom_vline(xintercept = 0, color = "#7B1E2B", linewidth = 0.25, linetype = "dashed", alpha = 0.35) + # death month
    geom_hline(yintercept = 0, color = "grey50") +
    geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, position = position_dodge(width = 0.5)) +
    geom_point(size = 1.2, position = position_dodge(width = 0.5)) +
    facet_grid(measure ~ age_label, scales = "free_y", labeller = label_wrap_gen(20)) +
    scale_color_manual(values = c("#D95F02", "#2F6B8F")) +
    scale_x_continuous(breaks = seq(-12, 6, 2)) +
    labs(x = "Month of the rain relative to the death month (grey = after, placebo)",
         y = "% change in monthly deaths", color = NULL,
         title = paste0("With and without temp lags, ", fe_label))
  save_fig(p, paste0("fig_temp_lags_", fe), 9, 9.5)
}

# Windows for both temp versions, one CSV
write_csv(bind_rows(temp_windows) %>% select(fe_spec, measure, temp, age_label, window, effect, ci_low, ci_high, p_value),
          file.path(OUTPUT_DIR, "precip_monthly_temp_lags_windows.csv"))
message("wrote: ", OUTPUT_DIR)
