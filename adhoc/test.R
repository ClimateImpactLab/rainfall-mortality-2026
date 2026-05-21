library(tidyverse)
library(fixest)
library(patchwork)
theme_set(theme_classic())
setwd('/Users/tombearpark/Library/CloudStorage/Dropbox/ks')

# ============================================================================
# 1. Load + minimal prep
# ============================================================================
df <- read_csv('reg_inputs/mortality/reginputs_mortality_1deg.csv',
               show_col_types = FALSE) %>% 
  rename(p1 = prcp_poly_1, 
         p2 = prcp_poly_2, 
         p3 = prcp_poly_3, 
         p4 = prcp_poly_4) %>% 
  mutate(
    upper = p4^(1/4),
    lower = p4/p3,
    gap   = upper - lower    # >1 = less concentrated; ~1 = one storm dominates
  ) %>% 
  filter(!is.na(p1))

df %>%
  filter(gap<0)
cat(min(df$gap))

# ============================================================================
# 2. Test the refactored interaction-variable API in functions.R
# ============================================================================
# Loads the same CSV but keeps the prcp_poly_* / tavg_poly_* names that
# fit_response / make_coef_names expect, then exercises three configurations:
#   (a) baseline: no extra interaction
#   (b) interact_var = "adm0_code" (country)
#   (c) interact_var = "prcp_lvl"  (low/mid/high precip, adm2 terciles)

source('/Users/tombearpark/Documents/GitHub/cil/rainfall-mortality-2026/0_utils/functions.R')

test_df <- read_csv('reg_inputs/mortality/reginputs_mortality_1deg.csv',
                    show_col_types = FALSE) %>%
  filter(!is.na(prcp_poly_1), !is.na(tavg_poly_1), !is.na(deathrate),
         agegroup != "total") %>%
  group_by(iso, agegroup) %>%
  mutate(deathrate_w99 = pmin(deathrate,
                              quantile(deathrate, 0.99, na.rm = TRUE, type = 2))) %>%
  ungroup() %>%
  group_by(iso) %>% mutate(adm0_code = cur_group_id()) %>%
  group_by(iso, adm1_id) %>% mutate(adm1_code = cur_group_id()) %>%
  group_by(iso, adm1_id, adm2_id) %>% mutate(adm2_code = cur_group_id()) %>%
  ungroup() %>%
  mutate(CHN_ts = 1L)

test_df <- get_weights(test_df) %>%
  mutate(adm0_code = as.factor(adm0_code),
         adm0      = as.factor(adm0),
         adm1_id   = as.factor(adm1_id))

# build a precip tercile category at the adm2 level: each adm2 gets its
# long-run mean prcp_poly_1, then is bucketed into low/mid/high terciles.
test_df <- test_df %>%
  group_by(adm2_code) %>%
  mutate(adm2_mean_prcp = mean(prcp_poly_1, na.rm = TRUE)) %>%
  ungroup() %>%
  mutate(prcp_lvl = cut(
    adm2_mean_prcp,
    breaks = quantile(adm2_mean_prcp, probs = c(0, 1/3, 2/3, 1), na.rm = TRUE),
    labels = c("low", "mid", "high"),
    include.lowest = TRUE,
    ordered_result = FALSE))

# (a) baseline
fit_a <- fit_response(test_df, tavg_order = 4, prcp_order = 2,
                      fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"))
key_a <- make_coef_names("prcp_poly_")
rf_a  <- build_response(fit_a, x = 0:300, poly_order = 2,
                        groups = tibble(agegroup = levels(test_df$agegroup)),
                        key = key_a, id = "Precip")
stopifnot(nrow(rf_a) > 0,
          all(grepl("^agegroup::.*:prcp_poly_[0-9]+$", names(coef(fit_a))[
            grepl("prcp_poly_", names(coef(fit_a)))])))

# (b) country interactions
fit_b <- fit_response(test_df, tavg_order = 4, prcp_order = 2,
                      interact_var = "adm0",
                      fe = c("adm2_code^agegroup", "adm0^year^agegroup"))
key_b <- make_coef_names("prcp_poly_", interact_var = "adm0", fit = fit_b)
rf_b  <- build_response(
  fit_b, x = 0:300, poly_order = 2,
  groups = tidyr::crossing(agegroup = levels(test_df$agegroup),
                           adm0     = levels(test_df$adm0)),
  key = key_b, id = "Precip")
stopifnot(nrow(rf_b) > 0,
          any(grepl("adm0", names(coef(fit_b)))))

# (c) low/high-precip interactions (adm2-level split)
fit_c <- fit_response(test_df, tavg_order = 4, prcp_order = 2,
                      interact_var = "prcp_lvl",
                      fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"))
key_c <- make_coef_names("prcp_poly_", interact_var = "prcp_lvl", fit = fit_c)
rf_c  <- build_response(
  fit_c, x = 0:300, poly_order = 2,
  groups = tidyr::crossing(agegroup = levels(test_df$agegroup),
                           prcp_lvl = levels(test_df$prcp_lvl)),
  key = key_c, id = "Precip")
stopifnot(nrow(rf_c) > 0,
          any(grepl("prcp_lvl", names(coef(fit_c)))))

message("interact_var refactor: all three fits produced response curves.")

# ----------------------------------------------------------------------------
# 3. Smoke-test plot_response for each configuration
# ----------------------------------------------------------------------------
library(MetBrewer)

p_a <- plot_response(rf_a, color = "agegroup",
                     xlab = "Precipitation",
                     ylab = "Δ deathrate (baseline)")

p_b <- plot_response(rf_b, color = "agegroup", facet = "adm0",
                     xlab = "Precipitation",
                     ylab = "Δ deathrate (× adm0)",
                     scales = "free_y")

p_c <- plot_response(rf_c, color = "agegroup", facet = "prcp_lvl",
                     xlab = "Precipitation",
                     ylab = "Δ deathrate (× prcp_lvl)",
                     scales = "free_y")

stopifnot(inherits(p_a, "ggplot"),
          inherits(p_b, "ggplot"),
          inherits(p_c, "ggplot"))

# Render to a temp file to confirm the plots build without ggplot errors
tmp_png <- tempfile(fileext = ".png")
ggsave(tmp_png, p_a / p_b / p_c, width = 12, height = 14)
message("plot_response: all three plots rendered to ", tmp_png)
