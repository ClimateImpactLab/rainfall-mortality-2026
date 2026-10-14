# ============================================================
# 03_brazil_het_regs.R
#
# Brazil annual drought regs by heterogeneity bin, on the panel from
# 01_build_brazil_panel.R. Same regs as 02_brazil_regs.R, but the drought
# effect is estimated separately for each age group x bin (for ex 65+ in low
# income municipalities).
#
# Heterogeneity dimensions (exact bins under --het_defs):
#   - urban share
#   - income (Kummu)
#   - baseline rainfall level
#   - baseline rainfall variability
#
# Output, per run:
#   - drought coefs by age group x bin
#   - within R2 added by drought, vs the same reg without drought
#   - test of whether the drought coefs differ across bins, within age group
#
# Options:
#   --het_defs = main | climate | all | comma-separated names
#       main: urban share (50% split, equal-width thirds), Kummu income
#         (median split, terciles), urban x income 2 x 2
#       climate: 1981-2010 rainfall level and rainfall variability (CV), each as a
#         median split and terciles, and level x variability 2 x 2
#       all: main + climate + two extra urban splits (any urban vs none,
#         thirds of the urban-share distribution)
#   --drought_vars = main | extended | all | comma-separated names
#       extended: main + the annual rainfall deviation (wet years negative) and
#       the worst 6-month SPI
#   --outcome_model = levels | poisson
#       levels: FE OLS on winsorized death rates
#       poisson: FE Poisson on deaths with log(population) offset
#   --fe_spec = main | saturated | both
#       main: ADM2 x age FE + year x age FE (fails the lead placebo)
#       saturated: main + ADM1 x year x age FE
#   --weighted = true | false
#       population weights. Default: true for levels, false for Poisson
#   --prcp_poly = true | false
#       true adds the annual precip poly (prcp_poly_1-3) x age group
#
# SEs clustered by state (ADM1).
# ============================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(readr)
library(glue)
library(fixest)


# -----------------------------
# Options
# -----------------------------

args <- commandArgs(FALSE)

# Return the requested command-line option, otherwise keep the default below.
get_arg <- function(name, default) {
  pattern <- paste0("^--", name, "=")
  hit <- args[grepl(pattern, args)]
  if (length(hit) == 0) default else sub(pattern, "", hit[[1]])
}

# Default run: levels model, main FE, weights, main het bins, main drought measures.
outcome_model <- get_arg("outcome_model", "levels")
fe_spec <- get_arg("fe_spec", "main")
weighted_default <- if (outcome_model == "poisson") "false" else "true"
weighted_arg <- tolower(get_arg("weighted", weighted_default))
het_defs_arg <- get_arg("het_defs", "main")
drought_vars_arg <- get_arg("drought_vars", "main")
prcp_poly_arg <- tolower(get_arg("prcp_poly", "false"))

weighted <- weighted_arg %in% c("true", "t", "1", "yes")
use_prcp_poly <- prcp_poly_arg %in% c("true", "t", "1", "yes")
log_mort <- outcome_model == "poisson"
weight_label <- if (weighted) "weighted" else "unweighted"


# -----------------------------
# Paths
# -----------------------------

USER <- Sys.getenv("USER")
source("../../../../0_utils/paths.R")

PANEL_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds"
)

DROUGHT_FILE <- paste0(
  "/project/cil/gcp/estimation/rainfall-mortality/climate_data/",
  "ERA5-LAND/drought/annual/era5land_admin_drought_annual_bra.rds"
)

OUTPUT_DIR <- file.path(
  DIR_REPO_RAINFALL_MORTALITY, "output", "data", "drought",
  "brazil-annual", "heterogeneity"
)


# -----------------------------
# Regression setup
# -----------------------------

# -------- a) Fixed-effect specs --------

specs <- tibble::tribble(
  ~spec_id, ~spec_label, ~fe,
  # Main spec matches the first Brazil annual drought regressions.
  "main",
  "ADM2 x age FE, country x year x age FE",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup")),
  # Saturated spec adds ADM1-year-age FE
  "saturated",
  "ADM2 x age FE, country x year x age FE, ADM1 x year x age FE",
  list(c("admin_code^agegroup", "adm0_code^year^agegroup", "adm1_code^year^agegroup"))
)

