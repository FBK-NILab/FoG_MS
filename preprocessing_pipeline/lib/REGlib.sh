#!/usr/bin/env bash
#########################################################################################################################
#   title:        Registration library
#   description:  Functions for registration of brain imaging data (ANTs + FSL).
#   version:      0.4.0   (modernized for Ubuntu 24.04+, GNU bash 5.x, ANTs 2.6.x, FSL 6.x)
#   notes:        Install ANTs and FSL to use this library.
#                 needs STRlib.sh, FILESlib.sh, IMAGINGlib.sh, CPUlib.sh
#   author:       gamorosino  (modernization pass 2026)
#   email:        g.amorosino@gmail.com
#
#   Changelog (0.3.5.6 -> 0.4.0)
#     * FIXED syntax error present in every extension check:
#         `if ( [ ... ] || [ "${extem}" == "nii" );`  had no closing `]`.
#       Replaced all of them with a single helper `_reg_strip_known_ext`.
#     * FIXED interpolation tables: tested for the typo "BSline" (never matched) and mixed the
#         default between "Bspline"/"NN"; ANTs also wants "BSpline" (capital S). Interp names are
#         now normalized case-insensitively via `_reg_norm_interp` and validated.
#     * FIXED verbose handling: the old `reg_n_warp_brain` added `-v` only when the user asked to
#         turn verbosity OFF (inverted test). Verbosity is now a single, correct `-v 0/1` flag.
#     * REMOVED the obsolete `== "2.1.0-g78931"` version gate. Verbosity no longer depends on a
#         hard-coded ANTs build string. ANTs 2.6.x is assumed; the legacy WarpImageMultiTransform
#         path in warp_image is kept but clearly guarded (it is never taken when antsApplyTransforms
#         is on PATH, which it always is in ANTs 2.x).
#     * FIXED `warp_image` long option `--interp=*` writing to a misspelled var (inteprolation).
#     * FIXED `reg_n_warp_brain`: duplicate/unreachable `--timeseries` case and the missing `shift`
#         on `-g|--res-def`.
#     * Quoted expansions throughout; invalid `return -1` avoided; diagnostics kept on stdout as
#         before but option-parse warnings go to stderr so they cannot corrupt captured values.
#     * `ANTSPATH`-independent: uses `command -v` to locate binaries.
#     * FIXED the -s 3 preset iteration values: its=10000x111110x11110 (an apparent typo, out of
#         family with every other iteration value in the file) -> 10000x10000x10000, giving the
#         clean progression  -s2: two levels / -s3: three levels / -s4: three levels + heavier
#         smoothing. Nonlinear SyN levels are unchanged (100x100x30).
#     * FIXED "Invalid flag provided l": removed the stray `-l 1` from all four antsRegistration
#         stage strings. `-l` (--use-estimate-learning-rate-once) is not a valid flag in current
#         antsRegistration (it was a legacy `ANTS`/old-build option); ANTs 2.6.5 rejected it once per
#         stage (hence four identical errors). Removal restores the modern default (learning rate is
#         estimated per level); no other behavioural change.
#
#   Compatibility note: public function names and their option flags are unchanged, so existing
#   callers keep working. The only behavioural change is that broken paths now actually work.
#########################################################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/STRlib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/FILESlib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/IMAGINGlib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/CPUlib.sh"

# --- include guard ------------------------------------------------------------------------------------------------
[ -n "${__REGLIB_SOURCED:-}" ] && return 0
__REGLIB_SOURCED=1

#########################################################################################################################
# Internal helpers
#########################################################################################################################

_reg_strip_known_ext() {
        # Basename of an image with .nii / .nii.gz removed. Replaces the broken inline
        # `if ( [ "$extem" == "gz" ] || [ "$extem" == "nii" );` blocks.
        # usage: _reg_strip_known_ext <path>
        local path="$1" base
        base="$( basename "$path" )"
        case "$base" in
            *.nii.gz) echo "${base%.nii.gz}" ;;
            *.nii)    echo "${base%.nii}" ;;
            *)        echo "${base%%.*}" ;;   # FSL-style fbasename fallback
        esac
}

