#========================================================================================#
#' Philippines rainfall & temperature response functions
#'
#' Estimates Carleton-style polynomial response functions for the new PHL
#' municipality-level mortality panel, then repeats them across a set of
#' heterogeneity margins.
#'
#' Reuses the shared estimation machinery in ../../0_utils/functions.R
#' (sourced via _phl_common.R):
#'   get_weights() -> fit_response() -> make_coef_names() -> build_response()
#'                                                        -> plot_response()
#'
#' Outputs (all consumed by ../../output/slides/phl_rainfall_mortality.tex):
#'   output/data/phl/*.csv     response curves
#'   output/figures/phl/*.png  figures
#'   output/tables/phl/*.tex   summary-stat tables
#'
#' Run:  Rscript adhoc/phl/01_phl_response_functions.R
#========================================================================================#

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(fixest)
  library(ggplot2)
  library(MetBrewer)
  library(stringr)
  library(glue)
  library(purrr)
  library(patchwork)
})
theme_set(theme_classic())

# Match the allocation we ask SLURM for, rather than every core on the node.
setFixest_nthreads(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = "1")))

# ---------------------------------------------------------------------------
# 0. Setup
# ---------------------------------------------------------------------------
# Walk up to adhoc/_common.R so this runs identically under Rscript on Midway3,
# locally, and from any working directory, whatever depth the script sits at.
.adhoc <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a) == 1) dirname(normalizePath(sub("^--file=", "", a))) else normalizePath(getwd())
  while (!file.exists(file.path(d, "_common.R")) && dirname(d) != d) d <- dirname(d)
  d
})
source(file.path(.adhoc, "_common.R"))
source(file.path(.adhoc, "phl", "_phl_common.R"))

DIRS <- out_dirs("phl")
DIR_DATA <- DIRS$data; DIR_FIG <- DIRS$fig; DIR_TAB <- DIRS$tab
message("panel: ", PHL_PANEL)

# ---------------------------------------------------------------------------
# 1. Load + prep
# ---------------------------------------------------------------------------
# Follows the same prep steps as 0_utils/load_mortality_data.R, adapted to a
# single-country panel (no adm0 dimension, no CHN time-split).
raw <- read_phl_panel()

# Sample definition, admin codes, covid_period, the CHIRPS temperature alias and
# the polynomial rescaling all live in _phl_common.R so 01/03/05 cannot drift.
df_all <- prep_phl_panel(raw, poly_k = 5,
                         suffixes = c("_ERA5LAND", "_CHIRPS"),
                         alias_tavg = "_CHIRPS") %>%
  # log outcome for the log-OLS estimator check; zeros (mostly ages 0-4, ~5% of
  # that group) go to NA and drop from that spec only
  mutate(log_deathrate_w99 = if_else(deathrate_w99 > 0,
                                     log(deathrate_w99), NA_real_)) %>%
  # alternative winsorisation level for the sensitivity check (section 6k);
  # p99 within age group is the pipeline default inherited from Carleton
  group_by(agegroup) %>%
  mutate(deathrate_w95 = pmin(deathrate,
                              quantile(deathrate, 0.95, na.rm = TRUE, type = 2))) %>%
  ungroup()

# --- heterogeneity margins, built on the FULL panel so every sample has them
# Urban share and settlement type vary within adm3 over time; income and
# long-run climate are fixed at the adm1 level.
df_all <- df_all %>%
  mutate(
    # GHSL degree-of-urbanisation classes collapsed to three readable bins
    smod = case_when(
      settlement_type %in% c(10, 11, 12, 13) ~ "Rural",
      settlement_type %in% c(21, 22)         ~ "Peri-urban",
      settlement_type %in% c(23, 30)         ~ "Urban centre",
      TRUE ~ NA_character_
    ),
    smod = factor(smod, levels = c("Rural", "Peri-urban", "Urban centre"))
  ) %>%
  # terciles of adm1 income and of adm1 long-run precipitation
  mutate(
    inc_ter = cut(gdppc_adm1_avg,
                  breaks = quantile(gdppc_adm1_avg, c(0, 1/3, 2/3, 1), na.rm = TRUE),
                  labels = c("Low income", "Mid income", "High income"),
                  include.lowest = TRUE),
    lrp_ter = cut(lr_prcp_ERA5LAND_adm1_avg,
                  breaks = quantile(lr_prcp_ERA5LAND_adm1_avg, c(0, 1/3, 2/3, 1), na.rm = TRUE),
                  labels = c("Dry", "Mid", "Wet"),
                  include.lowest = TRUE),
    # pandemic era, used by the pandemic-control specification in section 6g
    covid_period = factor(case_when(year <= 2019 ~ "pre",
                                    year <= 2022 ~ "pandemic",
                                    TRUE         ~ "post"),
                          levels = c("pre", "pandemic", "post"))
  )

# --- coastal exposure (built by 00_phl_coastal.R from the adm3 shapefile) ---
# coast_share is the fraction of a municipality's perimeter facing the sea.
# 41% of municipalities are landlocked (share = 0), so quantile bins would be
# degenerate; instead split landlocked vs the median of the coastal ones.
COASTAL_FILE <- file.path(DIR_DATA, "phl_coastal.csv")
if (file.exists(COASTAL_FILE)) {
  coastal <- read_csv(COASTAL_FILE, col_types = cols(adm3_id = col_character(),
                                                     .default = col_guess())) %>%
    select(adm3_id, coast_share)
  df_all <- df_all %>% left_join(coastal, by = "adm3_id")
  cut_hi <- median(coastal$coast_share[coastal$coast_share >= 0.01], na.rm = TRUE)
  df_all <- df_all %>%
    mutate(coast_bin = factor(case_when(
             is.na(coast_share)        ~ NA_character_,
             coast_share < 0.01        ~ "Landlocked",
             coast_share < cut_hi      ~ "Some coast",
             TRUE                      ~ "Highly coastal"),
           levels = c("Landlocked", "Some coast", "Highly coastal")))
  message(sprintf("coastal merge: %.1f%% of panel rows matched | split at %.2f",
                  100 * mean(!is.na(df_all$coast_share)), cut_hi))
  print(table(df_all$coast_bin, useNA = "ifany"))
} else {
  message("no phl_coastal.csv; run 00_phl_coastal.R -- coastal margin skipped")
  df_all$coast_bin <- NA
}

# --- estimation sample ------------------------------------------------------
# The full 2006-2024 panel is used, with the pandemic handled by a control
# rather than by truncation. 2021 old-age mortality runs ~45% above trend with
# no return to the previous level, but under the saturated fixed effects the
# province x year x age terms already absorb most of that shock (section 6f),
# and the municipality x age x era control in `spec_covid` handles the rest
# while keeping all 19 years (section 6g). `df_pre` is retained for comparison.
SAMPLE_MAX_YEAR <- 2019
df     <- df_all                                   # full panel, 2006-2024
df_pre <- filter(df_all, year <= SAMPLE_MAX_YEAR)  # pre-COVID, for comparison

message(glue("full panel: {nrow(df_all)} rows | estimation sample: {nrow(df)} rows | {n_distinct(df$adm3_code)} adm3 | ",
             "{n_distinct(df$adm2_code)} adm2 | {n_distinct(df$adm1_code)} adm1 | ",
             "{min(df$year)}-{max(df$year)}"))

# ---------------------------------------------------------------------------
# 2. Specification grid
# ---------------------------------------------------------------------------
# Single-country analogues of the specifications in 2_analysis/archive/nishka_legacy/het_regressions.R.
# Carleton's adm0^year^agegroup collapses to year^agegroup when there is one
# country, and adm2 (their unit of observation) becomes adm3 here.
# r(i) is the PROVINCE (adm2) containing municipality i.
spec1 <- c("adm3_code^agegroup", "year^agegroup")                               # year x age
spec2 <- c("adm3_code^agegroup", "year^agegroup", "adm2_agegrp_code[year]")     # + province-age trends
spec3 <- c("adm3_code^agegroup", "adm2_code^year^agegroup")                     # saturated: mu_ai + nu_{a,t,r(i)}

# Pandemic control. The saturated spec already absorbs any pandemic shock that
# is common within a province-year-age cell, so the useful control is one level
# lower: a separate intercept for each MUNICIPALITY x age in each pandemic era.
# That soaks up locality-specific COVID mortality while leaving within-era
# weather variation intact, so the full 2006-2024 panel can be used.
spec_covid <- c("adm3_code^agegroup^covid_period", "adm2_code^year^agegroup")

SPEC_LABS <- c(
  "adm3_code^agegroup+year^agegroup"                            = "(1) year x age",
  "adm3_code^agegroup+year^agegroup+adm2_agegrp_code[year]"     = "(2) + province-age trends",
  "adm3_code^agegroup+adm2_code^year^agegroup"                  = "(3) saturated",
  "adm3_code^agegroup^covid_period+adm2_code^year^agegroup"     = "(4) + pandemic control (default)"
)

# 17 adm1 regions is too few to cluster on; province (adm2) is the default.
CL <- ~adm2_code

# Response curves are evaluated over DAILY values, since the regressors are
# annual sums of daily polynomial terms.
X_PRCP <- 0:300      # mm/day, matching the range used elsewhere in the project
X_TAVG <- seq(15, 35, by = 0.1)
REF_TAVG <- 27       # Carleton reference temperature

# daily rainfall levels at which marginal effects are tabulated
ME_AT <- c(50, 100, 200)

