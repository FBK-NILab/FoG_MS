# Longitudinal lesion analysis: preprocessing and tract disconnection

Bash/Python scripts for the longitudinal analysis of T1w and FLAIR images with a manual
lesion segmentation drawn on the FLAIR:

- **preprocessing_pipeline/**: skull-stripped, lesion-filled synthetic T1/FLAIR images,
  a subject-specific template (SST) and the lesion masks of every session in MNI space;
- **tractogram_filt/**: disconnection of normative (HCP) streamlines and KUL_FWT bundles
  by the new lesions.

## Folder structure

```
scripts/
├── config.sh                 single configuration file (edit before running)
├── utils.sh                  helper functions shared by all bash scripts
├── templates/                MNI152 1 mm templates (from FSL)
├── preprocessing_pipeline/   00-15, run_all.sh, lib/ (REGlib.sh, used by step 14)
└── tractogram_filt/          16-24, parcellizzazione_giulia/ (lesion parcellation tool)
```

## Requirements

| Software | Used in |
|---|---|
| [FSL](https://fsl.fmrib.ox.ac.uk) 6.x | all folders |
| [ANTs](https://github.com/ANTsX/ANTs) 2.x | preprocessing |
| [FreeSurfer](https://surfer.nmr.mgh.harvard.edu) development version (≥ Oct 2025, for SuperSynth) | preprocessing, atrophy |
| [MRtrix3](https://www.mrtrix.org) | tractogram_filt |
| Python ≥ 3.10 with `numpy`, `nibabel`, `dipy`, `Pillow` (+ `parcellizzazione_giulia/requirements.txt`) | tractogram_filt |
| bash ≥ 4.4, `bc` | all folders |

The Python environment must be **activated before running** the tractogram_filt scripts
(e.g. `conda activate <env>`).

## Configuration

Edit **`config.sh`**:

| Variable | Meaning |
|---|---|
| `BIDS` | BIDS root folder; outputs are written to `$BIDS/derivatives` (`BASE`) |
| `MNI`, `MNI_MASK` | MNI152 1 mm brain and brain mask (default: `templates/`) |
| `REF_SESSION` | reference session of the longitudinal registrations (default `ses-01`) |
| `FLAIR_SYNTH_T1_SESSIONS` | sessions with a cut T1w field of view (see notes) |
| `OVERWRITE` | `0` skips outputs that already exist, `1` recomputes them |
| `TRACTO_SUBJECT`, `LESION_SES_OLD`, `LESION_SES_NEW` | subject and sessions of the disconnection analyses |
| `HCP_TCK_DIR`, `TRACTO_DIR`, `FWT_ATLAS_DIR` | HCP tractograms, tractography outputs, KUL_FWT bundle models |
| `CLUSTER_DIR`, `CLUSTERS_OLD`, `CLUSTERS_DIFF`, `PARCEL_DIR` | clustered lesion masks in MNI space and their parcellation |
| `N_JOBS` | subjects processed in parallel in script 16 |

## Input data

```
$BIDS/sub-XXX/ses-YY/anat/selected/
    sub-XXX_ses-YY_T1w.nii.gz
    sub-XXX_ses-YY_FLAIR.nii.gz
    sub-XXX_ses-YY_FLAIR_segmentation.nii.gz     # manual lesion mask, drawn on the FLAIR
```

## Running

Scripts are run in numerical order within each folder. The preprocessing can be run at once:

```bash
bash preprocessing_pipeline/run_all.sh
```

Each script loops over all subjects and sessions and skips those whose inputs are missing
(`[SKIP]` messages).

## preprocessing_pipeline

| Script | Step | Main output (in `derivatives/sub-*/ses-*/anat/`) |
|---|---|---|
| 00 | Reorientation to standard axes (images and lesion segmentation) | `process/*_reoriented.nii.gz` |
| 01 | Denoising + N4 bias field correction | `process/*_reoriented_corrected.nii.gz` |
| 02 | FLAIR → T1 rigid registration | `mat/*_flair2t1_0GenericAffine.mat` |
| 03 | Synthetic 1 mm contrasts and segmentation (SuperSynth) | `flair_super_synth/`, `t1_super_synth/` |
| 04 | FLAIR skull stripping (SynthStrip) | `*_FLAIR_stripped.nii.gz`, `process/*_FLAIR_brain_mask.nii.gz` |
| 05 | T1 skull stripping (FLAIR brain mask in T1 space) | `*_T1w_stripped.nii.gz` |
| 06 | T1 WM mask (FAST) | `process/*_T1w_WM_mask.nii.gz` |
| 07 | WM mask to FLAIR space | `process/*_FLAIR_WM_mask_transp.nii.gz` |
| 08 | Lesion segmentation onto the synthetic FLAIR grid | `*_FLAIR_segmentation_original2synth.nii.gz` |
| 09 | Lesion segmentation to T1 space | `*_T1w_segmentation_original2synth.nii.gz` |
| 10 | WM mask + lesion | `*_T1w_WM_mask_sum.nii.gz`, `*_FLAIR_WM_mask_sum.nii.gz` |
| 11 | Lesion filling | `*_T1w_filled_high_res.nii.gz`, `*_FLAIR_filled_high_res.nii.gz` |
| 12 | Rigid registration of each session to `REF_SESSION` | `*_filled_high_res_registered2ses01.nii.gz` |
| 13 | Multimodal subject-specific template (T1 + FLAIR) | `sub-*/SST/SST_template0.nii.gz` (T1), `SST_template1.nii.gz` (FLAIR) |
| 14 | SST → MNI non-linear registration (`registration_brain`) | `sub-*/SST/Reg_/SST_template0_SyN*` |

## tractogram_filt

| Script | Step |
|---|---|
| 15 | Original lesion segmentation to MNI (single resampling) | `sub-*_ses-*_segmentation_to_MNI.nii.gz` |
| 16 (+16a) | HCP streamlines crossing the new lesion only: density maps and bundle centroids, per subject |
| 17 (+17a) | Group mean density, fraction of subjects, group tractogram of the centroids |
| 17b | Pruning of the group clusters (minimum number of subjects); run manually |
| 18 | % of each KUL_FWT bundle disconnected by the new lesion |
| 19 | Assignment of the group centroids to the KUL_FWT bundles (MDF distance); run manually |
| 20 | mrview overview of the 22b results, with colour legend |
| 21 | Voxel-wise overlap between the group disconnection map and the FWT bundle maps |

## References

- **FSL**: Jenkinson M, et al. FSL. *NeuroImage*. 2012;62(2):782-790. doi:10.1016/j.neuroimage.2011.09.015
- **FSL**: Smith SM, et al. Advances in functional and structural MR image analysis and implementation as FSL. *NeuroImage*. 2004;23(Suppl 1):S208-S219. doi:10.1016/j.neuroimage.2004.07.051
- **DenoiseImage**: Manjón JV, et al. Adaptive non-local means denoising of MR images with spatially varying noise levels. *J Magn Reson Imaging*. 2010;31(1):192-203. doi:10.1002/jmri.22003
- **N4**: Tustison NJ, et al. N4ITK: improved N3 bias correction. *IEEE Trans Med Imaging*. 2010;29(6):1310-1320. doi:10.1109/TMI.2010.2046908
- **ANTs**: Avants BB, et al. A reproducible evaluation of ANTs similarity metric performance in brain image registration. *NeuroImage*. 2011;54(3):2033-2044. doi:10.1016/j.neuroimage.2010.09.025
- **ANTs**: Tustison NJ, et al. The ANTsX ecosystem for quantitative biological and medical imaging. *Sci Rep*. 2021;11:9068. doi:10.1038/s41598-021-87564-6
- **SyN**: Avants BB, et al. Symmetric diffeomorphic image registration with cross-correlation: evaluating automated labeling of elderly and neurodegenerative brain. *Med Image Anal*. 2008;12(1):26-41. doi:10.1016/j.media.2007.06.004
- **SST**: Avants BB, et al. The optimal template effect in hippocampus studies of diseased populations. *NeuroImage*. 2010;49(3):2457-2466. doi:10.1016/j.neuroimage.2009.09.062
- **SuperSynth** (no dedicated paper yet; citations requested by the FreeSurfer wiki):
  - Billot B, et al. SynthSeg: Segmentation of brain MRI scans of any contrast and resolution without retraining. *Med Image Anal*. 2023;86:102789. doi:10.1016/j.media.2023.102789
  - Iglesias JE, et al. SynthSR: A public AI tool to turn heterogeneous clinical brain scans into high-resolution T1-weighted images for 3D morphometry. *Sci Adv*. 2023;9(5):eadd3607. doi:10.1126/sciadv.add3607
- **FreeSurfer**: Fischl B. FreeSurfer. *NeuroImage*. 2012;62(2):774-781. doi:10.1016/j.neuroimage.2012.01.021
- **SynthStrip**: Hoopes A, et al. SynthStrip: skull-stripping for any brain image. *NeuroImage*. 2022;260:119474. doi:10.1016/j.neuroimage.2022.119474
- **FAST**: Zhang Y, Brady M, Smith S. Segmentation of brain MR images through a hidden Markov random field model and the expectation-maximization algorithm. *IEEE Trans Med Imaging*. 2001;20(1):45-57. doi:10.1109/42.906424
- **lesion_filling**: Battaglini M, Jenkinson M, De Stefano N. Evaluating and reducing the impact of white matter lesions on brain volume measurements. *Hum Brain Mapp*. 2012;33(9):2062-2071. doi:10.1002/hbm.21344
- **FLIRT**: Jenkinson M, Smith S. A global optimisation method for robust affine registration of brain images. *Med Image Anal*. 2001;5(2):143-156. doi:10.1016/S1361-8415(01)00036-6
- **FLIRT**: Jenkinson M, et al. Improved optimization for the robust and accurate linear registration and motion correction of brain images. *NeuroImage*. 2002;17(2):825-841. doi:10.1006/nimg.2002.1132
- **MNI152 template**: Grabner G, et al. Symmetric atlasing and model based segmentation: an application to the hippocampus in older adults. *MICCAI 2006*, LNCS 4191:58-66. doi:10.1007/11866763_8
- **MRtrix3**: Tournier JD, et al. MRtrix3: A fast, flexible and open software framework for medical image processing and visualisation. *NeuroImage*. 2019;202:116137. doi:10.1016/j.neuroimage.2019.116137
- **Track-density imaging**: Calamante F, et al. Track-density imaging (TDI): super-resolution white matter imaging using whole-brain track-density mapping. *NeuroImage*. 2010;53(4):1233-1243. doi:10.1016/j.neuroimage.2010.07.024
- **QuickBundles / MDF**: Garyfallidis E, et al. QuickBundles, a method for tractography simplification. *Front Neurosci*. 2012;6:175. doi:10.3389/fnins.2012.00175
- **DIPY**: Garyfallidis E, et al. Dipy, a library for the analysis of diffusion MRI data. *Front Neuroinform*. 2014;8:8. doi:10.3389/fninf.2014.00008
- **KUL_FWT atlas**: Radwan AM, et al. An atlas of white matter anatomy, its variability, and reproducibility based on constrained spherical deconvolution of diffusion MRI. *NeuroImage*. 2022;254:119029. doi:10.1016/j.neuroimage.2022.119029
- **HCP**: Van Essen DC, et al. The WU-Minn Human Connectome Project: an overview. *NeuroImage*. 2013;80:62-79. doi:10.1016/j.neuroimage.2013.05.041
- **brainlife.io**: Hayashi S, et al. brainlife.io: a decentralized and open-source cloud platform to support neuroscience research. *Nat Methods*. 2024;21(5):809-813. doi:10.1038/s41592-024-02237-2