_reg_norm_interp() {
        # Normalize an interpolation name (case-insensitive) to the ANTs spelling, or "" if invalid.
        # Accepts: linear, nn/nearestneighbor, bspline, ml/multilabel, gaussian, genericlabel, lanczos...
        # usage: _reg_norm_interp <name>
        local in; in="$( printf '%s' "$1" | tr '[:upper:]' '[:lower:]' )"
        case "$in" in
            linear)                     echo "Linear" ;;
            nn|nearestneighbor)         echo "NearestNeighbor" ;;
            bspline)                    echo "BSpline" ;;
            ml|multilabel)              echo "MultiLabel" ;;
            gaussian)                   echo "Gaussian" ;;
            genericlabel)               echo "GenericLabel" ;;
            cosinewindowedsinc|lanczos) echo "LanczosWindowedSinc" ;;
            *)                          echo "" ;;
        esac
}

_reg_have() { command -v "$1" >/dev/null 2>&1; }

_reg_remove_ext() {
        # Prefer FSL's remove_ext when available, else strip .nii/.nii.gz ourselves.
        if _reg_have remove_ext; then remove_ext "$1"; else
            case "$1" in
                *.nii.gz) echo "${1%.nii.gz}" ;;
                *.nii)    echo "${1%.nii}" ;;
                *)        echo "${1%.*}" ;;
            esac
        fi
}

