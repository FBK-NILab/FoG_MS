#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"     # BASE, MNI
source "$SCRIPT_DIR/../utils.sh"      # first_match

#-------------------------------------------------------------------------------------------------------------------------------------
#SCRIPT: brings the original lesion mask from original FLAIR space to original T1 space (needed only when the T1 SST is chosen), then to synthetic space (minimal transform), registers everything to the SST and finally to MNI, in a single call.
#STEP 1 --> transform from FLAIR to T1w space (needed only if template0 is used as reference instead of template1)
#STEP 2 --> from original T1w space to synthetic T1 space
  #!! steps 1 and 2 are applied only to sessions 1 to 5. The synthetic images of sessions 6 and 7 are in FLAIR space, like the segmentations, so for them the transform already computed at step 08 is applied
#STEP 3 --> register everything to the SST (non-linear)
#STEP 4 --> non-linear registration to MNI
#STEP 5 --> apply all the transforms in a single call
#------------------------------------------------------------------------------------------------------------------------------------


#STEP 1 --> transform already computed, applied at the end in the single call

#STEP 2 --> compute the transform from original T1w space to synthetic T1 space
function original2synth {
    local original="$1" #/process/*_reoriented_corrected.nii.gz
    local synth="$2"    #/*_super_synth/*_SynthT1.nii.gz

    local anat_folder mat_folder file_name out_prefix
    anat_folder=$(dirname "$(dirname "$original")")
    mat_folder="${anat_folder}/mat"
    file_name=$(basename "$original" "_reoriented_corrected.nii.gz")
    out_prefix="${mat_folder}/${file_name}_original2synth_"    
        
    antsRegistration \
        --dimensionality 3 \
        --float 0 \
        --output ["$out_prefix","${out_prefix}Warped.nii.gz"] \
        --interpolation Linear \
        --winsorize-image-intensities [0.005,0.995] \
        --use-histogram-matching 0 \
        --initial-moving-transform ["$synth","$original",1] \
        --transform Rigid[0.1] \
        --metric MI["$synth","$original",1,32,Regular,0.25] \
        --convergence [1000x500x250x100,1e-6,10] \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox \
        --collapse-output-transforms 1 
}

#STEP 3 --> registration to the SST
function ses2SST {
    local stripped="$1" #stripped synthetic T1 image

    local anat_folder mat_folder file_name out_prefix
    anat_folder=$(dirname "$stripped")
    mat_folder="${anat_folder}/mat"
    file_name=$(basename "$stripped" "_stripped.nii.gz")
    out_prefix="${mat_folder}/${file_name}_ses2SST_"

    if [ ! -f "$SST" ]; then
        echo "[SKIP] SST not available"
        return
    fi
        antsRegistration \
        --dimensionality 3 \
        --float 0 \
        --output ["$out_prefix","${out_prefix}Warped.nii.gz"] \
        --interpolation Linear \
        --winsorize-image-intensities [0.005,0.995] \
        --use-histogram-matching 0 \
        --initial-moving-transform ["$SST","$stripped",1] \
        --transform Rigid[0.1] \
        --metric MI["$SST","$stripped",1,32,Regular,0.25] \
        --convergence [1000x500x250x100,1e-6,10] \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox \
        --transform Affine[0.1] \
        --metric MI["$SST","$stripped",1,32,Regular,0.25] \
        --convergence [1000x500x250x100,1e-6,10] \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox \
        --transform SyN[0.1,3,0] \
        --metric CC["$SST","$stripped",1,4] \
        --convergence [100x70x50x20,1e-6,10] \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox \
        --collapse-output-transforms 1
}


#STEP 4 --> transform already computed, applied at the end in the single call


#STEP 5 --> apply all the transforms
function transform {
    local sub="$1"
    local ses="$2"
    local segmentation="$3"
    shift 3

    local process_folder anat_folder output_name
    process_folder=$(dirname "$segmentation")
    anat_folder=$(dirname "$process_folder")
    output_name="${anat_folder}/${sub}_${ses}_segmentation_to_MNI.nii.gz"

    echo "$@"
    antsApplyTransforms -d 3 \
        -i "$segmentation" \
        -r "$MNI" \
        -n GenericLabel \
        -o "$output_name" \
        "$@"
}





##########################SCRIPT STARTS HERE##################################

