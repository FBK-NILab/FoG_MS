#!/bin/bash
# =============================================================================
# 07_flair_WM_mask_transposed.sh
# PURPOSE: Transfers the T1 WM mask into FLAIR space using the inverse of the
#          FLAIR-to-T1 rigid transform (identity for FLAIR_SYNTH_T1_SESSIONS).
# INPUT:   anat/process/*_T1w_WM_mask.nii.gz
#          anat/*_FLAIR_stripped.nii.gz (reference grid)
#          anat/mat/*_flair2t1_0GenericAffine.mat
# OUTPUT:  anat/process/*_FLAIR_WM_mask_transp.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

wm_mask_2flair() {
    local t1_wm_mask="$1"
    local flair="$2"
    local matrix="$3"
    local output_folder file_name out_mask
    local transform=()

    output_folder=$(dirname "$t1_wm_mask")                  # anat/process
    file_name=$(basename "$flair" "_stripped.nii.gz")      # sub-XXX_ses-YY_FLAIR
    out_mask="$output_folder/${file_name}_WM_mask_transp.nii.gz"

    if already_done "$out_mask"; then
        echo "[SKIP] $file_name -> FLAIR WM mask already exists"
        return 0
    fi

    if [ "$matrix" == "identity" ]; then
        transform=( -t identity )
    else
        transform=( -t "[$matrix,1]" )    # ",1" = use the inverse (T1 -> FLAIR)
    fi

    echo "[RUN] $file_name -> WM mask (T1 space) -> FLAIR space"
    antsApplyTransforms -d 3 \
        -i "$t1_wm_mask" \
        -r "$flair" \
        "${transform[@]}" \
        -n GenericLabel \
        -o "$out_mask"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    ses=$(session_of "$d")
    t1_wm_mask=$(first_match "$d"/process/*_T1w_WM_mask.nii.gz)
    flair=$(first_match "$d"/*_FLAIR_stripped.nii.gz)

    if uses_flair_synth_t1 "$ses"; then
        matrix="identity"   # WM mask computed on flair_SynthT1, already in FLAIR space
    else
        matrix=$(first_match "$d"/mat/*_flair2t1_0GenericAffine.mat)
    fi

    if [ -z "$t1_wm_mask" ] || [ -z "$flair" ] || [ -z "$matrix" ]; then
        echo "[SKIP] $d -> T1 WM mask, stripped FLAIR or transform missing"
        continue
    fi

    wm_mask_2flair "$t1_wm_mask" "$flair" "$matrix"
done

# REFERENCES
# [ANTs] Avants BB, Tustison NJ, Song G, Cook PA, Klein A, Gee JC. A reproducible evaluation of ANTs similarity metric
#       performance in brain image registration. NeuroImage. 2011;54(3):2033-2044. doi:10.1016/j.neuroimage.2010.09.025
# [ANTs] Tustison NJ, Cook PA, Holbrook AJ, et al. The ANTsX ecosystem for quantitative biological and medical
#       imaging. Sci Rep. 2021;11:9068. doi:10.1038/s41598-021-87564-6
