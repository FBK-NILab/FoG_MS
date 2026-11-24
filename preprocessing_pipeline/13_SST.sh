#!/bin/bash
# =============================================================================
# 13_SST.sh
# PURPOSE: Builds a multimodal subject-specific template (SST) from the lesion-filled
#          T1 and FLAIR images of all sessions (rigid, ANTs multivariate template
#          construction). template0 = T1, template1 = FLAIR.
# INPUT:   REF_SESSION:     anat/*_T1w_filled_high_res.nii.gz, anat/*_FLAIR_filled_high_res.nii.gz
#          other sessions:  anat/*_T1w_filled_high_res_registered2ses01.nii.gz,
#                           anat/*_FLAIR_filled_high_res_registered2ses01.nii.gz
# OUTPUT:  sub-*/SST/SST_inputs.csv (one line per session: T1,FLAIR)
#          sub-*/SST/SST_template0.nii.gz (T1), sub-*/SST/SST_template1.nii.gz (FLAIR)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

REF_TAG="${REF_SESSION//-/}"    # ses-01 -> ses01

build_sst() {
    local subject_folder="$1"
    local subject_name output_folder out_prefix input_csv d ses t1 flair n_sessions=0

    subject_name=$(basename "$subject_folder")
    echo "=========================================="
    echo "$subject_name"
    echo "=========================================="

    output_folder="$subject_folder/SST"
    out_prefix="$output_folder/SST_"
    input_csv="$output_folder/SST_inputs.csv"

    if already_done "${out_prefix}template0.nii.gz" && already_done "${out_prefix}template1.nii.gz"; then
        echo "[SKIP] $subject_name -> SST already exists"
        return 0
    fi

    mkdir -p "$output_folder"
    : > "$input_csv"

    # One T1/FLAIR pair per session: the reference session as it is,
    # the others registered to it (script 12)
    for d in "$subject_folder"/ses-*/anat; do
        [ -d "$d" ] || continue
        ses=$(session_of "$d")
        if [ "$ses" == "$REF_SESSION" ]; then
            t1=$(first_match "$d"/*_T1w_filled_high_res.nii.gz)
            flair=$(first_match "$d"/*_FLAIR_filled_high_res.nii.gz)
        else
            t1=$(first_match "$d"/*_T1w_filled_high_res_registered2${REF_TAG}.nii.gz)
            flair=$(first_match "$d"/*_FLAIR_filled_high_res_registered2${REF_TAG}.nii.gz)
        fi

        if [ -z "$t1" ] || [ -z "$flair" ]; then
            echo "[SKIP] $d -> T1 or FLAIR missing (run scripts 11 and 12 first)"
            continue
        fi

        # Same order on every line: T1 first (-> template0), FLAIR second (-> template1)
        echo "$t1,$flair" >> "$input_csv"
        n_sessions=$((n_sessions + 1))
    done

    if [ "$n_sessions" -eq 0 ]; then
        echo "[ERROR] $subject_name -> no T1/FLAIR pair found"
        return 0
    fi

    echo "$subject_name -> input pairs (T1,FLAIR)"
    sed 's/^/  /' "$input_csv"
    echo "[RUN] $subject_name -> building SST ($n_sessions sessions)"

    # -k 2: two modalities (T1, FLAIR), read from the csv; -w 1x1: equal weight to both
    # -t Rigid: rigid-only template; -m CC: cross-correlation metric
    antsMultivariateTemplateConstruction2.sh \
        -d 3 \
        -o "$out_prefix" \
        -g 0.2 \
        -j 8 \
        -c 2 \
        -k 2 \
        -f 8x4x2x1 \
        -w 1x1 \
        -n 0 \
        -y 0 \
        -r 1 \
        -m CC \
        -t Rigid \
        "$input_csv"

    echo "[DONE] $subject_name -> SST created"
}

########################### SCRIPT STARTS HERE ###########################

for subject_folder in "$BASE"/sub-*; do
    [ -d "$subject_folder" ] || continue
    build_sst "$subject_folder"
done

# REFERENCES
# [SST] Avants BB, Yushkevich P, Pluta J, Minkoff D, Korczykowski M, Detre J, Gee JC. The optimal template effect in
#       hippocampus studies of diseased populations. NeuroImage. 2010;49(3):2457-2466.
#       doi:10.1016/j.neuroimage.2009.09.062
# [ANTs] Tustison NJ, Cook PA, Holbrook AJ, et al. The ANTsX ecosystem for quantitative biological and medical
#       imaging. Sci Rep. 2021;11:9068. doi:10.1038/s41598-021-87564-6
