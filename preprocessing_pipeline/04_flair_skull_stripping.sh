#!/bin/bash
# =============================================================================
# 04_flair_skull_stripping.sh
# PURPOSE: Skull-strips the synthetic FLAIR with SynthStrip and saves the
#          corresponding brain mask.
# INPUT:   anat/flair_super_synth/flair_SynthFLAIR.nii.gz
#          anat/process/*_FLAIR_reoriented_corrected.nii.gz (only used to name the outputs)
# OUTPUT:  anat/*_FLAIR_stripped.nii.gz
#          anat/process/*_FLAIR_brain_mask.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

flair_stripping() {
    local flair="$1"
    local name_file="$2"
    local anat_folder file_name output_name out_brain_mask

    anat_folder=$(dirname "$(dirname "$flair")")
    file_name=$(basename "$name_file" "_reoriented_corrected.nii.gz")   # sub-XXX_ses-YY_FLAIR
    output_name="$anat_folder/${file_name}_stripped.nii.gz"
    out_brain_mask="$anat_folder/process/${file_name}_brain_mask.nii.gz"

    if already_done "$output_name"; then
        echo "[SKIP] $file_name -> stripped FLAIR already exists"
        return 0
    fi

    echo "[RUN] $file_name -> skull stripping"
    mri_synthstrip \
        -i "$flair" \
        -o "$output_name" \
        -m "$out_brain_mask"

    echo "[DONE] $file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    flair=$(first_match "$d"/flair_super_synth/flair_SynthFLAIR.nii.gz)
    name_file=$(first_match "$d"/process/*_FLAIR_reoriented_corrected.nii.gz)

    if [ -z "$flair" ] || [ -z "$name_file" ]; then
        echo "[SKIP] $d -> synthetic FLAIR or corrected FLAIR missing"
        continue
    fi

    flair_stripping "$flair" "$name_file"
done

# REFERENCES
# [SynthStrip] Hoopes A, Mora JS, Dalca AV, Fischl B, Hoffmann M. SynthStrip: skull-stripping for any brain image.
#       NeuroImage. 2022;260:119474. doi:10.1016/j.neuroimage.2022.119474
