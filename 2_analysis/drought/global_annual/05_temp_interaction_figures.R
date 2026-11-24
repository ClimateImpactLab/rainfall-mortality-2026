# ============================================================================
# 05_temp_interaction_figures.R
#
# Tables and figure of the drought x normal temp regs (04), by age group, in %
# change in annual deaths per 1 unit of monthly SPI dry side (a month 1 SD
# drier):
#  - temp_annual.tex: linear, the total (t + t-1) effect at T* and its change
#    per 1 C, and the placebo (t+1) change per 1 C, one row per run
#  - temp_abs_annual.tex: abs (across places), cold, middle and hot months at
#    t, t-1, total and placebo, plus hot minus cold
#  - temp_both_annual.tex: season (within place, 3 cold, 6 mid, 3 hot) next to
#    abs
#  - temp_unittrend_annual.tex: 65+, abs hot months and hot minus cold, without
#    and with a linear trend for each admin unit x age
#  - temp_bins_annual.pdf: bins (across places, 10 groups), total and placebo
# Also prints a few more numbers for 65+: the single hottest and coldest month
# (season_n = 1), and abs hot months with drought x income
#
# Output: output/data/drought/global-annual/het/temp_interaction/ (tables)
# and output/data/drought/global-annual/het/figures/ (figure)
# ============================================================================


# ------------
# Packages
# ------------

library(dplyr)
library(ggplot2)


# ------------------
# Paths and labels
# ------------------

# results_dir and figures_dir
source("paths.R")
DIR <- file.path(results_dir, "temp_interaction")
load_run <- function(run) readRDS(file.path(DIR, paste0("temp_", run, ".rds")))

AGES <- c(`1` = "0-4", `2` = "5-64", `3` = "65+")
GROUPS <- c("cold", "mid", "hot")
GROUP_LABELS <- c("cold", "middle", "hot")

# Linear runs in the table, in order
LINEAR <- c(linear_rolling = "Main (rolling 30-year normal)", linear_fixed = "Fixed 1981-2010 normal",
            linear_rolling_noprecip = "No precip poly", linear_rolling_place = "Within place",
            linear_rolling_income = "+ drought \\texttimes{} income",
            linear_rolling_place_income = "Within place + drought \\texttimes{} income")

# Windows: t, t-1, total (t + t-1) and placebo (t+1)
WINDOWS <- list("", "_lag1", c("", "_lag1"), "_lead1")


# ------------------------
# Combining coefficients
# ------------------------

# Sum of coefs (minus: coefs subtracted, for hot minus cold), x 100 so in %,
# with its SE from the vcov (the coefs are correlated) and p
coef_sum <- function(res, vars, minus = character()) {
  a <- setNames(as.numeric(names(res$coef) %in% vars) - as.numeric(names(res$coef) %in% minus), names(res$coef))
  est <- sum(a * res$coef)
  se <- sqrt(as.numeric(t(a) %*% res$vcov %*% a))
  tibble(est = 100 * est, se = 100 * se, p = 2 * pnorm(-abs(est / se)))
}

# One table cell: the estimate with its stars, then its SE in brackets
cell <- function(d) {
  stars <- ifelse(d$p < 0.01, "$^{***}$", ifelse(d$p < 0.05, "$^{**}$", ifelse(d$p < 0.1, "$^{*}$", "")))
  sprintf("%s%s (%s)", sub("^-", "$-$", sprintf("%.3f", d$est)), stars, sprintf("%.3f", d$se))
}

# Coef names, for ex agegroup::3:dry_hot_lag1
v <- function(age, term, periods) paste0("agegroup::", age, ":", term, periods)
age_header <- function(age, n_cols) sprintf("\\multicolumn{%d}{l}{\\textit{%s}} \\\\", n_cols, AGES[[age]])

# One age group's cells for one run with groups: the 4 windows for each of cold, middle, hot and hot minus cold
group_cells <- function(res, age) {
  c(lapply(GROUPS, function(g) sapply(WINDOWS, function(w) cell(coef_sum(res, v(age, paste0("dry_", g), w))))),
    list(sapply(WINDOWS, function(w) cell(coef_sum(res, v(age, "dry_hot", w), v(age, "dry_cold", w))))))
}
ROW_LABELS <- c(GROUP_LABELS, "hot $-$ cold")
tex_row <- function(label, cells) paste(label, "&", paste(cells, collapse = " & "), "\\\\")


# --------------------------------
# Linear (drought x normal temp)
# --------------------------------

# One block per age group, one row per run: total effect at T*, total change per 1 C, placebo change per 1 C
linear <- lapply(names(LINEAR), load_run)
lines <- unlist(lapply(names(AGES), function(age) c(
  age_header(age, 4),
  sapply(seq_along(linear), function(r) tex_row(LINEAR[[r]], c(
    cell(coef_sum(linear[[r]], v(age, "dry_sum", c("", "_lag1")))),
    cell(coef_sum(linear[[r]], v(age, "dxt", c("", "_lag1")))),
    cell(coef_sum(linear[[r]], v(age, "dxt", "_lead1")))))),
  if (age != "3") "\\addlinespace")))
