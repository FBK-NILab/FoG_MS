#!/bin/bash
# =============================================================================
# 18_disconnected_FWT_lesion_filt.sh
# PURPOSE: For each bundle of the KUL_FWT atlas, computes the percentage of streamlines
#          disconnected by the new lesion, i.e. crossing the lesion of LESION_SES_NEW
#          and not touching that of LESION_SES_OLD.
# INPUT:   $FWT_ATLAS_DIR/*.tck
#          $BASE/<TRACTO_SUBJECT>/<ses>/anat/<sub>_<ses>_segmentation_to_MNI.nii.gz
# OUTPUT:  $TRACTO_DIR/atlas_FWT_disconnection/tck_disconnected/<bundle>_disconnected.tck
#          $TRACTO_DIR/atlas_FWT_disconnection/FWT_bundle_disconnection.csv
# REQUIRES: MRtrix3.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"
shopt -s nullglob

out_dir="$TRACTO_DIR/atlas_FWT_disconnection"
seg_old="$BASE/$TRACTO_SUBJECT/$LESION_SES_OLD/anat/${TRACTO_SUBJECT}_${LESION_SES_OLD}_segmentation_to_MNI.nii.gz"
seg_new="$BASE/$TRACTO_SUBJECT/$LESION_SES_NEW/anat/${TRACTO_SUBJECT}_${LESION_SES_NEW}_segmentation_to_MNI.nii.gz"

for f in "$seg_old" "$seg_new"; do
    [ -f "$f" ] || { echo "[ERROR] file not found: $f"; exit 1; }
done

mkdir -p "$out_dir/tck_disconnected"
csv="$out_dir/FWT_bundle_disconnection.csv"
echo "bundle,n_streamlines_total,n_streamlines_disconnected,percent_disconnected" > "$csv"

bundles=( "$FWT_ATLAS_DIR"/*.tck )
echo "Bundles found: ${#bundles[@]}"
(( ${#bundles[@]} > 0 )) || { echo "No .tck in $FWT_ATLAS_DIR, exiting."; exit 1; }

for b in "${bundles[@]}"; do
    name=$(basename "$b" .tck)
    out_tck="$out_dir/tck_disconnected/${name}_disconnected.tck"

    # Total streamlines of the bundle
    n_tot=$(tckinfo -quiet -count "$b" | awk '/actual count/ {print $NF}')

    # Streamlines of the bundle crossing the new lesion only
    tckedit -force -quiet \
        -include "$seg_new" \
        -exclude "$seg_old" \
        "$b" "$out_tck"
    n_dis=$(tckinfo -quiet -count "$out_tck" | awk '/actual count/ {print $NF}')

    # Percentage
    perc=$(awk -v d="$n_dis" -v t="$n_tot" 'BEGIN { if (t > 0) printf "%.2f", 100*d/t; else print "NA" }')

    echo "$name,$n_tot,$n_dis,$perc" >> "$csv"
    echo "$name: $n_dis / $n_tot streamlines ($perc%)"
done

echo "Done. Results in: $csv"

# REFERENCES
# [MRtrix3] Tournier JD, Smith R, Raffelt D, et al. MRtrix3: A fast, flexible and open software framework for medical
#       image processing and visualisation. NeuroImage. 2019;202:116137. doi:10.1016/j.neuroimage.2019.116137
# [KUL_FWT atlas] Radwan AM, Sunaert S, Schilling K, et al. An atlas of white matter anatomy, its variability, and
#       reproducibility based on constrained spherical deconvolution of diffusion MRI. NeuroImage. 2022;254:119029.
#       doi:10.1016/j.neuroimage.2022.119029
