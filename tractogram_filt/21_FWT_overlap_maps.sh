#!/bin/bash
# =============================================================================
# 21_FWT_overlap_maps.sh
# PURPOSE: Voxel-wise overlap between the group disconnection map (HCP data, script 17)
#          and the density maps of the 68 KUL_FWT bundles.
#
#          Disconnection map D: meanmax_tck_filt (0-1) restricted to the voxels involved
#          in at least frac_thr of the subjects.
#
#          For each FWT bundle:
#            - track density map (tckmap) normalised 0-1 and binary mask
#              (voxels >= bundle_thr * maximum)
#            - pct_bundle_covered   : % of the bundle voxels inside the disconnection
#                                     ("how much of the bundle is involved")
#            - pct_disc_in_bundle   : % of the disconnection (sum of D) falling inside the bundle
#                                     ("how much of the disconnection lies in the bundle")
#            - mean_D_along_bundle  : mean of D along the bundle, weighted by the bundle density (0-1)
#            - n_vox_intersection   : voxels shared by bundle and disconnection
#            - r_intersection       : Pearson correlation between D and bundle density, computed
#                                     ONLY in the voxels of the bundle ∩ disconnection intersection
# INPUT:   $TRACTO_DIR/group/meanmax_tck_filt.nii.gz, frac_subjects_tck_filt.nii.gz
#          $FWT_ATLAS_DIR/*.tck
# OUTPUT:  $TRACTO_DIR/A.FWT_maps_overlap/FWT_overlap_A.csv, D_meanmax_frac<thr>.nii.gz
#          $FWT_ATLAS_DIR/bundle_maps/<bundle>_density_map.nii.gz (computed once)
# REQUIRES: MRtrix3, FSL, Python environment with nibabel and numpy (activated).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"
shopt -s nullglob

########### PATHS ###########
group_dir="$TRACTO_DIR/group"
out_dir="$TRACTO_DIR/A.FWT_maps_overlap"
meanmax="$group_dir/meanmax_tck_filt.nii.gz"
frac="$group_dir/frac_subjects_tck_filt.nii.gz"

########### PARAMETERS ###########
frac_thr=0.5          # minimum fraction of subjects in which a voxel must be involved
bundle_thr=0.05       # a voxel belongs to the bundle if its density is >= 5% of the bundle maximum

for f in "$meanmax" "$frac"; do
    [ -f "$f" ] || { echo "[ERROR] $f not found (run script 17 first)"; exit 1; }
done
mkdir -p "$out_dir" "$FWT_ATLAS_DIR/bundle_maps"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Sum of all the voxels of an image, in double precision
# (do NOT use fslstats -m * -v: fslstats prints only 6 decimals and the mean of almost-empty images gets rounded)
img_sum() {
    local f="$1"
    [[ -f "$f" ]] || f="$f.nii.gz"     # fslmaths temporary files are named without extension
    python -c "import sys, numpy as np, nibabel as nib; print('%.10f' % np.asarray(nib.load(sys.argv[1]).dataobj, dtype=np.float64).sum())" "$f"
}

# 1. Disconnection map D (0-1, only voxels with frequency >= frac_thr)
D="$out_dir/D_meanmax_frac${frac_thr}.nii.gz"
fslmaths "$frac" -thr "$frac_thr" -bin "$tmp/fracmask"
fslmaths "$meanmax" -mas "$tmp/fracmask" "$D"
fslmaths "$D" -bin "$tmp/Dbin"
sum_D=$(img_sum "$D")
nvox_D=$(fslstats "$tmp/Dbin" -V | awk '{print $1}')
echo "Disconnection map: $nvox_D voxels, sum = $sum_D"

csv="$out_dir/FWT_overlap_A.csv"
echo "bundle,n_vox_bundle,pct_bundle_covered,pct_disc_in_bundle,mean_D_along_bundle,n_vox_intersection,r_intersection" > "$csv"

