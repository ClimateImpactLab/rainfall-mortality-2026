# ============================================================
# 02_make_overleaf_doc.R
#
# One Overleaf-ready LaTeX document for the USA flow analysis, with every
# figure it uses copied next to it. Reruns nothing.
#
# The text and the choice of figures follow the Overleaf version edited on
# 2026-10-20, plus the precip-only baseline, the drought and flood bins and
# the collinearity tables added after it:
#
#   1. Flow measures: how they are built            (from 00_describe_flow_measures.R)
#   2. The flow measures in the regression years    (from 00_describe_flow_measures.R)
#   3. Regressions: setup, the regression list, the variable summary and
#      the collinearity after the FE                (from the 02_usa_flow_regs.R CSVs)
#   4. Results, levels (OLS)                        (figures from 01_usa_flow_reg_outputs.R)
#   5. Results, Poisson                             (figures from 01_usa_flow_reg_outputs.R)
#
# Run after 00_describe_flow_measures.R and, for both outcome models, after
# 02_usa_flow_regs.R and 01_usa_flow_reg_outputs.R. The sbatch does this.
#
# Options (must match the regression runs; both outcome models are included):
#   --weighted = true | false
#   --wind_control = none | windmax | winddays | both
#
# Inputs (output/data/flows/usa-annual/):
#   tables/descriptives/usa_flow_measures_section.tex and figures/descriptives/
#   usa_flow_models_<run_id>.csv, usa_flow_variable_summary_<run_id>.csv,
#   usa_flow_fe_collinearity_<run_id>.csv and figures/<run_id>/ for the
#   levels and Poisson runs
#
# Output (output/data/flows/usa-annual/overleaf/), the folder to upload:
#   usa_flow_overleaf.tex   the document
#   figures/*.pdf           the figures it uses (rebuilt on every run)
#
# Also stacks the two runs' usa_flow_all_coefficients_<run_id>.csv into one
# file, output/data/flows/usa-annual/usa_flow_all_coefficients.csv: every
# coefficient of every reg, for both outcome models and both FE specs
#
# Dependencies: dplyr, readr, tidyr; ../../../0_utils/paths.R, so run this
# script from its own folder.
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(tidyr)


# -----------------------------
# Options
# -----------------------------

args <- commandArgs(FALSE)

# Use the value passed by sbatch, or the default if nothing is passed
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# Same defaults as 02_usa_flow_regs.R
weighted_arg <- tolower(get_arg("weighted", "true"))
wind_control <- get_arg("wind_control", "both")

weighted <- weighted_arg %in% c("true", "t", "1", "yes")
weight_label <- if (weighted) "weighted" else "unweighted"


# -----------------------------
# Project files and paths
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../0_utils/paths.R") # DIR_REPO_RAINFALL_MORTALITY

# Both outcome models go in the document, in this order
outcome_labels <- c(levels = "Levels (OLS)", poisson = "Poisson")

# Run names, the same as in 02_usa_flow_regs.R
run_ids <- paste(names(outcome_labels), weight_label, sep = "_")
if (wind_control != "none") {
  run_ids <- paste(run_ids, wind_control, sep = "_")
}
names(run_ids) <- names(outcome_labels)

OUTPUT_DIR <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "flows", "usa-annual")
measures_file <- file.path(OUTPUT_DIR, "tables", "descriptives", "usa_flow_measures_section.tex")
descriptive_figure_dir <- file.path(OUTPUT_DIR, "figures", "descriptives")

overleaf_dir <- file.path(OUTPUT_DIR, "overleaf")
overleaf_figure_dir <- file.path(overleaf_dir, "figures")
doc_file <- file.path(overleaf_dir, "usa_flow_overleaf.tex")


# -----------------------------
# Read inputs
# -----------------------------

model_files <- file.path(OUTPUT_DIR, paste0("usa_flow_models_", run_ids, ".csv"))
summary_files <- file.path(OUTPUT_DIR, paste0("usa_flow_variable_summary_", run_ids, ".csv"))
collinearity_files <- file.path(OUTPUT_DIR, paste0("usa_flow_fe_collinearity_", run_ids, ".csv"))
all_coef_files <- file.path(OUTPUT_DIR, paste0("usa_flow_all_coefficients_", run_ids, ".csv"))

