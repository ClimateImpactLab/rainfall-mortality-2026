# Minimal package loading
library(dplyr)
library(tidyr)
library(ggplot2)
library(readr)
library(RColorBrewer)
library(MetBrewer)
library(stringr)
library(glue)
library(purrr)
library(forcats)
theme_set(theme_classic())

# set paths
USER = Sys.getenv("USER")
setwd(this.path::this.dir())
source("../0_utils/paths.R")
source("../0_utils/functions.R")

# plots ------
## baseline temp and precipitation spec 2 -----
rf.main.spec <- read_csv(glue(DIR_REPO_RAINFALL_MORTALITY, "/output/data/rf/rf.main.spec.csv")) %>%
  # refactor everything as csv does not preserve order
  mutate(agegroup = as.factor(agegroup))

# dataframe of plot specs
plot_specs <- tribble(
  ~suffix,      ~id,           ~xlab,          ~ylim_lo, ~ylim_hi, ~dir,         ~dataset_label,
  "GMFD",           "Temperature", "Temperature",  -0.0025,  0.002,    "gmfd",       "GMFD",
  "_ERA5LAND",  "Temperature", "Temperature",  -0.0025,  0.002,    "era5-land",  "ERA5-Land",
  "GMFD",           "Precip",      "Precip",       -0.05,    0.15,     "gmfd",       "GMFD",
  "_ERA5LAND",  "Precip",      "Precip",       -0.05,    0.15,     "era5-land",  "ERA5-Land"
)

# generate the plots
plots <- pmap(plot_specs, function(suffix, id, xlab, ylim_lo, ylim_hi, dir, dataset_label) {
  
  title <- glue("Baseline {id} response - {dataset_label}")
  
  p <- plot_response(rf.main.spec %>% filter(suffix == !!suffix, id == !!id),
                     color = "agegroup",
                     xlab = xlab,
                     ylab = "Δ deathrate (baseline)",
                     p_title = title) +
    ylim(ylim_lo, ylim_hi)
  
  fname <- glue("{DIR_FIGURE}/regs/{dir}/baseline_{tolower(id)}_test.png")
  
  list(plot = p, path = fname)
})

# # save the plots. need to debug this 
# pwalk(plots, function(plot, path) {
#   ggsave(path, plot, width = 8, height = 6.4)
# })

## baseline precipitation -----
rf.precip.base.fe <- read_csv(glue(DIR_REPO_RAINFALL_MORTALITY, "/output/data/rf/rf.precip.base.fe.csv")) %>%
  # refactor everything as csv does not preserve order
  mutate(agegroup = as.factor(agegroup))

# generate plots
p <- map(unique(rf.precip.base.fe$spec), function(sp) {
  rf.precip.base.fe %>%
    filter(spec == sp) %>%
    plot_response(color = "agegroup",
                  xlab = "Precipitation",
                  ylab = "Δ deathrate",
                  scales = "fixed",
                  p_title = sp)
  })

# # save the plots
# iwalk(p, function(plot, idx) {
#   ggsave(glue("{DIR_FIGURE}/regs/era5-land/base_precip_spec{idx}.png"),
#          plot = plot, width = 8, height = 6.4)
# })

## urban heterogeniety -----
### plot all fixed effects and weights from Carleton et al 2022 ------
rf.precip.urban.fe <- read_csv(glue(DIR_REPO_RAINFALL_MORTALITY, "/output/data/rf/rf.precip.urban.fe.csv")) %>%
  # refactor everything as csv does not preserve order
  mutate(urban_bin = fct_reorder(urban_bin, bin_order),
         agegroup = as.factor(agegroup),
         bins = as.factor(bins))

# generate the plots
prf <- map(unique(rf.precip.urban.fe$spec), function(sp) {
  map(c(TRUE, FALSE), function(wt) {
    plots <- map(sort(unique(rf.precip.urban.fe$bins)), function(b) {
      rf.precip.urban.fe %>%
        filter(spec == sp, weighted == wt, bins == b) %>%
        plot_response(color = "agegroup", facet = "urban_bin",
                      xlab = "Precipitation",
                      ylab = "Δ deathrate",
                      scales = "fixed") + 
        ggh4x::force_panelsizes(cols = unit(8, "cm"), rows = unit(4, "cm"))
    })
    patchwork::wrap_plots(plots, ncol = 1) +
      patchwork::plot_annotation(title = glue("fe: {sp} | weighted: {wt}"))
  })
})

# # save the plots
# iwalk(prf, ~ iwalk(.x, function(p, wt_idx) {
#   sp_idx <- .y
#   wt_label <- if (wt_idx == 1) "weighted" else "unweighted"
#   ggsave(glue("{DIR_FIGURE}/regs/era5-land/urban_spec{sp_idx}_{wt_label}.png"),
#          plot = p, width = 18, height = 12)
# }))

### look at 100mm, 200mm and 300mm days ------
prf <- map(c(TRUE, FALSE), function(wt) {
  plots <- map(sort(unique(rf.precip.urban.fe$bins)), function(b) {
    rf.precip.urban.fe %>%
      filter(weighted == wt, bins == b,
             x %in% c(100, 200, 300)) %>%
      mutate(x = paste0(x, 'mm')) %>% 
      ggplot() + 
      geom_hline(yintercept=0, color = 'grey') + 
      geom_point(aes(x = x, y = dy, color= urban_bin,
                     group = interaction(urban_bin, spec)), 
                 position = position_dodge(width = .7))  + 
      geom_errorbar(aes(x = x, ymin = lo, ymax= hi, 
                        color= urban_bin, linetype = spec,
                        group = interaction(urban_bin, spec)), 
                    position = position_dodge(width = .7)) + 
      ylab("Δ deathrate") + 
      xlab("Precipitation") +
      facet_wrap(~agegroup+bins, nrow=3) + 
      ggh4x::force_panelsizes(cols = unit(11, "cm"), rows = unit(4, "cm")) +
      guides(
        linetype = guide_legend(title = "Specification", ncol = 1),
        color    = guide_legend(title = "Urban bin", ncol = 1)
      )
  })
  
  patchwork::wrap_plots(plots, ncol = 4, guides = "collect") +
    patchwork::plot_annotation(title = glue("weighted: {wt}")) &
    theme(
      legend.position = "bottom",
      legend.box = "horizontal",   # legends side by side...
      legend.direction = "vertical" # ...but each one stacks vertically
    )
})

# # save the plots
# iwalk(prf, function(p, wt_idx) {
#   wt_label <- if (wt_idx == 1) "weighted" else "unweighted"
#   ggsave(glue("{DIR_FIGURE}/regs/era5-land/urban_combined_{wt_label}.png"),
#          plot = p, width = 20, height = 9)
# })

## urban + income heterogeniety -----