#########################################################################################################################
registration_brain() {
#########################################################################################################################

    _rb_usage() {
        cat >&2 <<'USAGE'

    Usage:  registration_brain <moving_image.ext> <fixed_image.ext> [ Options ]

    Main arguments:
       moving_image     Image to be registered to the reference image
       fixed_image      Reference image

    Options:
       -o, --outputdir   Directory for registration outputs (warp field, affine mat, warped image).
                         Default: a 'Reg_' folder beside the moving image.
       -s, --settings    antsRegistration preset: 1 test / 2 fast / 3 balanced / 4 best (default) / 4+
       --timeseries      Moving image is a 4D time-series: estimate on the mean volume, apply to all.
       --no-transl       Disable translation stage
       --no-rigid        Disable rigid stage
       --no-affine       Disable affine stage
       --no-nonlin       Disable non-linear stage
       -i, --interp      linear | NN | BSpline | ML | Gaussian | GenericLabel   (default BSpline)
       -c, --CPUs        Cores for multithreading (default 2, or 'auto')
    Advanced:
       -x, --masks       [fixedImageMask,movingImageMask]
       -m, --metrics     ANTs-style metric list for the non-linear stage
       -w, --winsorize   [lowerQuantile,upperQuantile]
       -g, --res-def     Restrict displacement-field optimization per component (e.g. 1x1x0.2)
    Other:
       -h, --help        Show this help
       -v, --no-verbose  Turn off verbose output

    Example:
       registration_brain moving.nii.gz fixed.nii.gz -s 3 -c auto --no-transl
USAGE
    }

    #----------------------------------------------------------------- Input parsing
    local m="${1}" f="${2}"
    local m_reg="${m}"
    local nargs=$#

    # defaults
    local transl=1 rigid=1 affine=1 nonlin=1 timeseries=0 interp="BSpline" verbose_=1
    local regPath cpu_num settings interp_in masks metrics winsorize resdef

    [[ "$1" == "-h" || "$1" == "--help" ]] && { _rb_usage; return 0; }

    while [[ $# -gt 0 ]]; do
        local key="$3"
        case "$key" in
            -h|--help)         _rb_usage; return 0 ;;
            -o|--outputdir)    shift; regPath="$3";      (( nargs-- )) ;;
            --outputdir=*)     regPath="${key#*=}" ;;
            -c|--CPUs)         shift; cpu_num="$3";       (( nargs-- )) ;;
            --CPUs=*)          cpu_num="${key#*=}" ;;
            -s|--settings)     shift; settings="$3";      (( nargs-- )) ;;
            --settings=*)      settings="${key#*=}" ;;
            -i|--interp)       shift; interp_in="$3";     (( nargs-- )) ;;
            --interp=*)        interp_in="${key#*=}" ;;
            -x|--masks)        shift; masks="$3";         (( nargs-- )) ;;
            --masks=*)         masks="${key#*=}" ;;
            -m|--metrics)      shift; metrics="$3";       (( nargs-- )) ;;
            --metrics=*)       metrics="${key#*=}" ;;
            -w|--winsorize)    shift; winsorize="$3";     (( nargs-- )) ;;
            --winsorize=*)     winsorize="${key#*=}" ;;
            -g|--res-def)      shift; resdef="$3";        (( nargs-- )) ;;
            --res-def=*)       resdef="${key#*=}" ;;
            --timeseries)      timeseries=1 ;;
            --no-transl)       transl=0 ;;
            --no-rigid)        rigid=0 ;;
            --no-affine)       affine=0 ;;
            --no-nonlin)       nonlin=0 ;;
            -v|--no-verbose)   verbose_=0 ;;
            *)                 [ -n "$key" ] && echo "Unknown option '$key'" >&2 ;;
        esac
        shift
    done

    [ "$nargs" -lt 2 ] && { _rb_usage; return 1; }

    [ -z "$regPath" ]  && regPath="$(dirname "$m")/Reg_"
    mkdir -p "$regPath"
    [ -z "$settings" ] && settings=4
    [ "$cpu_num" = "auto" ] && cpu_num="$( CPUs_available )"
    [ -z "$cpu_num" ] && cpu_num=2

    # interpolation
    if [ -n "$interp_in" ]; then
        local norm; norm="$( _reg_norm_interp "$interp_in" )"
        [ -z "$norm" ] && { echo "Unknown interpolation '$interp_in'" >&2; return 1; }
        interp="$norm"
    fi

    echo "regPath:  $regPath"
    echo "cpu_num:  $cpu_num"
    echo "settings: $settings"
    echo "interp:   $interp"

    setITKthreads "$cpu_num"
    echo "number of cores for multithreading: $ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS"

    local dimf dimm dim
    dimf="$( imm_dim "$f" )"; echo "fixed image dimension:  $dimf"
    dimm="$( imm_dim "$m" )"; echo "moving image dimension: $dimm"

    if [ "$timeseries" -eq 1 ]; then
        if [ "$dimm" -eq 4 ]; then
            local m_mean; m_mean="$( _reg_remove_ext "$m" )_mean.nii.gz"
            fslmaths "$m" -Tmean "$m_mean"; m="$m_mean"
        else
            echo "wrong moving image dimension" >&2; return 1
        fi
        if [ "$dimf" -eq 4 ]; then
            local f_mean; f_mean="$( _reg_remove_ext "$f" )_mean.nii.gz"
            fslmaths "$f" -Tmean "$f_mean"; f="$f_mean"
        elif [ "$dimf" -ne 3 ]; then
            echo "wrong fixed image dimension" >&2; return 1
        fi
        dim=3
    else
        [ "$dimm" -ne "$dimf" ] && echo "WARNING: the dimension of the images is different" >&2
        dim="$dimf"
    fi

    #----------------------------------------------------------------- Main
    local thresold="1.e-8"
    local diffeo="SyN[0.25]"
    local reg="antsRegistration"
    local nm2; nm2="$( _reg_strip_known_ext "$m_reg" )"

    local its percentage syn sigma shrink sigma_lin shrink0 shrink_lin
    case "$settings" in
        1)  echo "one level"
            its=10000x0x0;        percentage=0.1; syn="100x0x0,0,5"
            sigma=1x0.5x0vox;     shrink=4x2x1;   sigma_lin=4x2x1vox; shrink0=6x4x2; shrink_lin=3x2x1 ;;
        2)  echo "two levels"
            its=10000x10000x0;    percentage=0.3; syn="100x100x0,-0.01,5"
            sigma=1x0.5x0vox;     shrink=4x2x1;   sigma_lin=4x2x1vox; shrink0=6x4x2; shrink_lin=3x2x1 ;;
        3)  echo "three levels"
            its=10000x10000x10000; percentage=0.3; syn="100x100x30,-0.01,5"
            sigma=1x0.5x0vox;     shrink=4x2x1;   sigma_lin=4x2x1vox; shrink0=6x4x2; shrink_lin=3x2x1 ;;
        4)  echo "four levels"
            its=10000x10000x10000; percentage=0.3; syn="100x80x50x20,${thresold},10"
            sigma=2x1x0.5x0vox;   shrink=8x4x2x1; sigma_lin=4x2x1vox; shrink0=6x4x2; shrink_lin=3x2x1 ;;
        4+) echo "four levels (all)"
            its=10000x10000x10000x10000; percentage=0.3; syn="100x80x50x20,${thresold},10"
            sigma=2x1x0.5x0vox;   shrink=8x4x2x1; sigma_lin=8x4x2x1vox; shrink0=12x6x4x2; shrink_lin=6x3x2x1 ;;
        *)  echo "invalid setting '$settings'" >&2; return 1 ;;
    esac

    local stage3=""
    if [ "$nonlin" -eq 1 ]; then
        if [ -z "$metrics" ]; then
            metrics="mattes[ $f, $m , 0.5 , 32 ] -m cc[ $f, $m , 0.5 , 4 ]"
            echo "use default metrics (non-linear stage):"
            echo "  $metrics"
        else
            metrics="${metrics// /}"
            metrics="${metrics//],/] -m }"
            metrics="${metrics:1:${#metrics}-2}"
            echo "use metrics (non-linear stage):"
            echo "  $metrics"
        fi
        stage3="-m ${metrics}   -c [ $syn ]  -t $diffeo -s $sigma -f $shrink -u 1 -z 1"
        [ -n "$resdef" ] && stage3="${stage3} -g ${resdef} "
    fi

    local stage0="-m mattes[ $f, $m , 1 , 32, regular, $percentage ] -t translation[ 0.1 ] -c [$its,$thresold,20] -u 1 -s $shrink_lin -f $shrink0"
    local stage1="-m mattes[ $f, $m , 1 , 32, regular, $percentage ] -t rigid[ 0.1 ]       -c [$its,$thresold,20] -u 1 -s $shrink_lin -f $shrink_lin"
    local stage2="-m mattes[ $f, $m , 1 , 32, regular, $percentage ] -t affine[ 0.1 ]      -c [$its,$thresold,20] -u 1 -s $shrink_lin -f $shrink_lin"

    local diffeopost=""
    [ "$transl" -eq 0 ] && stage0='' || diffeopost="trasl"
    [ "$rigid"  -eq 0 ] && stage1='' || diffeopost="rigid"
    [ "$affine" -eq 0 ] && stage2='' || diffeopost="affine"
    [ "$nonlin" -eq 0 ] && stage3='' || diffeopost="$( echo "$diffeo" | cut -d '[' -f1 )"

    local reg_command1=" -v $verbose_ "

    if [ -n "$masks" ]; then
        stage0="${stage0} -x [NULL,NULL]"
        stage1="${stage1} -x [NULL,NULL]"
        stage2="${stage2} -x [NULL,NULL]"
        stage3="${stage3} -x ${masks} "
    fi

    local ref_command_w=""
    [ -n "$winsorize" ] && ref_command_w="-w ${winsorize}"

    local nm="${nm2}_${diffeopost}"
    set -f
    $reg -d "$dim" -r [ "$f", "$m" ,1] --float 1 $reg_command1 \
         $stage0 $stage1 $stage2 $stage3 $ref_command_w \
         -o [${regPath}/${nm},${regPath}/${nm}_diff.nii.gz,${regPath}/${nm}_inv.nii.gz]
    set +f

    local input_type=0
    { [ "$dimm" -eq 4 ] && [ "$timeseries" -eq 1 ]; } && input_type=3

    if [ "$nonlin" -eq 1 ]; then
        antsApplyTransforms -d "$dim" -i "$m_reg" -r "$f" \
            -t "${regPath}/${nm}1Warp.nii.gz" -t "${regPath}/${nm}0GenericAffine.mat" \
            -o "${regPath}/${nm}_warped.nii.gz" -v "$verbose_" -n "$interp" -e "$input_type"
    else
        antsApplyTransforms -d "$dim" -i "$m_reg" -r "$f" \
            -t "${regPath}/${nm}0GenericAffine.mat" \
            -o "${regPath}/${nm}_warped.nii.gz" -v "$verbose_" -n "$interp" -e "$input_type"
    fi
}