# Stop early, naming what is missing
input_files <- c(measures_file, model_files, summary_files, collinearity_files, all_coef_files)
missing_inputs <- input_files[!file.exists(input_files)]
if (length(missing_inputs) > 0) {
  stop(
    "Missing inputs. Run 00_describe_flow_measures.R, then 02_usa_flow_regs.R and ",
    "01_usa_flow_reg_outputs.R for both outcome models:\n",
    paste(missing_inputs, collapse = "\n"),
    call. = FALSE
  )
}

measures_lines <- readLines(measures_file)
models <- bind_rows(lapply(model_files, read_csv, show_col_types = FALSE))
summaries <- lapply(summary_files, read_csv, show_col_types = FALSE)
collinearities <- lapply(collinearity_files, read_csv, show_col_types = FALSE)

# Both runs use the same rows and weights, so the document states one sample
# size, one variable summary and one collinearity table. Stop if they differ
if (n_distinct(models$sample_rows) != 1 || n_distinct(models$counties) != 1) {
  stop("The levels and Poisson runs have different samples", call. = FALSE)
}
if (!isTRUE(all.equal(summaries[[1]], summaries[[2]]))) {
  stop("The levels and Poisson runs have different variable summaries", call. = FALSE)
}
if (!isTRUE(all.equal(collinearities[[1]], collinearities[[2]]))) {
  stop("The levels and Poisson runs have different collinearity tables", call. = FALSE)
}
variable_summary <- summaries[[1]]
collinearity <- collinearities[[1]]

# Reg and FE order as run
set_order <- unique(models$set_label)
spec_order <- unique(models$spec_short)


# -----------------------------
# Figures
# -----------------------------

# Figures for each run, in the order they appear in the results sections.
# The temperature curves were taken out of the 2026-10-20 Overleaf version,
# so they are made by 01_usa_flow_reg_outputs.R but not used here. The
# coefficient plots are the free-y versions: the 65+ coefficients are much
# larger than the others, so a shared scale flattens the younger groups
run_figures <- tibble::tribble(
  ~stub, ~caption,
  "flow_response", paste(
    "Flow response, relative to 0. x is one month's flow in a grid cell (mm summed over",
    "the cell and every cell upstream of it), from 0 to the 99th percentile of the",
    "county-year average month."
  ),
  "upstream_response", paste(
    "Upstream inflow response, relative to 0. x is one month's upstream inflow to a grid",
    "cell, from 0 to the 99th percentile of the county-year average month."
  ),
  "precip_response", "Precipitation response, relative to 0 mm of daily precipitation.",
  "precip_overlay", paste(
    "Precipitation response of every regression with the precipitation polynomial, by",
    "age group, relative to 0 mm. Gray band: 95\\% CI of the precip-only regression."
  ),
  "flow_anomaly_coefs", paste(
    "z-score and SPI coefficients for a 1-unit change (z-scores: SDs of the county's previous",
    "20 years; SPI: standard normal), positive = wetter. The y-axis scale differs by row."
  ),
  "flow_bin_coefs", paste(
    "Drought and flood bin coefficients: a year in the bin compared with a year whose",
    "annual mean flow is above its 25th percentile and annual max flow below its 75th",
    "percentile (among the county's 20 previous years). The y-axis scale differs by row."
  )
)

run_figure_file <- function(stub, run_id) {
  if (stub %in% c("flow_anomaly_coefs", "flow_bin_coefs")) {
    paste0("fig_usa_", stub, "_", run_id, "_free_y.pdf")
  } else {
    paste0("fig_usa_", stub, "_", run_id, ".pdf")
  }
}

# Every figure the document uses: the descriptive ones named in the measures
# section, and each run's figures
descriptive_figures <- regmatches(
  measures_lines,
  regexpr("(?<=\\{figures/)[^}]+\\.pdf", measures_lines, perl = TRUE)
)

figure_sources <- c(
  file.path(descriptive_figure_dir, descriptive_figures),
  unlist(lapply(run_ids, function(run_id) {
    file.path(OUTPUT_DIR, "figures", run_id, vapply(run_figures$stub, run_figure_file, "", run_id = run_id))
  }), use.names = FALSE)
)

missing_figures <- figure_sources[!file.exists(figure_sources)]
if (length(missing_figures) > 0) {
  stop("Missing figures:\n", paste(missing_figures, collapse = "\n"), call. = FALSE)
}

# The figures folder is rebuilt each time, so it holds only what the
# document uses
unlink(overleaf_figure_dir, recursive = TRUE)
dir.create(overleaf_figure_dir, recursive = TRUE, showWarnings = FALSE)