if (fe_spec != "both") {
  specs <- specs %>% filter(spec_id == fe_spec)
}


# -------- b) Drought measures --------

# Every drought measure the script can run
drought_vars_all <- tibble::tribble(
  ~variable, ~measure_label,
  # Simple annual rainfall measure
  "gs_neglog_annual_rain_pop",
  "-log annual rainfall",

  # Rocha-Soares-style 12-month drought summaries.
  "rs_drought_months_12m_pop",
  "Rocha-Soares drought months",

  "rs_worst_logdev_severity_pop",
  "Worst Rocha-Soares log deviation",

  "rs_worst_pctdev_severity_pop",
  "Worst Rocha-Soares percent deviation",

  # percentile and severity measures from the prior-20-year baseline
  "drought_6m_low10_months_pop",
  "6-month windows below 10th percentile",

  "drought_6m_low05_months_pop",
  "6-month windows below 5th percentile",

  "drought_6m_worst_z_severity_pop",
  "Worst 6-month z-score severity",

  "deficit_mm_max_06m_pop",
  "Largest 6-month rainfall deficit",

  # Calendar-year rainfall vs normal (larger = drier, wet years negative) and
  # worst 6-month SPI severity
  "rain_dry_logdev_pop",
  "Annual rain log deviation",

  "spi06_worst_severity_pop",
  "Worst 6-month SPI severity"
)

# Defining smaller set of "main" drought vars for first het test
main_drought_vars <- c(
  "gs_neglog_annual_rain_pop",
  "rs_drought_months_12m_pop",
  "rs_worst_logdev_severity_pop",
  "drought_6m_low05_months_pop",
  "drought_6m_worst_z_severity_pop"
)

# Choose which drought measures to run:
# "main" = smaller default set, "all" = every measure above, otherwise a comma-separated list
if (drought_vars_arg == "main") {
  drought_vars <- drought_vars_all %>% filter(variable %in% main_drought_vars)
  drought_set <- "maindrought"
} else if (drought_vars_arg == "extended") {
  drought_vars <- drought_vars_all %>%
    filter(variable %in% c(main_drought_vars, "rain_dry_logdev_pop", "spi06_worst_severity_pop"))
  drought_set <- "extendeddrought"
} else if (drought_vars_arg == "all") {
  drought_vars <- drought_vars_all
  drought_set <- "alldrought"
} else {
  requested <- trimws(strsplit(drought_vars_arg, ",", fixed = TRUE)[[1]])
  drought_vars <- drought_vars_all %>% filter(variable %in% requested)
  drought_set <- "customdrought"
}


# -------- c) Heterogeneity groups --------

# The heterogeneity splits the script can run (picked with --het_defs)
het_defs_all <- tibble::tribble(
  ~het_def_id, ~het_def_label,
  # Urban bins matching the earlier precip heterogeneity setup
  "urban2_50", "Urban share, 50% split",
  "urban3_equal_width", "Urban share, equal-width thirds",
  # Kummu income has ADM2 variation, unlike the older ADM1 legacy income
  "income2_kummu", "Kummu income, median split",
  "income3_kummu", "Kummu income, tertiles",
  # Joint urban-income cells
  "urban_income_2x2", "Urban 50% split x Kummu income split",
  # Extra urban splits used to diagnose the Brazil urban-share distribution
  "urban3_distribution", "Urban share, distribution thirds",
  "urban2_any", "Urban share, zero vs above zero",
  # Baseline climate bins from 1981-2010 annual rainfall
  "rain_level2", "Baseline rainfall level, median split",
  "rain_level3", "Baseline rainfall level, terciles",
  "rain_cv2", "Rainfall variability, median split",
  "rain_cv3", "Rainfall variability, terciles",
  "rain_level_cv_2x2", "Baseline rainfall level x variability"
)

# Default set of "main" het vars: urban alone, income alone, and their 2 x 2 combo
main_het_defs <- c(
  "urban2_50",
  "urban3_equal_width",
  "income2_kummu",
  "income3_kummu",
  "urban_income_2x2"
)