#########################################################################################################################
warp_image() {
#########################################################################################################################

    _wi_usage() {
        cat >&2 <<'USAGE'

    Usage:  warp_image <moving_image.ext> <image_to_warp.ext> [ Options ]

    Main arguments:
       moving_image     Image whose space defines where image_to_warp is sent
       image_to_warp    Image to be warped

    Options:
       -r, --reg-dir     Directory holding the registration outputs (default: 'Reg_' beside moving).
       -t, --reg-transf  Last transform stage used (trasl | rigid | affine | BSplineSyN | SyN). Default SyN.
       -o, --out-image   Output warped image (default: 'Warped_' beside moving image).
       -i, --interp      linear | NN | BSpline | ML | Gaussian | GenericLabel   (default NN)
       -f, --warp-forward  Warp moving->reference (image_to_warp assumed in moving space)
       -m, --ref-image   Reference image defining the output grid (default: moving image)
       --timeseries      image_to_warp is a time-series
       -h, --help        Show this help
       -v, --no-verbose  Turn off verbose output

    Example:
       warp_image moving.nii.gz ref.nii.gz -t BSplineSyN
USAGE
    }

    #----------------------------------------------------------------- Input parsing
    local image_out="${1}" mask_rif="${2}"
    local nargs=$#

    # defaults
    local timeseries=0 interpolation="NN" useInverse=1 verbose_=1
    local diffeopost mask_out regPath ref_image

    [[ "$1" == "-h" || "$1" == "--help" ]] && { _wi_usage; return 0; }

    while [[ $# -gt 0 ]]; do
        local key="$3"
        case "$key" in
            -h|--help)          _wi_usage; return 0 ;;
            -t|--reg-transf)    shift; diffeopost="$3";    (( nargs-- )) ;;
            --reg-transf=*)     diffeopost="${key#*=}" ;;
            -o|--out-image)     shift; mask_out="$3";      (( nargs-- )) ;;
            --out-image=*)      mask_out="${key#*=}" ;;
            -r|--reg-dir)       shift; regPath="$3";       (( nargs-- )) ;;
            --reg-dir=*)        regPath="${key#*=}" ;;
            -i|--interp)        shift; interpolation="$3"; (( nargs-- )) ;;
            --interp=*)         interpolation="${key#*=}" ;;   # FIXED: was writing to 'inteprolation'
            --timeseries)       timeseries=1 ;;
            -f|--warp-forward)  useInverse=0 ;;
            -m|--ref-image)     shift; ref_image="$3";     (( nargs-- )) ;;
            --ref-image=*)      ref_image="${key#*=}" ;;
            -v|--no-verbose)    verbose_=0 ;;
            *)                  [ -n "$key" ] && echo "Unknown option '$key'" >&2 ;;
        esac
        shift
    done

    [ "$nargs" -lt 2 ] && { _wi_usage; return 1; }

    local default_reg_dir="Reg_"
    [ -z "$diffeopost" ] && diffeopost="SyN"

    #----------------------------------------------------------------- Main
    local mask_name Image_name
    mask_name="$( _reg_strip_known_ext "$mask_rif" )"
    Image_name="$( _reg_strip_known_ext "$image_out" )"

    local nm="${Image_name}_${diffeopost}"

    local warpPath
    if [ -z "$mask_out" ]; then
        warpPath="$(dirname "$image_out")/Warped_"
        mask_out="${warpPath}/${mask_name}_${nm}_warped.nii.gz"
        mkdir -p "$warpPath"
    else
        warpPath="$(dirname "$mask_out")"
        mkdir -p "$warpPath"
    fi

    [ -z "$regPath" ] && regPath="$(dirname "$image_out")/${default_reg_dir}/"

    local campo="${regPath}/${nm}1InverseWarp.nii.gz"
    local dcampo="${regPath}/${nm}1Warp.nii.gz"
    local mat_aff="${regPath}/${nm}0GenericAffine.mat"

    # interpolation -> apply flag
    local apply_interp
    apply_interp="$( _reg_norm_interp "$interpolation" )"
    [ -z "$apply_interp" ] && { echo "Unknown interpolation '$interpolation'" >&2; return 1; }
    local apply_command0=" --interpolation ${apply_interp} "

    [ "$useInverse" -eq 0 ] && campo="$dcampo"

    if [ "$timeseries" -eq 1 ]; then
        local m_mean; m_mean="$( _reg_remove_ext "$image_out" )_mean.nii.gz"
        fslmaths "$image_out" -Tmean "$m_mean"; image_out="$m_mean"
    fi

    local mask_size warp_type
    mask_size=( $( imm_size "$mask_rif" "space" ) )
    if [ -z "${mask_size[3]:-}" ]; then warp_type=0; else warp_type=3; fi

    if [ -n "$ref_image" ]; then
        image_out="$ref_image"
    elif [ "$useInverse" -eq 0 ]; then
        image_out="${regPath}/${nm}_warped.nii.gz"
    fi

    # ANTs 2.x path (antsApplyTransforms is always present). Legacy WarpImageMultiTransform
    # path retained only as a guarded fallback for pre-2.x installs.
    if _reg_have antsApplyTransforms; then
        if [ "$diffeopost" = "SyN" ] || [ "$diffeopost" = "BSplineSyN" ]; then
            antsApplyTransforms -d 3 -r "$image_out" -o "$mask_out" -i "$mask_rif" \
                -t "$campo" -t [${mat_aff},${useInverse}] $apply_command0 -e "$warp_type" -v "$verbose_"
        else
            antsApplyTransforms -d 3 -r "$image_out" -o "$mask_out" -i "$mask_rif" \
                -t [${mat_aff},${useInverse}] $apply_command0 -e "$warp_type" -v "$verbose_"
        fi
    elif _reg_have WarpImageMultiTransform; then
        echo "WARNING: falling back to legacy WarpImageMultiTransform (pre-ANTs-2.x)" >&2
        local warp_command0="" warp_commad1=""
        case "$apply_interp" in
            NearestNeighbor) warp_command0="--use-NN" ;;
            BSpline)         warp_command0="--use-BSpline" ;;
            MultiLabel)      warp_command0="--use-ML 0.5x0.5x0.5vox" ;;
        esac
        [ "$useInverse" -eq 1 ] && warp_commad1=" -i "
        if [ -z "${mask_size[3]:-}" ]; then
            if [ "$diffeopost" = "SyN" ] || [ "$diffeopost" = "BSplineSyN" ]; then
                WarpImageMultiTransform 3 "$mask_rif" "$mask_out" -R "$image_out" $warp_command0 $warp_commad1 "$mat_aff" "$campo"
            else
                WarpImageMultiTransform 3 "$mask_rif" "$mask_out" -R "$image_out" $warp_command0 $warp_commad1 "$mat_aff"
            fi
        else
            echo "4D warp not implemented for the legacy ANTs path" >&2
            return 1
        fi
    else
        echo "Neither antsApplyTransforms nor WarpImageMultiTransform found on PATH." >&2
        return 1
    fi
}

