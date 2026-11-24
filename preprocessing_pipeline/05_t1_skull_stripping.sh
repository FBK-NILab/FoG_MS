#!/bin/bash
# =============================================================================
# 05_t1_skull_stripping.sh
# PURPOSE: Skull-strips the synthetic T1 by transferring the FLAIR brain mask into
#          T1 space with the FLAIR-to-T1 rigid transform. For the sessions listed in
#          FLAIR_SYNTH_T1_SESSIONS the FLAIR-derived SynthT1 is used instead, which
#          already shares the FLAIR space, so no transform is applied.
# INPUT:   anat/process/*_FLAIR_brain_mask.nii.gz
#          anat/mat/*_flair2t1_0GenericAffine.mat
#          anat/t1_super_synth/t1_SynthT1.nii.gz (or flair_super_synth/flair_SynthT1.nii.gz)
# OUTPUT:  anat/process/*_T1w_brain_mask.nii.gz
#          anat/*_T1w_stripped.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

t1_skull_stripping() {
    local flair_brain_mask="$1"
    local matrix="$2"
    local t1="$3"
    local name_file="$4"
    local anat_folder file_name t1_brain_mask output_name

    anat_folder=$(dirname "$(dirname "$name_file")")
    file_name=$(basename "$name_file" "_reoriented_corrected.nii.gz")   # sub-XXX_ses-YY_T1w
    t1_brain_mask="$anat_folder/process/${file_name}_brain_mask.nii.gz"
    output_name="$anat_folder/${file_name}_stripped.nii.gz"

    if already_done "$output_name"; then
        echo "[SKIP] $file_name -> stripped T1 already exists"
        return 0
    fi

    echo "[RUN] $file_name -> FLAIR brain mask to T1 space"
    antsApplyTransforms -d 3 \
        -i "$flair_brain_mask" \
        -r "$t1" \
        -t "$matrix" \
        -n GenericLabel \
        -o "$t1_brain_mask"

    echo "[RUN] $file_name -> T1 skull stripping"
    fslmaths "$t1" -mas "$t1_brain_mask" "$output_name"

    echo "[DONE] $file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    ses=$(session_of "$d")
    flair_brain_mask=$(first_match "$d"/process/*_FLAIR_brain_mask.nii.gz)
    name_file=$(first_match "$d"/process/*_T1w_reoriented_corrected.nii.gz)   # only used to name the outputs

    if uses_flair_synth_t1 "$ses"; then
        # T1w field of view cuts the brain: use the SynthT1 generated from the FLAIR,
        # which is already on the FLAIR grid -> no transform needed
        t1=$(first_match "$d"/flair_super_synth/flair_SynthT1.nii.gz)
        matrix="identity"
    else
        t1=$(first_match "$d"/t1_super_synth/t1_SynthT1.nii.gz)
        matrix=$(first_match "$d"/mat/*_flair2t1_0GenericAffine.mat)
    fi

    if [ -z "$flair_brain_mask" ] || [ -z "$matrix" ] || [ -z "$t1" ] || [ -z "$name_file" ]; then
        echo "[SKIP] $d -> brain mask, transform, synthetic T1 or corrected T1 missing"
        continue
    fi

    t1_skull_stripping "$flair_brain_mask" "$matrix" "$t1" "$name_file"
done

# REFERENCES
# [ANTs] Avants BB, Tustison NJ, Song G, Cook PA, Klein A, Gee JC. A reproducible evaluation of ANTs similarity metric
#       performance in brain image registration. NeuroImage. 2011;54(3):2033-2044. doi:10.1016/j.neuroimage.2010.09.025
# [ANTs] Tustison NJ, Cook PA, Holbrook AJ, et al. The ANTsX ecosystem for quantitative biological and medical
#       imaging. Sci Rep. 2021;11:9068. doi:10.1038/s41598-021-87564-6
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