climate_het_defs <- c(
  "rain_level2",
  "rain_level3",
  "rain_cv2",
  "rain_cv3",
  "rain_level_cv_2x2"
)

# Choose which heterogeneity groups to run:
# "main" = urban/income, "climate" = rainfall bins, "all" = every group above,
# otherwise a comma-separated list.
if (het_defs_arg == "main") {
  het_defs <- het_defs_all %>% filter(het_def_id %in% main_het_defs)
  het_set <- "mainhet"
} else if (het_defs_arg == "climate") {
  het_defs <- het_defs_all %>% filter(het_def_id %in% climate_het_defs)
  het_set <- "climatehet"
} else if (het_defs_arg == "all") {
  het_defs <- het_defs_all
  het_set <- "allhet"
} else {
  requested <- trimws(strsplit(het_defs_arg, ",", fixed = TRUE)[[1]])
  het_defs <- het_defs_all %>% filter(het_def_id %in% requested)
  het_set <- "customhet"
}

# -------- d) Run label and output files --------

run_id <- paste(fe_spec, outcome_model, weight_label, het_set, drought_set, sep = "_")
if (use_prcp_poly) run_id <- paste(run_id, "prcpoly", sep = "_")
# File names record the spec choices so runs do not overwrite each other
coef_file <- file.path(OUTPUT_DIR, paste0("het_coefs_", run_id, ".csv"))
model_file <- file.path(OUTPUT_DIR, paste0("het_models_", run_id, ".csv"))
test_file <- file.path(OUTPUT_DIR, paste0("het_tests_", run_id, ".csv"))
bin_file <- file.path(OUTPUT_DIR, paste0("het_bins_", run_id, ".csv"))


# -----------------------------
# Read Brazil panel
# -----------------------------

df <- readRDS(PANEL_FILE) %>%
  mutate(agegroup = as.factor(agegroup))

if (log_mort) {
  df <- df %>%
    filter(!is.na(deaths), !is.na(population), population > 0)
}

# check panel N, N adm2, adm1 and year coverage:
message(glue(
  "Brazil heterogeneity sample: {nrow(df)} rows | ",
  "{n_distinct(df$admin_code)} ADM2s | ",
  "{n_distinct(df$adm1_code)} ADM1s | ",
  "{min(df$year)}-{max(df$year)}"
))


# -----------------------------
# Heterogeneity bins
# -----------------------------

# Heterogeneity bins are defined at the ADM2 level (ie not repeated for every
# age-year row in the reg panel)
adm2_bins <- df %>%
  distinct(admin_code, .keep_all = TRUE) %>%
  transmute(
    admin_code,
    urban_share,
    kummu_loggdppc_avg_2010_2024
  )

# Baseline climate bins use 1981-2010 annual rainfall for each ADM2.
baseline_climate <- readRDS(DROUGHT_FILE) %>%
  filter(climate_country == "BRA", year >= 1981, year <= 2010) %>%
  mutate(admin_code = paste(climate_country, as.integer(ID_1), as.integer(ID_2), sep = "_")) %>%
  group_by(admin_code) %>%
  summarise(
    baseline_rain_mean_mm = mean(annual_rain_mm_pop, na.rm = TRUE),
    baseline_rain_sd_mm = sd(annual_rain_mm_pop, na.rm = TRUE),
    baseline_rain_cv = baseline_rain_sd_mm / baseline_rain_mean_mm,
    .groups = "drop"
  )

adm2_bins <- adm2_bins %>%
  left_join(baseline_climate, by = "admin_code")

# Cutoffs used for income, urban-share, and baseline-climate bins
income_median <- median(adm2_bins$kummu_loggdppc_avg_2010_2024, na.rm = TRUE)
income_tertiles <- quantile(adm2_bins$kummu_loggdppc_avg_2010_2024, c(1 / 3, 2 / 3), na.rm = TRUE)
urban_tertiles <- quantile(adm2_bins$urban_share, c(1 / 3, 2 / 3), na.rm = TRUE)
rain_mean_median <- median(adm2_bins$baseline_rain_mean_mm, na.rm = TRUE)
rain_mean_tertiles <- quantile(adm2_bins$baseline_rain_mean_mm, c(1 / 3, 2 / 3), na.rm = TRUE)
rain_cv_median <- median(adm2_bins$baseline_rain_cv, na.rm = TRUE)
rain_cv_tertiles <- quantile(adm2_bins$baseline_rain_cv, c(1 / 3, 2 / 3), na.rm = TRUE)