#########################################################################################################################
mask_cleaning() {
#########################################################################################################################
    # Clean rounding errors in a warped label image by re-quantizing into integer labels.
    # usage: mask_cleaning <input_mask.ext> [<output_mask.ext>]
    if [ "$#" -lt 1 ]; then
        echo "${FUNCNAME[0]}: usage: mask_cleaning <input_mask.ext> [<output_mask.ext>]" >&2
        return 1
    fi

    local mask_in="$1" fileclean_n="$2"
    local direct; direct="$(dirname "$mask_in")"
    local dim; dim="$( imm_dim "$mask_in" )"
    local nmc; nmc="$( fbasename "$mask_in" )"
    local multy=1000
    local file="${direct}/${nmc}_mul.nii.gz"

    local max order_true order ord N
    max="$( imm_max "$mask_in" )";  order_true="${#max}"
    ImageMath "$dim" "$file" m "$mask_in" "$multy"
    max="$( imm_max "$file" )";     order="${#max}"
    order="$( echo "scale=9; ${order}-${order_true}" | bc )"
    ord="$(   echo "scale=9; 10^${order}" | bc )"
    N="$(     echo "scale=0; ${max}/${ord}" | bc )"
    echo "maximum number of labels: $N"

    [ -z "$fileclean_n" ] && fileclean_n="${direct}/${nmc}_clean.nii.gz"

    local fileclean_f="" j fileclean thr
    for (( j=1; j<=N; j++ )); do
        fileclean="${direct}/${nmc}_clean${j}.nii.gz"
        thr="$( echo "scale=9; ${ord}*${j}" | bc )"
        ThresholdImage "$dim" "$file" "$fileclean" "$thr" "$thr"
        ImageMath "$dim" "$fileclean" m "$fileclean" "$thr"
        if [ "$j" -eq 1 ]; then
            fileclean_f="$fileclean"
        else
            ImageMath "$dim" "$fileclean_f" + "$fileclean" "$fileclean_f"
            rm -f "$fileclean"
        fi
    done

    mv "$fileclean_f" "$fileclean_n"
    ImageMath "$dim" "$fileclean_n" / "$fileclean_n" "$multy"
    rm -f "$file"
}

