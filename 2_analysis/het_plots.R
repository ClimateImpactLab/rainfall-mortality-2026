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
## urban heterogeniety -----
# plot all fixed effects and weights from Carleton et al 2022
rf.urban.fe <- read_csv(glue(DIR_REPO_RAINFALL_MORTALITY, "/output/data/rf/rf.urban.fe.csv")) %>%
  # refactor everything as csv does not preserve order
  mutate(urban_bin = fct_reorder(urban_bin, bin_order),
         agegroup = as.factor(agegroup),
         bins = as.factor(bins))

prf <- map(unique(rf.urban.fe$spec), function(sp) {
  map(c(TRUE, FALSE), function(wt) {
    plots <- map(sort(unique(rf.urban.fe$bins)), function(b) {
      rf.urban.fe %>%
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

# iwalk(prf, ~ iwalk(.x, function(p, wt_idx) {
#   sp_idx <- .y
#   wt_label <- if (wt_idx == 1) "weighted" else "unweighted"
#   ggsave(glue("{DIR_FIGURE}/regs/urban_spec{sp_idx}_{wt_label}.png"),
#          plot = p, width = 18, height = 12)
# }))

prf <- map(c(TRUE, FALSE), function(wt) {
  plots <- map(sort(unique(rf.urban.fe$bins)), function(b) {
    rf.urban.fe %>%
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

# iwalk(prf, function(p, wt_idx) {
#   wt_label <- if (wt_idx == 1) "weighted" else "unweighted"
#   ggsave(glue("{DIR_FIGURE}/regs/urban_combined_{wt_label}.png"),
#          plot = p, width = 20, height = 9)
# })

## urban + income heterogeniety -----