adm2_bins <- adm2_bins %>%
  mutate(
    # Urban bins: main bins as precip het regs plus distribution checks
    # Any urban pop vs none
    urban2_any = factor(
      if_else(urban_share == 0, "0% urban", "above 0% urban"),
      levels = c("0% urban", "above 0% urban")),
    # Main two-bin split, matching the precip het setup
    urban2_50 = factor(
      if_else(urban_share <= 50, "0-50% urban", "above 50% urban"),
      levels = c("0-50% urban", "above 50% urban")),
    # Main three-bin split, using equal urban-share ranges
    urban3_equal_width = factor(
      case_when(
        urban_share < 34 ~ "0-33% urban",
        urban_share < 67 ~ "34-66% urban",
        TRUE ~ "67-100% urban"),
      levels = c("0-33% urban", "34-66% urban", "67-100% urban")),
    # diagnostic split based on the observed Brazil urban-share distribution
    urban3_distribution = factor(
      case_when(
        urban_share == 0 ~ "0% urban",
        urban_share <= urban_tertiles[[2]] ~ "above 0%, below 67th pct",
        TRUE ~ "above 67th pct"),
      levels = c("0% urban", "above 0%, below 67th pct", "above 67th pct")),
    # Kummu income bins: median split and terciles
    # median
    income2_kummu = factor(
      if_else(
        kummu_loggdppc_avg_2010_2024 <= income_median,
        "low Kummu income",
        "high Kummu income"),
      levels = c("low Kummu income", "high Kummu income")),
    # tercile
    income3_kummu = factor(
      case_when(
        kummu_loggdppc_avg_2010_2024 <= income_tertiles[[1]] ~ "low Kummu income",
        kummu_loggdppc_avg_2010_2024 <= income_tertiles[[2]] ~ "middle Kummu income",
        TRUE ~ "high Kummu income"),
      levels = c("low Kummu income", "middle Kummu income", "high Kummu income")),
    # Baseline rainfall level: 1981-2010 mean annual rainfall
    rain_level2 = factor(
      if_else(baseline_rain_mean_mm <= rain_mean_median, "dry rainfall", "wet rainfall"),
      levels = c("dry rainfall", "wet rainfall")),
    rain_level3 = factor(
      case_when(
        baseline_rain_mean_mm <= rain_mean_tertiles[[1]] ~ "dry rainfall",
        baseline_rain_mean_mm <= rain_mean_tertiles[[2]] ~ "middle rainfall",
        TRUE ~ "wet rainfall"),
      levels = c("dry rainfall", "middle rainfall", "wet rainfall")),
    # Rainfall variability: 1981-2010 CV of annual rainfall
    rain_cv2 = factor(
      if_else(baseline_rain_cv <= rain_cv_median, "stable rainfall", "volatile rainfall"),
      levels = c("stable rainfall", "volatile rainfall")),
    rain_cv3 = factor(
      case_when(
        baseline_rain_cv <= rain_cv_tertiles[[1]] ~ "stable rainfall",
        baseline_rain_cv <= rain_cv_tertiles[[2]] ~ "middle variability",
        TRUE ~ "volatile rainfall"),
      levels = c("stable rainfall", "middle variability", "volatile rainfall"))
  ) %>%
  mutate(
    # 2 x 2 crossed group: urban split x income split
    urban_income_2x2 = factor(
      paste(urban2_50, income2_kummu, sep = " + "),
      levels = c(
        "0-50% urban + low Kummu income",
        "0-50% urban + high Kummu income",
        "above 50% urban + low Kummu income",
        "above 50% urban + high Kummu income"
      )
    ),
    # 2 x 2 crossed group: rainfall level x variability
    rain_level_cv_2x2 = factor(
      paste(rain_level2, rain_cv2, sep = " + "),
      levels = c(
        "dry rainfall + stable rainfall",
        "dry rainfall + volatile rainfall",
        "wet rainfall + stable rainfall",
        "wet rainfall + volatile rainfall"
      )
    )
  )

