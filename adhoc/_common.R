#========================================================================================#
#' Shared setup for the ad-hoc studies under adhoc/
#'
#' Sourced by every script in adhoc/phl/ and adhoc/wind_tc_validation/ via the
#' four-line bootstrap at the top of each file, which walks up the directory
#' tree until it finds this file. Nothing here depends on the depth a script
#' sits at, so scripts can live in subfolders (adhoc/phl/prototype/) without
#' any path arithmetic.
#'
#' Defines: REPO_ROOT, ADHOC_DIR, out_dirs(), save_fig(), fmt(), write_facts(),
#'          PAL3, GREEN/ORANGE/BLUE/GREY, N_CORES.
#'
#' Study-specific setup lives alongside the scripts that use it:
#'   adhoc/phl/_phl_common.R                     panel resolution and prep
#'   adhoc/wind_tc_validation/_wind_common.R     panel, estimator, cache
#========================================================================================#

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# This file lives in adhoc/, so the repo root is its parent. Verified against
# two directories that only exist at the root, so a stray copy of this file
# somewhere else fails loudly instead of silently writing to the wrong tree.
ADHOC_DIR <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # sys.frames() is empty when this file is sourced from the command line, so
  # fall back to the --file= argument of the script that sourced it.
  d <- if (length(a) == 1) {
    dirname(normalizePath(sub("^--file=", "", a)))
  } else {
    normalizePath(getwd())
  }
  while (!file.exists(file.path(d, "_common.R")) && dirname(d) != d) d <- dirname(d)
  if (!file.exists(file.path(d, "_common.R"))) {
    stop("could not locate adhoc/_common.R above ", getwd(),
         "; run with Rscript, or setwd() inside the repo")
  }
  d
})

REPO_ROOT <- Sys.getenv("RAINFALL_MORTALITY_REPO", unset = NA_character_)
if (is.na(REPO_ROOT)) REPO_ROOT <- dirname(ADHOC_DIR)
REPO_ROOT <- normalizePath(REPO_ROOT, mustWork = TRUE)
stopifnot(dir.exists(file.path(REPO_ROOT, "0_utils")),
          dir.exists(file.path(REPO_ROOT, "2_analysis")))
message("repo root: ", REPO_ROOT)

#' Output directories for one study, created if absent.
#' Returns a list so callers can name the three however they like; every script
#' here unpacks it into DIR_DATA / DIR_FIG / DIR_TAB.
out_dirs <- function(study) {
  d <- list(
    data = file.path(REPO_ROOT, "output", "data", study),
    fig  = file.path(REPO_ROOT, "output", "figures", study),
    tab  = file.path(REPO_ROOT, "output", "tables", study)
  )
  for (p in d) dir.create(p, recursive = TRUE, showWarnings = FALSE)
  d
}

# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------
# Every figure in these studies is a PNG at 200 dpi. Keeping that in one place
# stops the two studies drifting apart and makes a change of device or
# resolution a one-line edit.
#
# `bg` defaults to NULL, which is ggsave's own default (take the background from
# the active theme), NOT "white". Most calls here rely on that; the handful that
# want an explicit white ground pass bg = "white" themselves.
save_fig <- function(name, plot, width, height, dir = DIR_FIG,
                     dpi = 200, bg = NULL) {
  ggplot2::ggsave(file.path(dir, name), plot,
                  width = width, height = height, dpi = dpi, bg = bg)
}

# Shared palettes. PAL3 is the three-colour ramp used for age groups and for
# most three-level heterogeneity margins; the named colours are the wind study's
# measure colours.
PAL3   <- MetBrewer::met.brewer("Hokusai3", 3)
GREEN  <- "#1b7d5f"
ORANGE <- "#d1670a"
BLUE   <- "#2b5d8c"
GREY   <- "grey40"

# ---------------------------------------------------------------------------
# LaTeX output
# ---------------------------------------------------------------------------
# Note there is deliberately no shared fmt() here. Both studies format numbers
# the same way (formatC, fixed notation, thousands separated) but want different
# default digit counts -- 1 for the PHL death-rate scale, 3 for the wind
# coefficients -- and 87 call sites rely on that default. Each study layer
# defines its own fmt(); what is genuinely shared, and was genuinely duplicated,
# is write_facts() below.

#' Write a file of \newcommand definitions for a deck to \input.
#'
#' Call as write_facts(path, name = value, ...). Values are pasted in as-is, so
#' run them through fmt() first when they are numeric.
#'
#' The stopifnot() is not decoration. sprintf() on a zero-length value returns
#' character(0), which c() drops without complaint, so a fact that silently
#' failed to compute would leave the macro undefined and the deck would fail to
#' compile with an error pointing at the .tex file rather than at the code that
#' produced it. Catch it here instead.
write_facts <- function(path, ...) {
  vals <- list(...)
  stopifnot(length(vals) > 0, !is.null(names(vals)), all(nzchar(names(vals))))
  bad <- names(vals)[lengths(vals) != 1]
  if (length(bad)) {
    stop("write_facts: these facts are not length 1: ", paste(bad, collapse = ", "))
  }
  lines <- vapply(names(vals), function(n) {
    sprintf("\\newcommand{\\%s}{%s}", n, as.character(vals[[n]]))
  }, character(1), USE.NAMES = FALSE)
  writeLines(lines, path)
  message("  wrote ", length(lines), " facts -> ", basename(path))
  invisible(lines)
}

# ---------------------------------------------------------------------------
# Parallelism
# ---------------------------------------------------------------------------
# Leave two cores for the rest of the machine and cap at 6: the jackknives are
# memory-bound more than CPU-bound, and more workers mostly means more copies of
# the panel. On SLURM, take the allocation rather than the node's core count.
N_CORES <- local({
  slurm <- suppressWarnings(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = NA)))
  if (!is.na(slurm)) max(1L, slurm)
  else max(1L, min(6L, parallel::detectCores() - 2L))
})