for b in "$FWT_ATLAS_DIR"/*.tck; do
    name=$(basename "$b" .tck); name=${name%_GN_symmetrical}
    tdi="$FWT_ATLAS_DIR/bundle_maps/${name}_density_map.nii.gz"

    # Bundle density map (computed once)
    if [[ -f "$tdi" ]]; then
        echo "  $name: map already present"
    else
        echo "  $name: computing map..."
        tckmap -quiet -force -precise -template "$MNI" "$b" "$tdi"
    fi

    max=$(fslstats "$tdi" -R | awk '{print $2}')
    if awk -v m="$max" 'BEGIN {exit !(m <= 0)}'; then
        echo "$name,0,NA,NA,NA,0,NA" >> "$csv"; continue
    fi

    # Density normalised 0-1 and bundle mask
    fslmaths "$tdi" -div "$max" "$tmp/Bn"
    fslmaths "$tmp/Bn" -thr "$bundle_thr" -bin "$tmp/Bmask"
    nvox_B=$(fslstats "$tmp/Bmask" -V | awk '{print $1}')

    # Bundle voxels inside the disconnection (= intersection voxels)
    nvox_ov=$(fslstats "$tmp/Dbin" -k "$tmp/Bmask" -V | awk '{print $1}')

    # Bundle ∩ disconnection, and correlation between the two maps in those voxels
    fslmaths "$tmp/Bmask" -mul "$tmp/Dbin" "$tmp/Imask"
    r=NA
    if (( nvox_ov > 2 )); then
        r=$(fslcc --noabs -t -1 -p 4 -m "$tmp/Imask" "$D" "$tmp/Bn" | awk 'NR==1 {print $3}')
        [[ -z "$r" ]] && r=NA
    fi

    # Sum of D inside the bundle
    fslmaths "$D" -mas "$tmp/Bmask" "$tmp/D_in"
    sum_D_in=$(img_sum "$tmp/D_in")

    # Mean of D along the bundle, weighted by the bundle density
    fslmaths "$tmp/Bn" -mas "$tmp/Bmask" "$tmp/Bw"
    fslmaths "$D" -mul "$tmp/Bw" "$tmp/DB"
    num=$(img_sum "$tmp/DB")
    den=$(img_sum "$tmp/Bw")

    awk -v nb="$nvox_B" -v no="$nvox_ov" -v sd="$sum_D" -v sdi="$sum_D_in" \
        -v num="$num" -v den="$den" -v r="$r" -v name="$name" 'BEGIN {
        cov  = (nb > 0) ? 100 * no / nb : 0
        din  = (sd > 0) ? 100 * sdi / sd : 0
        mD   = (den > 0) ? num / den : 0
        printf "%s,%d,%.2f,%.2f,%.4f,%d,%s\n", name, nb, cov, din, mD, no, r
    }' >> "$csv"
    echo "  $name done (r = $r)"
done

# Sort by mean of D along the bundle (column 5), most involved first
{ head -1 "$csv"; tail -n +2 "$csv" | sort -t, -k5 -gr; } > "$tmp/sorted.csv"
mv "$tmp/sorted.csv" "$csv"

echo "Done. Results in: $csv"

# REFERENCES
# [MRtrix3] Tournier JD, Smith R, Raffelt D, et al. MRtrix3: A fast, flexible and open software framework for medical
#       image processing and visualisation. NeuroImage. 2019;202:116137. doi:10.1016/j.neuroimage.2019.116137
# [TDI] Calamante F, Tournier JD, Jackson GD, Connelly A. Track-density imaging (TDI): super-resolution white matter
#       imaging using whole-brain track-density mapping. NeuroImage. 2010;53(4):1233-1243.
#       doi:10.1016/j.neuroimage.2010.07.024
# [FSL] Jenkinson M, Beckmann CF, Behrens TE, Woolrich MW, Smith SM. FSL. NeuroImage. 2012;62(2):782-790.
#       doi:10.1016/j.neuroimage.2011.09.015
# [KUL_FWT atlas] Radwan AM, Sunaert S, Schilling K, et al. An atlas of white matter anatomy, its variability, and
#       reproducibility based on constrained spherical deconvolution of diffusion MRI. NeuroImage. 2022;254:119029.
#       doi:10.1016/j.neuroimage.2022.119029
