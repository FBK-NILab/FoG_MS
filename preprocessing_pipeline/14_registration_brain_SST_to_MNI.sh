#!/bin/bash
# =============================================================================
# 14_registration_brain_SST_to_MNI.sh
# PURPOSE: Non-linearly registers the T1 component of each subject-specific template
#          (SST) to the MNI152 1 mm brain template with registration_brain (REGlib.sh):
#          translation -> rigid -> affine -> SyN (ANTs), preset "-s 4".
# INPUT:   sub-*/SST/SST_template0.nii.gz (T1 component of the SST, moving), $MNI (fixed)
# OUTPUT:  sub-*/SST/Reg_/SST_template0_SyN0GenericAffine.mat
#          sub-*/SST/Reg_/SST_template0_SyN1Warp.nii.gz (+ inverse warp)
#          sub-*/SST/Reg_/SST_template0_SyN_warped.nii.gz
# REQUIRES: lib/REGlib.sh and the libraries it sources (STRlib, FILESlib, IMAGINGlib,
#          ARRAYlib, CPUlib), by G. Amorosino.
# NOTE:    no "set -euo pipefail" in this script: REGlib.sh is not written for it.
#          If registration_brain fails, the check on its outputs stops the script.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

# Must be sourced last: it redefines SCRIPT_DIR (not used below)
source "$SCRIPT_DIR/lib/REGlib.sh"

sst_to_mni() {
    local sst="$1"     # moving
    local mni="$2"     # fixed
    local reg_path nm

    # registration_brain writes its outputs into a "Reg_" folder beside the moving
    # image, named <moving>_SyN* (SyN = last stage of the registration)
    reg_path="$(dirname "$sst")/Reg_"
    nm="$(basename "$sst" .nii.gz)_SyN"

    if already_done "${reg_path}/${nm}1Warp.nii.gz"; then
        echo "[SKIP] $sst -> SST-to-MNI transform already exists"
        return 0
    fi

    echo "[RUN] $sst -> MNI (registration_brain, preset 4)"
    registration_brain "$sst" "$mni" -s 4 -c auto

    if [ ! -f "${reg_path}/${nm}1Warp.nii.gz" ] || [ ! -f "${reg_path}/${nm}0GenericAffine.mat" ]; then
        echo "[ERROR] $sst -> registration_brain did not produce the expected transforms in $reg_path"
        exit 1
    fi

    echo "[DONE] $sst"
}

########################### SCRIPT STARTS HERE ###########################

if [ ! -f "$MNI" ]; then
    echo "[ERROR] MNI template not found: $MNI (check config.sh)"
    exit 1
fi

for subject_folder in "$BASE"/sub-*; do
    sst=$(first_match "$subject_folder"/SST/SST_template0.nii.gz)
    if [ -z "$sst" ]; then
        echo "[SKIP] $subject_folder -> SST missing (run script 13 first)"
        continue
    fi
    sst_to_mni "$sst" "$MNI"
done

# REFERENCES
# [registration_brain] REGlib.sh v0.4.0, G. Amorosino (g.amorosino@gmail.com), included in lib/.
# [SyN] Avants BB, Epstein CL, Grossman M, Gee JC. Symmetric diffeomorphic image registration with cross-correlation:
#       evaluating automated labeling of elderly and neurodegenerative brain. Med Image Anal. 2008;12(1):26-41.
#       doi:10.1016/j.media.2007.06.004
# [ANTs] Avants BB, Tustison NJ, Song G, Cook PA, Klein A, Gee JC. A reproducible evaluation of ANTs similarity metric
#       performance in brain image registration. NeuroImage. 2011;54(3):2033-2044. doi:10.1016/j.neuroimage.2010.09.025
# [MNI152] Grabner G, Janke AL, Budge MM, Smith D, Pruessner J, Collins DL. Symmetric atlasing and model based
#       segmentation: an application to the hippocampus in older adults. MICCAI 2006, LNCS 4191:58-66.
#       doi:10.1007/11866763_8
