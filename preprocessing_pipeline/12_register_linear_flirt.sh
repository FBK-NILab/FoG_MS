#!/bin/bash
# =============================================================================
# 12_register_linear_flirt.sh
# PURPOSE: Rigidly registers (6 DOF, FLIRT) the lesion-filled T1 and FLAIR of every
#          session to the corresponding images of the reference session (REF_SESSION).
# INPUT:   anat/*_T1w_filled_high_res.nii.gz, anat/*_FLAIR_filled_high_res.nii.gz
#          (reference: same files in REF_SESSION)
# OUTPUT:  anat/mat/*_filled_high_res_to_ses01.mat
#          anat/*_filled_high_res_registered2ses01.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

REF_TAG="${REF_SESSION//-/}"    # ses-01 -> ses01 (used in output names)

# flirt_to_ref IMAGE REFERENCE
flirt_to_ref() {
    local image="$1"
    local ref="$2"
    local anat_folder file_name omat output_name

    anat_folder=$(dirname "$image")
    mkdir -p "$anat_folder/mat"
    file_name=$(basename "$image" .nii.gz)
    omat="$anat_folder/mat/${file_name}_to_${REF_TAG}.mat"
    output_name="$anat_folder/${file_name}_registered2${REF_TAG}.nii.gz"

    if already_done "$output_name"; then
        echo "[SKIP] $file_name -> already registered to $REF_SESSION"
        return 0
    fi

    echo "[RUN] $file_name -> rigid registration to $REF_SESSION"
    # 1) estimate the rigid transform
    flirt \
        -in "$image" \
        -ref "$ref" \
        -dof 6 \
        -omat "$omat"

    # 2) apply it
    flirt \
        -in "$image" \
        -ref "$ref" \
        -applyxfm \
        -init "$omat" \
        -interp trilinear \
        -out "$output_name"

    echo "[DONE] $file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    ses=$(session_of "$d")
    [ "$ses" == "$REF_SESSION" ] && continue    # the reference session is not registered

    subject_folder=$(dirname "$(dirname "$d")")
    t1=$(first_match "$d"/*_T1w_filled_high_res.nii.gz)
    flair=$(first_match "$d"/*_FLAIR_filled_high_res.nii.gz)
    ref_t1=$(first_match "$subject_folder/$REF_SESSION"/anat/*_T1w_filled_high_res.nii.gz)
    ref_flair=$(first_match "$subject_folder/$REF_SESSION"/anat/*_FLAIR_filled_high_res.nii.gz)

    if [ -z "$t1" ] || [ -z "$flair" ]; then
        echo "[SKIP] $d -> filled T1 or FLAIR missing"
        continue
    fi
    if [ -z "$ref_t1" ] || [ -z "$ref_flair" ]; then
        echo "[SKIP] $d -> filled T1 or FLAIR of $REF_SESSION missing"
        continue
    fi

    flirt_to_ref "$t1"    "$ref_t1"
    flirt_to_ref "$flair" "$ref_flair"
done

# REFERENCES
# [FLIRT] Jenkinson M, Smith S. A global optimisation method for robust affine registration of brain images.
#       Med Image Anal. 2001;5(2):143-156. doi:10.1016/S1361-8415(01)00036-6
# [FLIRT] Jenkinson M, Bannister P, Brady M, Smith S. Improved optimization for the robust and accurate linear
#       registration and motion correction of brain images. NeuroImage. 2002;17(2):825-841. doi:10.1006/nimg.2002.1132
