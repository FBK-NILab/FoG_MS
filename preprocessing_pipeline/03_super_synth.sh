#!/bin/bash
# =============================================================================
# 03_super_synth.sh
# PURPOSE: Generates synthetic 1 mm isotropic contrasts (SynthT1, SynthFLAIR, ...)
#          with mri_super_synth, separately from the FLAIR and from the T1w,
#          and converts the outputs to NIfTI.
# INPUT:   anat/process/*_FLAIR_reoriented_corrected.nii.gz
#          anat/process/*_T1w_reoriented_corrected.nii.gz
# OUTPUT:  anat/flair_super_synth/flair_*.nii.gz  (synthesised from the FLAIR)
#          anat/t1_super_synth/t1_*.nii.gz        (synthesised from the T1w)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

# run_super_synth INPUT OUTPUT_FOLDER PREFIX
# Runs mri_super_synth, adds PREFIX_ to every output file and converts .mgz to .nii.gz
run_super_synth() {
    local input="$1"
    local output_folder="$2"
    local prefix="$3"
    local file_name f base nii_name

    file_name=$(basename "$input" .nii.gz)

    # The synthetic T1 is produced in both cases: used as completion check
    if already_done "$output_folder/${prefix}_SynthT1.nii.gz"; then
        echo "[SKIP] $file_name -> ${prefix}_super_synth already exists"
        return 0
    fi

    # A folder without the final output comes from an interrupted run:
    # remove it, otherwise the renaming below would add the prefix twice
    if [ -d "$output_folder" ]; then
        echo "[WARNING] $output_folder is incomplete, removing it and starting again"
        rm -rf "$output_folder"
    fi
    mkdir -p "$output_folder"

    echo "[RUN] $file_name -> synthesis from ${prefix}"
    mri_super_synth \
        --i "$input" \
        --o "$output_folder" \
        --mode invivo

    # Add the prefix to every output file
    for f in "$output_folder"/*; do
        base=$(basename "$f")
        mv "$f" "$output_folder/${prefix}_${base}"
    done

    # Convert every .mgz output to .nii.gz and remove the .mgz
    for f in "$output_folder"/"${prefix}"_*.mgz; do
        [ -f "$f" ] || continue
        nii_name="${f%.mgz}.nii.gz"
        echo "[CONVERT] $(basename "$f") -> $(basename "$nii_name")"
        mri_convert "$f" "$nii_name"
        rm "$f"
    done

    echo "[DONE] $file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat/process; do
    flair=$(first_match "$d"/*_FLAIR_reoriented_corrected.nii.gz)
    t1=$(first_match "$d"/*_T1w_reoriented_corrected.nii.gz)

    if [ -z "$flair" ] || [ -z "$t1" ]; then
        echo "[SKIP] $d -> FLAIR or T1 missing"
        continue
    fi

    anat_folder=$(dirname "$d")
    run_super_synth "$flair" "$anat_folder/flair_super_synth" "flair"
    run_super_synth "$t1"    "$anat_folder/t1_super_synth"    "t1"
done

# REFERENCES
# mri_super_synth (FreeSurfer SuperSynth) has no dedicated paper yet; the FreeSurfer wiki asks to cite:
# [SynthSeg] Billot B, et al. SynthSeg: Segmentation of brain MRI scans of any contrast and resolution without
#       retraining. Med Image Anal. 2023;86:102789. doi:10.1016/j.media.2023.102789
# [SynthSR] Iglesias JE, et al. SynthSR: A public AI tool to turn heterogeneous clinical brain scans into
#       high-resolution T1-weighted images for 3D morphometry. Sci Adv. 2023;9(5):eadd3607. doi:10.1126/sciadv.add3607
# [FreeSurfer, mri_convert] Fischl B. FreeSurfer. NeuroImage. 2012;62(2):774-781. doi:10.1016/j.neuroimage.2012.01.021
