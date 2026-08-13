#!/bin/bash
#SBATCH --job-name=flooding-prepanal
#SBATCH --output=/home/jrising/flooding/logs/flooding-prepanal-%j.out
#SBATCH --error=/home/jrising/flooding/logs/flooding-prepanal-%j.err
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem=50G

cd /home/jrising/flooding
python prepanal.py