#########################################################################################################################
reg_n_warp_brain() {
#########################################################################################################################

    _rnw_usage() {
        cat >&2 <<'USAGE'

    Usage:  reg_n_warp_brain <moving_image.ext> <fixed_image.ext> <image_to_warp.ext> [ Options ]

    Main arguments:
       moving_image     Image to be registered to the reference image
       fixed_image      Reference image
       image_to_warp    Image to be warped to moving_image space

    General:
       -c, --CPUs        Cores for multithreading (default 2, or 'auto')
    Registration:
       -r, --reg-dir     Directory for registration outputs (default 'Reg_' beside moving image)
       -s, --settings    1 test / 2 fast / 3 balanced / 4 best (default)
       -x, --reg-masks   [fixedImageMask,movingImageMask]
       -m, --reg-metrics ANTs-style metric list for the non-linear stage
       -w, --winsorize   [lowerQuantile,upperQuantile]
       -g, --res-def     Restrict displacement field per component (e.g. 1x1x0.2)
       -p, --reg-interp  Interpolation in the registration stage (default BSpline)
       --timeseries      Moving image is a time-series
       --no-transl / --no-rigid / --no-affine / --no-nonlin
    Warp:
       -o, --out-image   Output warped mask (default 'Warped_' beside moving image)
       -i, --warp-interp Interpolation in the warp stage (default NN)
       -f, --warp-forward  Warp moving->reference
       -l, --clean-mask  Clean warped mask from rounding errors
    Other:
       -h, --help        Show this help
       -v, --no-verbose  Turn off verbose output

    Example:
       reg_n_warp_brain moving.nii.gz fixed.nii.gz ref_mask.nii.gz -s 3 -c auto --no-nonlin
USAGE
    }

    local START; START="$(date +%s)"

    #----------------------------------------------------------------- Input parsing
    local m="${1}" f="${2}" mask_rif="${3}"
    local nargs=$#

    # defaults
    local transl=1 rigid=1 affine=1 nonlin=1 timeseries=0 settings=4
    local clean_mask=0 interpolation="NN" multiimage=0 reginterp="BSpline" verbose_=1
    local regPath masks metrics reginterp_in winsorize resdef cpu_num mask_out warp_command1

    [[ "$1" == "-h" || "$1" == "--help" ]] && { _rnw_usage; return 0; }

    while [[ $# -gt 0 ]]; do
        local key="$4"
        case "$key" in
            -h|--help)          _rnw_usage; return 0 ;;
            -r|--reg-dir)       shift; regPath="$4";       (( nargs-- )) ;;
            --reg-dir=*)        regPath="${key#*=}" ;;
            -x|--reg-masks)     shift; masks="$4";         (( nargs-- )) ;;
            --reg-masks=*)      masks="${key#*=}" ;;
            -m|--reg-metrics)   shift; metrics="$4";       (( nargs-- )) ;;
            --reg-metrics=*)    metrics="${key#*=}" ;;
            -p|--reg-interp)    shift; reginterp_in="$4";  (( nargs-- )) ;;
            --reg-interp=*)     reginterp_in="${key#*=}" ;;
            -w|--winsorize)     shift; winsorize="$4";     (( nargs-- )) ;;
            --winsorize=*)      winsorize="${key#*=}" ;;
            -g|--res-def)       shift; resdef="$4";        (( nargs-- )) ;;   # FIXED: added missing shift
            --res-def=*)        resdef="${key#*=}" ;;
            -c|--CPUs)          shift; cpu_num="$4";       (( nargs-- )) ;;
            --CPUs=*)           cpu_num="${key#*=}" ;;
            -s|--settings)      shift; settings="$4";      (( nargs-- )) ;;
            --settings=*)       settings="${key#*=}" ;;
            --timeseries)       timeseries=1 ;;
            --no-transl)        transl=0 ;;
            --no-rigid)         rigid=0 ;;
            --no-affine)        affine=0 ;;
            --no-nonlin)        nonlin=0 ;;
            --clean-mask|-l)    clean_mask=1 ;;
            -o|--out-image)     shift; mask_out="$4";      (( nargs-- )) ;;
            --out-image=*)      mask_out="${key#*=}" ;;
            -i|--warp-interp)   shift; interpolation="$4"; (( nargs-- )) ;;
            --warp-interp=*)    interpolation="${key#*=}" ;;
            -f|--warp-forward)  warp_command1=" -f " ;;
            -4D)                multiimage=1 ;;            # FIXED: no longer aliased to --timeseries
            -v|--no-verbose)    verbose_=0 ;;
            *)                  [ -n "$key" ] && echo "Unknown option '$key'" >&2 ;;
        esac
        shift
    done

    [ "$nargs" -lt 3 ] && { _rnw_usage; return 1; }

    [ -n "$reginterp_in" ] && reginterp="$reginterp_in"

    local inputPath; inputPath="$(dirname "$m")"
    [ -z "$regPath" ] && regPath="${inputPath}/Reg_/"
    mkdir -p "$regPath"
    [ -z "$cpu_num" ] && cpu_num=2

    # verbosity (FIXED: was inverted — used to enable -v only when verbose was OFF)
    local reg_commandV=""
    [ "$verbose_" -eq 0 ] && reg_commandV=" -v "

    #----------------------------------------------------------------- Registration
    local transf reg_command0="" reg_command1 reg_command2 reg_command3 reg_command4
    local reg_command5="" reg_command6="" reg_command7="" reg_command8=""

    [ "$timeseries" -eq 1 ] && reg_command0="--timeseries"
    [ -n "$masks" ]         && reg_command5=" -x ${masks} "
    [ "$transl" -eq 1 ] && { transf="trasl";  reg_command1="  "; } || reg_command1=" --no-transl "
    [ "$rigid"  -eq 1 ] && { transf="rigid";  reg_command2="  "; } || reg_command2=" --no-rigid "
    [ "$affine" -eq 1 ] && { transf="affine"; reg_command3="  "; } || reg_command3=" --no-affine "
    [ "$nonlin" -eq 1 ] && { transf="SyN";    reg_command4="  "; } || reg_command4=" --no-nonlin "
    [ -n "$metrics" ]   && reg_command6=" --metrics ${metrics}"
    [ -n "$winsorize" ] && reg_command7=" -w ${winsorize}"
    [ -n "$resdef" ]    && reg_command8=" -g ${resdef}"

    registration_brain "$m" "$f" --outputdir "$regPath" -c "$cpu_num" -s "$settings" -i "$reginterp" \
        $reg_command0 $reg_command1 $reg_command2 $reg_command3 $reg_command4 \
        $reg_command5 $reg_command6 $reg_command7 $reg_command8 $reg_commandV

    echo
    echo ":::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    echo "::::::::::::::::            Registration of $(basename "$m") done            :::::::::::::::::::"
    echo ":::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    echo

    #----------------------------------------------------------------- Warp
    local warpPath="${inputPath}/Warped_/"
    mkdir -p "$warpPath"
    local Image_name; Image_name="$( fbasename "$m" )"
    local nm="${Image_name}_${transf}"
    local mask_name; mask_name="$( fbasename "$mask_rif" )"
    local mask_out_n="${warpPath}/${mask_name}_${nm}_warped.nii.gz"
    [ -z "$mask_out" ] && mask_out="$mask_out_n"

    local warp_command0="" warp_command2=""
    [ "$multiimage" -eq 1 ] && warp_command0="--timeseries"
    [ -n "$warp_command1" ] && warp_command2=" --ref-image ${f} "

    warp_image "$m" "$mask_rif" --reg-dir "$regPath" --out-image "$mask_out" \
        --reg-transf "$transf" --interp "$interpolation" \
        $reg_command0 $warp_command0 $warp_command1 $warp_command2 $reg_commandV

    echo
    echo "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    echo "::::::::::::::::            Warp of $(basename "$mask_rif") done            :::::::::::::::::::"
    echo "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    echo

    #----------------------------------------------------------------- Optional mask cleaning
    if [ "$clean_mask" -eq 1 ]; then
        mask_cleaning "$mask_out"
        echo
        echo "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
        echo "::::::::::::::::               mask cleaning done                :::::::::::::::::::"
        echo "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
        echo
    fi

    #----------------------------------------------------------------- Timing
    echo
    echo ":::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    echo "::::::::::: EXECUTION TIME : $( elapsed_time "$START" ) :::::::::::::"
    echo ":::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    echo
}