# Add the selected heterogeneity bins back onto every row of the reg panel
df <- df %>%
  left_join(adm2_bins %>% select(admin_code, all_of(het_defs$het_def_id)), by = "admin_code")

# Save bin sizes so we can see how much data each heterogeneity comparison uses:
bin_counts <- bind_rows(lapply(seq_len(nrow(het_defs)), function(i) {
  het_def_id <- het_defs$het_def_id[[i]]

  df %>%
    distinct(admin_code, year, .keep_all = TRUE) %>%
    filter(!is.na(.data[[het_def_id]])) %>%
    group_by(het_group = .data[[het_def_id]]) %>%
    summarise(
      het_def_id = het_def_id,
      het_def_label = het_defs$het_def_label[[i]],
      adm2s = n_distinct(admin_code),
      admin_years = n(),
      .groups = "drop"
    ) %>%
    select(het_def_id, het_def_label, het_group, adm2s, admin_years)
}))


# -----------------------------
# Model/Regs helpers
# -----------------------------

# Keep age-specific temp controls
temperature_terms <- c(
  "i(agegroup, tavg_poly_1)",
  "i(agegroup, tavg_poly_2)"
)

# pptional annual precip poly (--prcp_poly=true): dry years also have less
# heavy rainfall, so without it the drought coef can pick up fewer flood deaths
prcp_terms <- paste0("i(agegroup, prcp_poly_", 1:3, ")")
base_terms <- if (use_prcp_poly) c(temperature_terms, prcp_terms) else temperature_terms

# Levels use death rates. Poisson uses deaths with log(population) as exposure.
fit_model <- function(data, rhs, fe) {
  fe <- unlist(fe, use.names = FALSE)
  outcome <- if (log_mort) "deaths" else "deathrate_w99"
  rhs_text <- paste(rhs, collapse = " + ")

  if (log_mort) {
    rhs_text <- paste(rhs_text, "offset(log(population))", sep = " + ")
  }

  # Build the fixest formula from the selected RHS and FEs
  f <- as.formula(sprintf(
    "%s ~ %s | %s",
    outcome,
    rhs_text,
    paste(fe, collapse = " + ")
  ))

  if (log_mort) {
    fepois(f, data = data, weights = if (weighted) ~weight else NULL,
           cluster = ~adm1_code, lean = FALSE)
  } else {
    feols(f, data = data, weights = if (weighted) ~weight else NULL,
          cluster = ~adm1_code, lean = FALSE)
  }
}

# Extract fit stat as a number (like within r2 etc.)
get_fitstat <- function(fit, type) {
  out <- fitstat(fit, type)
  as.numeric(out[[type]])
}

# Keep model-level diagnostics in one row per reg
model_summary <- function(fit, data, spec, model_id, het_def, drought_var = NA_character_,
                          base_within_r2 = NA_real_) {
  tibble(
    model_id = model_id,
    spec_id = spec$spec_id,
    spec_label = spec$spec_label,
    het_def_id = het_def$het_def_id,
    het_def_label = het_def$het_def_label,
    drought_var = drought_var,
    nobs = nobs(fit),
    adm1_clusters = n_distinct(data$adm1_code),
    within_r2 = get_fitstat(fit, "wr2"),
    delta_within_r2 = get_fitstat(fit, "wr2") - base_within_r2,
    outcome_model = outcome_model,
    weighted = weighted,
    prcp_poly = use_prcp_poly
  )
}

# Split fixest coef names back into age group and het group
split_age_het <- function(term, drought_var) {
  # age_het was created as "age group x het bin", and fixest stores the
  # interaction coef as "age_het::age group x het bin:drought_var"
  x <- sub(paste0("^age_het::(.+):", drought_var, "$"), "\\1", term)
  split <- strsplit(x, " x ", fixed = TRUE)[[1]]
  tibble(agegroup = split[[1]], het_group = paste(split[-1], collapse = " x "))
}

