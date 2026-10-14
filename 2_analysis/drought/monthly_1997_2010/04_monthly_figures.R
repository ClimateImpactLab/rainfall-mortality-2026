# ============================================================================
# 04_monthly_figures.R
#
# Figures and tables for the Brazil monthly drought regs (03_monthly_regs.R)
# Reads the coefficient and lag-sum CSVs, does not rerun anything
#
#   fig_monthly_lag_profile       coef on each month's SPI, from 11 months
#                                 before the death month to 6 months after
#                                 (placebo)
#   fig_monthly_lag_profile_dry_wet
#                                 same, dry side vs wet side of the SPI
#   fig_monthly_windows           3/6/12-month SPI and the dry flags, each
#                                 next to its placebo
#   tab_monthly_lag_sums.tex      sums of the 12 lags and of the 6 leads
#   tab_monthly_windows.tex       3/6/12-month SPI and the dry flags
#   tab_monthly_region.tex        dry/wet sums, Northeast vs rest (if run)
#
# All effects are % change in monthly deaths (100 x Poisson coef), per 1 SD
# drier month (SPI) or per month flagged dry (0/1).
#
# Options:
#   --period = 1997_2010 | 2000_2024
#   --years = all (default) | start_end, reads the 03 results for those years
#   --region = all (default) | northeast | rest, same
#
# Output: output/data/drought/brazil-monthly/<period>/summary/
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)


# -----------------------------
# Options and paths
# -----------------------------

# Options (see header), the same as the 03 run being plotted
args <- commandArgs(trailingOnly = TRUE)


get_arg <- function(name, default) {
  hit <- sub(paste0("^--", name, "="), "", args[grepl(paste0("^--", name, "="), args)])
  if (length(hit) == 0) default else hit[[1]]
}

period <- get_arg("period", "1997_2010")
years <- get_arg("years", "all")
region <- get_arg("region", "all")
# Shown in the figure subtitles, for ex "1997-2010, Northeast"
period_label <- paste0(sub("_", "-", if (years == "all") period else years),
                       c(all = "", northeast = ", Northeast", rest = ", rest of Brazil")[[region]])

# Results of 03_monthly_regs.R. Figures and tables go in summary/
RESULTS_DIR <- sub("/$", "", file.path(
  "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/output/data/drought/brazil-monthly",
  period,
  # Subfolders for a year or region subset, for ex 1997_2010/region_northeast
  paste(c(if (years != "all") paste0("years_", years), if (region != "all") paste0("region_", region)), collapse = "/")
))
OUTPUT_DIR <- file.path(RESULTS_DIR, "summary")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Plot settings
# -----------------------------

# Age and FE labels for the panels. The figures show main and saturated FE
age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")
fe_labels <- c(main = "Main FE", saturated = "Saturated FE")

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

# Stars for the tables
stars <- function(p) case_when(p < 0.01 ~ "***", p < 0.05 ~ "**", p < 0.1 ~ "*", TRUE ~ "")


# -----------------------------
# Read results
# -----------------------------

# Year and region subsets are only run with saturated FE, so read only the FE
# specs that have results
read_both <- function(type) {
  fe_run <- names(fe_labels)[file.exists(file.path(RESULTS_DIR, paste0("brazil_monthly_drought_", type, "_", names(fe_labels), ".csv")))]
  bind_rows(lapply(fe_run, function(fe) {
    read_csv(file.path(RESULTS_DIR, paste0("brazil_monthly_drought_", type, "_", fe, ".csv")),
             show_col_types = FALSE)
  })) %>%
    mutate(
      age_label = factor(age_labels[as.character(agegroup)], levels = age_labels),
      fe_label = factor(fe_labels[fe_spec], levels = fe_labels),
      effect = 100 * estimate,
      ci_low = 100 * (estimate - 1.96 * std_error),
      ci_high = 100 * (estimate + 1.96 * std_error)
    )
}

coefs <- read_both("coefficients")
sums <- read_both("lag_sums")


# -----------------------------
# Lag profile
# -----------------------------

