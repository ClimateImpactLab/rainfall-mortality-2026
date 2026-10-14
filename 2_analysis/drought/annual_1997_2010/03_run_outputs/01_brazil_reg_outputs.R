# ============================================================
# 01_brazil_reg_outputs.R
#
# Tables and the coef plot for one run of 02_regressions/02_brazil_regs.R (same options)
# Reads that run's CSVs and the panel, reruns nothing
#
#   - summary stats of each drought measure (one row per municipality-year)
#   - coefs scaled to a +1 SD change in the measure (in % for Poisson).
#     0/1 measures (very dry/wet year, rainfall bins) stay as the effect of the
#     dummy switching on
#   - TeX tables: measure summary, coefs, within R2 added, joint tests
#   - one coef plot, measures x age group
#
# Output: output/data/drought/brazil-annual/, in tables/ and figures/, one
# folder per run
#
# Options:
#   --outcome_model=levels | poisson
#   --fe_spec=main | saturated | statetrend | region
#   --weighted=true | false
#   --prcp_poly=true | false
#   --temp=tavg | tmax
#   --sample=all | northeast
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(ggplot2)


# -----------------------------
# Options and paths
# -----------------------------

# Same options as 02_brazil_regs.R, so the run name matches its CSVs
args <- commandArgs(FALSE)

# Read one option from the command line, for ex --fe_spec=saturated gives
# "saturated". If the option isn't given, use the default
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# Same defaults as 02_brazil_regs.R
outcome_model <- get_arg("outcome_model", "levels")
fe_spec <- get_arg("fe_spec", "main")
weighted_default <- if (outcome_model == "poisson") "false" else "true"
weighted_arg <- tolower(get_arg("weighted", weighted_default))
prcp_poly_arg <- tolower(get_arg("prcp_poly", "false"))
weighted <- weighted_arg %in% c("true", "t", "1", "yes")
use_prcp_poly <- prcp_poly_arg %in% c("true", "t", "1", "yes")
weight_label <- if (weighted) "weighted" else "unweighted"
temp_spec <- get_arg("temp", "tavg")
sample_spec <- get_arg("sample", "all")
# Shown in the plot subtitle
control_label <- if (use_prcp_poly) "temp controls + precip poly" else "temp controls only"

# paths.R gives DIR_REPO_RAINFALL_MORTALITY (the repo on RCC)
USER <- Sys.getenv("USER")
source("../../../../0_utils/paths.R")

# Panel from 01_build_brazil_panel.R. Results go next to the reg CSVs
PANEL_FILE <- paste0("/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
                     "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds")

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "drought", "brazil-annual")

# Run name, the same as in 02_brazil_regs.R
run_id <- paste(fe_spec, outcome_model, weight_label, sep = "_")
if (use_prcp_poly) run_id <- paste(run_id, "prcpoly", sep = "_")
if (temp_spec == "tmax") run_id <- paste(run_id, "tmax", sep = "_")
if (sample_spec == "northeast") run_id <- paste(run_id, "northeast", sep = "_")
if (temp_spec == "tmax") control_label <- paste(control_label, "+ tmax poly")
label_run_id <- gsub("_", "-", run_id)

# CSVs written by 02_brazil_regs.R for this run
coef_file <- file.path(OUTPUT_DIR, paste0("brazil_annual_drought_coefficients_", run_id, ".csv"))
model_file <- file.path(OUTPUT_DIR, paste0("brazil_annual_drought_models_", run_id, ".csv"))
joint_file <- file.path(OUTPUT_DIR, paste0("brazil_annual_drought_joint_tests_", run_id, ".csv"))

# One table and one figure folder per run
table_dir <- file.path(OUTPUT_DIR, "tables", run_id)
figure_dir <- file.path(OUTPUT_DIR, "figures", run_id)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Small formatting helpers
# -----------------------------

age_labels <- c("1" = "0-4", "2" = "5-64", "3" = "65+")
coef_color <- "#2F6B8F"

