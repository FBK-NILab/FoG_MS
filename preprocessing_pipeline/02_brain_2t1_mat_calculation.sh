#!/bin/bash
# =============================================================================
# 02_brain_2t1_mat_calculation.sh
# PURPOSE: Computes the rigid transform from FLAIR to T1w space for each session,
#          using the denoised and bias-corrected (non skull-stripped) images.
# INPUT:   anat/process/*_FLAIR_reoriented_corrected.nii.gz (moving)
#          anat/process/*_T1w_reoriented_corrected.nii.gz   (fixed)
# OUTPUT:  anat/mat/*_flair2t1_0GenericAffine.mat
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

flair2t1_registration() {
    local flair="$1"
    local t1="$2"
    local anat_folder mat_folder file_name out_prefix

    anat_folder=$(dirname "$(dirname "$flair")")
    mat_folder="$anat_folder/mat"
    mkdir -p "$mat_folder"

    file_name=$(basename "$flair" _FLAIR_reoriented_corrected.nii.gz)   # sub-XXX_ses-YY
    out_prefix="$mat_folder/${file_name}_flair2t1_"

    if already_done "${out_prefix}0GenericAffine.mat"; then
        echo "[SKIP] $file_name -> FLAIR-to-T1 transform already exists"
        return 0
    fi

    echo "[RUN] $file_name -> FLAIR to T1 (rigid)"
    antsRegistration \
        --dimensionality 3 \
        --float 0 \
        --output "$out_prefix" \
        --interpolation Linear \
        --winsorize-image-intensities "[0.005,0.995]" \
        --use-histogram-matching 0 \
        --initial-moving-transform "[$t1,$flair,1]" \
        --transform "Rigid[0.1]" \
        --metric "MI[$t1,$flair,1,32,Regular,0.25]" \
        --convergence "[1000x500x250x0,1e-6,10]" \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat/process; do
    flair=$(first_match "$d"/*_FLAIR_reoriented_corrected.nii.gz)
    t1=$(first_match "$d"/*_T1w_reoriented_corrected.nii.gz)

    if [ -z "$flair" ] || [ -z "$t1" ]; then
        echo "[SKIP] $d -> FLAIR or T1 missing"
        continue
    fi

    flair2t1_registration "$flair" "$t1"
done

# REFERENCES
# [ANTs] Avants BB, Tustison NJ, Song G, Cook PA, Klein A, Gee JC. A reproducible evaluation of ANTs similarity metric
#       performance in brain image registration. NeuroImage. 2011;54(3):2033-2044. doi:10.1016/j.neuroimage.2010.09.025
# [ANTs] Tustison NJ, Cook PA, Holbrook AJ, et al. The ANTsX ecosystem for quantitative biological and medical
#       imaging. Sci Rep. 2021;11:9068. doi:10.1038/s41598-021-87564-6
