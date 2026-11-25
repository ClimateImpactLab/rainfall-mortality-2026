# ============================================================
# 01_fe_comparison_figures.R
#
# Why the main FE results are confounded by regional trends, and what the
# stricter FE cost. Main FE (just year x age with Brazil alone) fail the
# placebo.
#
#   a) the lead placebo (next year's drought) under each FE spec
#   b) the Northeast vs the rest of Brazil by year, the pattern behind it
#   c) how much drought variation each FE spec leaves to estimate from
#
#   fig_placebo_fe_specs_<model>, tab_placebo_fe_specs.tex (three calendar-year measures)
#   tab_lags_leads_65plus.tex        65+ last / this / next year by spec and measure
#   tab_northeast_vs_rest_by_year.tex
#   fig_variation_left, tab_variation_left.tex
#
# Run from 05_summary_figures/ (sources 00_figure_setup.R).
# ============================================================

source("00_figure_setup.R")

panel <- readRDS(PANEL_FILE)
# Drought is the same for every age group, so one age group = one row per
# municipality-year
panel_year <- panel %>% filter(agegroup == 1)


# -----------------------------
# 2. Regional confounding
# -----------------------------

# -------- a) Placebo by FE spec --------

# The pooled runs to compare: every FE spec, Poisson and levels
placebo_runs <- c(
  paste0(names(fe_labels), "_poisson_unweighted"),
  paste0(names(fe_labels), "_levels_weighted")
)

# The three calendar-year drought measures, each as this year + last year +
# next year (placebo). Rolling-window measures can't give clean lags.
placebo_sets <- c(
  rain_dev_lag_lead = "Annual rain log deviation",
  spi12_lag_lead = "Annual SPI",
  very_dry_lag_lead = "Very dry year (below p10)"
)

placebo <- bind_rows(lapply(placebo_runs, read_pooled)) %>%
  filter(set_id %in% names(placebo_sets)) %>%
  mutate(
    measure = factor(placebo_sets[set_id], levels = placebo_sets),
    term = factor(
      case_when(
        grepl("lag1", variable) ~ "Last year",
        grepl("lead1", variable) ~ "Next year (placebo)",
        TRUE ~ "This year"
      ),
      levels = c("Next year (placebo)", "This year", "Last year")
    )
  )

# Coef plot: this year, last year and next year by FE spec (columns) and age
# (rows), for one outcome model
plot_placebo <- function(model) {
  plot_df <- placebo %>% filter(outcome_model == model)

  # Same x range within each age row, across FE columns
  blank_df <- plot_df %>%
    group_by(age_label) %>%
    reframe(x = c(min(ci_low_sd, 0), max(ci_high_sd, 0))) %>%
    tidyr::crossing(fe_label = unique(plot_df$fe_label))

  ggplot(plot_df, aes(x = estimate_sd, y = term, color = measure)) +
    geom_blank(data = blank_df, aes(x = x), inherit.aes = FALSE) +
    geom_vline(xintercept = 0, color = "grey60") +
    geom_errorbarh(aes(xmin = ci_low_sd, xmax = ci_high_sd), height = 0,
                   position = position_dodge(width = 0.6)) +
    geom_point(size = 1.8, position = position_dodge(width = 0.6)) +
    facet_grid2(age_label ~ fe_label, scales = "free_x", independent = "x") +
    scale_color_manual(values = c("#2F6B8F", "#6A9A4B", "#B5452B")) +
    labs(x = x_label(model), y = NULL, color = NULL,
         title = "Placebo: next year's drought should have no effect on this year's deaths",
         subtitle = paste0("Calendar-year drought measures, this year + last year + next year. ",
                           ifelse(model == "poisson", "Poisson, unweighted.", "Levels, population weighted.")))
}

save_fig(plot_placebo("poisson"), "fig_placebo_fe_specs_poisson", 11, 7)
save_fig(plot_placebo("levels"), "fig_placebo_fe_specs_levels", 11, 7)

# Full Poisson table (all three terms) as CSV. The TeX table keeps only the
# placebo (next year) rows.
placebo_table <- placebo %>%
  filter(outcome_model == "poisson") %>%
  mutate(cell = paste0(sprintf("%+.1f", estimate_sd), stars(p_value))) %>%
  select(fe_label, measure, term, age_label, cell) %>%
  pivot_wider(names_from = age_label, values_from = cell) %>%
  arrange(fe_label, measure, match(term, c("Last year", "This year", "Next year (placebo)")))