# Month of the rainfall relative to the death month: 0 = same month,
# -1 to -11 = months before (lags), 1 to 6 = months after (leads, placebo)
lag_profile <- coefs %>%
  filter(set_id %in% c("spi01_lags", "spi01_dry_wet")) %>%
  mutate(
    side = case_when(
      grepl("dryside", variable) ~ "Dry side",
      grepl("wetside", variable) ~ "Wet side",
      TRUE ~ "Both sides"
    ),
    # for ex spi01_dry_lag3 -> -3, spi01_dry_lead2 -> 2, spi01_dry -> 0
    n_months = as.integer(ifelse(grepl("_(lag|lead)[0-9]+$", variable),
                                 sub("^.*_(lag|lead)", "", variable), "0")),
    month_rel = if_else(grepl("_lead[0-9]+$", variable), n_months, -n_months)
  )

# One SPI coef per month (both sides together), months after the death month
# shaded (placebo). One panel per FE spec x age group
p <- ggplot(filter(lag_profile, side == "Both sides"), aes(x = month_rel, y = effect)) +
  annotate("rect", xmin = 0.5, xmax = 6.5, ymin = -Inf, ymax = Inf, fill = "grey93") +
  geom_vline(xintercept = 0, color = "#7B1E2B", linewidth = 0.25, linetype = "dashed", alpha = 0.35) + # death month
  geom_hline(yintercept = 0, color = "grey50") +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, color = "#2F6B8F") +
  geom_point(color = "#2F6B8F", size = 1.6) +
  facet_grid(fe_label ~ age_label, scales = "free_y") +
  scale_x_continuous(breaks = seq(-10, 6, 2)) +
  labs(x = "Month of the rain relative to the death month (0 = same month, grey: months after, placebo)",
       y = "% change in monthly deaths, 95% CI",
       title = "Effect of a 1 SD drier month on deaths, by when the month was",
       subtitle = paste0("Brazil monthly, ", period_label, ". Poisson, clustered by state."))

save_fig(p, "fig_monthly_lag_profile", 10, 6)

# Same with the dry side and the wet side, next to each other
p <- ggplot(filter(lag_profile, side != "Both sides"),
            aes(x = month_rel + if_else(side == "Dry side", -0.15, 0.15), y = effect, color = side)) +
  annotate("rect", xmin = 0.5, xmax = 6.5, ymin = -Inf, ymax = Inf, fill = "grey93") +
  geom_vline(xintercept = 0, color = "#7B1E2B", linewidth = 0.25, linetype = "dashed", alpha = 0.35) + # death month
  geom_hline(yintercept = 0, color = "grey50") +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0) +
  geom_point(size = 1.6) +
  facet_grid(fe_label ~ age_label, scales = "free_y") +
  scale_x_continuous(breaks = seq(-10, 6, 2)) +
  scale_color_manual(values = c("Dry side" = "#B5452B", "Wet side" = "#2F6B8F")) +
  labs(x = "Month of the rain relative to the death month (0 = same month, grey: months after, placebo)",
       y = "% change in monthly deaths, 95% CI", color = NULL,
       title = "Dry months vs wet months",
       subtitle = paste0("Dry side: per 1 SD drier than normal. Wet side: per 1 SD wetter than normal. ",
                         "Brazil monthly, ", period_label, "."))

save_fig(p, "fig_monthly_lag_profile_dry_wet", 10, 6)


# --------------------------------
# Rain over the last 3/6/12 months
# ---------------------------------

# One row per measure. Filled point: the window ending in the death month.
# Hollow point: its placebo (the next 3/6/12 months), which should be about 0 (!!)
window_measures <- c(
  spi03_dry = "SPI, last 3 months", spi06_dry = "SPI, last 6 months",
  spi12_dry = "SPI, last 12 months", dry10_6m = "6-month rain below p10",
  dry05_6m = "6-month rain below p5"
)