# Keep only drought coefs from fitted model and attach readable labels
coef_table <- function(fit, spec, model_id, het_def, drought_var, drought_meta) {
  ct <- as.data.frame(coeftable(fit))
  ct$term <- rownames(ct)
  stat_col <- grep(" value$", names(ct), value = TRUE)[[1]]
  p_col <- grep("^Pr\\(", names(ct), value = TRUE)[[1]]

  ct <- ct %>%
    filter(grepl(paste0(":", drought_var, "$"), term))

  # Recover the age group and het bin from each interaction term name, then add
  # those labels back to the coef table
  term_labels <- bind_rows(lapply(ct$term, split_age_het, drought_var = drought_var))

  bind_cols(ct, term_labels) %>%
    transmute(
      model_id = model_id,
      spec_id = spec$spec_id,
      spec_label = spec$spec_label,
      het_def_id = het_def$het_def_id,
      het_def_label = het_def$het_def_label,
      variable = drought_var,
      measure_label = drought_meta$measure_label,
      agegroup = agegroup,
      het_group = het_group,
      estimate = Estimate,
      std_error = `Std. Error`,
      statistic = .data[[stat_col]],
      p_value = .data[[p_col]],
      outcome_model = outcome_model,
      weighted = weighted,
      prcp_poly = use_prcp_poly
    )
}

# Heterogeneity test: within each age group, are drought coefficients equal
# across bins? The main thing we're interested in here
group_equality_tests <- function(fit, spec, model_id, het_def, drought_var, drought_meta) {
  beta <- coef(fit)
  beta_names <- names(beta)
  vc <- vcov(fit)

  # Only the age x bin drought coefs
  terms <- beta_names[grepl(paste0(":", drought_var, "$"), beta_names)]
  term_labels <- bind_cols(
    tibble(term = terms),
    bind_rows(lapply(terms, split_age_het, drought_var = drought_var))
  )

  # Run the equality test separately by age group.
  bind_rows(lapply(unique(term_labels$agegroup), function(age) {
    age_terms <- term_labels %>% filter(agegroup == age)

    # If an age group has only one bin coef, there is no cross-bin test
    if (nrow(age_terms) < 2) {
      return(tibble(
        model_id = model_id,
        spec_id = spec$spec_id,
        spec_label = spec$spec_label,
        het_def_id = het_def$het_def_id,
        het_def_label = het_def$het_def_label,
        variable = drought_var,
        measure_label = drought_meta$measure_label,
        test_type = "equal coefficients across bins",
        agegroup = age,
        statistic = NA_real_,
        df = NA_integer_,
        p_value = NA_real_,
        outcome_model = outcome_model,
        weighted = weighted,
        prcp_poly = use_prcp_poly
      ))
    }

    test_terms <- age_terms$term
    base_term <- test_terms[[1]]

    # Restriction matrix for testing each other bin against the first bin
    rmat <- matrix(0, nrow = length(test_terms) - 1, ncol = length(beta))
    colnames(rmat) <- beta_names

    # Each row tests one bin coef against the first bin in that age group
    for (j in seq_along(test_terms[-1])) {
      rmat[j, test_terms[[j + 1]]] <- 1
      rmat[j, base_term] <- -1
    }

    # Wald statistic for equality across bins within this age group
    diff <- rmat %*% beta
    vdiff <- rmat %*% vc %*% t(rmat)
    solved <- tryCatch(qr.solve(vdiff, diff), error = function(e) rep(NA_real_, length(diff)))
    stat <- as.numeric(t(diff) %*% solved)
    if (!is.finite(stat)) stat <- NA_real_

    # One output row: for this age group, did the drought coefs differ across bins?
    tibble(
      model_id = model_id,
      spec_id = spec$spec_id,
      spec_label = spec$spec_label,
      het_def_id = het_def$het_def_id,
      het_def_label = het_def$het_def_label,
      variable = drought_var,
      measure_label = drought_meta$measure_label,
      test_type = "equal coefficients across bins",
      agegroup = age,
      statistic = stat,
      df = nrow(rmat),
      p_value = if_else(is.na(stat), NA_real_, pchisq(stat, df = nrow(rmat), lower.tail = FALSE)),
      outcome_model = outcome_model,
      weighted = weighted,
      prcp_poly = use_prcp_poly
    )
  }))
}


