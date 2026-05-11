#!/bin/bash
#SBATCH --job-name=ghsl-download
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --array=0-23%4
#SBATCH --time=00:30:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --output=logs/ghsl_%A_%a.out
#SBATCH --error=logs/ghsl_%A_%a.err

set -euo pipefail
cd /project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data/ghsl # parent dir
# mkdir -p logs data do this before submitting de job
 
YEARS=(1975 1980 1985 1990 1995 2000 2005 2010 2015 2020 2025 2030)
PRODUCTS=(POP SMOD)
CRS=4326
RES=30ss

N=${#YEARS[@]}
PROD=${PRODUCTS[$(( SLURM_ARRAY_TASK_ID / N ))]}
YEAR=${YEARS[$(( SLURM_ARRAY_TASK_ID % N ))]}

FOLDER="GHS_${PROD}_E${YEAR}_GLOBE_R2023A_${CRS}_${RES}"
URL="https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/GHS_${PROD}_GLOBE_R2023A/${FOLDER}/V1-0/${FOLDER}_V1_0.zip"

wget -c -P data/ "$URL"