for d in "$BASE"/sub-*/ses-0*/anat; do
    ses=$(basename "$(dirname "$d")")
    sub=$(basename  "$(dirname "$(dirname "$d")")")
    echo "########################################"
    echo "[RUN] --> $sub $ses"

    #SST of the subject (T1 component) and its transforms to MNI (scripts 13 and 14)
    SST="$BASE/$sub/SST/SST_template0.nii.gz"
    SST2MNI_warp="$BASE/$sub/SST/Reg_/SST_template0_SyN1Warp.nii.gz"
    SST2MNI_affine="$BASE/$sub/SST/Reg_/SST_template0_SyN0GenericAffine.mat"
    if [ ! -f "$SST2MNI_warp" ] || [ ! -f "$SST2MNI_affine" ]; then
        echo "[SKIP] $sub -> SST to MNI transforms missing"
        continue
    fi
    
    #retrieve the files needed for the steps...

    segmentation=$(first_match "$d"/process/*_FLAIR_segmentation_reoriented.nii.gz) #original segmentation in FLAIR space
    if [ -z "$segmentation" ] ; then
	   echo "[SKIP] $d -> missing: the segmentation"
	   continue 
    fi

    if [[ "$ses" == ses-0[67] ]]; then #the selected SynthT1 images are in FLAIR space, so the FLAIR_original2synth transform is applied
	FLAIRoriginal2synth=$(first_match "$d"/mat/*_FLAIR_original2synth_0GenericAffine.mat)
	if [ -z "$FLAIRoriginal2synth" ]; then
	   echo "[SKIP] $d -> missing: the FLAIR original2synth transform"
	   continue 
	fi
	bottom=( -t "$FLAIRoriginal2synth" )
       else #for the other sessions the SynthT1 images are in T1 space, so FLAIR-->T1 and then T1_original2synth are applied
	   
   #1 --> transform from FLAIR to T1:
       flair2t1mat=$(first_match "$d"/mat/*_flair2t1_0GenericAffine.mat)
       if [ -z "$flair2t1mat" ] ; then
	   echo "[SKIP] $d -> missing: the flair2t1 transform"
	   continue 
       fi

   #2 --> transform from original T1 to synthetic T1:
       original_t1=$(first_match "$d"/process/*_T1w_reoriented_corrected.nii.gz)
       synth_t1=$(first_match "$d"/t1_super_synth/t1_SynthT1.nii.gz)

       if [ -z "$original_t1" ] || [ -z "$synth_t1" ]; then
	   echo "[SKIP] $d -> missing: the original or the synthetic T1"
	   continue 
       fi

       echo "COMPUTING TRANSFORM: ORIGINAL --> SYNTH"
       original2synth "$original_t1" "$synth_t1"

       #retrieve the output of original2synth, needed for step 5
       t1orig2synth=$(first_match "$d"/mat/*_T1w_original2synth_0GenericAffine.mat)
       if [ -z "$t1orig2synth" ]; then
	   echo "[SKIP] $d -> missing: the T1 original2synth transform"
	   continue
       fi
       bottom=( -t "$t1orig2synth" -t "$flair2t1mat" )
    fi
       

  #3 --> registration to the SST

    stripped=$(first_match "$d"/*_T1w_stripped.nii.gz)
    if [ -z "$stripped" ]; then
        echo "[SKIP] $d -> missing: the stripped synthetic T1"
        continue
    fi

    echo "COMPUTING TRANSFORM: $ses --> SST"
    ses2SST "$stripped"

    #retrieve the output of ses2SST, needed for step 5
    ses2SST_mat=$(first_match "$d"/mat/*_ses2SST_0GenericAffine.mat)
    ses2SST_warp=$(first_match "$d"/mat/*_ses2SST_1Warp.nii.gz)
    if [ -z "$ses2SST_mat" ] || [ -z "$ses2SST_warp" ] ; then
        echo "[SKIP] $d -> missing: the ses2SST transform or warp"
        continue
    fi


  #4 --> registration to MNI:
    #taken at the beginning of the loop (per subject)
    

  #5 --> apply the transforms
    echo "APPLYING THE TRANSFORMS"
    transform "$sub" "$ses" "$segmentation" \
	-t "$SST2MNI_warp" \
        -t "$SST2MNI_affine" \
	-t "$ses2SST_warp" \
        -t "$ses2SST_mat" \
        "${bottom[@]}"

done
