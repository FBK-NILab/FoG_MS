#!/bin/bash
# =============================================================================
# 11_high_res_lesion_filling.sh
# PURPOSE: Performs lesion filling (FSL lesion_filling) on the skull-stripped
#          synthetic FLAIR and T1, using the high-resolution lesion masks and the
#          WM+lesion masks.
# INPUT:   anat/*_FLAIR_stripped.nii.gz, anat/*_FLAIR_segmentation_original2synth.nii.gz,
#          anat/*_FLAIR_WM_mask_sum.nii.gz
#          anat/*_T1w_stripped.nii.gz,    anat/*_T1w_segmentation_original2synth.nii.gz,
#          anat/*_T1w_WM_mask_sum.nii.gz
# OUTPUT:  anat/*_FLAIR_filled_high_res.nii.gz
#          anat/*_T1w_filled_high_res.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

# fill_lesions IMAGE LESION_MASK WM_MASK
fill_lesions() {
    local image="$1"
    local lesion_mask="$2"
    local wm_mask="$3"
    local output_folder file_name output_name

    output_folder=$(dirname "$image")
    file_name=$(basename "$image" "_stripped.nii.gz")   # sub-XXX_ses-YY_FLAIR or _T1w
    output_name="$output_folder/${file_name}_filled_high_res.nii.gz"

    if already_done "$output_name"; then
        echo "[SKIP] $file_name -> filled image already exists"
        return 0
    fi

    echo "[RUN] $file_name -> lesion filling"
    lesion_filling \
        -i "$image" \
        -l "$lesion_mask" \
        -o "$output_name" \
        -w "$wm_mask"

    echo "[DONE] $file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    # FLAIR
    flair=$(first_match "$d"/*_FLAIR_stripped.nii.gz)
    flair_lesion_mask=$(first_match "$d"/*_FLAIR_segmentation_original2synth.nii.gz)
    flair_wm_mask=$(first_match "$d"/*_FLAIR_WM_mask_sum.nii.gz)

    # T1
    t1=$(first_match "$d"/*_T1w_stripped.nii.gz)
    t1_lesion_mask=$(first_match "$d"/*_T1w_segmentation_original2synth.nii.gz)
    t1_wm_mask=$(first_match "$d"/*_T1w_WM_mask_sum.nii.gz)

    if [ -z "$flair" ] || [ -z "$flair_lesion_mask" ] || [ -z "$flair_wm_mask" ]; then
        echo "[SKIP] $d -> FLAIR, FLAIR lesion mask or FLAIR WM mask missing"
        continue
    fi
    if [ -z "$t1" ] || [ -z "$t1_lesion_mask" ] || [ -z "$t1_wm_mask" ]; then
        echo "[SKIP] $d -> T1, T1 lesion mask or T1 WM mask missing"
        continue
    fi

    fill_lesions "$flair" "$flair_lesion_mask" "$flair_wm_mask"
    fill_lesions "$t1"    "$t1_lesion_mask"    "$t1_wm_mask"
done

# REFERENCES
# [lesion_filling] Battaglini M, Jenkinson M, De Stefano N. Evaluating and reducing the impact of white matter lesions
#       on brain volume measurements. Hum Brain Mapp. 2012;33(9):2062-2071. doi:10.1002/hbm.21344
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
