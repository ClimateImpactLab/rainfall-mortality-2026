library(haven)
library(fixest)
library(dplyr)
library(stringr)
library(tidyr)
library(ggplot2)
library(patchwork)
theme_set(theme_classic())

# can't seem to use my packages
# devtools::install_github("TomBearpark/useful")

data_dir <- "/project/cil/battuta_shares/gcp/estimation/mortality/"
setwd("/home/tbearpark/")

# Load data, remove variables to make it smaller

mortality_data <- read_dta(file.path(data_dir, 
                         'release_2020/data/0_data_cleaning/3_final/',
                         'global_mortality_panel.dta')) %>% 
  select(-contains("BEST"),
         -contains("Spline"),
         -contains("bins"),
         -contains("rcs"),
         -contains("cdd"), 
         -contains("hdd"), 
         -contains("UDEL"), 
         -contains("13"), 
         -contains("tmax"))
gc()

source("rainfall-mortality-2026/carleton2022_precip/prep_data.R")
names(mortality_data) <- str_remove_all(names(mortality_data), "_GMFD")

# Functions so we don't have to copy code

get_weights <- function(df){
  df %>%
    group_by(year, agegroup) %>%
    mutate(tot_pop = sum(population, na.rm = TRUE)) %>%
    ungroup() %>%
    mutate(weight = population/tot_pop, # generate weights
           agegroup = as.factor(agegroup), # convert to factor for feols
           adm0_code = as.factor(adm0_code)) # convert to factor for feols
  
}

mortality_data <- get_weights(mortality_data)

# Functions -------------------

#' Fit a Carleton-style polynomial regression.
#' tavg_order / prcp_order: 0 to skip that block, otherwise the polynomial order.
#' country_prcp: TRUE -> adm0_code × prcp × agegroup interactions
#'               FALSE -> i(agegroup, prcp_poly_k) only
fit_response <- function(data,
                         lhs          = "deathrate_w99",
                         tavg_order   = 2,
                         prcp_order   = 2,
                         country_prcp = FALSE,
                         fe = c("adm2_code^CHN_ts^agegroup",
                                "adm0_code^year^agegroup"),
                         weights = ~weight,
                         cluster = ~adm1_code,
                         ...) {
  
  rhs <- character()
  if (tavg_order > 0)
    rhs <- c(rhs, paste0("i(agegroup, tavg_poly_", seq_len(tavg_order), ")"))
  if (prcp_order > 0) {
    rhs <- c(rhs, if (country_prcp)
      paste0("adm0_code:prcp_poly_", seq_len(prcp_order), ":agegroup")
      else
        paste0("i(agegroup, prcp_poly_", seq_len(prcp_order), ")"))
  }
  
  f <- as.formula(sprintf("%s ~ %s | %s",
                          lhs,
                          paste(rhs, collapse = " + "),
                          paste(fe, collapse = " + ")))
  
  feols(f, data = data, weights = weights, cluster = cluster, lean = TRUE, ...)
}

#' Coefficient-name template that matches what `fit_response` produces.
#' Picks the right naming convention based on `country`.
make_key <- function(prefix, country = FALSE, fit = NULL) {
  if (country) {
    if (is.null(fit))
      stop("country = TRUE needs `fit` to handle fixest's variable token ordering")
    cn     <- names(coef(fit))
    cn_tok <- strsplit(cn, ":", fixed = TRUE)
    function(g, k) {
      want <- c(paste0("adm0_code", g$adm0_code),
                paste0("agegroup",  g$agegroup),
                paste0(prefix, k))
      hits <- which(vapply(cn_tok, setequal, logical(1), want))
      if (length(hits) == 1) cn[hits] else NA_character_
    }
  } else {
    function(g, k) sprintf("agegroup::%s:%s%d", g$agegroup, prefix, k)
  }
}

