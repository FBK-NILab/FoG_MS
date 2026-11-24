#!/bin/bash
# =============================================================================
# 17_wm_hubs_average.sh
# PURPOSE: Group-level summary of script 16: averages the normalised track density
#          maps of all HCP subjects (incrementally), computes the fraction of subjects
#          with at least one streamline in each voxel, and merges the bundle centroids
#          of all subjects into a single group tractogram (17a_average_tck.py).
# INPUT:   $TRACTO_DIR/sub-*/sub-*_tck_filt_norm.nii.gz, sub-*_tck_clust.tck (+ _weights.txt), *.done
# OUTPUT:  $TRACTO_DIR/group/mean_tck_filt_norm.nii.gz     mean normalised density
#          $TRACTO_DIR/group/frac_subjects_tck_filt.nii.gz  fraction of subjects per voxel
#          $TRACTO_DIR/group/meanmax_tck_filt.nii.gz        mean density / its maximum (0-1)
#          $TRACTO_DIR/group/group_tck_clust.tck (+ weights, n_subjects, summary.csv)
#
# CHECKS BEFORE RUNNING (from $TRACTO_DIR):
#   subjects without streamlines:   grep -l "no streamline" sub-*/*_log.txt | wc -l
#   empty maps:
#     for m in sub-*/sub-*_tck_filt_norm.nii.gz; do
#         read -r nvox _ < <(fslstats "$m" -V -l 0)
#         (( nvox == 0 )) && echo "$(basename "$m"): empty map"
#     done
#   number of centroids = number of weights:
#     for c in sub-*/sub-*_tck_clust.tck; do
#         nc=$(tckinfo -count "$c" | awk '/actual count/ {print $NF}')
#         nw=$(wc -l < "${c%.tck}_weights.txt")
#         (( nc == nw )) || echo "$(basename "$c"): $nc centroids but $nw weights"
#     done
# REQUIRES: FSL, Python environment with dipy, nibabel, numpy (activated).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"
shopt -s nullglob

out_dir="$TRACTO_DIR/group"
qb_threshold=20                  # QuickBundles distance threshold for the group clustering (mm)
mkdir -p "$out_dir"

maps=( "$TRACTO_DIR"/sub-*/sub-*_tck_filt_norm.nii.gz )
done_files=( "$TRACTO_DIR"/sub-*/*.done )
n_maps=${#maps[@]}
n=${#done_files[@]}              # all processed subjects, including those without streamlines
echo "Processed subjects: $n  -  with map: $n_maps  -  without streamlines: $((n - n_maps))"
(( n_maps > 0 )) || { echo "No map found, exiting."; exit 1; }

sum="$out_dir/sum_norm.nii"
count="$out_dir/count_bin.nii"

# Empty images (all zeros) on the same grid as the maps
FSLOUTPUTTYPE=NIFTI fslmaths "${maps[0]}" -mul 0 "$sum"
FSLOUTPUTTYPE=NIFTI fslmaths "${maps[0]}" -mul 0 "$count"

i=0
for m in "${maps[@]}"; do
    i=$((i + 1))
    echo "[$i/$n_maps] $(basename "$m")"
    FSLOUTPUTTYPE=NIFTI fslmaths "$sum" -add "$m" "$sum"               # sum of the values
    FSLOUTPUTTYPE=NIFTI fslmaths "$m" -bin -add "$count" "$count"     # in how many subjects the voxel is > 0
done

# Mean density map (divided by ALL processed subjects, those without streamlines count as zero)
fslmaths "$sum" -div "$n" "$out_dir/mean_tck_filt_norm.nii.gz"

# Fraction of subjects with at least one streamline in each voxel
fslmaths "$count" -div "$n" "$out_dir/frac_subjects_tck_filt.nii.gz"

# Mean / max map (0-1)
read -r _ mmax < <(fslstats "$out_dir/mean_tck_filt_norm.nii.gz" -R)
fslmaths -dt double "$out_dir/mean_tck_filt_norm.nii.gz" -div "$mmax" "$out_dir/meanmax_tck_filt.nii.gz"

rm "$sum" "$count"

# Group tractogram of all the subject centroids
python "$SCRIPT_DIR/17a_average_tck.py" \
    "$TRACTO_DIR" \
    "$out_dir/group_tck_clust.tck" \
    "$qb_threshold"

echo "Done: average over $n subjects"

# REFERENCES
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
# [QuickBundles] Garyfallidis E, Brett M, Correia MM, Williams GB, Nimmo-Smith I. QuickBundles, a method for
#       tractography simplification. Front Neurosci. 2012;6:175. doi:10.3389/fnins.2012.00175