# Numbers and p-values as text for the TeX tables (blank if missing)
fmt_num <- function(x, digits = 3) {
  ifelse(is.na(x), "", format(round(x, digits), nsmall = digits, trim = TRUE, scientific = FALSE))
}

fmt_p <- function(x) {
  ifelse(is.na(x), "", ifelse(x < 0.001, "0.000", format(round(x, 3), nsmall = 3, trim = TRUE)))
}

# Escape characters TeX would read as commands (_, %, &, ...)
latex_escape <- function(x) {
  x <- as.character(x)
  x <- gsub("\\\\", "\\\\textbackslash{}", x)
  x <- gsub("([#$%&_{}])", "\\\\\\1", x, perl = TRUE)
  x <- gsub("~", "\\\\textasciitilde{}", x)
  x <- gsub("\\^", "\\\\textasciicircum{}", x)
  x
}

# Plain LaTeX table with adjustbox so the output stays on portrait pages.
write_latex_table <- function(data, file, caption, label, align = NULL) {
  if (is.null(align)) align <- paste0("l", strrep("r", ncol(data) - 1))

  rows <- apply(data, 1, function(row) {
    paste(latex_escape(row), collapse = " & ")
  })

  lines <- c(
    "\\begin{table}[!htbp]",
    "\\centering",
    "\\small",
    paste0("\\caption{", latex_escape(caption), "}"),
    paste0("\\label{", label, "}"),
    "\\begin{adjustbox}{max width=\\textwidth}",
    paste0("\\begin{tabular}{", align, "}"),
    "\\hline",
    paste(latex_escape(names(data)), collapse = " & "),
    "\\\\",
    "\\hline",
    paste0(rows, "\\\\"),
    "\\hline",
    "\\end{tabular}",
    "\\end{adjustbox}",
    "\\end{table}"
  )

  writeLines(lines, file)
}

# Coefficient table is grouped by measure to avoid repeating long measure names
# three times.
write_grouped_coef_table <- function(data, file, caption, label) {
  effect_header <- if (outcome_model == "poisson") "Effect +1 SD (\\%)" else "Effect +1 SD"
  ci_header <- if (outcome_model == "poisson") "95\\% CI +1 SD (\\%)" else "95\\% CI +1 SD"

  lines <- c(
    "\\begin{table}[!htbp]",
    "\\centering",
    "\\small",
    paste0("\\caption{", latex_escape(caption), "}"),
    paste0("\\label{", label, "}"),
    "\\begin{adjustbox}{max width=\\textwidth}",
    "\\begin{tabular}{lrrrrl}",
    "\\hline",
    paste0("Age & Coef & SE & ", effect_header, " & ", ci_header, " & P value\\\\"),
    "\\hline"
  )

  for (measure in unique(data$measure_label)) {
    rows <- data %>% filter(measure_label == measure)

    lines <- c(
      lines,
      paste0("\\multicolumn{6}{l}{\\textbf{", latex_escape(measure), "}}\\\\")
    )

    rows <- rows %>%
      transmute(
        Age = age_label,
        Coef = fmt_num(estimate),
        SE = fmt_num(std_error),
        `Effect +1 SD` = fmt_num(estimate_sd),
        `95% CI +1 SD` = paste0("[", fmt_num(ci_low_sd), ", ", fmt_num(ci_high_sd), "]"),
        `P value` = fmt_p(p_value)
      )

    row_lines <- apply(rows, 1, function(row) paste(latex_escape(row), collapse = " & "))
    lines <- c(lines, paste0(row_lines, "\\\\"))
  }

  lines <- c(lines, "\\hline", "\\end{tabular}", "\\end{adjustbox}", "\\end{table}")
  writeLines(lines, file)
}


# -----------------------------
# Read inputs
# -----------------------------

# The panel is only used for the SD of each drought measure
panel <- readRDS(PANEL_FILE)
if (sample_spec == "northeast") panel <- panel %>% filter(northeast)
coef_results <- read_csv(coef_file, show_col_types = FALSE)
model_results <- read_csv(model_file, show_col_types = FALSE)
joint_results <- read_csv(joint_file, show_col_types = FALSE)