# -----------------------------
# Estimate regressions
# -----------------------------

# Store results as lists while looping, then bind into csv tables at the end
coef_results <- list()
model_results <- list()
test_results <- list()
result_i <- 1

# Loop over FE specs: main by default, saturated if requested
for (spec_i in seq_len(nrow(specs))) {
  spec <- specs[spec_i, ]

  # For each het definition, rebuild the sample and age-bin factor
  for (het_i in seq_len(nrow(het_defs))) {
    het_def <- het_defs[het_i, ]
    het_col <- het_def$het_def_id

    reg_df <- df %>%
      filter(!is.na(.data[[het_col]])) %>%
      mutate(
        het_group = droplevels(.data[[het_col]]),
        # Create one factor level for each age x bin cell.
        # That's what later appears inside the i(age_het, drought_var) interaction terms
        age_het = interaction(agegroup, het_group, sep = " x ", drop = TRUE)
      )

    # printing current model setup and N while script runs
    message(glue(
      "Running {spec$spec_id} | {het_def$het_def_id}: ",
      "{nrow(reg_df)} rows, {n_distinct(reg_df$admin_code)} ADM2s"
    ))

    # Base model for this sample: temp controls only, or temp + precip poly.
    # delta within R2 below compares each drought model with this same base.
    base_fit <- fit_model(reg_df, rhs = base_terms, fe = spec$fe[[1]])
    base_within_r2 <- get_fitstat(base_fit, "wr2")

    # Save the base model once for this FE spec and het sample
    model_results[[result_i]] <- model_summary(
      base_fit, reg_df, spec,
      model_id = paste(spec$spec_id, het_def$het_def_id, "base", sep = "_"),
      het_def = het_def,
      base_within_r2 = base_within_r2
    )
    result_i <- result_i + 1

    # Run each selected drought measure one at a time on the same sample
    for (var_i in seq_len(nrow(drought_vars))) {
      drought_meta <- drought_vars[var_i, ]
      drought_var <- drought_meta$variable
      model_id <- paste(spec$spec_id, het_def$het_def_id, drought_var, sep = "_")

      # print the drought measure currently being estimated
      message("  drought measure: ", drought_meta$measure_label)

      # Add drought x age-bin terms to the chosen base controls.
      rhs <- c(base_terms, paste0("i(age_het, ", drought_var, ")"))
      fit <- fit_model(reg_df, rhs = rhs, fe = spec$fe[[1]])

      # Coef output: one drought effect per age x heterogeneity bin.
      coef_results[[length(coef_results) + 1]] <- coef_table(
        fit, spec, model_id, het_def, drought_var, drought_meta
      )

      # Model output: within R2 and delta within R2 against the base model.
      model_results[[result_i]] <- model_summary(
        fit, reg_df, spec, model_id, het_def, drought_var, base_within_r2
      )
      result_i <- result_i + 1

      # Test output: within each age group, do the bin-specific coefs differ?
      test_results[[length(test_results) + 1]] <- group_equality_tests(
        fit, spec, model_id, het_def, drought_var, drought_meta
      )
    }
  }
}


# -----------------------------
# Write results
# -----------------------------

# create output folder if this is the first het run
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# collapse loop outputs into one table per output type
coef_results <- bind_rows(coef_results)
model_results <- bind_rows(model_results)
test_results <- bind_rows(test_results)

# write coef estimates, model fit stats, het tests, and bin counts
write_csv(coef_results, coef_file)
write_csv(model_results, model_file)
write_csv(test_results, test_file)
write_csv(bin_counts, bin_file)

message("Wrote coefficients to: ", coef_file)
message("Wrote model comparison table to: ", model_file)
message("Wrote tests to: ", test_file)
message("Wrote bin counts to: ", bin_file)
