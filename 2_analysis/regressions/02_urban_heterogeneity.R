# ============================================================
# 02_urban_heterogeneity.R
#
# Estimate rainfall-mortality response functions separately by urban-share group
#
# This script asks whether wetter-year mortality responses differ between more
# rural and more urban admin units. It uses the rebuilt urban analysis panel,
# bins admin units by GHSL urban share, and interacts those bins with the
# precipitation response function.
#
# This script writes the response-function CSVs and the country-composition
# table. Figures are made separately by
# `2_analysis/figures/02_plot_urban_heterogeneity.R`.
#
# `fit_response()`, `make_coef_names()`, and `build_response()` are defined in
# `0_utils/functions.R`.
#
# Options:
#   --weighted = true | false
#   --outcome_model = levels | poisson
#   --urban_defs = all | equal_3,equal_4,equal_5,binary_50,binary_70
# ============================================================

# -----------------------------
# Packages
# -----------------------------

library(dplyr)
library(tidyr)
library(readr)
library(glue)
library(fixest)

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

# These options are usually set in the sbatch files
weighted_arg <- tolower(get_arg("weighted", "true")) # use population weights
outcome_model <- get_arg("outcome_model", "levels") # levels or Poisson
urban_defs_arg <- get_arg("urban_defs", "all") # urban-share groupings to run

weighted <- weighted_arg %in% c("true", "t", "1", "yes") # treat true/t/1/yes as weighted
log_mort <- outcome_model == "poisson"                   # Poisson runs use the log-link model
model_label <- outcome_model
weight_label <- if (weighted) "weighted" else "unweighted" # used in output file names
out_suffix <- if (weighted && !log_mort) "" else file.path(weight_label, model_label)

# -----------------------------
# Project files
# -----------------------------

USER <- Sys.getenv("USER")
source("../../0_utils/paths.R")
source("../../0_utils/functions.R") # fit_response(), make_coef_names(), build_response()
source("00_prep_analysis_panel.R")  # load_new_panel(), filter_regression_sample()


# -----------------------------
# Output paths
# -----------------------------

rf_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "rf", out_suffix)
diag_dir <- file.path(DIR_REPO_RAINFALL_MORTALITY, "output", "data", "diagnostics", out_suffix)