windows <- coefs %>%
  filter(set_id %in% c("spi03", "spi06", "spi12", "dry10_6m", "dry05_6m")) %>%
  mutate(
    timing = if_else(grepl("_lead$", variable), "Placebo (next months)", "Last months"),
    measure = factor(window_measures[sub("_lead$", "", variable)], levels = rev(window_measures))
  )

# One row per measure, the window and its placebo next to each other
p <- ggplot(windows, aes(x = effect, y = measure, shape = timing)) +
  geom_vline(xintercept = 0, color = "grey50") +
  geom_errorbarh(aes(xmin = ci_low, xmax = ci_high), height = 0, color = "#2F6B8F",
                 position = position_dodge(width = 0.6)) +
  geom_point(size = 1.8, color = "#2F6B8F", fill = "white",
             position = position_dodge(width = 0.6)) +
  facet_grid(fe_label ~ age_label, scales = "free_x") +
  scale_shape_manual(values = c("Last months" = 16, "Placebo (next months)" = 21)) +
  labs(x = "% change in monthly deaths, per 1 SD drier (SPI) or per month flagged dry, 95% CI",
       y = NULL, shape = NULL,
       title = "Rain over the last 3, 6 or 12 months, one coef each",
       subtitle = paste0("Brazil monthly, ", period_label, ". Poisson, clustered by state."))

save_fig(p, "fig_monthly_windows", 10, 5.5)


# -----------------------------
# Tables
# -----------------------------

# One cell per age x FE: effect and stars in separate columns
fmt_cell <- function(effect, p_value) paste0(sprintf("%+.1f", effect), " & ", stars(p_value))

# One row per row_id, in the order of row_labels.
# cols:  main 0-4 ... saturated 65+ 
write_tex_table <- function(data, row_labels, file) {
  rows <- data %>%
    filter(row_id %in% names(row_labels)) %>%
    mutate(cell = fmt_cell(effect, p_value)) %>%
    arrange(fe_label, age_label) %>%
    group_by(row_id) %>%
    summarise(line = paste(cell, collapse = " & "), .groups = "drop") %>%
    mutate(row_id = factor(row_id, levels = names(row_labels))) %>%
    arrange(row_id) %>%
    mutate(row_label = row_labels[as.character(row_id)])

  lines <- c(
    "\\begin{tabular}{l*{6}{r@{}l}}",
    "\\toprule",
    " & \\multicolumn{6}{c}{Main FE} & \\multicolumn{6}{c}{Saturated FE} \\\\",
    "\\cmidrule(lr){2-7}\\cmidrule(lr){8-13}",
    " & \\multicolumn{2}{c}{0-4} & \\multicolumn{2}{c}{5-64} & \\multicolumn{2}{c}{65+} & \\multicolumn{2}{c}{0-4} & \\multicolumn{2}{c}{5-64} & \\multicolumn{2}{c}{65+} \\\\",
    "\\midrule",
    paste0(rows$row_label, " & ", rows$line, " \\\\"),
    "\\bottomrule",
    "\\end{tabular}"
  )
  writeLines(lines, file.path(OUTPUT_DIR, file))
}

# Lag sums table: rows and their labels
sum_labels <- c(
  "spi01_lags.lags" = "Sum of 12 months (this month + 11 before)",
  "spi01_lags.leads" = "Placebo: sum of next 6 months",
  "spi01_dry_wet.dry_lags" = "Dry side: sum of 12 months",
  "spi01_dry_wet.dry_leads" = "Dry side placebo: next 6 months",
  "spi01_dry_wet.wet_lags" = "Wet side: sum of 12 months",
  "spi01_dry_wet.wet_leads" = "Wet side placebo: next 6 months"
)

write_tex_table(
  sums %>% mutate(row_id = paste(set_id, block, sep = ".")),
  sum_labels, "tab_monthly_lag_sums.tex"
)

