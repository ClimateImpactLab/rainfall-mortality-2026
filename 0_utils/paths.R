# setup paths for R
# if first-time user, ensure these paths correspond to your code repo and input data
REPO = paste0("/project/cil/home_dirs/", USER, "/repos")

# carleton et al 2022 data directory
CARLETON_2022_DATA_DIR = "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/"

# defined dynamically
DIR_REPO_RAINFALL_MORTALITY = paste0(REPO,"/rainfall-mortality-2026")
DIR_FIGURE = paste0(DIR_REPO_RAINFALL_MORTALITY,"/output/figures")
DIR_TABLE = paste0(DIR_REPO_RAINFALL_MORTALITY,"/output/tables")