writeLines(lines, file.path(DIR, "temp_annual.tex"))


# -----------------------------
# Cold, middle and hot months
# -----------------------------

across <- load_run("abs_rolling")
within <- load_run("season_rolling")

# Across places, with the cuts in C in the labels
cut <- round(across$cuts, 1)
ABS_LABELS <- c(sprintf("cold (below %.1f\\textdegree C)", cut[1]), sprintf("middle (%.1f-%.1f\\textdegree C)", cut[1], cut[2]),
                sprintf("hot (above %.1f\\textdegree C)", cut[2]), "hot $-$ cold")
writeLines(unlist(lapply(names(AGES), function(age) c(
  age_header(age, 5), mapply(tex_row, ABS_LABELS, group_cells(across, age)), if (age != "3") "\\addlinespace"))),
  file.path(DIR, "temp_abs_annual.tex"))

# Within place next to across places, the 4 windows each
writeLines(unlist(lapply(names(AGES), function(age) c(
  age_header(age, 9), mapply(function(l, w, a) tex_row(l, c(w, a)), ROW_LABELS, group_cells(within, age), group_cells(across, age)),
  if (age != "3") "\\addlinespace"))),
  file.path(DIR, "temp_both_annual.tex"))


# 65+ hot months, without and with a linear trend for each admin unit x age
# (the placebo of the hot months is significant without trends)
trend <- load_run("abs_rolling_unittrend")
hot_rows <- function(res) list(
  sapply(WINDOWS, function(w) cell(coef_sum(res, v(3, "dry_hot", w)))),
  sapply(WINDOWS, function(w) cell(coef_sum(res, v(3, "dry_hot", w), v(3, "dry_cold", w)))))
rows <- c(hot_rows(across), hot_rows(trend))[c(1, 3, 2, 4)]
TREND_LABELS <- c("hot months, across places, no unit trends", "hot months, across places, unit trends",
                  "hot $-$ cold, across places, no unit trends", "hot $-$ cold, across places, unit trends")
writeLines(c(age_header("3", 5), mapply(tex_row, TREND_LABELS, rows)), file.path(DIR, "temp_unittrend_annual.tex"))


# -------------
# 10 bins
# -------------

# Total and placebo for each bin of the month's normal (deciles over all admin unit-months), labelled by its range in C
bins <- load_run("bins_rolling")
br <- round(bins$cuts)
BIN_LABELS <- c(paste0("<", br[1]), paste0(br[-9], "-", br[-1]), paste0(">", br[9]))
BIN_WINDOWS <- list(`total (t + t-1)` = c("", "_lag1"), `t+1 (placebo)` = "_lead1")
by_bin <- bind_rows(lapply(names(AGES), function(age) bind_rows(lapply(1:10, function(b) bind_rows(lapply(names(BIN_WINDOWS), function(w)
  coef_sum(bins, v(age, paste0("dry_b", b), BIN_WINDOWS[[w]])) %>% mutate(window = w))) %>% mutate(bin = b))) %>%
  mutate(agegroup = factor(AGES[[age]], levels = AGES))))

p <- ggplot(by_bin, aes(x = bin, y = est, color = window, shape = window)) +
  geom_hline(yintercept = 0, color = "grey65", linewidth = 0.3, linetype = "dashed", alpha = 0.5) +
  geom_pointrange(aes(ymin = est - 1.96 * se, ymax = est + 1.96 * se), position = position_dodge(width = 0.5), size = 0.2) +
  scale_x_continuous(breaks = 1:10, labels = BIN_LABELS) +
  scale_color_manual(values = c(`total (t + t-1)` = "#9b1d2e", `t+1 (placebo)` = "grey60")) +
  scale_shape_manual(values = c(`total (t + t-1)` = 16, `t+1 (placebo)` = 1)) +
  facet_wrap(~agegroup, scales = "free_y") +
  labs(x = "Normal temp of the dry month (C), 10 groups with the same number of months over all places",
       y = "% change in annual deaths\nper dry month (1 SD)", color = NULL, shape = NULL) +
  theme_bw(base_size = 9) + theme(legend.position = "bottom", axis.text.x = element_text(angle = 45, hjust = 1))
ggsave(file.path(figures_dir, "temp_bins_annual.pdf"), p, width = 10, height = 3.8)


# ---------------------
# Numbers in the text
# ---------------------

# 65+, total (t + t-1): single hottest and coldest month (within place), and across places with drought x income
one <- load_run("season_n1_rolling")
income <- load_run("abs_rolling_income")
total <- c("", "_lag1")
message("cuts across places (C): ", paste(round(across$cuts, 1), collapse = ", "))
message("65+ single hottest month: ", cell(coef_sum(one, v(3, "dry_hot", total))),
        ", coldest: ", cell(coef_sum(one, v(3, "dry_cold", total))))
message("65+ hot months with drought x income: ", cell(coef_sum(income, v(3, "dry_hot", total))),
        ", placebo: ", cell(coef_sum(income, v(3, "dry_hot", "_lead1"))))
message("wrote: ", DIR, " and ", figures_dir)