#' Polynomial response f(x) − f(x_ref) with delta-method SE.
poly_response <- function(b, V, x, coef_names, x_ref = 0) {
  P    <- length(coef_names)
  xpow <- outer(x, 1:P, `^`) - matrix(x_ref^(1:P), nrow = length(x), ncol = P,
                                      byrow = TRUE)
  Vsub <- V[coef_names, coef_names, drop = FALSE]
  dy   <- as.numeric(xpow %*% b[coef_names])
  se   <- sqrt(rowSums((xpow %*% Vsub) * xpow))
  z    <- qt(1 - alpha/2, df)
  tibble(x = x, dy = dy, se = se, lo = dy - 1.96*se, hi = dy + 1.96*se)
}

#' Build response curves across grouping combinations, relative to x_ref.
build_response <- function(fit, x, poly_order, groups, key,
                           x_ref = 0, id = "") {
  b <- coef(fit); V <- vcov(fit); cn <- names(b)
  
  out <- groups %>%
    mutate(.gid = row_number()) %>%
    group_by(.gid) %>%
    group_modify(~ {
      nms <- vapply(seq_len(poly_order),
                    function(k) key(.x, k), character(1))
      if (!all(nms %in% cn)) {
        return(tibble(x = x, dy = NA_real_, se = NA_real_,
                      lo = NA_real_, hi = NA_real_))
      }
      poly_response(b, V, x, nms, x_ref = x_ref)
    }) %>%
    ungroup() %>%
    left_join(mutate(groups, .gid = row_number()), by = ".gid") %>%
    select(-.gid) %>%
    mutate(id = id)
  
  # report dropped cells
  dropped <- out %>%
    filter(is.na(dy)) %>%
    distinct(across(all_of(names(groups))))
  if (nrow(dropped) > 0) {
    message("build_response: dropped ", nrow(dropped),
            " cell(s) with no estimated coefficients:")
    message(paste(utils::capture.output(print(dropped)), collapse = "\n"))
  }
  
  out %>% filter(!is.na(dy))
}

plot_response <- function(resp, color = "agegroup", facet = NULL,
                          xlab = NULL, ylab = "Δ outcome (vs x = ref)",
                          scales='fixed') {
  p <- ggplot(resp, aes(x, dy, color = .data[[color]], fill = .data[[color]])) +
    geom_hline(yintercept=0, alpha=0.1)+
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.15, color = NA) +
    geom_line() +
    labs(x = xlab, y = ylab) 
  if (!is.null(facet)) p <- p + facet_wrap(facet, scales = scales)
  p
}

# Run ----------------------

## A) age-only prcp response, poly order 3-------

fit  <- fit_response(mortality_data, tavg_order = 3, prcp_order = 3)

resp <- build_response(
  fit, x = 0:300, poly_order = 3,
  groups = tibble(agegroup = levels(mortality_data$agegroup)),
  key    = make_key("prcp_poly_", country = FALSE), 
  id = "Precip"
)
resp_temp <- build_response(
  fit, x = 0:40, poly_order = 3,
  groups = tibble(agegroup = levels(mortality_data$agegroup)),
  key    = make_key("tavg_poly_", country = FALSE), 
  x_ref=20, 
  id = "Temp"
)

pA <- bind_rows(resp, resp_temp) %>% 
  plot_response(xlab = "Temp") + 
  facet_wrap(~id + agegroup, scales='free_x')
pA

##  B) country × age prcp response, poly order 3 ------
fit_c  <- fit_response(mortality_data, tavg_order = 2, prcp_order = 2,
                       country_prcp = TRUE)

resp_c <- build_response(
  fit_c, x = 0:300, poly_order = 2,
  groups = tidyr::crossing(
    agegroup  = levels(mortality_data$agegroup),
    adm0_code = levels(mortality_data$adm0_code)
  ),
  key    = make_key("prcp_poly_", country = TRUE, fit = fit_c)
)
plot_response(resp_c, color = "adm0_code", facet = "agegroup",
              xlab = "Precipitation")