# ---------------------------------------------------------------------------
# 3. Generic response-curve wrapper
# ---------------------------------------------------------------------------
#' Generalises base_rf()/urban_rf() from 2_analysis/archive/nishka_legacy/het_regressions.R into a
#' single helper: with interact_var = NULL it is the uninteracted baseline,
#' otherwise it returns one curve per (agegroup x interact_var) cell.
#'
#' @param interact_var name of a categorical column in `df`, or NULL
#' @param prefix       "prcp_poly_" or "tavg_poly_"
#' @param suffix       "_ERA5LAND" or "_CHIRPS"
#' @return response-curve tibble; the fitted model is attached as attr(, "fit")
phl_rf <- function(df,
                   interact_var = NULL,
                   lhs = "deathrate_w99",
                   prcp_order = 3,
                   tavg_order = 3,
                   x = X_PRCP,
                   x_ref = 0,
                   fe = spec_covid,   # saturated + pandemic control, section 2
                   weights = ~weight,
                   log_mort = TRUE,
                   prefix = "prcp_poly_",
                   suffix = "_ERA5LAND",
                   cluster = CL,
                   id = "Precip",
                   ...) {          # extra args forwarded to fit_response -> fepois/feols
                                   # (e.g. offset = ~log(population))

  df$agegroup <- as.factor(df$agegroup)

  if (!is.null(interact_var)) {
    df <- df %>% filter(!is.na(.data[[interact_var]]))
    df[[interact_var]] <- as.factor(df[[interact_var]])
  }

  fit <- fit_response(df,
                      lhs = lhs,
                      tavg_order = tavg_order,
                      prcp_order = prcp_order,
                      interact_var = interact_var,
                      fe = fe,
                      weights = weights,
                      log_mort = log_mort,
                      cluster = cluster,
                      suffix = suffix,
                      ...)

  key <- make_coef_names(prefix = prefix,
                         interact_var = interact_var,
                         fit = if (is.null(interact_var)) NULL else fit,
                         suffix = suffix)

  poly_order <- if (prefix == "tavg_poly_") tavg_order else prcp_order

  groups <- if (is.null(interact_var)) {
    tibble(agegroup = levels(df$agegroup))
  } else {
    grp <- tidyr::crossing(agegroup = levels(df$agegroup),
                           lvl = levels(df[[interact_var]]))
    names(grp)[2] <- interact_var
    grp
  }

  # `x` arrives in natural units (mm/day, degrees C); the regression is in
  # rescaled units, so evaluate there and convert the axis back afterwards.
  sc <- if (prefix == "tavg_poly_") TAVG_SCALE else PRCP_SCALE

  rf <- build_response(fit, x = x / sc, x_ref = x_ref / sc, poly_order = poly_order,
                       groups = groups, key = key, id = id) %>%
    mutate(x = x * sc,
           age_lab = factor(AGE_LABS[as.character(agegroup)],
                            levels = unname(AGE_LABS)))

  attr(rf, "fit") <- fit
  rf
}

# ---------------------------------------------------------------------------
# 4. Summary statistics
# ---------------------------------------------------------------------------

# Panel A: mortality by age group
tabA <- df %>%
  group_by(`Age group` = age_lab) %>%
  summarise(
    N            = n(),
    Mean         = mean(deathrate, na.rm = TRUE),
    `Std. dev.`  = sd(deathrate, na.rm = TRUE),
    Median       = median(deathrate, na.rm = TRUE),
    `p99`        = quantile(deathrate, 0.99, na.rm = TRUE),
    `Share zero` = mean(deathrate == 0, na.rm = TRUE),
    .groups = "drop"
  )

# Panel B: climate (annual totals and implied daily means)
clim <- tibble(
  Variable = c("Annual precipitation, ERA5-Land (mm)",
               "Annual precipitation, CHIRPS (mm)",
               "Mean daily temperature, ERA5-Land ($^\\circ$C)",
               "Long-run mean precipitation, adm1 (mm)",
               "Long-run mean temperature, adm1 ($^\\circ$C)"),
  # multiply back out of the regression units set above
  value = list(df$prcp_poly_1_ERA5LAND * PRCP_SCALE,
               df$prcp_poly_1_CHIRPS   * PRCP_SCALE,
               df$tavg_poly_1_ERA5LAND * TAVG_SCALE / 365,
               df$lr_prcp_ERA5LAND_adm1_avg,
               df$lr_tavg_ERA5LAND_adm1_avg)
) %>%
  mutate(Mean = map_dbl(value, mean, na.rm = TRUE),
         `Std. dev.` = map_dbl(value, sd, na.rm = TRUE),
         Min = map_dbl(value, min, na.rm = TRUE),
         Max = map_dbl(value, max, na.rm = TRUE)) %>%
  select(-value)

# Panel C: heterogeneity margins
het <- tibble(
  Variable = c("Urban population share (\\%)",
               "GDP per capita, adm1 average (USD)"),
  value = list(df$urban_share, df$gdppc_adm1_avg)
) %>%
  mutate(Mean = map_dbl(value, mean, na.rm = TRUE),
         `Std. dev.` = map_dbl(value, sd, na.rm = TRUE),
         Min = map_dbl(value, min, na.rm = TRUE),
         Max = map_dbl(value, max, na.rm = TRUE)) %>%
  select(-value)

# write a single booktabs table with three panels
sumstat_tex <- c(
  "\\begin{tabular}{lrrrrrr}",
  "\\toprule",
  "\\multicolumn{7}{l}{\\textit{Panel A: Mortality rate (deaths per 100,000)}} \\\\",
  "\\midrule",
  "Age group & N & Mean & Std. dev. & Median & p99 & Share zero \\\\",
  "\\midrule",
  paste0(tabA$`Age group`, " & ", fmt(tabA$N, 0), " & ", fmt(tabA$Mean), " & ",
         fmt(tabA$`Std. dev.`), " & ", fmt(tabA$Median), " & ", fmt(tabA$p99),
         " & ", fmt(tabA$`Share zero`, 3), " \\\\"),
  "\\midrule",
  "\\multicolumn{7}{l}{\\textit{Panel B: Climate}} \\\\",
  "\\midrule",
  "Variable & \\multicolumn{2}{r}{Mean} & \\multicolumn{2}{r}{Std. dev.} & Min & Max \\\\",
  "\\midrule",
  paste0(clim$Variable, " & \\multicolumn{2}{r}{", fmt(clim$Mean), "} & \\multicolumn{2}{r}{",
         fmt(clim$`Std. dev.`), "} & ", fmt(clim$Min), " & ", fmt(clim$Max), " \\\\"),
  "\\midrule",
  "\\multicolumn{7}{l}{\\textit{Panel C: Heterogeneity margins}} \\\\",
  "\\midrule",
  paste0(het$Variable, " & \\multicolumn{2}{r}{", fmt(het$Mean), "} & \\multicolumn{2}{r}{",
         fmt(het$`Std. dev.`), "} & ", fmt(het$Min), " & ", fmt(het$Max), " \\\\"),
  "\\bottomrule",
  "\\end{tabular}"
)
writeLines(sumstat_tex, file.path(DIR_TAB, "summary_stats.tex"))

# panel-structure facts used on the data slide
write_facts(
  file.path(DIR_TAB, "panel_facts.tex"),
  phlNobs      = fmt(nrow(df), 0),
  phlNadmthree = fmt(n_distinct(df$adm3_code), 0),
  phlNadmtwo   = fmt(n_distinct(df$adm2_code), 0),
  phlNadmone   = fmt(n_distinct(df$adm1_code), 0),
  phlYearMin   = min(df$year),
  phlYearMax   = max(df$year)
)

# ---------------------------------------------------------------------------
# 5. Baseline (uninteracted) response functions
# ---------------------------------------------------------------------------
message("\n=== 5. baseline ===")

rf_precip_base <- phl_rf(df, id = "Precip")
rf_tavg_base   <- phl_rf(df, prefix = "tavg_poly_", x = X_TAVG,
                         x_ref = REF_TAVG, id = "Temperature")

p_precip <- plot_response(rf_precip_base, color = "age_lab",
                          xlab = "Daily precipitation (mm)",
                          ylab = "Δ deaths per 100,000")
save_fig("baseline_precip.png", p_precip,
       width = 7, height = 4.5)

p_tavg <- plot_response(rf_tavg_base, color = "age_lab",
                        xlab = "Daily mean temperature (°C)",
                        ylab = "Δ deaths per 100,000")
save_fig("baseline_tavg.png", p_tavg,
       width = 7, height = 4.5)

write_csv(bind_rows(rf_precip_base, rf_tavg_base),
          file.path(DIR_DATA, "rf_baseline.csv"))

# ---------------------------------------------------------------------------
# 5b. Fit diagnostics for the default specification
# ---------------------------------------------------------------------------
# Everything else uses lean = TRUE, which discards residuals; refit the
# default model once keeping them. `obs()` maps back to the estimation rows
# (fepois drops 0-outcome and singleton FE cells).
message("\n=== 5b. fit diagnostics ===")

d_diag <- df; d_diag$agegroup <- as.factor(d_diag$agegroup)
fml_diag <- as.formula(paste(
  "deathrate_w99 ~",
  paste(c(paste0("i(agegroup, tavg_poly_", 1:3, "_ERA5LAND)"),
          paste0("i(agegroup, prcp_poly_", 1:3, "_ERA5LAND)")), collapse = " + "),
  "|", paste(spec_covid, collapse = " + ")))
fit_diag <- fepois(fml_diag, data = d_diag, weights = ~weight,
                   cluster = CL, lean = FALSE)

diag_df <- d_diag[obs(fit_diag), ] %>%
  mutate(mu   = fitted(fit_diag),
         pear = residuals(fit_diag, type = "pearson"))

fit_stats <- diag_df %>%
  group_by(age_lab) %>%
  summarise(r2 = cor(deathrate_w99, mu)^2, .groups = "drop")
message("squared corr(actual, fitted) by age:")
print(as.data.frame(fit_stats), digits = 3)


p_a <- ggplot(diag_df, aes(mu, deathrate_w99)) +
  geom_bin2d(bins = 60) +
  geom_abline(slope = 1, intercept = 0, colour = "red", linewidth = 0.3) +
  scale_fill_viridis_c(trans = "log10", guide = "none") +
  scale_x_continuous(trans = "sqrt") + scale_y_continuous(trans = "sqrt") +
  facet_wrap(~age_lab, scales = "free") +
  labs(x = "Fitted death rate", y = "Actual death rate",
       title = "Predicted vs actual (sqrt axes)") +
  theme_classic() + theme(plot.title = element_text(size = 10))