if (!all(file.copy(figure_sources, overleaf_figure_dir))) {
  stop("Some figures were not copied to ", overleaf_figure_dir, call. = FALSE)
}


# -----------------------------
# TeX helpers
# -----------------------------

# Flow sums run into the millions, so the summary table uses 3 significant digits
fmt_sig <- function(x) {
  ifelse(is.na(x), "", formatC(x, digits = 3, format = "g"))
}

fmt_count <- function(x) {
  format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
}

fmt_2 <- function(x) {
  ifelse(is.na(x), "", formatC(x, digits = 2, format = "f"))
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

# Plain LaTeX table with adjustbox so the output stays on portrait pages
latex_table <- function(data, caption, label, align = NULL) {
  if (is.null(align)) align <- paste0("l", strrep("r", ncol(data) - 1))

  rows <- apply(data, 1, function(row) {
    paste(latex_escape(row), collapse = " & ")
  })

  c(
    "\\begin{table}[!htbp]",
    "\\centering",
    "\\small",
    paste0("\\caption{", latex_escape(caption), "}"),
    paste0("\\label{", label, "}"),
    "\\begin{adjustbox}{max width=\\textwidth}",
    paste0("\\begin{tabular}{", align, "}"),
    "\\hline",
    paste0(paste(latex_escape(names(data)), collapse = " & "), "\\\\"),
    "\\hline",
    paste0(rows, "\\\\"),
    "\\hline",
    "\\end{tabular}",
    "\\end{adjustbox}",
    "\\end{table}",
    ""
  )
}

# Same figure block as 00_describe_flow_measures.R
figure_tex <- function(file, caption, label) {
  c(
    "\\begin{figure}[!htbp]",
    "\\centering",
    paste0("\\includegraphics[width=\\textwidth,height=0.8\\textheight,keepaspectratio]{figures/", file, "}"),
    paste0("\\caption{", caption, "}"),
    paste0("\\label{", label, "}"),
    "\\end{figure}",
    ""
  )
}


# -----------------------------
# Preamble
# -----------------------------

preamble <- c(
  "\\documentclass[11pt]{article}",
  "\\usepackage[margin=1in]{geometry}",
  "\\usepackage{amsmath}",
  "\\usepackage{graphicx}",
  "\\usepackage{adjustbox}",
  "\\usepackage[hidelinks]{hyperref}",
  # File paths are written as \path{}, which xurl lets break anywhere, so
  # they do not run into the margin
  "\\usepackage{xurl}",
  "",
  "\\title{Rainfall flow and mortality: USA counties, 1970--2010}",
  "\\date{\\today}",
  "",
  "\\begin{document}",
  "\\maketitle",
  "\\tableofcontents",
  "\\clearpage",
  ""
)


# -----------------------------
# Regressions section
# -----------------------------

# -------- Setup --------

# Wording of the 2026-10-20 Overleaf version. The wind text and the weights
# follow the run options; with the defaults they read as in that version
wind_setup_text <- switch(
  wind_control,
  none = "the temperature polynomial (order 2) $\\times$ age group, with no wind controls",
  windmax = paste(
    "the temperature polynomial (order 2) and annual population-weighted extreme",
    "wind, each $\\times$ age group"
  ),
  winddays = paste(
    "the temperature polynomial (order 2) and annual population-weighted",
    "high-wind days, each $\\times$ age group"
  ),
  both = paste(
    "the temperature polynomial (order 2) and annual population-weighted extreme",
    "wind and high-wind days, each $\\times$ age group"
  )
)

weight_setup_text <- if (weighted) "with population weights" else "unweighted"

setup_lines <- c(
  "\\subsection{Setup}",
  "\\begin{itemize}",
  paste(
    "\\item Fixed effects. Main FE: county $\\times$ age group and year $\\times$ age",
    "group. Saturated FE adds state $\\times$ year $\\times$ age group."
  ),
  "\\item Standard errors: clustered by state.",
  paste0(
    "\\item Controls in every regression: ", wind_setup_text, ". Every flow, upstream, ",
    "precipitation, z-score, SPI and bin term is also interacted with age group."
  ),
  paste0(
    "\\item Sample: ", fmt_count(models$sample_rows[[1]]), " county $\\times$ age group ",
    "$\\times$ year rows in ", fmt_count(models$counties[[1]]), " counties, 1970--2010."
  ),
  paste0(
    "\\item Outcome: $M_{iat}$, the death rate per 100,000, winsorized at the 99th ",
    "percentile within each age group. Both OLS and Poisson ", weight_setup_text, "."
  ),
  "\\end{itemize}",
  ""
)

# -------- Regression list and variable summary --------

summary_labels <- c(
  flow_poly_1_pop = "Annual flow (sum of monthly cell flow)",
  upstream_poly_1_pop = "Annual upstream inflow (sum of monthly cell inflow)",
  prcp_poly_1 = "Annual precip (mm)",
  flowmean_z_pop = "Annual mean flow z-score",
  flowmax_z_pop = "Annual max flow z-score",
  spi12_flow_pop = "Flow SPI",
  flowmean_bin_p00_10_pop = "Drought bin: driest 10% of mean flow (0/1)",
  flowmean_bin_p10_25_pop = "Drought bin: 10th-25th pct of mean flow (0/1)",
  flowmax_bin_p75_90_pop = "Flood bin: 75th-90th pct of max flow (0/1)",
  flowmax_bin_p90_100_pop = "Flood bin: wettest 10% of max flow (0/1)"
)

variable_table <- variable_summary %>%
  transmute(
    `Measure` = unname(summary_labels[variable]),
    `County-years` = fmt_count(county_years),
    `Mean` = fmt_sig(mean),
    `SD` = fmt_sig(sd),
    `Min` = fmt_sig(min),
    `P10` = fmt_sig(p10),
    `P50` = fmt_sig(p50),
    `P90` = fmt_sig(p90),
    `Max` = fmt_sig(max)
  )

# The regression list in the 2026-10-20 version starts each name in lower
# case (flow + SPI, not flow + spi), with no final period
spec_list <- paste0(tolower(substr(set_order, 1, 1)), substring(set_order, 2))

equation_lines <- c(
  "\\subsection{Equations}",
  "",
  paste0("\\noindent Regression specifications: ", latex_escape(paste(spec_list, collapse = ", ")), "\\\\"),
  paste(
    "What I'm testing is different dimensions of flow vs.\\ precip + upstream and",
    "z-score vs.\\ SPI. The precip-only regression is the baseline for the precipitation",
    "curves, and the bins regressions estimate drought and flood separately."
  ),
  "",
  latex_table(
    variable_table,
    "USA flow measures in the regression sample, one row per county-year, 1970-2010. For the 0/1 bins, the mean is the share of county-years in the bin",
    "tab:usa-flow-variable-summary",
    align = "lrrrrrrrr"
  )
)

# -------- Collinearity after the FE --------

collinearity_labels <- c(
  prcp_poly_1 = "Precip k=1", prcp_poly_2 = "Precip k=2", prcp_poly_3 = "Precip k=3",
  upstream_poly_1_pop = "Upstream k=1", upstream_poly_2_pop = "Upstream k=2", upstream_poly_3_pop = "Upstream k=3",
  flow_poly_1_pop = "Flow k=1", flow_poly_2_pop = "Flow k=2", flow_poly_3_pop = "Flow k=3",
  flowmean_z_pop = "Mean flow z-score", flowmax_z_pop = "Max flow z-score", spi12_flow_pop = "Flow SPI"
)

collinearity <- collinearity %>%
  mutate(
    label1 = unname(collinearity_labels[var1]),
    label2 = unname(collinearity_labels[var2]),
    spec_short = factor(spec_short, levels = spec_order)
  )

# Share of each measure's variation left after the FE, one column per FE spec
share_table <- collinearity %>%
  filter(measure == "share_left") %>%
  mutate(label1 = factor(label1, levels = unname(collinearity_labels))) %>%
  select(label1, spec_short, value) %>%
  pivot_wider(names_from = spec_short, values_from = value) %>%
  arrange(label1) %>%
  mutate(across(-label1, fmt_2), label1 = as.character(label1)) %>%
  rename(Measure = label1)

# Every precip term with every upstream term, one row per pair and one
# column per FE spec (a 3 x 3 grid per FE spec is too wide for the page)
prcp_upstream_table <- collinearity %>%
  filter(measure == "correlation", grepl("^prcp_poly_", var1), grepl("^upstream_poly_", var2)) %>%
  arrange(var1, var2) %>%
  mutate(pair = paste(label1, "vs", label2)) %>%
  mutate(pair = factor(pair, levels = unique(pair))) %>%
  select(pair, spec_short, value) %>%
  pivot_wider(names_from = spec_short, values_from = value) %>%
  mutate(across(-pair, fmt_2), pair = as.character(pair)) %>%
  rename(Pair = pair)

# Flow and the anomaly measures
anomaly_pair_table <- collinearity %>%
  filter(measure == "correlation", !(grepl("^prcp_poly_", var1) & grepl("^upstream_poly_", var2))) %>%
  mutate(pair = paste(label1, "vs", label2)) %>%
  mutate(pair = factor(pair, levels = unique(pair))) %>%
  select(pair, spec_short, value) %>%
  pivot_wider(names_from = spec_short, values_from = value) %>%
  mutate(across(-pair, fmt_2), pair = as.character(pair)) %>%
  rename(Pair = pair)

collinearity_lines <- c(
  "\\subsection{Collinearity after the fixed effects}",
  "",
  paste(
    "\\noindent Each measure is demeaned on the regression fixed effects, with the",
    "regression weights, so what is left is the variation the coefficients are",
    "identified from. Table~\\ref{tab:usa-flow-fe-share} gives the share of each",
    "measure's variation left after the fixed effects;",
    "Tables~\\ref{tab:usa-flow-fe-prcp-upstream} and~\\ref{tab:usa-flow-fe-anomaly}",
    "give correlations after the fixed effects. The temperature and wind controls are",
    "not taken out, and this is the OLS version: Poisson reweights observations while",
    "fitting, so for the Poisson runs it is a close guide, not exact. $k$ is the",
    "polynomial term."
  ),
  "",
  latex_table(
    share_table,
    "Share of each measure's variation left after the fixed effects",
    "tab:usa-flow-fe-share"
  ),
  latex_table(
    prcp_upstream_table,
    "Correlation of the precipitation and upstream polynomial terms after the fixed effects",
    "tab:usa-flow-fe-prcp-upstream"
  ),
  latex_table(
    anomaly_pair_table,
    "Correlation of flow and the anomaly measures after the fixed effects",
    "tab:usa-flow-fe-anomaly"
  )
)

regression_lines <- c(
  "\\section{Regressions}",
  "",
  setup_lines,
  equation_lines,
  collinearity_lines
)


# -----------------------------
# Results sections
# -----------------------------

results_lines <- character()

for (outcome_model in names(run_ids)) {
  run_id <- run_ids[[outcome_model]]

  scale_text <- if (outcome_model == "poisson") {
    "the change in the log death rate"
  } else {
    "the change in annual deaths per 100,000"
  }

  results_lines <- c(
    results_lines,
    "\\clearpage",
    paste0("\\section{Results: ", outcome_labels[[outcome_model]], "}"),
    "",
    paste0(
      "\\noindent Response curves are ", scale_text, ", by age group, with 95\\% ",
      "confidence intervals (SEs clustered by state). Rows: regressions; columns: FE specs."
    ),
    ""
  )

  for (figure_i in seq_len(nrow(run_figures))) {
    stub <- run_figures$stub[[figure_i]]

    results_lines <- c(
      results_lines,
      figure_tex(
        run_figure_file(stub, run_id),
        paste0(outcome_labels[[outcome_model]], ". ", run_figures$caption[[figure_i]]),
        paste0("fig:usa-", gsub("_", "-", stub), "-", outcome_model)
      )
    )
  }
}


# -----------------------------
# Write the document
# -----------------------------

dir.create(overleaf_dir, recursive = TRUE, showWarnings = FALSE)

writeLines(
  c(
    preamble,
    measures_lines,
    "\\clearpage",
    regression_lines,
    results_lines,
    "\\end{document}"
  ),
  doc_file
)

message("Wrote the Overleaf document to: ", doc_file)
message("Copied ", length(figure_sources), " figures to: ", overleaf_figure_dir)


# -----------------------------
# Combined coefficient file
# -----------------------------

# Both runs stacked, levels first. Read as text so every value is written
# back unchanged
all_coefficients <- bind_rows(lapply(all_coef_files, read_csv, col_types = cols(.default = "c")))
all_coef_out <- file.path(OUTPUT_DIR, "usa_flow_all_coefficients.csv")
write_csv(all_coefficients, all_coef_out)

message("Wrote ", nrow(all_coefficients), " coefficients, both runs, to: ", all_coef_out)
