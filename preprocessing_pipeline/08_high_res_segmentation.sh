#!/bin/bash
# =============================================================================
# 08_high_res_segmentation.sh
# PURPOSE: Registers the original FLAIR to the synthetic FLAIR (rigid + SyN) and
#          applies the transform to the manual lesion segmentation, bringing it onto
#          the 1 mm grid of the synthetic FLAIR (high-resolution segmentation).
# INPUT:   anat/process/*_FLAIR_segmentation_reoriented.nii.gz
#          anat/process/*_FLAIR_reoriented_corrected.nii.gz (moving)
#          anat/flair_super_synth/flair_SynthFLAIR.nii.gz    (fixed)
# OUTPUT:  anat/mat/*_FLAIR_original2synth_0GenericAffine.mat, *_1Warp.nii.gz
#          anat/*_FLAIR_segmentation_original2synth.nii.gz
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../utils.sh"

high_res_seg() {
    local segmentation="$1"
    local synth_flair="$2"       # fixed image
    local original_flair="$3"    # moving image
    local anat_folder mat_folder file_name out_prefix output_name

    anat_folder=$(dirname "$(dirname "$segmentation")")
    mat_folder="$anat_folder/mat"
    mkdir -p "$mat_folder"

    file_name=$(basename "$segmentation" "_segmentation_reoriented.nii.gz")   # sub-XXX_ses-YY_FLAIR
    out_prefix="$mat_folder/${file_name}_original2synth_"
    output_name="$anat_folder/${file_name}_segmentation_original2synth.nii.gz"

    if already_done "$output_name"; then
        echo "[SKIP] $file_name -> high-resolution segmentation already exists"
        return 0
    fi

    echo "[RUN] $file_name -> original FLAIR to synthetic FLAIR (rigid + SyN)"
    antsRegistration \
        --dimensionality 3 \
        --float 0 \
        --output "$out_prefix" \
        --interpolation Linear \
        --winsorize-image-intensities "[0.005,0.995]" \
        --use-histogram-matching 0 \
        --initial-moving-transform "[$synth_flair,$original_flair,1]" \
        --transform "Rigid[0.1]" \
        --metric "MI[$synth_flair,$original_flair,1,32,Regular,0.25]" \
        --convergence "[1000x500x250x0,1e-6,10]" \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox \
        --transform "SyN[0.1,3,0]" \
        --metric "CC[$synth_flair,$original_flair,1,4]" \
        --convergence "[100x70x50x20,1e-6,10]" \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox

    # Transforms are applied in reverse order: affine first, then the warp
    echo "[RUN] $file_name -> lesion segmentation to synthetic FLAIR space"
    antsApplyTransforms \
        --dimensionality 3 \
        --input "$segmentation" \
        --reference-image "$synth_flair" \
        --output "$output_name" \
        --interpolation NearestNeighbor \
        --transform "${out_prefix}1Warp.nii.gz" \
        --transform "${out_prefix}0GenericAffine.mat"

    echo "[DONE] $file_name"
}

########################### SCRIPT STARTS HERE ###########################

for d in "$BASE"/sub-*/ses-*/anat; do
    segmentation=$(first_match "$d"/process/*_FLAIR_segmentation_reoriented.nii.gz)
    original_flair=$(first_match "$d"/process/*_FLAIR_reoriented_corrected.nii.gz)
    synth_flair=$(first_match "$d"/flair_super_synth/flair_SynthFLAIR.nii.gz)

    if [ -z "$segmentation" ] || [ -z "$original_flair" ] || [ -z "$synth_flair" ]; then
        echo "[SKIP] $d -> segmentation, original FLAIR or synthetic FLAIR missing"
        continue
    fi

    high_res_seg "$segmentation" "$synth_flair" "$original_flair"
done

# REFERENCES
# [SyN] Avants BB, Epstein CL, Grossman M, Gee JC. Symmetric diffeomorphic image registration with cross-correlation:
#       evaluating automated labeling of elderly and neurodegenerative brain. Med Image Anal. 2008;12(1):26-41.
#       doi:10.1016/j.media.2007.06.004
# [ANTs] Avants BB, Tustison NJ, Song G, Cook PA, Klein A, Gee JC. A reproducible evaluation of ANTs similarity metric
#       performance in brain image registration. NeuroImage. 2011;54(3):2033-2044. doi:10.1016/j.neuroimage.2010.09.025
# [ANTs] Tustison NJ, Cook PA, Holbrook AJ, et al. The ANTsX ecosystem for quantitative biological and medical
#       imaging. Sci Rep. 2021;11:9068. doi:10.1038/s41598-021-87564-6