p_b <- ggplot(diag_df, aes(mu, pear)) +
  geom_bin2d(bins = 60) +
  geom_hline(yintercept = 0, colour = "red", linewidth = 0.3) +
  scale_fill_viridis_c(trans = "log10", guide = "none") +
  scale_x_continuous(trans = "log10") +
  facet_wrap(~age_lab, scales = "free_x") +
  labs(x = "Fitted death rate (log scale)", y = "Pearson residual",
       title = "Residuals vs fitted") +
  theme_classic() + theme(plot.title = element_text(size = 10))

# Relative error (y - mu)/mu for the aggregate panels: scale-free, immune to
# the weighting, and readable as "% over/under-predicted". Pearson residuals
# stay in the residuals-vs-fitted scatter, where checking the variance
# function is the point.
diag_df <- diag_df %>%
  mutate(rel = (deathrate_w99 - mu) / mu) %>%
  # bin population WITHIN age group: 65+ counts are a small share of total
  # population, so pooled bins mix the age groups and produce spurious spikes
  group_by(age_lab) %>%
  mutate(pop_dec = ntile(population, 10),
         pop_ter = cut(ntile(population, 3), 3,
                       labels = c("Small", "Mid", "Large"))) %>%
  ungroup()

p_c <- diag_df %>%
  group_by(year, age_lab, pop_ter) %>%
  summarise(m = mean(rel), .groups = "drop") %>%
  ggplot(aes(year, m, colour = pop_ter)) +
  geom_hline(yintercept = 0, colour = "grey60") +
  geom_line(linewidth = 0.7) +
  facet_wrap(~age_lab) +
  scale_color_manual(values = PAL3) +
  scale_y_continuous(labels = scales::percent) +
  labs(x = NULL, y = "Mean relative error", colour = "Municipality size",
       title = "Relative error by year and municipality size") +
  theme_classic() +
  theme(plot.title = element_text(size = 10), legend.position = "bottom")

p_d <- diag_df %>%
  group_by(pop_dec, age_lab) %>%
  summarise(med = median(rel), lo = quantile(rel, .25), hi = quantile(rel, .75),
            pop = median(population), .groups = "drop") %>%
  ggplot(aes(pop, med, colour = age_lab, fill = age_lab)) +
  geom_hline(yintercept = 0, colour = "grey60") +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.15, colour = NA) +
  geom_line(linewidth = 0.7) + geom_point(size = 0.8) +
  scale_x_continuous(trans = "log10", labels = scales::label_comma()) +
  scale_y_continuous(labels = scales::percent) +
  scale_color_manual(values = PAL3) +
  scale_fill_manual(values = PAL3) +
  labs(x = "Cell population (log scale, deciles within age)",
       y = "Relative error", colour = "Age", fill = "Age",
       title = "Median relative error by size (band = IQR)") +
  theme_classic() +
  theme(plot.title = element_text(size = 10), legend.position = "bottom")

save_fig("fit_diagnostics.png",
       (p_a / p_b) | (p_c / p_d),
       width = 13, height = 7, bg = "white")

# municipality-mean residuals, mapped by adhoc/phl/02_phl_maps.R
diag_df %>%
  group_by(adm3_id) %>%
  summarise(mean_pearson = mean(pear), mean_rel = mean(rel), .groups = "drop") %>%
  write_csv(file.path(DIR_DATA, "resid_adm3.csv"))

# ---------------------------------------------------------------------------
# 6. Robustness: polynomial order, fixed effects, climate product
# ---------------------------------------------------------------------------
message("\n=== 6a. precip polynomial order (temperature held at order 3) ===")
rf_poly <- map_dfr(1:4, function(k) {
  phl_rf(df, prcp_order = k) %>% mutate(precip_poly = paste0("Order ", k))
}) %>% mutate(precip_poly = factor(precip_poly))