write_csv(placebo_table, file.path(OUTPUT_DIR, "placebo_fe_specs_poisson.csv"))

placebo_rows <- placebo_table %>%
  filter(term == "Next year (placebo)") %>%
  select(-term)

placebo_tex <- c(
  "\\begin{tabular}{llrrr}",
  "\\toprule",
  "FE spec & Drought measure (next year) & 0--4 & 5--64 & 65+ \\\\",
  "\\midrule",
  apply(placebo_rows, 1, function(r) paste0(paste(r, collapse = " & "), " \\\\")),
  "\\bottomrule",
  "\\end{tabular}"
)
placebo_tex <- gsub("_", "\\\\_", placebo_tex)
writeLines(placebo_tex, file.path(OUTPUT_DIR, "tab_placebo_fe_specs.tex"))

# 65+ last / this / next year by FE spec and measure, for the "what the story
# predicts vs what we see" part of the note.
# Number and stars go in separate columns (r@{}l) so the numbers line up.
lags_65 <- placebo %>%
  filter(outcome_model == "poisson", age_label == "65+") %>%
  mutate(cell = paste0(sprintf("%+.1f", estimate_sd), " & ", stars(p_value))) %>%
  select(fe_label, measure, term, cell) %>%
  pivot_wider(names_from = term, values_from = cell) %>%
  select(fe_label, measure, `Last year`, `This year`, `Next year (placebo)`) %>%
  arrange(fe_label, measure)

# One bold panel header per FE spec instead of repeating it on every row.
lags_65_rows <- unlist(lapply(levels(droplevels(lags_65$fe_label)), function(fe) {
  rows <- lags_65 %>% filter(fe_label == fe) %>% select(-fe_label)
  c(paste0("\\multicolumn{7}{l}{\\textbf{", fe, "}} \\\\"),
    apply(rows, 1, function(r) paste0(paste(r, collapse = " & "), " \\\\")))
}))

writeLines(c(
  "\\begin{tabular}{lr@{}lr@{}lr@{}l}",
  "\\toprule",
  "Measure & \\multicolumn{2}{c}{Last year} & \\multicolumn{2}{c}{This year} & \\multicolumn{2}{c}{Next year (placebo)} \\\\",
  "\\midrule",
  lags_65_rows,
  "\\bottomrule",
  "\\end{tabular}"
), file.path(OUTPUT_DIR, "tab_lags_leads_65plus.tex"))

# -------- b) Example of the regional pattern behind the failed placebo --------

# Northeast vs rest of Brazil by year: average rainfall vs normal (ADM2 mean) and
# the 65+ death rate indexed to 1997. With year FE only, the Northeast's
# drier-early / wetter-late sequence lines up with its elderly mortality
# diverging from the rest of Brazil.
ne_vs_rest <- panel %>%
  filter(agegroup == 3) %>%
  mutate(region = if_else(northeast, "Northeast", "Rest of Brazil")) %>%
  group_by(region, year) %>%
  summarise(
    rain_pct_vs_normal = 100 * mean(exp(-rain_dry_logdev_pop) - 1),
    deathrate_65 = 1e5 * sum(deaths) / sum(population),
    .groups = "drop"
  ) %>%
  group_by(region) %>%
  mutate(deathrate_65_index = 100 * deathrate_65 / deathrate_65[year == 1997]) %>%
  ungroup()

write_csv(ne_vs_rest, file.path(OUTPUT_DIR, "northeast_vs_rest_by_year.csv"))

ne_vs_rest_wide <- ne_vs_rest %>%
  transmute(year, region,
            rain = sprintf("%+.0f\\%%", rain_pct_vs_normal),
            index = sprintf("%.0f", deathrate_65_index)) %>%
  pivot_wider(names_from = region, values_from = c(rain, index)) %>%
  select(year, `rain_Northeast`, `index_Northeast`, `rain_Rest of Brazil`, `index_Rest of Brazil`)

