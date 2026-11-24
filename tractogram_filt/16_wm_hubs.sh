#!/bin/bash
# =============================================================================
# 16_wm_hubs.sh
# PURPOSE: For each normative (HCP) tractogram, keeps only the streamlines that cross
#          the lesion of LESION_SES_NEW and not that of LESION_SES_OLD (lesions in MNI
#          space), computes their normalised track density map and clusters them into
#          bundles (QuickBundles centroids). Removes the filteret .tck.
#          Subjects are processed in parallel (N_JOBS).
# INPUT:   $HCP_TCK_DIR/sub*/*.tck
#          $BASE/<TRACTO_SUBJECT>/<ses>/anat/<sub>_<ses>_segmentation_to_MNI.nii.gz (preprocessing, 15)
# OUTPUT:  $TRACTO_DIR/<hcp_sub>/<hcp_sub>_tck_filt.nii.gz       (track density map)
#          $TRACTO_DIR/<hcp_sub>/<hcp_sub>_tck_filt_norm.nii.gz  (min-max normalised, within MNI brain mask)
#          $TRACTO_DIR/<hcp_sub>/<hcp_sub>_tck_clust.tck (+ _weights.txt)  (bundle centroids)
#          $TRACTO_DIR/<hcp_sub>/<hcp_sub>.done, <hcp_sub>_log.txt
# REQUIRES: MRtrix3, FSL, bc, Python environment with dipy, nibabel, numpy (activated).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

seg_old="$BASE/$TRACTO_SUBJECT/$LESION_SES_OLD/anat/${TRACTO_SUBJECT}_${LESION_SES_OLD}_segmentation_to_MNI.nii.gz"
seg_new="$BASE/$TRACTO_SUBJECT/$LESION_SES_NEW/anat/${TRACTO_SUBJECT}_${LESION_SES_NEW}_segmentation_to_MNI.nii.gz"
cluster_py="$SCRIPT_DIR/16a_cluster_tck.py"     # bundle clustering
qb_threshold=20                                   # QuickBundles distance threshold (mm)

for f in "$seg_old" "$seg_new" "$MNI" "$MNI_MASK"; do
    [ -f "$f" ] || { echo "[ERROR] file not found: $f"; exit 1; }
done

########################### SCRIPT STARTS HERE ###########################

for tck in "$HCP_TCK_DIR"/sub*/*.tck; do
    [ -f "$tck" ] || continue
    sub=$(basename "$(dirname "$tck")")
    output_dir="$TRACTO_DIR/$sub"
    output_name="${sub}_tck_filt.tck"
    output_nii="${sub}_tck_filt.nii.gz"
    output_clust="${sub}_tck_clust.tck"
    mkdir -p "$output_dir"

    # Skip subjects already completed
    if [[ -f "$output_dir/${sub}.done" ]]; then
        echo "$sub - already done, skipping"
        continue
    fi

    # Wait for a free slot (at most N_JOBS subjects in parallel)
    while (( $(jobs -rp | wc -l) >= N_JOBS )); do
        wait -n || true
    done

    echo "######################################################"
    echo "[START] $sub"

    (
        # 1) Streamlines crossing ONLY the new lesion -> filtered .tck
        time tckedit \
            -force \
            -quiet \
            -nthreads 3 \
            -include "$seg_new" \
            -exclude "$seg_old" \
            "$tck" \
            "$output_dir/$output_name"

        # 2) Track density map of the filtered .tck
        time tckmap \
            -force \
            -quiet \
            -precise \
            -nthreads 3 \
            -template "$MNI" \
            "$output_dir/$output_name" \
            "$output_dir/$output_nii"

        # 3) Min-max normalisation of the density map (within the MNI brain mask)
        min_max=( $(fslstats "$output_dir/$output_nii" -k "$MNI_MASK" -R) )
        val_range=$(echo "scale=32;${min_max[1]}-${min_max[0]}" | bc)

        if (( $(echo "$val_range == 0" | bc) )); then
            echo "  no streamline selected for $tck, skipping normalisation and clustering"
            rm "$output_dir/$output_name"
            touch "$output_dir/${sub}.done"     # mark the subject as done
            exit 0                              # leave the block of this subject
        fi
        fslmaths -dt double "$output_dir/$output_nii" -sub "${min_max[0]}" -div "$val_range" \
            "$output_dir/${sub}_tck_filt_norm.nii.gz"

        # 4) Clustering of the filtered streamlines into bundles (centroids + weights)
        time python "$cluster_py" \
            "$output_dir/$output_name" \
            "$output_dir/$output_clust" \
            "$MNI" \
            "$qb_threshold"

        rm "$output_dir/$output_name"         # filtered .tck no longer needed

        touch "$output_dir/${sub}.done"
        echo "[DONE] $sub"
        echo "#################################################################"
    ) > "$output_dir/${sub}_log.txt" 2>&1 &

done

wait
echo "All subjects completed"

# REFERENCES
# [MRtrix3] Tournier JD, Smith R, Raffelt D, et al. MRtrix3: A fast, flexible and open software framework for medical
#       image processing and visualisation. NeuroImage. 2019;202:116137. doi:10.1016/j.neuroimage.2019.116137
# [TDI] Calamante F, Tournier JD, Jackson GD, Connelly A. Track-density imaging (TDI): super-resolution white matter
#       imaging using whole-brain track-density mapping. NeuroImage. 2010;53(4):1233-1243.
#       doi:10.1016/j.neuroimage.2010.07.024
# [QuickBundles] Garyfallidis E, Brett M, Correia MM, Williams GB, Nimmo-Smith I. QuickBundles, a method for
#       tractography simplification. Front Neurosci. 2012;6:175. doi:10.3389/fnins.2012.00175
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
# [HCP] Van Essen DC, Smith SM, Barch DM, Behrens TEJ, Yacoub E, Ugurbil K. The WU-Minn Human Connectome Project:
#       an overview. NeuroImage. 2013;80:62-79. doi:10.1016/j.neuroimage.2013.05.041
# [brainlife.io] Hayashi S, et al. brainlife.io: a decentralized and open-source cloud platform to support
#       neuroscience research. Nat Methods. 2024;21(5):809-813. doi:10.1038/s41592-024-02237-2
