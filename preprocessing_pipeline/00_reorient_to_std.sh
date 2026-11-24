#!/bin/bash
# =============================================================================
# 00_reorient_to_std.sh
# PURPOSE: Reorients the selected raw T1w and FLAIR images, and the manual lesion
#          segmentation drawn on the FLAIR, to the standard (MNI) axis orientation,
#          and creates the BIDS derivatives folder structure.
# INPUT:   $BIDS/sub-*/ses-*/anat/selected/*_T1w.nii.gz
#          $BIDS/sub-*/ses-*/anat/selected/*_FLAIR.nii.gz
#          $BIDS/sub-*/ses-*/anat/selected/*_FLAIR_segmentation.nii.gz
# OUTPUT:  $BASE/sub-*/ses-*/anat/process/*_reoriented.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

# Reorients one image and writes it into the matching derivatives "process" folder
reorient_to_std() {
    local original_image="$1"
    local file_name anat_folder rel_path output_folder output_name

    file_name=$(basename "$original_image" .nii.gz)
    anat_folder=$(dirname "$(dirname "$original_image")")   # .../sub-XXX/ses-YY/anat
    rel_path="${anat_folder#"$BIDS"/}"                        # sub-XXX/ses-YY/anat
    output_folder="$BASE/$rel_path/process"
    output_name="$output_folder/${file_name}_reoriented.nii.gz"

    if already_done "$output_name"; then
        echo "[SKIP] $file_name -> reoriented image already exists"
        return 0
    fi

    mkdir -p "$output_folder"
    echo "[RUN] $file_name -> fslreorient2std"
    fslreorient2std "$original_image" "$output_name"
}

########################### SCRIPT STARTS HERE ###########################

for f in "$BIDS"/sub-*/ses-*/anat/selected/*_FLAIR.nii.gz \
         "$BIDS"/sub-*/ses-*/anat/selected/*_T1w.nii.gz \
         "$BIDS"/sub-*/ses-*/anat/selected/*_FLAIR_segmentation.nii.gz; do
    [[ -e "$f" ]] || continue    # skip unmatched glob patterns
    reorient_to_std "$f"
done

# REFERENCES
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
# [FSL] Smith SM, Jenkinson M, Woolrich MW, et al. Advances in functional and structural MR image analysis and
#       implementation as FSL. NeuroImage. 2004;23(Suppl 1):S208-S219. doi:10.1016/j.neuroimage.2004.07.051