# Windows table (3/6/12-month SPI and dry flags): rows and their labels
window_labels <- c(
  spi03_dry = "SPI, last 3 months", spi03_dry_lead = "Placebo: next 3 months",
  spi06_dry = "SPI, last 6 months", spi06_dry_lead = "Placebo: next 6 months",
  spi12_dry = "SPI, last 12 months", spi12_dry_lead = "Placebo: next 12 months",
  dry10_6m = "6-month rain below p10", dry10_6m_lead = "Placebo: next 6 months",
  dry05_6m = "6-month rain below p5", dry05_6m_lead = "Placebo: next 6 months"
)

write_tex_table(
  coefs %>% filter(variable %in% names(window_labels)) %>% mutate(row_id = variable),
  window_labels, "tab_monthly_windows.tex"
)


# -----------------------------
# Season FE check
# -----------------------------

# 0-11 lag sums and lead sums of the SPI, saturated FE vs letting each
# place's seasonality drift (season trend)
# Table only, the figures above stay on main and saturated FE
season_fe <- c("saturated", "seasontrend")
season_files <- file.path(RESULTS_DIR, paste0("brazil_monthly_drought_lag_sums_", season_fe, ".csv"))
if (all(file.exists(season_files))) {
  bind_rows(lapply(season_files, read_csv, show_col_types = FALSE)) %>%
    filter(set_id %in% c("spi01_lags", "spi01_dry_wet")) %>%
    mutate(age_label = age_labels[as.character(agegroup)], effect = 100 * estimate,
           ci_low = 100 * (estimate - 1.96 * std_error), ci_high = 100 * (estimate + 1.96 * std_error)) %>%
    select(set_id, block, age_label, fe_spec, effect, ci_low, ci_high, p_value) %>%
    arrange(set_id, block, age_label, match(fe_spec, season_fe)) %>%
    write_csv(file.path(OUTPUT_DIR, "monthly_seasonal_fe_check.csv"))
}


# -----------------------------
# Northeast vs rest of Brazil
# -----------------------------

# Dry and wet side sums and placebos, saturated FE: all of Brazil, then the
# 03 runs with --region=northeast and --region=rest.
# written only if both region runs exist
region_dirs <- c(all = RESULTS_DIR, northeast = file.path(RESULTS_DIR, "region_northeast"),
                 rest = file.path(RESULTS_DIR, "region_rest"))
region_files <- file.path(region_dirs, "brazil_monthly_drought_lag_sums_saturated.csv")
if (region == "all" && all(file.exists(region_files))) {
  region_labels <- c(dry_lags = "Dry side: sum of 12 months", dry_leads = "Dry side placebo: next 6 months",
                     wet_lags = "Wet side: sum of 12 months", wet_leads = "Wet side placebo: next 6 months")
  region_rows <- bind_rows(lapply(seq_along(region_dirs), function(i) {
    read_csv(region_files[[i]], show_col_types = FALSE) %>% mutate(region = names(region_dirs)[i])
  })) %>%
    filter(set_id == "spi01_dry_wet") %>%
    mutate(cell = fmt_cell(100 * estimate, p_value)) %>%
    group_by(agegroup, block) %>%
    summarise(line = paste(cell[match(names(region_dirs), region)], collapse = " & "), .groups = "drop") %>%
    arrange(agegroup, match(block, names(region_labels)))
  # One block of rows per age group
  body <- unlist(lapply(split(region_rows, region_rows$agegroup), function(d) {
    c(paste0("\\multicolumn{7}{l}{\\textbf{", age_labels[[as.character(d$agegroup[1])]], "}} \\\\"),
      paste0("\\quad ", region_labels[d$block], " & ", d$line, " \\\\"))
  }))
  writeLines(c(
    "\\begin{tabular}{l*{3}{r@{}l}}",
    "\\toprule",
    " & \\multicolumn{2}{c}{All} & \\multicolumn{2}{c}{Northeast} & \\multicolumn{2}{c}{Rest of Brazil} \\\\",
    "\\midrule",
    body,
    "\\bottomrule",
    "\\end{tabular}"
  ), file.path(OUTPUT_DIR, "tab_monthly_region.tex"))
}

message("wrote: ", OUTPUT_DIR)