drought_vars <- coef_results %>%
  distinct(variable, measure_label)


# -----------------------------
# Drought variable summaries
# -----------------------------

# Drought variables are ADM2-year measures repeated across age groups, so the
# summary stats use one row per ADM2-year.
panel_admin_year <- panel %>%
  distinct(admin_code, year, .keep_all = TRUE)

variable_summary <- bind_rows(lapply(seq_len(nrow(drought_vars)), function(i) {
  variable <- drought_vars$variable[[i]]
  x <- panel_admin_year[[variable]]

  tibble(
    variable = variable,
    measure_label = drought_vars$measure_label[[i]],
    # 0/1 terms are scaled by 1 below, not by their SD
    is_dummy = all(x %in% c(0, 1, NA)),
    admin_years = sum(!is.na(x)),
    mean = mean(x, na.rm = TRUE),
    sd = sd(x, na.rm = TRUE),
    min = min(x, na.rm = TRUE),
    p10 = quantile(x, 0.10, na.rm = TRUE, names = FALSE),
    p50 = quantile(x, 0.50, na.rm = TRUE, names = FALSE),
    p90 = quantile(x, 0.90, na.rm = TRUE, names = FALSE),
    max = max(x, na.rm = TRUE)
  )
}))

write_csv(variable_summary, file.path(table_dir, paste0("brazil_drought_variable_summary_", run_id, ".csv")))


# -----------------------------
# Standardized coefficients
# -----------------------------

# Raw coefficients are in each measure's own units. For the plot/table, multiply
# by the ADM2-year SD of the drought measure so the columns show a +1SD change.
# Indicators keep their raw coefficient (effect of the indicator switching on).
coef_standardized <- coef_results %>%
  left_join(
    variable_summary %>% transmute(variable, measure_label, drought_sd = if_else(is_dummy, 1, sd)),
    by = c("variable", "measure_label")
  ) %>%
  mutate(
    age_label = recode(as.character(agegroup), !!!age_labels),
    ci_low = estimate - 1.96 * std_error,
    ci_high = estimate + 1.96 * std_error,
    estimate_sd_log = estimate * drought_sd,
    std_error_sd_log = std_error * drought_sd,
    ci_low_sd_log = ci_low * drought_sd,
    ci_high_sd_log = ci_high * drought_sd,
    # Poisson coefficients are log rate ratios. Convert +1SD effects to percent.
    estimate_sd = if_else(outcome_model == "poisson", 100 * (exp(estimate_sd_log) - 1), estimate_sd_log),
    std_error_sd = if_else(outcome_model == "poisson", NA_real_, std_error_sd_log),
    ci_low_sd = if_else(outcome_model == "poisson", 100 * (exp(ci_low_sd_log) - 1), ci_low_sd_log),
    ci_high_sd = if_else(outcome_model == "poisson", 100 * (exp(ci_high_sd_log) - 1), ci_high_sd_log)
  )

write_csv(coef_standardized, file.path(table_dir, paste0("brazil_drought_coefficients_standardized_", run_id, ".csv")))


# -----------------------------
# TeX tables
# -----------------------------

# One data frame per TeX table, then written below
variable_table <- variable_summary %>%
  transmute(
    `Measure` = measure_label,
    `Admin-years` = admin_years,
    `Mean` = fmt_num(mean),
    `SD` = fmt_num(sd),
    `Min` = fmt_num(min),
    `P10` = fmt_num(p10),
    `P50` = fmt_num(p50),
    `P90` = fmt_num(p90),
    `Max` = fmt_num(max)
  )

coef_table <- coef_standardized %>%
  mutate(
    measure_label = factor(measure_label, levels = drought_vars$measure_label),
    age_label = factor(age_label, levels = c("0-4", "5-64", "65+"))
  ) %>%
  arrange(measure_label, age_label)

# Within R2 added by each measure, best first
model_table <- model_results %>%
  filter(!is.na(drought_var)) %>%
  arrange(desc(delta_within_r2)) %>%
  transmute(
    `Measure` = set_label,
    `Model within R2` = fmt_num(within_r2, 4),
    `Delta within R2` = fmt_num(delta_within_r2, 4)
  )

