# ============================================================================
# 03_outputs.R
#
# Tables and figures for the Brazil monthly drought x normal temp regs
# (02_regs.R), by age group, in % change in monthly deaths per 1 unit of
# dry-side SPI (a month 1 SD drier):
#   temp_monthly_brazil.tex: linear (drought x normal temp), summed over this month + 11
#     lags, the effect at T* and the change per 1 C, and the placebo (6 leads)
#     change per 1 C, one row per run
#   temp_monthly_brazil_lags.pdf: linear within place, the effect at each lag
#     and lead in a usually hot month (90th percentile normal)
#   temp_season_monthly_brazil.tex: within place, cold / middle / hot months,
#     same month (lag 0), lags 0-11 and placebo, plus hot - cold
#   temp_season_monthly_brazil_lags.pdf: same, each lag and lead
#   temp_both_monthly_brazil.tex: within place next to across places
# and prints the numbers quoted in the doc's text (single hottest and coldest month)
#
# Options (--period): see "Paths and labels" below.
#
# Output: output/data/drought/brazil-monthly/<period>/temp_interaction/
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(ggplot2)


# -----------------------------
# Paths and labels
# -----------------------------

# Years of the regs in 02_regs.R: --period=2000_2024 (default) or 1997_2010
args <- commandArgs(trailingOnly = TRUE)
PERIOD <- sub("^--period=", "", grep("^--period=", args, value = TRUE))
if (length(PERIOD) == 0) PERIOD <- "2000_2024"
DIR <- file.path("/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/output/data/drought/brazil-monthly",
                 PERIOD, "temp_interaction")
load_run <- function(run) readRDS(file.path(DIR, paste0("temp_interaction_", run, ".rds")))

AGES <- c(`1` = "0-4", `2` = "5-64", `3` = "65+")
GROUPS <- c("cold", "mid", "hot")
GROUP_LABELS <- c("cold", "middle", "hot")
SEASON_LABELS <- c("3 coldest months", "6 middle months", "3 hottest months")

# Linear runs in the table, in order
LINEAR <- c(linear_rolling = "Main (rolling 30-year normal)", linear_fixed = "Fixed 1981-2010 normal",
            linear_rolling_noprecip = "No precip poly", linear_rolling_placeavg = "Within place")

# This month + 11 lags, and the 6 leads (placebo). Windows of the group
# tables: same month, lags 0-11, placebo
LAGS <- c("", paste0("_lag", 1:11))
LEADS <- paste0("_lead", 1:6)
WINDOWS <- list("", LAGS, LEADS)

# Each lag and lead for the figures: lags 0-11 on the right, leads -6 to -1
# (placebo, shaded) on the left
PERIODS <- c(LAGS, LEADS)
X <- c(0:11, -(1:6))


# -----------------------------
# Combining coefficients
# -----------------------------

# Weighted sum of coefs (weights named by coef), x 100 so in %, with its SE
# from the vcov (the coefs are correlated) and p
coef_sum <- function(res, w) {
  a <- setNames(rep(0, length(res$coef)), names(res$coef))
  a[names(w)] <- w
  est <- sum(a * res$coef)
  se <- sqrt(as.numeric(t(a) %*% res$vcov %*% a))
  tibble(est = 100 * est, se = 100 * se, p = 2 * pnorm(-abs(est / se)))
}
ones <- function(vars) setNames(rep(1, length(vars)), vars)

# Estimate with stars and SE, for ex "1.06$^{***}$ (0.26)"
cell <- function(d) {
  stars <- ifelse(d$p < 0.01, "$^{***}$", ifelse(d$p < 0.05, "$^{**}$", ifelse(d$p < 0.1, "$^{*}$", "")))
  sprintf("%s%s (%s)", sub("^-", "$-$", sprintf("%.2f", d$est)), stars, sprintf("%.2f", d$se))
}

# Coef names, for ex agegroup::3:dhot_lag1
v <- function(age, term, periods) paste0("agegroup::", age, ":", term, periods)
age_header <- function(age, n_cols) sprintf("\\multicolumn{%d}{l}{\\textit{%s}} \\\\", n_cols, AGES[[age]])
tex_row <- function(label, cells) paste(label, "&", paste(cells, collapse = " & "), "\\\\")

# One age group's cells for one run with groups (prefix d for within place,
# da across places): the 3 windows for each of cold, middle, hot and hot - cold
group_cells <- function(res, age, prefix) {
  hot_cold <- function(w) c(ones(v(age, paste0(prefix, "hot"), w)), -ones(v(age, paste0(prefix, "cold"), w)))
  c(lapply(GROUPS, function(g) sapply(WINDOWS, function(w) cell(coef_sum(res, ones(v(age, paste0(prefix, g), w)))))),
    list(sapply(WINDOWS, function(w) cell(coef_sum(res, hot_cold(w))))))
}


# -----------------------------
# Linear (drought x normal temp)
# -----------------------------

