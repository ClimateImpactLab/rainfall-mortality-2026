#========================================================================================#
#' Paths used by the rainfall-mortality scripts
#========================================================================================#

# Most scripts set USER before sourcing this file. Fall back to the shell user
# when running this file by hand.
if (!exists("USER")) {
  USER <- Sys.getenv("USER")
}

if (USER == "tbearpark") {
  REPO <- "~/repos/"
} else {
  REPO <- paste0("/project/cil/home_dirs/", USER, "/repos")
}


# Old Carleton mortality data
CARLETON_2022_DATA_DIR <- "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/"

# Shared rainfall-mortality data folder on RCC
DATA_DIR <- "/project/cil/gcp/estimation/rainfall-mortality"

# Repo output folders
DIR_REPO_RAINFALL_MORTALITY <- paste0(REPO, "/rainfall-mortality-2026")
DIR_FIGURE <- paste0(DIR_REPO_RAINFALL_MORTALITY, "/output/figures")
DIR_TABLE <- paste0(DIR_REPO_RAINFALL_MORTALITY, "/output/tables")