# Joint test that all of a measure's coefs are 0, smallest p-value first
joint_table <- joint_results %>%
  arrange(p_value) %>%
  transmute(
    `Measure` = measure_label,
    `Statistic` = fmt_num(statistic),
    `P value` = fmt_p(p_value)
  )

# Summary stats of each drought measure
write_latex_table(
  variable_table,
  file.path(table_dir, paste0("tab_brazil_drought_variable_summary_", run_id, ".tex")),
  "Brazil annual drought variable summary",
  paste0("tab:brazil-drought-variable-summary-", label_run_id),
  align = "lrrrrrrrr"
)

# Coefs and +1 SD effects, one block of 3 age rows per measure
write_grouped_coef_table(
  coef_table,
  file.path(table_dir, paste0("tab_brazil_drought_coefficients_", run_id, ".tex")),
  "Brazil annual drought coefficients",
  paste0("tab:brazil-drought-coefficients-", label_run_id)
)

# Within R2 added by each measure
write_latex_table(
  model_table,
  file.path(table_dir, paste0("tab_brazil_drought_model_comparison_", run_id, ".tex")),
  "Brazil annual drought model comparison",
  paste0("tab:brazil-drought-model-comparison-", label_run_id),
  align = "lrr"
)

# Joint tests
write_latex_table(
  joint_table,
  file.path(table_dir, paste0("tab_brazil_drought_joint_tests_", run_id, ".tex")),
  "Brazil annual drought joint tests",
  paste0("tab:brazil-drought-joint-tests-", label_run_id),
  align = "lrr"
)


# -----------------------------
# Coefficient plot
# -----------------------------

# Measures in the same order as the tables, top to bottom
plot_data <- coef_standardized %>%
  mutate(
    measure_label = factor(measure_label, levels = rev(drought_vars$measure_label)),
    age_label = factor(age_label, levels = c("0-4", "5-64", "65+"))
  )

# Subtitle: FE spec, outcome, weights, controls
plot_subtitle <- paste(
  recode(fe_spec, main = "Main FE", saturated = "Saturated FE", statetrend = "State trends", region = "Region x year FE"),
  paste(outcome_model, "outcome"),
  ifelse(weighted, "population weighted", "unweighted"),
  control_label,
  sep = ", "
)

# Poisson effects are in % of the death rate, levels in deaths per 100,000
x_axis_label <- if (outcome_model == "poisson") {
  "Percent mortality-rate change for a +1 SD increase in the drought measure (indicators: 0 to 1)"
} else {
  "Change in winsorized death rate per 100,000 for a +1 SD increase (indicators: 0 to 1)"
}

# +1 SD effect with 95% CI, one row per measure, one panel per age group.
# Each panel has its own x scale
coef_plot <- ggplot(plot_data, aes(x = estimate_sd, y = measure_label)) +
  geom_vline(xintercept = 0, color = "grey60", linewidth = 0.4) +
  geom_errorbarh(aes(xmin = ci_low_sd, xmax = ci_high_sd),
                 height = 0.18, linewidth = 0.55, color = coef_color) +
  geom_point(size = 2.2, color = coef_color) +
  facet_wrap(~age_label, nrow = 1, scales = "free_x") +
  labs(
    x = x_axis_label,
    y = NULL,
    title = "Brazil annual drought coefficients",
    subtitle = plot_subtitle
  ) +
  theme_bw(base_size = 11) +
  theme(
    panel.grid.minor = element_blank(),
    strip.background = element_rect(fill = "grey92", color = NA),
    plot.title = element_text(face = "bold"),
    axis.text.y = element_text(size = 9)
  )

# Height grows with the number of measures
ggsave(
  file.path(figure_dir, paste0("fig_brazil_drought_coefficients_standardized_", run_id, ".pdf")),
  coef_plot,
  width = 11,
  height = 2 + 0.28 * nrow(drought_vars)
)

message("Wrote tables to: ", table_dir)
message("Wrote figures to: ", figure_dir)
