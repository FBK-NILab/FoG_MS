#!/bin/bash
# =============================================================================
# config.sh
# PURPOSE: Single configuration file for the whole project (preprocessing and
#          analyses). Edit the paths below before running any script.
# =============================================================================

# Folder containing this file (the project root): used to locate scripts and templates
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################## PREPROCESSING (00-14) ##############################

# BIDS root folder (raw data). Script 00 reads the selected images from
# $BIDS/sub-*/ses-*/anat/selected/
BIDS="/path/to/bids"

# Derivatives folder: every output of the preprocessing is written here.
BASE="$BIDS/derivatives"

# MNI152 1 mm templates (included in templates/, from FSL).
MNI="$PROJECT_DIR/templates/MNI152_T1_1mm_brain.nii.gz"
MNI_MASK="$PROJECT_DIR/templates/MNI152_T1_1mm_brain_mask.nii.gz"

# Reference session: all the other sessions are registered to this one.
REF_SESSION="ses-01"

# Sessions in which the T1w field of view cuts part of the brain.
# For these sessions the synthetic T1 generated from the FLAIR (flair_SynthT1)
# is used instead of the one generated from the T1w, so T1 and FLAIR share the
# same (FLAIR) space and no FLAIR-to-T1 transform is needed.
FLAIR_SYNTH_T1_SESSIONS=(ses-06 ses-07)

# Set to 1 to recompute outputs that already exist (default: skip them).
OVERWRITE=0

############################## TRACTOGRAM FILTERING (15-21) ##############################

# Subject and sessions compared in the disconnection analyses:
# streamlines crossing the lesion of LESION_SES_NEW but not that of LESION_SES_OLD.
TRACTO_SUBJECT="sub-001"
LESION_SES_OLD="ses-01"
LESION_SES_NEW="ses-03"

# Normative tractograms (HCP subjects, one .tck per subject in <dir>/sub*/)
HCP_TCK_DIR="/path/to/HCP_TCK_Brainlife"

# Output folder of the tractogram filtering analyses
TRACTO_DIR="/path/to/tractography_analysis_dev"

# KUL_FWT bundle models (.tck), in MNI space
FWT_ATLAS_DIR="/path/to/KUL_FWT/KUL_FWT_templates/TCK_models"

# Clustered lesion masks in MNI space (input of scripts 18-21)
CLUSTER_DIR="/path/to/lesion_diff_clustering"
#   lesions of LESION_SES_OLD
CLUSTERS_OLD="$CLUSTER_DIR/${TRACTO_SUBJECT}_${LESION_SES_OLD}_segmentation_to_MNI_min14_clustered_06.nii.gz"
#   new lesions of LESION_SES_NEW (not present in LESION_SES_OLD)
CLUSTERS_DIFF="$CLUSTER_DIR/${TRACTO_SUBJECT}_${LESION_SES_NEW}_segmentation_to_MNI_diff_min14_clustered_06.nii.gz"

# Output folder of the lesion parcellation (scripts 18a/18b, read by 19a/19b)
PARCEL_DIR="$PROJECT_DIR/tractogram_filt/parcellizzazione_giulia/outputs"

# Number of subjects processed in parallel (script 16)
N_JOBS=7