writeLines(c(
  "\\begin{tabular}{lrrrr}",
  "\\toprule",
  " & \\multicolumn{2}{c}{Northeast} & \\multicolumn{2}{c}{Rest of Brazil} \\\\",
  "Year & Rain vs own normal & 65+ death rate & Rain vs own normal & 65+ death rate \\\\",
  " & (\\% diff.) & (1997 = 100) & (\\% diff.) & (1997 = 100) \\\\",
  "\\midrule",
  apply(ne_vs_rest_wide, 1, function(r) paste0(paste(r, collapse = " & "), " \\\\")),
  "\\bottomrule",
  "\\end{tabular}"
), file.path(OUTPUT_DIR, "tab_northeast_vs_rest_by_year.tex"))

# -------- c) Drought variation left under each FE spec --------

# Share of the drought measure's variance (ADM2-year) left after ADM2 FE and
# each time FE, relative to ADM2 + year FE (the main spec).
fe_formulas <- c(
  "Main FE" = "admin_code + year",
  "Region x year FE" = "admin_code + macro_region^year",
  "State trends" = "admin_code + year + adm1_code[year]",
  "Saturated FE" = "admin_code + adm1_code^year"
)

# Four measures: the whole-year shortfall and three "worst in year" measures
variation_measures <- c(
  "Annual rain log deviation" = "rain_dry_logdev_pop",
  "Worst RS log deviation" = "rs_worst_logdev_severity_pop",
  "Worst 6-month z-score" = "drought_6m_worst_z_severity_pop",
  "Worst 6-month SPI" = "spi06_worst_severity_pop"
)

# For each sample and measure: regress the measure on each set of FE only,
# take the variance of what's left, and divide by the same under main FE
variation_left <- bind_rows(lapply(c("All Brazil", "Northeast"), function(sample_name) {
  data <- if (sample_name == "Northeast") filter(panel_year, northeast) else panel_year

  bind_rows(lapply(names(variation_measures), function(measure) {
    v <- variation_measures[[measure]]
    resid_var <- sapply(fe_formulas, function(fe) {
      var(resid(feols(as.formula(paste(v, "~ 1 |", fe)), data, notes = FALSE)))
    })
    tibble(sample = sample_name, measure = measure, fe_label = names(fe_formulas),
           share_left = resid_var / resid_var[["Main FE"]])
  }))
}))

write_csv(variation_left, file.path(OUTPUT_DIR, "variation_left.csv"))

# Bars: share of drought variance left under each FE spec, by sample
variation_plot <- variation_left %>%
  mutate(fe_label = factor(fe_label, levels = names(fe_formulas))) %>%
  ggplot(aes(x = share_left, y = measure, fill = fe_label)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.75) +
  geom_text(aes(label = scales::percent(share_left, accuracy = 1)),
            position = position_dodge(width = 0.8), hjust = -0.15, size = 2.8) +
  facet_wrap(~sample) +
  scale_fill_manual(values = fe_colors) +
  scale_x_continuous(labels = scales::percent, limits = c(0, 1.15), breaks = c(0, 0.25, 0.5, 0.75, 1)) +
  labs(x = "Drought variance left, relative to main FE (ADM2 + year)", y = NULL, fill = NULL,
       title = "What the stricter FE cost: drought variation left to estimate from")

save_fig(variation_plot, "fig_variation_left", 10, 4.2)

# Same numbers as a TeX table, one row per sample x measure, one column per
# FE spec
variation_tex_df <- variation_left %>%
  mutate(cell = scales::percent(share_left, accuracy = 1)) %>%
  select(sample, measure, fe_label, cell) %>%
  pivot_wider(names_from = fe_label, values_from = cell)

variation_tex <- c(
  "\\begin{tabular}{llrrrr}",
  "\\toprule",
  paste0(paste(names(variation_tex_df), collapse = " & "), " \\\\"),
  "\\midrule",
  apply(variation_tex_df, 1, function(r) paste0(paste(r, collapse = " & "), " \\\\")),
  "\\bottomrule",
  "\\end{tabular}"
)
# Escape % for TeX
variation_tex <- gsub("%", "\\\\%", variation_tex)
writeLines(variation_tex, file.path(OUTPUT_DIR, "tab_variation_left.tex"))

message("wrote: ", OUTPUT_DIR)