save_fig("robust_poly_order.png",
       plot_response(rf_poly, color = "age_lab", facet = "precip_poly",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ deaths per 100,000"),
       width = 10, height = 4)

message("\n=== 6b. fixed effects ===")
rf_fe <- map_dfr(list(spec1, spec2, spec3, spec_covid), function(fe) {
  lbl <- SPEC_LABS[[paste(fe, collapse = "+")]]
  phl_rf(df, fe = fe) %>% mutate(spec = lbl)
}) %>% mutate(spec = factor(spec, levels = unname(SPEC_LABS)))

save_fig("robust_fe.png",
       plot_response(rf_fe, color = "age_lab", facet = "spec",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ deaths per 100,000"),
       width = 12, height = 4)

message("\n=== 6c. climate product ===")
rf_product <- map_dfr(c("_ERA5LAND", "_CHIRPS"), function(sfx) {
  phl_rf(df, suffix = sfx) %>%
    mutate(product = if_else(sfx == "_ERA5LAND", "ERA5-Land", "CHIRPS"))
}) %>% mutate(product = factor(product, levels = c("ERA5-Land", "CHIRPS")))

save_fig("robust_product.png",
       plot_response(rf_product, color = "age_lab", facet = "product",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ deaths per 100,000"),
       width = 9, height = 4)

message("\n=== 6d. estimator: Poisson (rate and count) vs OLS (levels and logs) ===")
# Default specification (4) estimated four ways.
#  - rate Poisson: fepois on the winsorised rate, population-share weighted
#    (the project convention);
#  - count Poisson: fepois on raw death counts with a log-population offset,
#    unweighted -- the textbook count model; keeps zero-death cells;
#  - log-OLS: comparable to both Poissons (all three are in log points) but
#    drops zero-deathrate cells (mostly ages 0-4, ~5% of that group);
#  - levels OLS: in deaths per 100,000.
rf_estimator <- bind_rows(
  phl_rf(df, log_mort = TRUE) %>%
    mutate(estimator = "Poisson, rate (default)"),
  phl_rf(df, log_mort = TRUE, lhs = "deaths", weights = NULL,
         offset = ~log(population)) %>%
    mutate(estimator = "Poisson, counts + offset"),
  phl_rf(df, log_mort = FALSE, lhs = "log_deathrate_w99") %>%
    mutate(estimator = "OLS, log deathrate"),
  phl_rf(df, log_mort = FALSE) %>%
    mutate(estimator = "OLS, levels")
) %>% mutate(estimator = factor(estimator, levels = c("Poisson, rate (default)",
                                                      "Poisson, counts + offset",
                                                      "OLS, log deathrate",
                                                      "OLS, levels")))

save_fig("robust_estimator.png",
       plot_response(rf_estimator, color = "age_lab", facet = "estimator",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ outcome (log points / deaths per 100,000)",
                     scales = "free_y"),
       width = 13, height = 3.8)

write_csv(bind_rows(rf_poly, rf_fe, rf_product, rf_estimator),
          file.path(DIR_DATA, "rf_robustness.csv"))

# ---------------------------------------------------------------------------
# 6e. Identification diagnostic
# ---------------------------------------------------------------------------
# How much of each climate variable's variation survives the fixed effects?
# This is what separates the precipitation result (credible) from the
# temperature result (not identified): in a single tropical country,
# temperature is spatially smooth and dominated by national interannual
# (ENSO-driven) swings, so year effects absorb almost all of it. Rainfall is
# far more local, so municipality deviations from the national year mean retain
# real signal.
message("\n=== 6e. FE absorption diagnostic ===")

FE_SETS <- list(
  "adm3 $\\times$ age"                        = c("adm3_code^agegroup"),
  "\\quad + year $\\times$ age"               = spec1,
  "\\quad + province-age trends"              = spec2,
  "adm3 $\\times$ age + prov $\\times$ yr $\\times$ age" = spec3
)

absorb <- map_dfr(names(FE_SETS), function(nm) {
  fe <- FE_SETS[[nm]]
  tibble(
    FE = nm,
    prcp = 100 * sd(resid(feols(as.formula(paste0("prcp_poly_1_ERA5LAND ~ 1 | ",
                                paste(fe, collapse = "+"))), data = df))) /
           sd(df$prcp_poly_1_ERA5LAND),
    tavg = 100 * sd(resid(feols(as.formula(paste0("tavg_poly_1_ERA5LAND ~ 1 | ",
                                paste(fe, collapse = "+"))), data = df))) /
           sd(df$tavg_poly_1_ERA5LAND)
  )
})
print(as.data.frame(absorb), digits = 3)

# (printed only; the deck's identification table below carries these numbers)

# temperature response under each FE set, to show the sign instability.
# The no-time-controls set (adm3 x age only) stays in the absorption print
# above but is dropped from the figure: without time effects it is not a
# specification anyone would run, so it distracts from the comparison.
rf_temp_fe <- map_dfr(setdiff(names(FE_SETS), "adm3 $\\times$ age"), function(nm) {
  phl_rf(df, prefix = "tavg_poly_", x = X_TAVG, x_ref = REF_TAVG,
         fe = FE_SETS[[nm]], id = "Temperature") %>%
    mutate(spec = str_replace_all(nm, c("\\\\quad " = "", "\\$\\\\times\\$" = "x")))
}) %>% mutate(spec = factor(spec, levels = unique(spec)))

save_fig("temp_fe_instability.png",
       plot_response(rf_temp_fe, color = "age_lab", facet = "spec",
                     xlab = "Daily mean temperature (°C)",
                     ylab = "Δ deaths per 100,000", scales = "free_y"),
       width = 10, height = 4)
write_csv(rf_temp_fe, file.path(DIR_DATA, "rf_temp_fe.csv"))

# Collinearity of the polynomial terms, after the FEs. This is the second
# reason the temperature curve cannot be read: the linear and quadratic terms
# are 0.99 correlated once the FEs are absorbed, so the quadratic is fitted off
# almost no independent variation.
resid_on_fe <- function(v) resid(feols(as.formula(paste0(v, " ~ 1 | ",
                                       paste(spec1, collapse = "+"))), data = df))
rt1 <- resid_on_fe("tavg_poly_1_ERA5LAND"); rt2 <- resid_on_fe("tavg_poly_2_ERA5LAND")
rp1 <- resid_on_fe("prcp_poly_1_ERA5LAND"); rp2 <- resid_on_fe("prcp_poly_2_ERA5LAND")

r2t <- summary(lm(rt2 ~ rt1))$r.squared
r2p <- summary(lm(rp2 ~ rp1))$r.squared

ident <- tibble(
  Quantity = c("\\% of s.d. surviving FEs",
               "corr(linear, quad.) post-FE",
               "variance inflation factor",
               "residual daily variation"),
  Precipitation = c(sprintf("%.1f", 100*sd(rp1)/sd(df$prcp_poly_1_ERA5LAND)),
                    sprintf("%.3f", cor(rp1, rp2)),
                    sprintf("%.1f", 1/(1-r2p)),
                    sprintf("%.2f mm", sd(rp1)*PRCP_SCALE/365)),
  Temperature   = c(sprintf("%.1f", 100*sd(rt1)/sd(df$tavg_poly_1_ERA5LAND)),
                    sprintf("%.3f", cor(rt1, rt2)),
                    sprintf("%.1f", 1/(1-r2t)),
                    sprintf("%.3f $^\\circ$C", sd(rt1)*TAVG_SCALE/365))
)
print(as.data.frame(ident))
writeLines(c("\\begin{tabular}{lrr}", "\\toprule",
             " & Precipitation & Temperature \\\\", "\\midrule",
             paste0(ident$Quantity, " & ", ident$Precipitation, " & ", ident$Temperature, " \\\\"),
             "\\bottomrule", "\\end{tabular}"),
           file.path(DIR_TAB, "identification.tex"))

# ---------------------------------------------------------------------------
# 6f. COVID sample sensitivity
# ---------------------------------------------------------------------------
# 2021 old-age mortality is ~45% above trend and the level never returns, so
# the pandemic years are a large shock sitting inside the estimation window.
# How much this matters depends on the fixed effects: under year x age effects
# the pandemic years roughly double the estimated rainfall effect, but under the
# saturated default (province x year x age) the samples differ by well under one
# standard error.
message("\n=== 6f. COVID sample sensitivity ===")

COVID_SAMPLES <- list(
  "All years 2006-2024" = unique(df_all$year),
  "Drop 2020-21"        = setdiff(unique(df_all$year), c(2020, 2021)),
  "Drop 2020-22"        = setdiff(unique(df_all$year), c(2020, 2021, 2022)),
  "Pre-COVID (<=2019)"  = 2006:SAMPLE_MAX_YEAR
)

rf_covid <- map_dfr(names(COVID_SAMPLES), function(nm) {
  phl_rf(filter(df_all, year %in% COVID_SAMPLES[[nm]]), fe = spec3, id = "Precip") %>%
    mutate(sample = nm)
}) %>% mutate(sample = factor(sample, levels = names(COVID_SAMPLES)))

save_fig("robust_covid.png",
       plot_response(rf_covid, color = "age_lab", facet = "sample",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ deaths per 100,000"),
       width = 13, height = 4)
write_csv(rf_covid, file.path(DIR_DATA, "rf_covid.csv"))

# annual mortality trend, to show the pandemic shock
save_fig("mortality_trend.png",
       df_all %>% group_by(year, age_lab) %>%
         summarise(mdr = weighted.mean(deathrate_w99, population), .groups = "drop") %>%
         ggplot(aes(year, mdr, colour = age_lab)) +
         geom_line(linewidth = 1) + geom_point(size = 1) +
         facet_wrap(~age_lab, scales = "free_y") +
         scale_color_manual(values = PAL3) +
         labs(x = NULL, y = "Deaths per 100,000", colour = "Age group") +
         theme(legend.position = "none"),
       width = 11, height = 3.4)

# ---------------------------------------------------------------------------
# 6g. Pandemic control: keep 2020-24 rather than dropping it
# ---------------------------------------------------------------------------
message("\n=== 6g. pandemic control ===")

rf_pandemic <- bind_rows(
  # "no control" on the full panel: identical model to the first COVID_SAMPLES
  # arm in 6f, refit here for clarity since 6f stores no fit objects
  phl_rf(df_all, fe = spec3, id = "Precip") %>%
    mutate(spec = "Full panel, no control"),
  # the default arm IS the baseline of section 5 (df == df_all, fe = spec_covid);
  # reuse it rather than refitting the same model
  rf_precip_base %>%
    mutate(spec = "Full panel + pandemic control (default)"),
  phl_rf(df_pre, fe = spec3, id = "Precip") %>%
    mutate(spec = "Pre-COVID, no control")
) %>% mutate(spec = factor(spec, levels = c("Full panel, no control",
                                            "Full panel + pandemic control (default)",
                                            "Pre-COVID, no control")))

write_csv(rf_pandemic, file.path(DIR_DATA, "rf_pandemic_control.csv"))
save_fig("pandemic_control.png",
       plot_response(rf_pandemic, color = "age_lab", facet = "spec",
                     xlab = "Daily precipitation (mm)",
                     ylab = "\u0394 deaths per 100,000"),
       width = 12, height = 4)

print(rf_pandemic %>% filter(x %in% c(100, 200)) %>%
        select(spec, age_lab, x, dy, se) %>%
        tidyr::pivot_wider(names_from = x, values_from = c(dy, se)) %>%
        as.data.frame(), digits = 3)

# ---------------------------------------------------------------------------
# 6h. Dynamics: lagged precipitation, cumulative effect, and a lead placebo
# ---------------------------------------------------------------------------
# Displacement ("harvesting") check: if heavy rainfall mostly shifts deaths
# forward in time, lagged rainfall enters with the opposite sign and the
# cumulative (t + t-1 + t-2) response shrinks toward zero. The lead (t+1) is a
# falsification test: future rainfall must not predict current mortality
# conditional on the fixed effects.
message("\n=== 6h. dynamics: lags, cumulative effect, lead placebo ===")

K_P <- 3
df_dyn <- df %>%
  group_by(adm3_code, agegroup) %>%
  arrange(year, .by_group = TRUE) %>%
  mutate(across(all_of(paste0("prcp_poly_", 1:K_P, "_ERA5LAND")),
                list(L1 = ~lag(.x, 1), L2 = ~lag(.x, 2), F1 = ~lead(.x, 1)),
                .names = "{.col}_{.fn}")) %>%
  ungroup() %>%
  mutate(agegroup = as.factor(agegroup))

fe_dyn      <- paste(spec_covid, collapse = " + ")
prcp_terms  <- function(sfx) paste0("i(agegroup, prcp_poly_", 1:K_P, "_ERA5LAND", sfx, ")")
tavg_terms  <- paste0("i(agegroup, tavg_poly_", 1:3, "_ERA5LAND)")

fml_dyn <- as.formula(paste(
  "deathrate_w99 ~",
  paste(c(tavg_terms, prcp_terms(""), prcp_terms("_L1"), prcp_terms("_L2")),
        collapse = " + "),
  "|", fe_dyn))
fit_dyn <- fepois(fml_dyn, data = filter(df_dyn, year >= min(year) + 2),
                  weights = ~weight, cluster = CL, lean = TRUE)

fml_lead <- as.formula(paste(
  "deathrate_w99 ~",
  paste(c(tavg_terms, prcp_terms(""), prcp_terms("_F1")), collapse = " + "),
  "|", fe_dyn))
fit_lead <- fepois(fml_lead, data = filter(df_dyn, year <= max(year) - 1),
                   weights = ~weight, cluster = CL, lean = TRUE)

#' Response curve for one lag horizon, via the shared poly_response()
horizon_curve <- function(fit, sfx, label) {
  b <- coef(fit); V <- fix_mat(vcov(fit))
  map_dfr(names(AGE_LABS), function(a) {
    nms <- sprintf("agegroup::%s:prcp_poly_%d_ERA5LAND%s", a, 1:K_P, sfx)
    stopifnot(all(nms %in% names(b)))
    poly_response(b, V, X_PRCP / PRCP_SCALE, nms) %>% mutate(agegroup = a)
  }) %>% mutate(x = x * PRCP_SCALE, horizon = label)
}

#' Cumulative response across horizons with the full delta method: the
#' gradient stacks the (x^1..x^K) block once per horizon.
cum_curve <- function(fit, sfxs, label) {
  b <- coef(fit); V <- fix_mat(vcov(fit))
  xs <- X_PRCP / PRCP_SCALE
  map_dfr(names(AGE_LABS), function(a) {
    nms <- as.vector(sapply(sfxs, function(s)
      sprintf("agegroup::%s:prcp_poly_%d_ERA5LAND%s", a, 1:K_P, s)))
    stopifnot(all(nms %in% names(b)))
    G  <- do.call(cbind, rep(list(outer(xs, 1:K_P, `^`)), length(sfxs)))
    dy <- as.numeric(G %*% b[nms])
    se <- sqrt(rowSums((G %*% V[nms, nms, drop = FALSE]) * G))
    tibble(x = xs, dy = dy, se = se, lo = dy - 1.96*se, hi = dy + 1.96*se,
           agegroup = a)
  }) %>% mutate(x = x * PRCP_SCALE, horizon = label)
}

rf_dyn <- bind_rows(
  horizon_curve(fit_dyn, "",    "t"),
  horizon_curve(fit_dyn, "_L1", "t-1"),
  horizon_curve(fit_dyn, "_L2", "t-2"),
  cum_curve(fit_dyn, c("", "_L1", "_L2"), "Cumulative"),
  horizon_curve(fit_lead, "_F1", "t+1 (placebo)")
) %>%
  mutate(horizon = factor(horizon, levels = c("t", "t-1", "t-2",
                                              "Cumulative", "t+1 (placebo)")),
         age_lab = factor(AGE_LABS[agegroup], levels = unname(AGE_LABS)))

write_csv(rf_dyn, file.path(DIR_DATA, "rf_dynamics.csv"))
save_fig("dynamics.png",
       plot_response(rf_dyn, color = "age_lab", facet = "horizon",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ deaths per 100,000"),
       width = 13, height = 3.6)

print(rf_dyn %>% filter(x == 200) %>%
        select(horizon, age_lab, dy, se) %>%
        tidyr::pivot_wider(names_from = age_lab, values_from = c(dy, se)) %>%
        as.data.frame(), digits = 3)

# ---------------------------------------------------------------------------
# 6i. Leave-one-region-out
# ---------------------------------------------------------------------------
# Is the response driven by a single region (e.g. the typhoon corridor)?
message("\n=== 6i. leave-one-region-out ===")

# One label per adm1_code. The panel's name columns have gaps -- highly
# urbanised cities (which sit outside provinces in the PSGC) carry NA names,
# and NCR (1300000000) / BARMM (1900000000) are nameless everywhere -- so take
# the first non-NA name per code and patch the two fully-nameless regions by
# their PSGC ids. Ids are complete; only the name strings are missing.
region_lab <- df %>%
  group_by(adm1_code) %>%
  summarise(adm1_id   = first(adm1_id),
            adm1_name = first(adm1_name[!is.na(adm1_name)]),
            .groups = "drop") %>%
  mutate(adm1_name = case_when(
           !is.na(adm1_name)          ~ adm1_name,
           adm1_id == "1300000000"    ~ "National Capital Region (NCR)",
           adm1_id == "1900000000"    ~ "BARMM",
           TRUE                       ~ paste0("adm1 ", adm1_id)
         ),
         region = coalesce(str_extract(adm1_name, "(?<=\\().+(?=\\))"), adm1_name))
stopifnot(!anyNA(region_lab$region),
          nrow(region_lab) == n_distinct(df$adm1_code))

loro <- map_dfr(region_lab$adm1_code, function(r) {
  phl_rf(filter(df, adm1_code != r), id = "Precip") %>%
    filter(x == 200) %>%
    mutate(adm1_code = r)
}) %>% left_join(select(region_lab, adm1_code, region), by = "adm1_code")
stopifnot(nrow(loro) == nrow(region_lab) * 3)   # 3 ages x 1 eval point per fit

full_ref <- rf_precip_base %>% filter(x == 200) %>% select(age_lab, dy_full = dy)

write_csv(loro, file.path(DIR_DATA, "rf_loro.csv"))
save_fig("loro.png",
       loro %>%
         left_join(full_ref, by = "age_lab") %>%
         ggplot(aes(reorder(region, dy), dy, colour = age_lab)) +
         geom_hline(aes(yintercept = dy_full, colour = age_lab),
                    linetype = "dashed", alpha = 0.6) +
         geom_hline(yintercept = 0, colour = "grey70") +
         geom_pointrange(aes(ymin = lo, ymax = hi), size = 0.3) +
         facet_wrap(~age_lab, scales = "free_y") +
         scale_color_manual(values = PAL3) +
         coord_flip() +
         labs(x = "Region dropped", y = "Δ deaths per 100,000 at 200 mm/day") +
         theme(legend.position = "none"),
       width = 12, height = 5)

# ---------------------------------------------------------------------------
# 6j. Regression weights
# ---------------------------------------------------------------------------
message("\n=== 6j. weighted vs unweighted ===")
rf_weights <- bind_rows(
  rf_precip_base %>% mutate(wt = "Population-weighted (default)"),
  phl_rf(df, weights = NULL) %>% mutate(wt = "Unweighted")
) %>% mutate(wt = factor(wt, levels = c("Population-weighted (default)", "Unweighted")))

write_csv(rf_weights, file.path(DIR_DATA, "rf_weights.csv"))
save_fig("robust_weights.png",
       plot_response(rf_weights, color = "age_lab", facet = "wt",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ deaths per 100,000"),
       width = 9, height = 4)

# ---------------------------------------------------------------------------
# 6k. Winsorisation of the death rate
# ---------------------------------------------------------------------------
message("\n=== 6k. winsorisation sensitivity ===")
rf_winsor <- bind_rows(
  rf_precip_base %>% mutate(wl = "p99 (default)"),
  phl_rf(df, lhs = "deathrate_w95") %>% mutate(wl = "p95"),
  phl_rf(df, lhs = "deathrate")     %>% mutate(wl = "None")
) %>% mutate(wl = factor(wl, levels = c("p99 (default)", "p95", "None")))

write_csv(rf_winsor, file.path(DIR_DATA, "rf_winsor.csv"))
save_fig("robust_winsor.png",
       plot_response(rf_winsor, color = "age_lab", facet = "wl",
                     xlab = "Daily precipitation (mm)",
                     ylab = "Δ deaths per 100,000"),
       width = 11, height = 4)

# ---------------------------------------------------------------------------
# 6l. Clustering of the standard errors
# ---------------------------------------------------------------------------
# Point estimates are identical across rows; only the SEs move. Region-level
# clustering has only 17 clusters, so treat its asymptotics with caution.
message("\n=== 6l. clustering ===")

CLUSTERS <- list(
  "Province (110 clusters, default)" = ~adm2_code,
  "Region (17 clusters)"             = ~adm1_code,
  "Two-way: province and year"       = ~adm2_code + year
)

clu <- map_dfr(names(CLUSTERS), function(nm) {
  phl_rf(df, cluster = CLUSTERS[[nm]]) %>%
    filter(x == 200) %>%
    mutate(clustering = nm)
})

clu_tab <- clu %>%
  select(clustering, age_lab, dy, se) %>%
  tidyr::pivot_wider(names_from = age_lab, values_from = c(dy, se))
print(as.data.frame(clu_tab), digits = 3)

writeLines(c(
  "\\begin{tabular}{lccc}",
  "\\toprule",
  " & 0--4 & 5--64 & 65+ \\\\",
  "\\midrule",
  sprintf("Point estimate & %.4f & %.4f & %.4f \\\\",
          clu_tab$`dy_0-4`[1], clu_tab$`dy_5-64`[1], clu_tab$`dy_65+`[1]),
  "\\midrule",
  paste0(clu_tab$clustering, sprintf(" & (%.4f) & (%.4f) & (%.4f) \\\\",
         clu_tab$`se_0-4`, clu_tab$`se_5-64`, clu_tab$`se_65+`)),
  "\\bottomrule",
  "\\end{tabular}"
), file.path(DIR_TAB, "clustering.tex"))

# ---------------------------------------------------------------------------
# 6m. Aggregation check: estimate at the province (adm2) level
# ---------------------------------------------------------------------------
# Does the result survive collapsing the unit of analysis one level up? Two
# aggregation choices matter here.
#
# 1. THE OUTCOME aggregates exactly: a province death rate is total deaths over
#    total population, which is the population-weighted mean of its
#    municipality rates. No modelling choice involved. Winsorisation is then
#    re-applied at the province level, since the p99 of a different
#    distribution is a different number.
#
# 2. THE CLIMATE REGRESSORS are averaged as the POLYNOMIAL TERMS, not
#    recomputed from averaged rainfall:
#        sum_i w_i ( sum_d P_id^k )   NOT   ( sum_i w_i sum_d P_id )^k
#    Because the model is linear in these terms, the first choice makes the
#    province response function exactly the population-weighted average of its
#    municipalities' response functions. The second would be a different
#    object entirely (a function of average rainfall, not average of the
#    function) and would understate extremes by Jensen's inequality.
#
#    Weights are TIME-INVARIANT (period-mean municipal population). Using
#    contemporaneous population would let a mortality shock that moves
#    population also move the measured climate exposure.
message("\n=== 6m. province-level (adm2) aggregation ===")

clim_cols <- c(paste0("prcp_poly_", 1:5, "_ERA5LAND"),
               paste0("tavg_poly_", 1:5, "_ERA5LAND"))

w_fixed <- df_all %>%
  group_by(adm3_code, agegroup) %>%
  summarise(w_fix = mean(population, na.rm = TRUE), .groups = "drop")

df_adm2 <- df_all %>%
  left_join(w_fixed, by = c("adm3_code", "agegroup")) %>%
  group_by(adm1_code, adm2_code, agegroup, year, covid_period) %>%
  summarise(deaths     = sum(deaths, na.rm = TRUE),
            population = sum(population, na.rm = TRUE),
            across(all_of(clim_cols), ~ weighted.mean(.x, w_fix, na.rm = TRUE)),
            .groups = "drop") %>%
  filter(population > 0) %>%
  mutate(deathrate = 1e5 * deaths / population) %>%
  group_by(agegroup) %>%
  mutate(deathrate_w99 = pmin(deathrate,
                              quantile(deathrate, 0.99, na.rm = TRUE, type = 2))) %>%
  ungroup()

df_adm2 <- get_weights(df_adm2) %>%
  mutate(age_lab = factor(AGE_LABS[as.character(agegroup)],
                          levels = unname(AGE_LABS)),
         agegroup = as.factor(agegroup))
message(sprintf("province panel: %d rows | %d adm2 | %d adm1",
                nrow(df_adm2), n_distinct(df_adm2$adm2_code),
                n_distinct(df_adm2$adm1_code)))

# FE structure shifted up one level: unit x age x era, and region x year x age
spec_covid_adm2 <- c("adm2_code^agegroup^covid_period", "adm1_code^year^agegroup")

# how much rainfall variation survives at each level?
absorb_lvl <- bind_rows(
  tibble(level = "Municipality (adm3)",
         pct = 100 * sd(resid(feols(as.formula(paste("prcp_poly_1_ERA5LAND ~ 1 |",
                        paste(spec_covid, collapse = "+"))), data = df)))
               / sd(df$prcp_poly_1_ERA5LAND)),
  tibble(level = "Province (adm2)",
         pct = 100 * sd(resid(feols(as.formula(paste("prcp_poly_1_ERA5LAND ~ 1 |",
                        paste(spec_covid_adm2, collapse = "+"))), data = df_adm2)))
               / sd(df_adm2$prcp_poly_1_ERA5LAND))
)
print(as.data.frame(absorb_lvl), digits = 3)

rf_adm2 <- bind_rows(
  rf_precip_base %>% mutate(level = "Municipality (adm3)"),
  phl_rf(df_adm2, fe = spec_covid_adm2, id = "Precip") %>%
    mutate(level = "Province (adm2)")
) %>% mutate(level = factor(level, levels = c("Municipality (adm3)", "Province (adm2)")))

write_csv(rf_adm2, file.path(DIR_DATA, "rf_adm2_aggregation.csv"))
save_fig("robust_adm2.png",
       plot_response(rf_adm2, color = "age_lab", facet = "level",
                     xlab = "Daily precipitation (mm)",
                     ylab = "\u0394 deaths per 100,000"),
       width = 9, height = 4)

print(rf_adm2 %>% filter(x %in% c(100, 200)) %>%
        select(level, age_lab, x, dy, se) %>%
        tidyr::pivot_wider(names_from = x, values_from = c(dy, se)) %>%
        as.data.frame(), digits = 3)

# ---------------------------------------------------------------------------
# 7. Heterogeneity
# ---------------------------------------------------------------------------
message("\n=== 7a. urban share bins ===")
rf_urban <- map_dfr(2:5, function(n) {
  # QUANTILE bins, not equal width: urban share is heavily left-skewed
  # (median 69%), so equal-width bins put 3.4x as many municipality-years in
  # the top bin as the bottom and estimate the low-urbanisation response off a
  # much smaller sample.
  br <- unique(quantile(df$urban_share, seq(0, 1, length.out = n + 1), na.rm = TRUE))
  stopifnot(length(br) == n + 1)   # ties would silently merge bins
  d <- df %>%
    mutate(urban_bin = cut(urban_share, breaks = br,
                           include.lowest = TRUE, ordered_result = FALSE))
  # cut() returns levels already ordered low -> high; carry that order along as
  # an integer, because binding across different `n` forces these to character
  # and the labels do NOT sort correctly as strings ("(33.3,66.7]" sorts before
  # "[0,33.3]" since "(" < "[" in ASCII).
  lv <- levels(d$urban_bin)
  phl_rf(d, interact_var = "urban_bin") %>%
    mutate(bins = paste0("N bins = ", n),
           bin_order = match(as.character(urban_bin), lv),
           urban_bin = as.character(urban_bin))
})
write_csv(rf_urban, file.path(DIR_DATA, "rf_het_urban.csv"))

#' Restore low->high bin ordering from `bin_order` before plotting.
order_bins <- function(d) {
  d %>% mutate(urban_bin = factor(urban_bin,
                                  levels = unique(urban_bin[order(bin_order)])))
}

# headline urban figure: the 3-bin version
save_fig("het_urban.png",
       rf_urban %>%
         filter(bins == "N bins = 3") %>%
         order_bins() %>%
         plot_response(color = "age_lab", facet = "urban_bin",
                       xlab = "Daily precipitation (mm)",
                       ylab = "Δ deaths per 100,000"),
       width = 11, height = 4)

# five-bin version: finer gradient, at the cost of ~5,800 obs per bin
save_fig("het_urban5.png",
       rf_urban %>%
         filter(bins == "N bins = 5") %>%
         order_bins() %>%
         plot_response(color = "age_lab", facet = "urban_bin",
                       xlab = "Daily precipitation (mm)",
                       ylab = "\u0394 deaths per 100,000"),
       width = 14, height = 3.6)

# all binnings, for the appendix
save_fig("het_urban_allbins.png",
       rf_urban %>%
         order_bins() %>%
         plot_response(color = "age_lab", facet = "urban_bin",
                       xlab = "Daily precipitation (mm)",
                       ylab = "Δ deaths per 100,000") +
         facet_wrap(~ bins + urban_bin, ncol = 5),
       width = 15, height = 9)

# ---------------------------------------------------------------------------
# 7a2. Is the urban gradient real? Three tests
# ---------------------------------------------------------------------------
# The five-bin figure shows one significant cell out of fifteen (most-urban
# quintile, ages 0-4). Under the null roughly 0.75 cells would clear 5% by
# chance, so before reading a gradient into it: (i) contrast the top and
# bottom bins directly, (ii) fit urban share as a CONTINUOUS interaction,
# which is far more powerful than five separate bins, and (iii) drop NCR,
# since "most urban" and "Metro Manila" could be the same thing.
message("\n=== 7a2. urban gradient tests ===")

X_TEST <- 200   # mm/day at which contrasts are evaluated

## (i) top-vs-bottom contrast, delta method on the fitted bin model ---------
br5 <- unique(quantile(df$urban_share, seq(0, 1, 0.2), na.rm = TRUE))
d5  <- df %>% mutate(urban_bin = cut(urban_share, br5, include.lowest = TRUE))
lv5 <- levels(d5$urban_bin)
fit5 <- fit_response(mutate(d5, agegroup = as.factor(agegroup)),
                     tavg_order = 3, prcp_order = 3, interact_var = "urban_bin",
                     fe = spec_covid, weights = ~weight, log_mort = TRUE,
                     cluster = CL, suffix = "_ERA5LAND")
key5 <- make_coef_names("prcp_poly_", interact_var = "urban_bin",
                        fit = fit5, suffix = "_ERA5LAND")
b5 <- coef(fit5); V5 <- fix_mat(vcov(fit5))
xs <- (X_TEST / PRCP_SCALE)^(1:3)

contrast <- map_dfr(names(AGE_LABS), function(a) {
  nm_hi <- vapply(1:3, function(k)
    key5(tibble(agegroup = a, urban_bin = lv5[5]), k), character(1))
  nm_lo <- vapply(1:3, function(k)
    key5(tibble(agegroup = a, urban_bin = lv5[1]), k), character(1))
  g <- setNames(rep(0, length(b5)), names(b5))
  g[nm_hi] <- xs; g[nm_lo] <- -xs
  est <- sum(g * b5); se <- sqrt(drop(t(g) %*% V5 %*% g))
  tibble(age_lab = AGE_LABS[a], diff = est, se = se, t = est / se,
         p = 2 * pnorm(-abs(est / se)))
})
cat("top minus bottom urban quintile, response at", X_TEST, "mm/day:\n")
print(as.data.frame(contrast), digits = 3)

## (ii) THRESHOLD tests -----------------------------------------------------
# A linear interaction in urban share tests a smooth gradient. If the true
# pattern is a threshold -- flat up to some level of urbanisation, damaging
# above it -- a linear term averages the flat region with the jump and returns
# roughly zero. So test the threshold form directly.
#
#   (a) top quintile vs ALL OTHERS POOLED (more powerful than top-vs-bottom,
#       and the exact statement "only the really urban places differ")
#   (b) a scan over candidate thresholds, to see whether and where one appears
#   (c) finer bins at the top of the distribution

contrast_binary <- function(d, lbl) {
  d <- d %>% mutate(agegroup = as.factor(agegroup))
  f <- fit_response(d, tavg_order = 3, prcp_order = 3, interact_var = "hi",
                    fe = spec_covid, weights = ~weight, log_mort = TRUE,
                    cluster = CL, suffix = "_ERA5LAND")
  kk <- make_coef_names("prcp_poly_", interact_var = "hi", fit = f,
                        suffix = "_ERA5LAND")
  b <- coef(f); V <- fix_mat(vcov(f))
  map_dfr(names(AGE_LABS), function(a) {
    nh <- vapply(1:3, function(k) kk(tibble(agegroup = a, hi = "above"), k), character(1))
    nl <- vapply(1:3, function(k) kk(tibble(agegroup = a, hi = "below"), k), character(1))
    if (anyNA(c(nh, nl))) return(tibble(age_lab = AGE_LABS[a], diff = NA_real_,
                                        se = NA_real_, p = NA_real_))
    g <- setNames(rep(0, length(b)), names(b)); g[nh] <- xs; g[nl] <- -xs
    est <- sum(g * b); se <- sqrt(drop(t(g) %*% V %*% g))
    tibble(age_lab = AGE_LABS[a], diff = est, se = se,
           p = 2 * pnorm(-abs(est / se)))
  }) %>% mutate(spec = lbl)
}

# (a) top quintile vs the pooled rest
tau80 <- quantile(df$urban_share, 0.8, na.rm = TRUE)
top_vs_rest <- contrast_binary(
  df %>% mutate(hi = factor(ifelse(urban_share > tau80, "above", "below"),
                            levels = c("below", "above"))),
  sprintf("top quintile (>%.1f%%) vs rest", tau80))
cat("\ntop quintile vs ALL OTHERS, response difference at", X_TEST, "mm/day:\n")
print(as.data.frame(top_vs_rest), digits = 3)

# (b) threshold scan
THRESH <- c(60, 70, 80, 85, 90, 95)
scan <- map_dfr(THRESH, function(tau) {
  d <- df %>% mutate(hi = factor(ifelse(urban_share > tau, "above", "below"),
                                 levels = c("below", "above")))
  contrast_binary(d, paste0(">", tau, "%")) %>%
    mutate(threshold = tau, share_above = mean(df$urban_share > tau, na.rm = TRUE))
})
cat("\nthreshold scan (difference above vs below, at", X_TEST, "mm/day):\n")
print(scan %>% select(threshold, share_above, age_lab, diff, se, p) %>%
        arrange(age_lab, threshold) %>% as.data.frame(), digits = 3)
write_csv(scan, file.path(DIR_DATA, "urban_threshold_scan.csv"))

save_fig("urban_threshold.png",
       scan %>%
         mutate(lo = diff - 1.96*se, hi_ = diff + 1.96*se) %>%
         ggplot(aes(threshold, diff, colour = age_lab)) +
         geom_hline(yintercept = 0, colour = "grey60") +
         geom_pointrange(aes(ymin = lo, ymax = hi_),
                         position = position_dodge(width = 2), size = 0.35) +
         scale_color_manual(values = PAL3) +
         labs(x = "Urban-share threshold (%)",
              y = paste0("Above minus below, at ", X_TEST, " mm/day"),
              colour = "Age group") +
         theme_classic(),
       width = 9, height = 4, bg = "white")

# (c) finer bins at the top of the distribution
br_top <- c(0, 60, 80, 90, 95, 100)
d_top <- df %>% mutate(urban_bin = cut(urban_share, br_top, include.lowest = TRUE))
cat("\nobservations per top-weighted bin:\n"); print(table(d_top$urban_bin))
lv_top <- levels(d_top$urban_bin)
rf_top <- phl_rf(d_top, interact_var = "urban_bin") %>%
  mutate(bin_order = match(as.character(urban_bin), lv_top),
         urban_bin = as.character(urban_bin))
write_csv(rf_top, file.path(DIR_DATA, "rf_het_urban_topbins.csv"))
cat("\nfiner top bins at", X_TEST, "mm/day:\n")
print(rf_top %>% filter(x == X_TEST) %>% arrange(bin_order, age_lab) %>%
        select(urban_bin, age_lab, dy, se, lo, hi) %>% as.data.frame(), digits = 3)

save_fig("het_urban_topbins.png",
       rf_top %>% order_bins() %>%
         plot_response(color = "age_lab", facet = "urban_bin",
                       xlab = "Daily precipitation (mm)",
                       ylab = "\u0394 deaths per 100,000"),
       width = 14, height = 3.6)

## (iii) does it survive dropping NCR? --------------------------------------
# NCR is only ~9% of the top quintile, so this should not move much -- but the
# top bin is otherwise CALABARZON/Central Luzon, i.e. the Manila periphery.
rf_urban_noncr <- {
  d <- df %>% filter(adm1_id != "1300000000") %>%
    mutate(urban_bin = cut(urban_share,
             unique(quantile(urban_share, seq(0, 1, 0.2), na.rm = TRUE)),
             include.lowest = TRUE))
  lv <- levels(d$urban_bin)
  phl_rf(d, interact_var = "urban_bin") %>%
    mutate(bin_order = match(as.character(urban_bin), lv),
           urban_bin = as.character(urban_bin))
}
cat("\ntop-quintile response at", X_TEST, "mm, NCR excluded:\n")
print(rf_urban_noncr %>% filter(x == X_TEST, bin_order == 5) %>%
        select(age_lab, dy, se, lo, hi) %>% as.data.frame(), digits = 3)

bind_rows(mutate(contrast, test = "top - bottom quintile"),
          mutate(top_vs_rest, test = "top quintile - pooled rest") %>% select(-spec),
          mutate(scan, test = paste0("threshold >", threshold, "%")) %>%
            select(age_lab, diff, se, p, test)) %>%
  write_csv(file.path(DIR_DATA, "urban_gradient_tests.csv"))

# figure: bin point estimates at X_TEST with the continuous gradient overlaid
save_fig("urban_gradient.png",
       rf_urban %>%
         filter(bins == "N bins = 5", x == X_TEST) %>%
         order_bins() %>%
         ggplot(aes(urban_bin, dy, colour = age_lab)) +
         geom_hline(yintercept = 0, colour = "grey60") +
         geom_pointrange(aes(ymin = lo, ymax = hi),
                         position = position_dodge(width = 0.45), size = 0.35) +
         scale_color_manual(values = PAL3) +
         labs(x = "Urban-share quintile", y = paste0("\u0394 deaths per 100,000 at ", X_TEST, " mm/day"),
              colour = "Age group") +
         theme_classic() +
         theme(axis.text.x = element_text(angle = 20, hjust = 1)),
       width = 9, height = 4, bg = "white")

message("\n=== 7b. settlement type (GHSL SMOD) ===")
rf_smod <- phl_rf(df, interact_var = "smod")
write_csv(rf_smod, file.path(DIR_DATA, "rf_het_smod.csv"))
save_fig("het_smod.png",
       rf_smod %>%
         mutate(smod = factor(smod, levels = c("Rural", "Peri-urban", "Urban centre"))) %>%
         plot_response(color = "age_lab", facet = "smod",
                       xlab = "Daily precipitation (mm)",
                       ylab = "Δ deaths per 100,000"),
       width = 11, height = 4)

message("\n=== 7c. income terciles ===")
rf_inc <- phl_rf(df, interact_var = "inc_ter")
write_csv(rf_inc, file.path(DIR_DATA, "rf_het_income.csv"))
save_fig("het_income.png",
       rf_inc %>%
         mutate(inc_ter = factor(inc_ter,
                                 levels = c("Low income", "Mid income", "High income"))) %>%
         plot_response(color = "age_lab", facet = "inc_ter",
                       xlab = "Daily precipitation (mm)",
                       ylab = "Δ deaths per 100,000"),
       width = 11, height = 4)

message("\n=== 7c2. coastal exposure ===")
if (!all(is.na(df$coast_bin))) {
  rf_coast <- phl_rf(df, interact_var = "coast_bin")
  write_csv(rf_coast, file.path(DIR_DATA, "rf_het_coastal.csv"))
  save_fig("het_coastal.png",
         rf_coast %>%
           mutate(coast_bin = factor(coast_bin,
                    levels = c("Landlocked", "Some coast", "Highly coastal"))) %>%
           plot_response(color = "age_lab", facet = "coast_bin",
                         xlab = "Daily precipitation (mm)",
                         ylab = "\u0394 deaths per 100,000"),
         width = 11, height = 4)
  print(rf_coast %>% filter(x %in% c(100, 200)) %>%
          select(coast_bin, age_lab, x, dy, se) %>%
          tidyr::pivot_wider(names_from = x, values_from = c(dy, se)) %>%
          as.data.frame(), digits = 3)
}

message("\n=== 7d. long-run climate terciles ===")
rf_lrp <- phl_rf(df, interact_var = "lrp_ter")
write_csv(rf_lrp, file.path(DIR_DATA, "rf_het_lrprecip.csv"))
save_fig("het_lrprecip.png",
       rf_lrp %>%
         mutate(lrp_ter = factor(lrp_ter, levels = c("Dry", "Mid", "Wet"))) %>%
         plot_response(color = "age_lab", facet = "lrp_ter",
                       xlab = "Daily precipitation (mm)",
                       ylab = "Δ deaths per 100,000"),
       width = 11, height = 4)

# ---------------------------------------------------------------------------
# 8. Marginal effects at selected daily-precip values
# ---------------------------------------------------------------------------
# Compact cross-margin comparison: effect of a heavy-rainfall day, by age.
me_tbl <- bind_rows(
  rf_smod %>% transmute(margin = "Settlement", group = as.character(smod), age_lab, x, dy, lo, hi),
  rf_inc  %>% transmute(margin = "Income",     group = as.character(inc_ter), age_lab, x, dy, lo, hi),
  rf_lrp  %>% transmute(margin = "Long-run precip", group = as.character(lrp_ter), age_lab, x, dy, lo, hi),
  if (exists("rf_coast")) rf_coast %>%
    transmute(margin = "Coastal", group = as.character(coast_bin), age_lab, x, dy, lo, hi)
) %>%
  filter(x %in% ME_AT) %>%
  # these are plotted on a shared discrete axis, so give them an explicit
  # order; alphabetical would put "Peri-urban" before "Rural" and "High
  # income" before "Low income".
  mutate(group = factor(group, levels = c("Rural", "Peri-urban", "Urban centre",
                                          "Low income", "Mid income", "High income",
                                          "Dry", "Mid", "Wet",
                                          "Landlocked", "Some coast", "Highly coastal")))

stopifnot(!any(is.na(me_tbl$group)))   # catches a renamed heterogeneity level

write_csv(me_tbl, file.path(DIR_DATA, "marginal_effects.csv"))

save_fig("marginal_effects.png",
       me_tbl %>%
         # factor, not paste: "100 mm/day" sorts before "50 mm/day" as a string
         mutate(x = factor(paste0(x, " mm/day"),
                           levels = paste0(sort(unique(x)), " mm/day"))) %>%
         ggplot(aes(group, dy, color = age_lab)) +
         geom_hline(yintercept = 0, colour = "grey60") +
         geom_point(position = position_dodge(width = 0.5)) +
         geom_errorbar(aes(ymin = lo, ymax = hi), width = 0,
                       position = position_dodge(width = 0.5)) +
         facet_grid(x ~ margin, scales = "free_x") +
         scale_color_manual(values = PAL3) +
         labs(x = NULL, y = "Δ deaths per 100,000", colour = "Age group") +
         theme(axis.text.x = element_text(angle = 30, hjust = 1)),
       width = 11, height = 6)

# ---------------------------------------------------------------------------
# 9. Alternative functional form: polynomial in ANNUAL precipitation
# ---------------------------------------------------------------------------
# Everything above uses the Carleton form, where the order-k regressor is the
# annual SUM OF DAILY powers, sum_d P_d^k, and the response is read over daily
# values. This section instead uses powers of the ANNUAL TOTAL, (sum_d P_d)^k,
# so the response is read over annual rainfall. The two answer different
# questions: the first asks what one wet day does, the second what a wet year
# does. They coincide only if rainfall is constant within the year.
message("\n=== 9. polynomial in annual precipitation ===")

ANN_SCALE <- 1000   # 1 regression unit = 1000 mm/year, keeps the cubic O(10)

# annual total in mm (undo the daily-form rescaling), then take powers of it
ann_mm <- df$prcp_poly_1_ERA5LAND * PRCP_SCALE
for (k in 1:3) {
  df[[paste0("prcp_poly_", k, "_ANNUAL")]] <- (ann_mm / ANN_SCALE)^k
  df[[paste0("tavg_poly_", k, "_ANNUAL")]] <- df[[paste0("tavg_poly_", k, "_ERA5LAND")]]
}

X_ANN     <- seq(1000, 5000, by = 25)          # mm/year
REF_ANN   <- median(ann_mm, na.rm = TRUE)      # reference = median wet year
message(sprintf("annual precip: median %.0f mm, range %.0f-%.0f mm",
                REF_ANN, min(ann_mm), max(ann_mm)))

d_ann <- df; d_ann$agegroup <- as.factor(d_ann$agegroup)
fit_ann <- fit_response(d_ann, tavg_order = 3, prcp_order = 3, fe = spec_covid,
                        weights = ~weight, log_mort = TRUE, cluster = CL,
                        suffix = "_ANNUAL")
key_ann <- make_coef_names("prcp_poly_", suffix = "_ANNUAL")

rf_annual <- build_response(fit_ann, x = X_ANN / ANN_SCALE,
                            x_ref = REF_ANN / ANN_SCALE, poly_order = 3,
                            groups = tibble(agegroup = levels(d_ann$agegroup)),
                            key = key_ann, id = "Precip (annual)") %>%
  mutate(x = x * ANN_SCALE,
         age_lab = factor(AGE_LABS[as.character(agegroup)],
                          levels = unname(AGE_LABS)))

write_csv(rf_annual, file.path(DIR_DATA, "rf_annual_form.csv"))

save_fig("annual_form.png",
       plot_response(rf_annual, color = "age_lab",
                     xlab = "Annual precipitation (mm/year)",
                     ylab = "Δ deaths per 100,000") +
         geom_vline(xintercept = REF_ANN, linetype = "dashed", alpha = 0.4),
       width = 7.5, height = 4.5)

print(rf_annual %>% filter(x %in% c(1500, 2000, 3000, 4000)) %>%
        select(age_lab, x, dy, se, lo, hi) %>% as.data.frame(), digits = 3)

# ---------------------------------------------------------------------------
# 9b. Comparison with the project's global (Carleton-sample) estimates
# ---------------------------------------------------------------------------
# Overlay the PHL precipitation response on the global response saved by
# 2_analysis/archive/nishka_legacy/het_regressions.R. Both are Poisson, so both curves are in log
# points; the global spec uses the Carleton design (adm2 x age and
# country x year x age effects) on the multi-country panel.
message("\n=== 9b. comparison with global estimates ===")

GLOBAL_RF <- file.path(REPO_ROOT, "output", "data", "rf", "rf.main.spec.csv")
if (file.exists(GLOBAL_RF)) {
  glob <- read_csv(GLOBAL_RF, show_col_types = FALSE) %>%
    filter(id == "Precip", suffix == "_ERA5LAND") %>%
    transmute(x, dy, se, lo, hi, agegroup = as.character(agegroup),
              source = "Global (Carleton sample)")

  cmp_glob <- bind_rows(
    rf_precip_base %>%
      transmute(x, dy, se, lo, hi, agegroup = as.character(agegroup),
                source = "Philippines (this analysis)"),
    glob
  ) %>% mutate(age_lab = factor(AGE_LABS[agegroup], levels = unname(AGE_LABS)),
               source = factor(source, levels = c("Philippines (this analysis)",
                                                  "Global (Carleton sample)")))

  write_csv(cmp_glob, file.path(DIR_DATA, "rf_global_overlay.csv"))
  save_fig("global_overlay.png",
         ggplot(cmp_glob, aes(x, dy, colour = source, fill = source)) +
           geom_hline(yintercept = 0, colour = "grey70") +
           geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.25, colour = NA) +
           geom_line(linewidth = 1) +
           facet_wrap(~age_lab, scales = "free_y") +
           scale_color_manual(values = PAL3[c(3, 1)]) +
           scale_fill_manual(values  = PAL3[c(3, 1)]) +
           labs(x = "Daily precipitation (mm)", y = "Δ log deaths per 100,000",
                colour = NULL, fill = NULL) +
           theme(legend.position = "bottom"),
         width = 11, height = 4.2)

  print(cmp_glob %>% filter(x == 200) %>%
          select(source, age_lab, dy, se) %>% as.data.frame(), digits = 3)
} else {
  message("global response file not found, skipping overlay: ", GLOBAL_RF)
}

# ---------------------------------------------------------------------------
# 9c. PROTOTYPE: drought vs extreme rainfall as separate exposures
# ---------------------------------------------------------------------------
# Two-part design: the daily polynomial keeps capturing wet-day extremes,
# while annual-anomaly bins capture cumulative deficit/surplus. The drought
# index here is a poor man's SPI -- the within-adm3 z-score of annual
# precipitation -- because monthly totals (for a real SPI) do not exist in
# this panel. Purpose: build the code path and quantify the identification
# problem. PHL is the wrong country for the drought answer (its droughts are
# ENSO-driven and national, so time FEs absorb them); the multi-country build
# is what makes this margin estimable.
message("\n=== 9c. drought-vs-extreme prototype ===")

df_dr <- df %>%
  group_by(adm3_code) %>%
  mutate(z_ann = (prcp_poly_1_ERA5LAND - mean(prcp_poly_1_ERA5LAND)) /
                  sd(prcp_poly_1_ERA5LAND)) %>%
  ungroup() %>%
  mutate(
    d_sevdry = as.integer(z_ann < -1.5),
    d_moddry = as.integer(z_ann >= -1.5 & z_ann < -0.5),
    d_modwet = as.integer(z_ann >  0.5  & z_ann <= 1.5),
    d_sevwet = as.integer(z_ann >  1.5),
    agegroup = as.factor(agegroup)
  )

cat("share of adm3-years by annual-anomaly bin:\n")
print(df_dr %>% filter(agegroup == "1") %>%
        summarise(across(starts_with("d_"), mean)) %>% as.data.frame(), digits = 2)

# --- identification first: how much of the drought index survives the FEs? --
DR_FES <- list("year x age (1)"        = spec1,
               "saturated (3)"         = spec3,
               "pandemic control (4)"  = spec_covid)

dr_absorb <- map_dfr(names(DR_FES), function(nm) {
  fe <- paste(DR_FES[[nm]], collapse = "+")
  tibble(
    FE = nm,
    z_ann    = 100 * sd(resid(feols(as.formula(paste("z_ann ~ 1 |", fe)),
                                    data = df_dr))) / sd(df_dr$z_ann),
    d_sevdry = 100 * sd(resid(feols(as.formula(paste("d_sevdry ~ 1 |", fe)),
                                    data = df_dr))) / sd(df_dr$d_sevdry)
  )
})
print(as.data.frame(dr_absorb), digits = 3)

writeLines(c("\\begin{tabular}{lrr}", "\\toprule",
             "Fixed effects & Annual z-score & Severe-drought dummy \\\\",
             " & \\multicolumn{2}{c}{\\% of s.d. remaining} \\\\", "\\midrule",
             paste0(dr_absorb$FE, " & ", fmt(dr_absorb$z_ann), " & ",
                    fmt(dr_absorb$d_sevdry), " \\\\"),
             "\\bottomrule", "\\end{tabular}"),
           file.path(DIR_TAB, "drought_absorption.tex"))

# --- horse race: annual-anomaly bins alongside the daily polynomial ---------
dr_terms <- paste0("i(agegroup, ", c("d_sevdry", "d_moddry", "d_modwet", "d_sevwet"), ")")
fml_dr <- function(fe) as.formula(paste(
  "deathrate_w99 ~",
  paste(c(paste0("i(agegroup, tavg_poly_", 1:3, "_ERA5LAND)"),
          paste0("i(agegroup, prcp_poly_", 1:3, "_ERA5LAND)"),
          dr_terms), collapse = " + "),
  "|", paste(fe, collapse = " + ")))

BIN_LABS <- c(d_sevdry = "Severe drought (z < -1.5)",
              d_moddry = "Moderate drought",
              d_modwet = "Wet (0.5 < z < 1.5)",
              d_sevwet = "Very wet (z > 1.5)")

rf_drought <- map_dfr(names(DR_FES), function(nm) {
  fit <- fepois(fml_dr(DR_FES[[nm]]), data = df_dr,
                weights = ~weight, cluster = CL, lean = TRUE)
  b <- coef(fit); V <- fix_mat(vcov(fit))
  tidyr::crossing(agegroup = names(AGE_LABS), bin = names(BIN_LABS)) %>%
    mutate(coef_name = sprintf("agegroup::%s:%s", agegroup, bin),
           dy = b[coef_name],
           se = sqrt(diag(V)[coef_name]),
           lo = dy - 1.96 * se, hi = dy + 1.96 * se,
           spec = nm)
}) %>%
  mutate(age_lab = factor(AGE_LABS[agegroup], levels = unname(AGE_LABS)),
         bin_lab = factor(BIN_LABS[bin], levels = unname(BIN_LABS)),
         spec    = factor(spec, levels = names(DR_FES)))

write_csv(rf_drought, file.path(DIR_DATA, "rf_drought_prototype.csv"))

save_fig("drought_prototype.png",
       rf_drought %>%
         ggplot(aes(bin_lab, dy, colour = age_lab)) +
         geom_hline(yintercept = 0, colour = "grey60") +
         geom_pointrange(aes(ymin = lo, ymax = hi),
                         position = position_dodge(width = 0.5), size = 0.35) +
         facet_wrap(~spec) +
         scale_color_manual(values = PAL3) +
         labs(x = NULL, y = "Δ log deaths vs normal rainfall year",
              colour = "Age group") +
         theme(axis.text.x = element_text(angle = 25, hjust = 1)),
       width = 12, height = 4.4)

print(rf_drought %>% filter(bin %in% c("d_sevdry", "d_moddry")) %>%
        select(spec, age_lab, bin, dy, se) %>%
        tidyr::pivot_wider(names_from = bin, values_from = c(dy, se)) %>%
        as.data.frame(), digits = 3)

# ---------------------------------------------------------------------------
# 10. Guard: delta-method SEs must be invariant to the units of the regressors
# ---------------------------------------------------------------------------
# If fixest's 1e-12 VCOV clip is binding, the SEs stop being scale-invariant
# and collapse onto sqrt(1e-12) * x^k. Re-fit the baseline at 10x the chosen
# scale and require the standard errors to agree.
message("\n=== 10. scale-invariance check ===")

df_alt <- df
for (k in 1:5) {
  pk <- paste0("prcp_poly_", k, "_ERA5LAND")
  df_alt[[pk]] <- df[[pk]] / (10^k)
}
PRCP_SCALE_KEEP <- PRCP_SCALE
PRCP_SCALE <- PRCP_SCALE * 10
rf_alt <- phl_rf(df_alt, id = "Precip")
PRCP_SCALE <- PRCP_SCALE_KEEP

chk <- rf_precip_base %>%
  select(agegroup, x, se) %>%
  inner_join(select(rf_alt, agegroup, x, se_alt = se), by = c("agegroup", "x")) %>%
  filter(x > 0) %>%
  mutate(rel_diff = abs(se - se_alt) / pmax(se, .Machine$double.eps))

worst <- max(chk$rel_diff)
message(sprintf("max relative SE difference across scalings: %.3g", worst))
if (worst > 1e-4) {
  warning("Delta-method SEs are NOT scale-invariant (max rel. diff ",
          signif(worst, 3), "). fixest's VCOV eigenvalue clip is binding: ",
          "increase PRCP_SCALE / TAVG_SCALE until this check passes.")
} else {
  message("PASS: standard errors are scale-invariant, the VCOV clip is not binding.")
}

message("\nDone. Figures -> ", DIR_FIG)
message("Tables  -> ", DIR_TAB)
message("Curves  -> ", DIR_DATA)
