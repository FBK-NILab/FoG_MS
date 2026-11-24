#!/bin/bash
# =============================================================================
# 09_segmentation_in_t1.sh
# PURPOSE: Transfers the high-resolution lesion segmentation from FLAIR to T1 space
#          with the FLAIR-to-T1 rigid transform (identity for FLAIR_SYNTH_T1_SESSIONS,
#          where T1 and FLAIR share the same space).
# INPUT:   anat/*_FLAIR_segmentation_original2synth.nii.gz
#          anat/*_T1w_stripped.nii.gz (reference grid)
#          anat/mat/*_flair2t1_0GenericAffine.mat
# OUTPUT:  anat/*_T1w_segmentation_original2synth.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

segmentation_to_t1() {
    local segmentation="$1"
    local t1="$2"
    local xfm="$3"
    local output_folder file_name out_mask

    output_folder=$(dirname "$segmentation")              # anat
    file_name=$(basename "$t1" "_stripped.nii.gz")       # sub-XXX_ses-YY_T1w
    out_mask="$output_folder/${file_name}_segmentation_original2synth.nii.gz"

    if already_done "$out_mask"; then
        echo "[SKIP] $file_name -> T1 lesion mask already exists"
        return 0
    fi

    echo "[RUN] $file_name -> segmentation (FLAIR space) -> T1 space"
    antsApplyTransforms -d 3 \
        -i "$segmentation" \
        -r "$t1" \
        -t "$xfm" \
        -n GenericLabel \
        -o "$out_mask"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    ses=$(session_of "$d")
    segmentation=$(first_match "$d"/*_FLAIR_segmentation_original2synth.nii.gz)
    t1=$(first_match "$d"/*_T1w_stripped.nii.gz)

    if uses_flair_synth_t1 "$ses"; then
        xfm="identity"   # stripped T1 = flair_SynthT1, already in FLAIR space: resampling only
    else
        xfm=$(first_match "$d"/mat/*_flair2t1_0GenericAffine.mat)
    fi

    if [ -z "$segmentation" ] || [ -z "$t1" ] || [ -z "$xfm" ]; then
        echo "[SKIP] $d -> segmentation, stripped T1 or transform missing"
        continue
    fi

    segmentation_to_t1 "$segmentation" "$t1" "$xfm"
done

# REFERENCES
# [ANTs] Avants BB, Tustison NJ, Song G, Cook PA, Klein A, Gee JC. A reproducible evaluation of ANTs similarity metric
#       performance in brain image registration. NeuroImage. 2011;54(3):2033-2044. doi:10.1016/j.neuroimage.2010.09.025
# [ANTs] Tustison NJ, Cook PA, Holbrook AJ, et al. The ANTsX ecosystem for quantitative biological and medical
#       imaging. Sci Rep. 2021;11:9068. doi:10.1038/s41598-021-87564-6
