#!/bin/bash
# =============================================================================
# 10_WM_sum_lesion.sh
# PURPOSE: Adds the lesion mask to the WM mask, in both T1 and FLAIR space, so that
#          lesioned voxels are included in the WM region used for lesion filling.
# INPUT:   anat/*_T1w_segmentation_original2synth.nii.gz,    anat/process/*_T1w_WM_mask.nii.gz
#          anat/*_FLAIR_segmentation_original2synth.nii.gz,  anat/process/*_FLAIR_WM_mask_transp.nii.gz
# OUTPUT:  anat/*_T1w_WM_mask_sum.nii.gz
#          anat/*_FLAIR_WM_mask_sum.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

wm_sum_lesion() {
    local t1_lesion_mask="$1"
    local t1_wm_mask="$2"
    local flair_lesion_mask="$3"
    local flair_wm_mask="$4"
    local anat_folder t1_file_name flair_file_name t1_output_name flair_output_name

    anat_folder=$(dirname "$t1_lesion_mask")
    t1_file_name=$(basename "$t1_wm_mask" ".nii.gz")                  # sub-XXX_ses-YY_T1w_WM_mask
    flair_file_name=$(basename "$flair_wm_mask" "_transp.nii.gz")     # sub-XXX_ses-YY_FLAIR_WM_mask
    t1_output_name="$anat_folder/${t1_file_name}_sum.nii.gz"
    flair_output_name="$anat_folder/${flair_file_name}_sum.nii.gz"

    if already_done "$t1_output_name" && already_done "$flair_output_name"; then
        echo "[SKIP] $t1_file_name -> WM+lesion masks already exist"
        return 0
    fi

    echo "[RUN] $t1_file_name -> WM + lesion"
    fslmaths "$t1_wm_mask"    -add "$t1_lesion_mask"    -bin "$t1_output_name"
    fslmaths "$flair_wm_mask" -add "$flair_lesion_mask" -bin "$flair_output_name"

    echo "[DONE] $t1_file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    t1_lesion_mask=$(first_match "$d"/*_T1w_segmentation_original2synth.nii.gz)
    t1_wm_mask=$(first_match "$d"/process/*_T1w_WM_mask.nii.gz)
    flair_lesion_mask=$(first_match "$d"/*_FLAIR_segmentation_original2synth.nii.gz)
    flair_wm_mask=$(first_match "$d"/process/*_FLAIR_WM_mask_transp.nii.gz)

    if [ -z "$t1_lesion_mask" ] || [ -z "$t1_wm_mask" ] || [ -z "$flair_lesion_mask" ] || [ -z "$flair_wm_mask" ]; then
        echo "[SKIP] $d -> lesion mask or WM mask missing"
        continue
    fi

    wm_sum_lesion "$t1_lesion_mask" "$t1_wm_mask" "$flair_lesion_mask" "$flair_wm_mask"
done

# REFERENCES
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
# [FSL] Smith SM, Jenkinson M, Woolrich MW, et al. Advances in functional and structural MR image analysis and
#       implementation as FSL. NeuroImage. 2004;23(Suppl 1):S208-S219. doi:10.1016/j.neuroimage.2004.07.051
