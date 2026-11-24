#!/bin/bash
# =============================================================================
# 01_denoising_N4.sh
# PURPOSE: Applies Rician non-local means denoising followed by N4 bias field
#          correction to the reoriented T1w and FLAIR images.
# INPUT:   anat/process/*_T1w_reoriented.nii.gz, anat/process/*_FLAIR_reoriented.nii.gz
# OUTPUT:  anat/process/*_reoriented_corrected.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

denoise_N4() {
    local original_image="$1"
    local file_name output_folder denoised corrected

    file_name=$(basename "$original_image" .nii.gz)
    output_folder=$(dirname "$original_image")      # output written next to the input
    denoised="$output_folder/${file_name}_denoised.nii.gz"
    corrected="$output_folder/${file_name}_corrected.nii.gz"

    if already_done "$corrected"; then
        echo "[SKIP] $file_name -> corrected image already exists"
        return 0
    fi

    echo "[RUN] $file_name -> denoising (Rician)"
    DenoiseImage \
        -d 3 \
        -i "$original_image" \
        -n Rician \
        -o "$denoised"

    echo "[RUN] $file_name -> N4 bias field correction"
    N4BiasFieldCorrection \
        -d 3 \
        -i "$denoised" \
        -o "$corrected"

    rm "$denoised"    # intermediate file, not needed anymore
}

########################### SCRIPT STARTS HERE ###########################

for f in "$BASE"/sub-*/ses-*/anat/process/*_T1w_reoriented.nii.gz \
         "$BASE"/sub-*/ses-*/anat/process/*_FLAIR_reoriented.nii.gz; do
    [[ -e "$f" ]] || continue    # skip unmatched glob patterns
    denoise_N4 "$f"
done

# REFERENCES
# [DenoiseImage] Manjón JV, Coupé P, Martí-Bonmatí L, Collins DL, Robles M. Adaptive non-local means denoising of
#       MR images with spatially varying noise levels. J Magn Reson Imaging. 2010;31(1):192-203. doi:10.1002/jmri.22003
# [N4] Tustison NJ, Avants BB, Cook PA, Zheng Y, Egan A, Yushkevich PA, Gee JC. N4ITK: improved N3 bias correction.
#       IEEE Trans Med Imaging. 2010;29(6):1310-1320. doi:10.1109/TMI.2010.2046908
# [ANTs] Tustison NJ, Cook PA, Holbrook AJ, et al. The ANTsX ecosystem for quantitative biological and medical
#       imaging. Sci Rep. 2021;11:9068. doi:10.1038/s41598-021-87564-6
