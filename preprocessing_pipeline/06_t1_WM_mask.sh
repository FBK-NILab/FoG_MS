#!/bin/bash
# =============================================================================
# 06_t1_WM_mask.sh
# PURPOSE: Segments the skull-stripped synthetic T1 into tissue classes with FAST
#          and thresholds the WM partial volume map (pve_2 > 0.5) to a binary WM mask.
# INPUT:   anat/*_T1w_stripped.nii.gz
# OUTPUT:  anat/process/*_T1w_fast_*     (FAST outputs)
#          anat/process/*_T1w_WM_mask.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

wm_mask() {
    local t1="$1"
    local anat_folder process_folder t1_file_name t1_fast_prefix t1_output_name

    anat_folder=$(dirname "$t1")
    process_folder="$anat_folder/process"
    t1_file_name=$(basename "$t1" "_stripped.nii.gz")   # sub-XXX_ses-YY_T1w
    t1_fast_prefix="$process_folder/${t1_file_name}_fast"
    t1_output_name="$process_folder/${t1_file_name}_WM_mask.nii.gz"

    if already_done "$t1_output_name"; then
        echo "[SKIP] $t1_file_name -> T1 WM mask already exists"
        return 0
    fi

    # Tissue segmentation (3 classes: CSF, GM, WM)
    echo "[RUN] $t1_file_name -> FAST tissue segmentation"
    fast -n 3 -o "$t1_fast_prefix" "$t1"

    # Binary WM mask from the WM partial volume map (pve_2)
    echo "[RUN] $t1_file_name -> thresholding pve_2 to a binary WM mask"
    fslmaths "${t1_fast_prefix}_pve_2.nii.gz" \
        -thr 0.5 \
        -bin "$t1_output_name"

    echo "[DONE] $t1_file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    t1=$(first_match "$d"/*_T1w_stripped.nii.gz)

    if [ -z "$t1" ]; then
        echo "[SKIP] $d -> stripped T1 missing"
        continue
    fi

    wm_mask "$t1"
done

# REFERENCES
# [FAST] Zhang Y, Brady M, Smith S. Segmentation of brain MR images through a hidden Markov random field model and
#       the expectation-maximization algorithm. IEEE Trans Med Imaging. 2001;20(1):45-57. doi:10.1109/42.906424
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