# One block per age group, one row per run: effect at T* and change per 1 C
# summed over lags 0-11, placebo change per 1 C summed over the leads
linear <- lapply(names(LINEAR), load_run)
writeLines(unlist(lapply(names(AGES), function(age) c(
  age_header(age, 4),
  sapply(seq_along(linear), function(r) tex_row(LINEAR[[r]], c(
    cell(coef_sum(linear[[r]], ones(v(age, "spi_dryside", LAGS)))),
    cell(coef_sum(linear[[r]], ones(v(age, "dxt", LAGS)))),
    cell(coef_sum(linear[[r]], ones(v(age, "dxt", LEADS))))))),
  if (age != "3") "\\addlinespace"))),
  file.path(DIR, "temp_monthly_brazil.tex"))

# Within place, the effect at each lag and lead in a usually hot month (the
# 90th percentile normal of the main run): b + (hot - T*) x phi
within_linear <- linear[[which(names(LINEAR) == "linear_rolling_placeavg")]]
hot <- linear[[1]]$normal_pct[["90%"]]
d <- bind_rows(lapply(names(AGES), function(age) bind_rows(lapply(seq_along(PERIODS), function(i)
  coef_sum(within_linear, setNames(c(1, hot - within_linear$t_star), v(age, c("spi_dryside", "dxt"), PERIODS[i]))) %>%
    mutate(x = X[i]))) %>% mutate(agegroup = factor(AGES[[age]], levels = AGES))))
p <- ggplot(d, aes(x = x, y = est)) +
  annotate("rect", xmin = -6.5, xmax = -0.5, ymin = -Inf, ymax = Inf, fill = "grey96") +
  geom_hline(yintercept = 0, color = "grey50", linewidth = 0.4, linetype = "longdash") +
  geom_vline(xintercept = 0, color = "grey50", linewidth = 0.4, linetype = "longdash") +
  geom_pointrange(aes(ymin = est - 1.96 * se, ymax = est + 1.96 * se), color = "#b2182b", size = 0.25) +
  scale_x_continuous(breaks = -6:11) +
  facet_wrap(~agegroup, scales = "free_y") +
  labs(x = "Months between the dry month and the deaths (negative: dry month after the deaths, placebo)",
       y = "% change in deaths per 1 unit\nof dry-side SPI") +
  theme_bw(base_size = 9)
ggsave(file.path(DIR, "temp_monthly_brazil_lags.pdf"), p, width = 10, height = 3.6)


# -----------------------------
# Cold, middle and hot months
# -----------------------------

within <- load_run("season_rolling")
across <- load_run("abs_rolling")

# Within place
writeLines(unlist(lapply(names(AGES), function(age) c(
  age_header(age, 4), mapply(tex_row, c(SEASON_LABELS, "hot $-$ cold"), group_cells(within, age, "d")),
  if (age != "3") "\\addlinespace"))),
  file.path(DIR, "temp_season_monthly_brazil.tex"))

# Within place next to across places
writeLines(unlist(lapply(names(AGES), function(age) c(
  age_header(age, 7),
  mapply(function(l, w, a) tex_row(l, c(w, a)), c(GROUP_LABELS, "hot $-$ cold"), group_cells(within, age, "d"), group_cells(across, age, "da")),
  if (age != "3") "\\addlinespace"))),
  file.path(DIR, "temp_both_monthly_brazil.tex"))

# Within place, each lag and lead, one color per group
d <- bind_rows(lapply(names(AGES), function(age) bind_rows(lapply(1:3, function(i) bind_rows(lapply(seq_along(PERIODS), function(j)
  coef_sum(within, ones(v(age, paste0("d", GROUPS[i]), PERIODS[j]))) %>% mutate(x = X[j]))) %>%
  mutate(season = factor(SEASON_LABELS[i], levels = SEASON_LABELS)))) %>% mutate(agegroup = factor(AGES[[age]], levels = AGES))))
p <- ggplot(d, aes(x = x, y = est, color = season)) +
  annotate("rect", xmin = -6.5, xmax = -0.5, ymin = -Inf, ymax = Inf, fill = "grey96") +
  geom_hline(yintercept = 0, color = "grey65", linewidth = 0.3, linetype = "dashed", alpha = 0.5) +
  geom_vline(xintercept = 0, color = "grey65", linewidth = 0.3, linetype = "dashed", alpha = 0.5) +
  geom_pointrange(aes(ymin = est - 1.96 * se, ymax = est + 1.96 * se), position = position_dodge(width = 0.6), size = 0.15) +
  scale_x_continuous(breaks = -6:11) +
  scale_color_manual(values = setNames(c("#2166ac", "grey45", "#b2182b"), SEASON_LABELS)) +
  facet_wrap(~agegroup, scales = "free_y") +
  labs(x = "Months between the dry month and the deaths (negative: dry month after the deaths, placebo)",
       y = "% change in deaths per 1 unit\nof dry-side SPI", color = "Dry month is one of the place's:") +
  theme_bw(base_size = 9) + theme(legend.position = "bottom")
ggsave(file.path(DIR, "temp_season_monthly_brazil_lags.pdf"), p, width = 10, height = 3.8)


# -----------------------------
# Numbers in the text
# -----------------------------

# 65+, same month: single hottest and coldest month of the place
one <- load_run("season_n1_rolling")
message("cuts across places (C): ", paste(round(across$cuts, 1), collapse = ", "))
message("65+ same month, single hottest month: ", cell(coef_sum(one, ones(v(3, "dhot", "")))),
        ", coldest: ", cell(coef_sum(one, ones(v(3, "dcold", "")))))
message("wrote: ", DIR)