dir.create(rf_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(diag_dir, recursive = TRUE, showWarnings = FALSE)


# -----------------------------
# Regression sample
# -----------------------------

# Use the main regression sample and require non-missing GHSL urban share
df <- load_new_panel(
  prcp_product = "ERA5LAND",
  temp_product = "ERA5LAND",
  require_urban = TRUE
) %>%
  filter_regression_sample(
    tavg_order = 2,
    prcp_order = 3,
    require_urban = TRUE
  )

message(glue(
  "Urban regression sample: {nrow(df)} rows | ",
  "{n_distinct(df$iso)} countries | ",
  "{n_distinct(df$admin_code)} admin units"
))


# -----------------------------
# Urban-share groups
# -----------------------------

# Divide admin units into equal urban-share bins or at a 50% or 70% threshold
make_urban_group <- function(data, definition) {
  
  if (definition == "equal_3") {
    data %>%
      mutate(
        urban_group = cut(
          urban_share,
          breaks = seq(0, 100, length.out = 4),
          include.lowest = TRUE,
          ordered_result = TRUE
        ),
        urban_def = "3 urban-share bins",
        urban_def_id = "equal_3"
      )
    
  } else if (definition == "equal_4") {
    data %>%
      mutate(
        urban_group = cut(
          urban_share,
          breaks = seq(0, 100, by = 25),
          include.lowest = TRUE,
          ordered_result = TRUE
        ),
        urban_def = "4 urban-share bins",
        urban_def_id = "equal_4"
      )
    
  } else if (definition == "equal_5") {
    data %>%
      mutate(
        urban_group = cut(
          urban_share,
          breaks = seq(0, 100, by = 20),
          include.lowest = TRUE,
          ordered_result = TRUE
        ),
        urban_def = "5 urban-share bins",
        urban_def_id = "equal_5"
      )
    
  } else if (definition == "binary_50") {
    data %>%
      mutate(
        urban_group = factor(
          if_else(urban_share > 50, "Urban share > 50%", "Urban share <= 50%"),
          levels = c("Urban share <= 50%", "Urban share > 50%")
        ),
        urban_def = "Binary urban-share split at 50%",
        urban_def_id = "binary_50"
      )
    
  } else if (definition == "binary_70") {
    data %>%
      mutate(
        urban_group = factor(
          if_else(urban_share > 70, "Urban share > 70%", "Urban share <= 70%"),
          levels = c("Urban share <= 70%", "Urban share > 70%")
        ),
        urban_def = "Binary urban-share split at 70%",
        urban_def_id = "binary_70"
      )
    
  } else {
    stop("Unknown urban definition: ", definition)
  }
}

all_urban_defs <- c("equal_3", "equal_4", "equal_5", "binary_50", "binary_70")

# Run all urban-share definitions or a comma-separated subset
urban_defs <- if (urban_defs_arg == "all") {
  all_urban_defs
} else {
  trimws(strsplit(urban_defs_arg, ",", fixed = TRUE)[[1]])
}


# -----------------------------
# Estimate response functions
# -----------------------------

# Estimate one urban-share definition for one fixed-effect specification
run_urban_rf <- function(data, spec_id, spec_short, spec_label, fe,
                         definition, prcp_order = 3, tavg_order = 2) {
  
  reg_df <- make_urban_group(data, definition) %>%
    filter(!is.na(urban_group)) %>%
    mutate(urban_group = droplevels(urban_group))
  
  message(glue(
    "Running {definition} | {spec_short}: ",
    "{nrow(reg_df)} rows, {n_distinct(reg_df$admin_code)} admin units"
  ))
  
  # `fit_response()` is defined in `0_utils/functions.R`. Here it estimates
  # separate precipitation responses by age and urban-share group.
  fit <- fit_response(
    reg_df,
    tavg_order = tavg_order,
    prcp_order = prcp_order,
    interact_var = "urban_group",
    fe = fe,
    weights = if (weighted) ~weight else NULL,
    cluster = ~adm1_code,
    log_mort = log_mort
  )
  
  # `make_coef_names()` and `build_response()` are defined in
  # `0_utils/functions.R`.
  key <- make_coef_names(
    prefix = "prcp_poly_",
    interact_var = "urban_group",
    fit = fit
  )

  response_groups <- crossing(
    agegroup = levels(reg_df$agegroup),
    urban_group = levels(reg_df$urban_group)
  )
  
  # Build one precipitation response for every age group and urban-share group.
  # Responses are relative to 0 mm rainfall.
  rf <- build_response(
    fit,
    x = 0:300,
    x_ref = 0,
    poly_order = prcp_order,
    groups = response_groups,
    key = key,
    id = "Precipitation",
    vcov_cluster = ~adm1_code,
    vcov_fix = FALSE
  ) %>%
    mutate(
      urban_group = as.character(urban_group),
      spec_id = spec_id,
      spec_short = spec_short,
      spec_label = spec_label,
      urban_def = unique(reg_df$urban_def),
      urban_def_id = unique(reg_df$urban_def_id),
      product = "ERA5-Land",
      weighted = weighted,
      model = outcome_model,
      response_scale = if_else(
        log_mort,
        "poisson_delta_deathrate",
        "deathrate_levels"
      )
    )
  
  # Country composition of each urban-share group
  composition <- reg_df %>%
    mutate(
      urban_group = as.character(urban_group),
      spec_id = spec_id,
      spec_short = spec_short
    ) %>%
    group_by(urban_def_id, urban_def, spec_id, spec_short, urban_group, iso) %>%
    summarize(
      rows = n(),
      admin_units = n_distinct(admin_code),
      population = sum(population, na.rm = TRUE),
      .groups = "drop"
    )
  
  list(rf = rf, composition = composition)
}


# Run each urban-share definition for both preferred fixed-effect specifications
results <- list()
result_index <- 1

for (spec_row in seq_len(nrow(new_panel_specs))) {
  for (definition in urban_defs) {
    results[[result_index]] <- run_urban_rf(
      df,                                      # regression sample
      spec_id = new_panel_specs$spec_id[[spec_row]],       # fixed-effect spec ID
      spec_short = new_panel_specs$spec_short[[spec_row]], # short fixed-effect label
      spec_label = new_panel_specs$spec_label[[spec_row]], # full fixed-effect label
      fe = new_panel_specs$fe[[spec_row]],                 # fixed effects passed to fixest
      definition = definition                              # urban-share grouping to estimate
    )
    
    result_index <- result_index + 1
  }
}


# -----------------------------
# Write results
# -----------------------------

# Response-function rows are split by age group, urban-share group, and
# fixed-effect specification
rf_urban <- bind_rows(lapply(results, `[[`, "rf"))

# This table records how much each country contributes to each urban-share group
urban_composition <- bind_rows(lapply(results, `[[`, "composition"))

rf_file <- paste("urban_heterogeneity", outcome_model, weight_label, sep = "_")
rf_file <- paste0(rf_file, ".csv")

composition_file <- paste(
  "urban_country_composition",
  outcome_model,
  weight_label,
  sep = "_"
)
composition_file <- paste0(composition_file, ".csv")

write_csv(rf_urban, file.path(rf_dir, rf_file))
write_csv(urban_composition, file.path(diag_dir, composition_file))

message("Wrote urban response functions to: ", file.path(rf_dir, rf_file))
message("Wrote urban country composition to: ", file.path(diag_dir, composition_file))
