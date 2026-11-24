#!/usr/bin/env bash
#########################################################################################################################
#########################################################################################################################
###################                                                                                   ###################
###################   title:        Imaging library                                                   ###################
###################   description:  Wrappers for neuroimaging primitives (FSL + ANTs + FreeSurfer),    ###################
###################                 segmentation/label tools, ROI builders, connectome reshaping and   ###################
###################                 DICOM/NIfTI conversion.                                            ###################
###################                                                                                   ###################
###################   version:      0.5.0  (modernized 2026: Ubuntu 24.04+, bash 5.x, ANTs 2.6.5,     ###################
###################                          FSL 6.x; Python heredocs ported to Python 3)              ###################
###################   notes:        needs STRlib.sh ARRAYlib.sh CPUlib.sh FILESlib.sh REGlib helpers,  ###################
###################                 and the Python 3 modules immpy.py / csvpack.py / imageconvert.py   ###################
###################   author:       gamorosino  (modernization pass 2026)                             ###################
###################   email:        g.amorosino@gmail.com                                             ###################
###################                                                                                   ###################
#########################################################################################################################
#########################################################################################################################
#
#   MODERNIZATION SUMMARY (see per-section BUGFIX tags Bxx for details)
#   ------------------------------------------------------------------------------------------------------------------
#   Section 1 (primitives):    B1 label-driven ImageIntensityStatistics parse; B2 quoting;
#                              B3-B5 return codes, deterministic volume counting/merge.
#   Section 2 (segmentation):  B6 aseg cerebellar-label misclassification (FLAG: cerebellum-exterior
#                              6/45 -> GM); B7/B8 confusion-matrix formatting + zero-denominator guards;
#                              B9 cluster->fsl-cluster (FSL 6); B10/B11 temp names, quoting.
#   Section 3 (python heredocs): moved to immpy.py (Python 3). B12 flip_as IndentationError/exec;
#                              B13 RGB header dtype; B14 spurious 2nd file; B15 usage string;
#                              B16 hardcrop asymmetric margin (PRESERVED + flagged).
#   Section 4 (roi/dicom/misc): B17 nii2dcm fileds=/unterminated string; B18 imm_compare no output;
#                              B19 createSphere Y/Z swap (FLAG); B20 mni2cor per-axis inverse spacing;
#                              B21/B22 removed get_data(), pandas header-eating; B23 python3/quoting.
#
#   VERIFICATION NOTE: text/coordinate/array logic and all Python (immpy/csvpack/imageconvert) were
#   executed and unit-tested on Ubuntu 24.04.4 with nibabel 5.4/pydicom 3.0/pandas 3.0/scipy 1.17.
#   Functions that shell out to FSL/ANTs/FreeSurfer/MRtrix binaries were code-reviewed against the
#   ANTs 2.6.5 / FSL 6.0 target but NOT executed here (those tools are not installed in the build env).
#   Run the full suite once on a host with FSL+ANTs installed.
#
#   DEPENDENCY FLAGS: imm_createSphereX and imm_createInclusionSphere require MRtrix3 (`mredit`),
#   which is outside the confirmed ANTs+FSL toolchain; they guard-and-error if it is absent.
#########################################################################################################################

# --- dependency sourcing --------------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/STRlib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/ARRAYlib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/CPUlib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/FILESlib.sh"

# --- Python 3 helper modules (paths overridable via the environment) ------------------------------------------------
: "${IMMPY:=${SCRIPT_DIR}/immpy.py}"
: "${CSVPACK:=${SCRIPT_DIR}/csvpack.py}"
: "${IMAGECONVERT:=${SCRIPT_DIR}/imageconvert.py}"
export IMMPY CSVPACK IMAGECONVERT

# --- fallback for _reg_have when REGlib.sh has not been sourced -----------------------------------------------------
if ! declare -F _reg_have >/dev/null 2>&1; then
    _reg_have() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F _reg_remove_ext >/dev/null 2>&1; then
    _reg_remove_ext() {
        if command -v remove_ext >/dev/null 2>&1; then remove_ext "$1"; else
            case "$1" in *.nii.gz) echo "${1%.nii.gz}";; *.nii) echo "${1%.nii}";; *) echo "${1%.*}";; esac
        fi
    }
fi

# --- include guard --------------------------------------------------------------------------------------------------
[ -n "${__IMAGINGLIB_SOURCED:-}" ] && return 0
__IMAGINGLIB_SOURCED=1

#########################################################################################################################
###   SECTION 1 -- image-primitive wrappers
#########################################################################################################################
imm_spacing() {
        # Voxel spacing of an image, as read from the ANTs header (PrintHeader field 1).
        # usage: imm_spacing <image> [<sep>]   (sep default "," ; "space" -> " ")
        local stringspacing sep
        stringspacing="$(PrintHeader "$1" 1)"
        sep="${2:-,}"                                  # BUGFIX B2: quoted default
        [ "$sep" = "space" ] && sep=" "
        echo "${stringspacing//x/$sep}"
}

imm_size() {
        # Matrix size of an image (PrintHeader field 2).
        # usage: imm_size <image> [<sep>]
        local stringsize sep
        stringsize="$(PrintHeader "$1" 2)"
        sep="${2:-,}"                                  # BUGFIX B2
        [ "$sep" = "space" ] && sep=" "
        echo "${stringsize//x/$sep}"
}

imm_dim() {
        # Dimensionality (3 or 4) inferred from the size string.
        # usage: imm_dim <image>
        local sizem dimm
        sizem="$(PrintHeader "$1" 2)"
        dimm="$(grep -o 'x' <<<"$sizem" | wc -l)"
        echo "$(( dimm + 1 ))"
}

# --- internal: robustly read one labelled column from ImageIntensityStatistics -------------------
_imm_intensity_stat() {
        # usage: _imm_intensity_stat <image> <Min|Max|Mean|Sum|Variance|Sigma|...>
        # Parses the two-row (header + values) output of ANTs ImageIntensityStatistics by matching
        # the requested column name in the header, instead of a hard-coded numeric offset.
        local img="$1" want="$2" dim
        dim="$( imm_dim "$img" )"
        ImageIntensityStatistics "$dim" "$img" | awk -v want="$want" '
            NR==1 { for (i=1;i<=NF;i++) if ($i==want) col=i; next }
            NR==2 { if (col) print $col }'
}

imm_max() {
        # Maximum intensity of an image.  usage: imm_max <image>
        local v; v="$( _imm_intensity_stat "$1" "Max" )"          # BUGFIX B1
        # Fallback to the legacy fixed offset if the column name wasn't found (old ANTs).
        if [ -z "$v" ]; then
            local dim; dim="$( imm_dim "$1" )"
            local stats=( $( ImageIntensityStatistics "$dim" "$1" ) ); v="${stats[21]}"
        fi
        echo "$v"
}

imm_min() {
        # Minimum intensity of an image.  usage: imm_min <image>
        local v; v="$( _imm_intensity_stat "$1" "Min" )"          # BUGFIX B1
        if [ -z "$v" ]; then
            local dim; dim="$( imm_dim "$1" )"
            local stats=( $( ImageIntensityStatistics "$dim" "$1" ) ); v="${stats[20]}"
        fi
        echo "$v"
}

maximum() {
        # DEPRECATED: kept for backward compatibility. Prefer imm_max.
        # Parses MeasureMinMaxMean text output.
        local subs="$1" dim direct warplog header b indexh maxstring max
        dim="$( imm_dim "$1" )"
        direct="$(dirname "$subs")"
        warplog="${direct}/warplog$(date +%s).txt"
        header="$( MeasureMinMaxMean "$dim" "$subs" "$warplog" 1 )"
        b="Max : ["
        indexh="$( str_index "$header" "$b" )"
        maxstring="${header:indexh+${#b}}"
        max="$( echo "$maxstring" | cut -d ']' -f1 )"
        rm -f "$warplog" 2>/dev/null
        echo "$max"
}

minimum() {
        # DEPRECATED: kept for backward compatibility. Prefer imm_min.
        local subs="$1" dim direct warplog header b indexh minstring min
        dim="$( imm_dim "$1" )"
        direct="$(dirname "$subs")"
        warplog="${direct}/warplog$(date +%s).txt"
        header="$( MeasureMinMaxMean "$dim" "$subs" "$warplog" 1 )"
        b="Min : ["
        indexh="$( str_index "$header" "$b" )"
        minstring="${header:indexh+${#b}}"
        min="$( echo "$minstring" | cut -d ']' -f1 )"
        rm -f "$warplog" 2>/dev/null
        echo "$min"
}

extract_volume() {
        # Extract a single 3D volume (by 0-based index) from a 4D image.
        # usage: extract_volume <file_in> <file_out> <index>
        local input="$1" output="$2" index="$3"
        fslroi "$input" "$output" 0 -1 0 -1 0 -1 "$index" 1
}

extract_allvolumes() {
        # Extract every 3D volume from a 4D image into <output_dir> as <basename>_NNNN.nii.gz.
        # usage: extract_allvolumes <file_in> [<output_dir>] [<basename>] [<nthreads>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: extract_allvolumes <file_in> [<output_dir>] [<basename>] [<nthreads>]" >&2
            return 1
        fi
        local input="$1" output_dir="$2" fbase="$3" nthreads="$4"
        [ -z "$output_dir" ] && output_dir="$(dirname "$input")/$( fbasename "$input" )"
        [ -z "$fbase" ] && fbase="$( fbasename "$input" )"
        local output_f="${output_dir}/${fbase}"
        mkdir -p "$output_dir"

        local shape=( $( imm_size "$input" "space" ) )
        echo "image shape: ${shape[*]}"
        local N="${shape[3]}"
        if [ -z "$N" ]; then
            echo "${FUNCNAME[0]}: input is not 4D (no 4th dimension)" >&2
            return 1
        fi

        local i number
        if [ -z "$nthreads" ]; then
            for (( i=0; i<N; i++ )); do
                number="$( printf '%04d' "$i" )"
                echo "${output_f}_${number} extracted"
                extract_volume "$input" "${output_f}_${number}" "$i"
            done
        else
            expr "$nthreads" : '-\?[0-9]\+$' >/dev/null || {
                echo "integer expression expected for nthreads argument" >&2; return 1; }   # BUGFIX B3
            for (( i=0; i<N; i++ )); do
                number="$( printf '%04d' "$i" )"
                echo "${output_f}_${number} extracted"
                extract_volume "$input" "${output_f}_${number}" "$i" &
                waiting4script fslroi "$nthreads" 0
            done
            # BUGFIX B4: count only finished, correctly-named outputs; poll with a sleep.
            local done_n
            while :; do
                done_n="$( ls "${output_f}"_[0-9][0-9][0-9][0-9].nii.gz 2>/dev/null | wc -l )"
                [ "$done_n" -ge "$N" ] && break
                local pct; pct="$( awk -v a="$done_n" -v b="$N" 'BEGIN{printf "%.1f", a/b*100}' )"
                echo -ne "${pct}% done (${done_n} vs ${N})\033[0K\r"
                sleep 0.3
            done
            echo
        fi
}

remove_volumes() {
        # Remove a comma-separated list of volume indices from a 4D image.
        # usage: remove_volumes <file_in> <file_out> <index_list> [<nthreads>]
        if [ "$#" -lt 3 ]; then
            echo "${FUNCNAME[0]}: usage: remove_volumes <file_in> <file_out> <index_list> [<nthreads>]" >&2
            return 1
        fi
        local file_in="$1" file_out="$2" index_comma="$3" nthreads="$4"
        local index_list=( ${index_comma//,/ } )
        local temp_dir; temp_dir="$(dirname "$file_in")/temp_$(date +%s)"
        extract_allvolumes "$file_in" "$temp_dir" "vol" "$nthreads"

        local i number to_delete
        for i in "${index_list[@]}"; do
            number="$( printf '%04d' "$i" )"
            to_delete="${temp_dir}/vol_${number}.nii.gz"
            if [ "$( exists "$to_delete" )" -eq 1 ]; then
                rm -f "$to_delete"
            else
                echo "volume $i does not exist" >&2
                rm -rf "$temp_dir"
                return 1                                   # BUGFIX B5: was return -1
            fi
        done

        echo "Merging the remaining volumes"
        # BUGFIX B5: explicit, sorted list so temporal order is preserved deterministically.
        local remaining=( $( ls "$temp_dir"/vol_[0-9][0-9][0-9][0-9].nii.gz 2>/dev/null | sort ) )
        fslmerge -t "$file_out" "${remaining[@]}"
        [ "$( exists "$temp_dir" )" -eq 1 ] && rm -rf "$temp_dir"
}

#########################################################################################################################
###   SECTION 2 -- segmentation / label machinery
#########################################################################################################################
imm_unpackSeg() {
        # Split a multi-label segmentation into one binary file per non-empty label.
        # usage: imm_unpackSeg <segmentation.ext> [<output_folder>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_unpackSeg <segmentation.ext> [<output_folder>]" >&2
            return 1
        fi
        local seg="$1" ofolder="$2" dim
        dim="$( imm_dim "$seg" )"
        [ -z "$ofolder" ] && ofolder="$(dirname "$seg")/$( fbasename "$seg" )_unpackSeg/"
        mkdir -p "$ofolder"
        local N_labels first_label i label V_stats
        N_labels="$( imm_max "$seg" )"
        first_label="$( imm_min "$seg" )"
        [ "$first_label" -eq 0 ] 2>/dev/null && first_label=1
        for (( i=first_label; i<=N_labels; i++ )); do
            label="${ofolder}/$( fbasename "$seg" )_${i}.nii.gz"
            ThresholdImage "$dim" "$seg" "$label" "$i" "$i"
            V_stats=( $( fslstats "$label" -V ) )
            [ "${V_stats[0]}" -eq 0 ] && rm -f "$label"
        done
}

imm_seg25tt() {
        # Merge unpacked labels into a 5TT-style 4D file, optionally in a given label order.
        # usage: imm_seg25tt <segmentation.ext> [<output.ext>] [<labels_order>] [<add_zeros>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_seg25tt <segmentation.ext> [<output.ext>] [<labels_order>] [<add_zeros>]" >&2
            return 1
        fi
        local seg="$1" output="$2" label_order="$3" add_zeros="${4:-0}"
        [ -z "$output" ] && output="$(dirname "$seg")/$( fbasename "$seg" )_5tt.nii.gz"
        [ -z "$label_order" ] && label_order="None"

        local temp_dir; temp_dir="$(dirname "$seg")/imm_SegTo5tt_temp$(date +%s)"
        imm_unpackSeg "$seg" "$temp_dir"

        if [ "$label_order" = "None" ]; then
            local files=( $( ls "$temp_dir"/* 2>/dev/null | sort ) )   # deterministic order
            fslmerge -t "$output" "${files[@]}"
        else
            local order=( ${label_order//,/ } ) merg_list=() i
            for i in "${order[@]}"; do
                merg_list+=( "${temp_dir}/$( fbasename "$seg" )_${i}.nii.gz" )
            done
            fslmerge -t "$output" "${merg_list[@]}"
        fi

        if [ "$add_zeros" -eq 1 ]; then
            local zeros="${temp_dir}/zeros$(date +%s).nii.gz"
            fslmaths "$seg" -sub "$seg" "$zeros"
            fslmerge -t "$output" "$output" "$zeros"
        fi
        rm -rf "$temp_dir"
}

imm_assign_aseglabel() {
        # Assign a single FreeSurfer aseg label <i> to a tissue class and move its binary mask into
        # the corresponding tissue folder. Internal helper for imm_aseg2seg.
        # usage: imm_assign_aseglabel <i> <label> <seg> <seg_type> <csf> <gm> <wm> <dgm> <trunk> <crbllm>
        local i="$1" label="$2" seg="$3" seg_type="$4"
        local csf_seg="$5" gm_seg="$6" wm_seg="$7" dgm_seg="$8" trunk_seg="$9" crbllm_seg="${10}"

        # --- FreeSurfer aseg component groups (values are aseg label numbers) ---
        local csf_components=( 24 14 15 43 44 4 5 )
        local gm_components=( 3 42 20 )
        local wm_components=( 2 41 219 223 250 251 252 253 254 255 77 )
        local dgm_components=( 11 50 12 51 136 137 9 10 48 49 13 52 53 17 19 55 \
                               20 56 18 54 96 97 218 26 58 27 59 60 28 )
        local crbllm_components=( 6 7 8 45 46 47 )   # 0:6L-ext 1:7L-wm 2:8L-cortex 3:45R-ext 4:46R-wm 5:47R-cortex
        local trunk_components=( 16 )
        local other_components=( 31 62 63 85 )

        # --- merged classes -------------------------------------------------------------------
        local dgm_components_all=( "${dgm_components[@]}" )
        # cerebellar cortex (8,47) AND exterior (6,45) -> GM.
        # BUGFIX B6 / REVIEW: crbllm exterior -- indices [0],[3] (labels 6,45) were previously lost
        # to out-of-range indexing. Move them here if your protocol wants them elsewhere.
        local gm_components_all=( "${gm_components[@]}" \
                                  "${crbllm_components[2]}" "${crbllm_components[5]}" \
                                  "${crbllm_components[0]}" "${crbllm_components[3]}" )
        # cerebellar WM (7,46) + brainstem -> WM.
        local wm_components_all=( "${wm_components[@]}" \
                                  "${crbllm_components[1]}" "${crbllm_components[4]}" \
                                  "${trunk_components[@]}" )
        # BUGFIX B6: removed the two invalid entries crbllm_components[6] and csf_components[45].
        local csf_components_all=( "${csf_components[@]}" )
        local gm_dgm_components_all=( "${gm_components_all[@]}" "${dgm_components_all[@]}" )

        local dim; dim="$( imm_dim "$seg" )"
        ThresholdImage "$dim" "$seg" "$label" "$i" "$i"

        local V_stats=( $( fslstats "$label" -V ) )
        if [ "${V_stats[0]}" -eq 0 ]; then
            rm -f "$label"
            return 0
        fi

        _move_to() {  # <dir_base_seg>
            local base="$1" d
            d="$(dirname "$base")/$( fbasename "$base" )"
            mkdir -p "$d"
            mv "$label" "${d}/$( fbasename "$base" )_${i}.nii.gz"
        }

        case "$seg_type" in
            1|3tissue)
                if   [ "$( array_iselement "$i" "${csf_components_all[@]}" )" -eq 1 ]; then _move_to "$csf_seg"
                elif [ "$( array_iselement "$i" "${wm_components_all[@]}"  )" -eq 1 ]; then _move_to "$wm_seg"
                elif [ "$( array_iselement "$i" "${gm_dgm_components_all[@]}" )" -eq 1 ]; then _move_to "$gm_seg"
                fi ;;
            2|4tissue)
                if   [ "$( array_iselement "$i" "${csf_components_all[@]}" )" -eq 1 ]; then _move_to "$csf_seg"
                elif [ "$( array_iselement "$i" "${wm_components_all[@]}"  )" -eq 1 ]; then _move_to "$wm_seg"
                elif [ "$( array_iselement "$i" "${gm_components_all[@]}"  )" -eq 1 ]; then _move_to "$gm_seg"
                elif [ "$( array_iselement "$i" "${dgm_components_all[@]}" )" -eq 1 ]; then _move_to "$gm_seg"
                fi ;;
            3|PTBP)
                if   [ "$( array_iselement "$i" "${csf_components[@]}" )" -eq 1 ]; then _move_to "$csf_seg"
                elif [ "$( array_iselement "$i" "${wm_components[@]}"  )" -eq 1 ]; then _move_to "$wm_seg"
                elif [ "$( array_iselement "$i" "${gm_components[@]}"  )" -eq 1 ]; then _move_to "$gm_seg"
                elif [ "$( array_iselement "$i" "${dgm_components[@]}" )" -eq 1 ]; then _move_to "$dgm_seg"
                elif [ "$( array_iselement "$i" "${trunk_components[@]}" )" -eq 1 ]; then _move_to "$trunk_seg"
                elif [ "$( array_iselement "$i" "${crbllm_components[@]}" )" -eq 1 ]; then _move_to "$crbllm_seg"
                fi ;;
        esac

        if [ "$( array_iselement "$i" "${other_components[@]}" )" -eq 1 ]; then
            local other_dir; other_dir="$(dirname "$csf_seg")/Other_structures/"
            mkdir -p "$other_dir"
            case "$i" in
                31) mv "$label" "${other_dir}/Left_choroid_plexus.nii.gz" ;;
                63) mv "$label" "${other_dir}/Right_choroid_plexus.nii.gz" ;;
                62) mv "$label" "${other_dir}/Right_vessel.nii.gz" ;;
                85) mv "$label" "${other_dir}/Optic_chiasm.nii.gz" ;;   # was mislabeled "Left_choroid_plexus"
            esac
        fi
}

imm_addlabels() {
        # Sum a set of binary masks, multiply by <val>, write to <seg_out>.
        # usage: imm_addlabels <mask1> <mask2> ... <val> <seg_out>
        local list=( "$@" )
        local last_idx=$(( ${#list[@]} - 1 ))
        local seg_="${list[$last_idx]}"
        local val="${list[$last_idx-1]}"
        unset 'list[last_idx]'
        unset 'list[last_idx-1]'
        local fsl_command="${list[*]}"
        fsl_command="${fsl_command// / -add }"
        fslmaths $fsl_command -mul "$val" "$seg_"
}

imm_aseg2seg() {
        # Convert a FreeSurfer aseg into a tissue segmentation (3/4/PTBP tissue classes).
        # usage: imm_aseg2seg <aseg.ext> [<type>] [<output.ext>] [<nthreads>] [<keep>]
        #   type: 1|3tissue (CSF,GM,WM) | 2|4tissue (+DGM) | 3|PTBP (+Trunk,Cerebellum)
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_aseg2seg <aseg.ext> [<type>] [<output.ext>] [<nthreads>] [<keep>]" >&2
            return 1
        fi
        local seg="$1" seg_type="${2:-1}" output="$3" nthreads="${4:-1}" keep="${5:-0}"

        local f_seg seg_ext
        f_seg="$(dirname "$seg")/$( fbasename "$seg" )"
        seg_ext="$( fextension "$seg" )"
        if [ "$seg_ext" = "mgz" ]; then
            local seg_nii="${f_seg}.nii.gz"
            mri_convert "$seg" "$seg_nii"
            seg="$seg_nii"
        fi

        if [ -z "$output" ]; then
            case "$seg_type" in
                3|PTBP)    output="$(dirname "$seg")/$( fbasename "$seg" )_PTBP.nii.gz" ;;
                1|3tissue) output="$(dirname "$seg")/$( fbasename "$seg" )_3tissue.nii.gz" ;;
                2|4tissue) output="$(dirname "$seg")/$( fbasename "$seg" )_4tissue.nii.gz" ;;
            esac
        fi

        local N_labels first_label
        N_labels="$( imm_max "$seg" )"
        first_label="$( imm_min "$seg" )"
        [ "$first_label" -eq 0 ] 2>/dev/null && first_label=1

        local temp_dir; temp_dir="$(dirname "$seg")/imm_aseg2seg_temp$(date +%s)"
        mkdir -p "$temp_dir"
        local csf_seg="${temp_dir}/csf_seg.nii.gz"
        local gm_seg="${temp_dir}/gm_seg.nii.gz"
        local wm_seg="${temp_dir}/wm_seg.nii.gz"
        local dgm_seg="" trunk_seg="" crbllm_seg=""
        local final_add="${csf_seg} -add ${gm_seg} -add ${wm_seg} "

        case "$seg_type" in
            2|4tissue|3|PTBP) dgm_seg="${temp_dir}/dgm_seg.nii.gz"; final_add="${final_add} -add ${dgm_seg} " ;;
        esac
        case "$seg_type" in
            3|PTBP) crbllm_seg="${temp_dir}/cerebellum_seg.nii.gz"; trunk_seg="${temp_dir}/trunk_seg.nii.gz"
                    final_add="${final_add} -add ${trunk_seg} -add ${crbllm_seg}" ;;
        esac

        local i label
        for (( i=first_label; i<=N_labels; i++ )); do
            label="${temp_dir}/$( fbasename "$seg" )_${i}.nii.gz"
            if [ "$nthreads" -ne 1 ]; then
                imm_assign_aseglabel "$i" "$label" "$seg" "$seg_type" "$csf_seg" "$gm_seg" "$wm_seg" "$dgm_seg" "$trunk_seg" "$crbllm_seg" &
                waiting4script ThresholdImage "$nthreads" 0
            else
                imm_assign_aseglabel "$i" "$label" "$seg" "$seg_type" "$csf_seg" "$gm_seg" "$wm_seg" "$dgm_seg" "$trunk_seg" "$crbllm_seg"
            fi
        done
        [ "$nthreads" -ne 1 ] && { waiting4script ThresholdImage 1 0; waiting4script fslmaths 1 0; wait; }
        echo "assignment complete"

        local segmentations=( "$csf_seg" "$gm_seg" "$wm_seg" "$dgm_seg" "$trunk_seg" "$crbllm_seg" )
        local count=0 s segs
        for s in "${segmentations[@]}"; do
            [ -z "$s" ] && continue
            count=$(( count + 1 ))
            segs=( $( ls "$(dirname "$s")/$( fbasename "$s" )/$( fbasename "$s" )_"* 2>/dev/null ) )
            [ "${#segs[@]}" -eq 0 ] && continue
            if [ "$nthreads" -ne 1 ]; then
                imm_addlabels "${segs[@]}" "$count" "$s" &
                waiting4script fslmaths "$nthreads" 0
            else
                imm_addlabels "${segs[@]}" "$count" "$s"
            fi
        done
        [ "$nthreads" -ne 1 ] && { waiting4script fslmaths 1 0; wait; }
        echo "single tissue masks composed"

        echo "create output segmentation: $output"
        fslmaths $final_add "$output"
        [ "$keep" -eq 0 ] && rm -rf "$temp_dir"
        echo "complete"
}

imm_sumExclusive() {
        # imm3 = imm1 OR (imm2 AND NOT imm1)   (imm1 takes precedence in overlap).
        # usage: imm_sumExclusive <imm1> <imm2> <imm3_out>
        if [ "$#" -lt 3 ]; then
            echo "${FUNCNAME[0]}: usage: imm_sumExclusive <imm1> <imm2> <imm3_out>" >&2
            return 1
        fi
        local imm1="$1" imm2="$2" imm3="$3"
        local temp_dir; temp_dir="$(dirname "$imm1")/imm_sumExclusive$(date +%s)/"   # BUGFIX B10
        mkdir -p "$temp_dir"
        local imm1_binv="${temp_dir}/$( fbasename "$imm1" )_binv.nii.gz"
        local imm2_mul="${temp_dir}/$( fbasename "$imm1" )_mul.nii.gz"
        fslmaths "$imm1" -binv "$imm1_binv"
        fslmaths "$imm2" -mul "$imm1_binv" "$imm2_mul"
        fslmaths "$imm1" -add "$imm2_mul" "$imm3"
        rm -rf "$temp_dir"
}

imm_ConfMat() {
        # Confusion-matrix metrics between two label images at label <k>.
        # Echoes: accuracy sensitivity specificity Dice
        # usage: imm_ConfMat <image1.ext> <image2.ext> [<label>]
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_ConfMat <image1.ext> <image2.ext> [<label>]" >&2
            return 1
        fi
        local result="$1" label="$2" k="${3:-1}"
        local temp_dir; temp_dir="$(dirname "$result")/ConfMat$(date +%s)/"
        mkdir -p "$temp_dir"
        local result_k="${temp_dir}/image1.nii.gz" label_k="${temp_dir}/image2.nii.gz"
        fslmaths "$result" -thr "$k" -uthr "$k" -bin "$result_k"
        fslmaths "$label"  -thr "$k" -uthr "$k" -bin "$label_k"

        local sum_img="${temp_dir}/sum_img.nii.gz"
        fslmaths "$result_k" -add "$label_k" "$sum_img"
        local TPimg="${temp_dir}/TPimg.nii.gz" TNimg="${temp_dir}/TNimg.nii.gz"
        local diff_img="${temp_dir}/diff_img.nii.gz" FNimg="${temp_dir}/FNimg.nii.gz" FPimg="${temp_dir}/FPimg.nii.gz"
        fslmaths "$sum_img" -thr 2 -uthr 2 -bin "$TPimg"
        fslmaths "$sum_img" -binv "$TNimg"
        fslmaths "$result_k" -sub "$label_k" "$diff_img"
        fslmaths "$diff_img" -thr -1 -uthr -1 -mul -1 "$FNimg"
        fslmaths "$diff_img" -thr 1 -uthr 1 -bin "$FPimg"

        local TP TN FN FP
        TP="$( fslstats "$TPimg" -V | awk '{print $1}' )"
        TN="$( fslstats "$TNimg" -V | awk '{print $1}' )"
        FN="$( fslstats "$FNimg" -V | awk '{print $1}' )"
        FP="$( fslstats "$FPimg" -V | awk '{print $1}' )"

        # BUGFIX B7/B8: compute metrics in one awk pass with zero-denominator guards and correct
        # 0.x formatting (the old bc guards always fired and produced "00.87"/"01.0").
        awk -v TP="$TP" -v TN="$TN" -v FN="$FN" -v FP="$FP" 'BEGIN{
            ALL=TP+TN+FN+FP;
            acc = (ALL>0)      ? (TP+TN)/ALL        : 0;
            sen = (TP+FN>0)    ? TP/(TP+FN)         : 0;
            spe = (TN+FP>0)    ? TN/(TN+FP)         : 0;
            dice= (2*TP+FP+FN>0)? (2*TP)/(2*TP+FP+FN): 0;
            printf "%.5f %.5f %.5f %.5f\n", acc, sen, spe, dice;
        }'
        rm -rf "$temp_dir"
}

imm_getMaxCluster() {
        # Keep only the largest supra-threshold connected cluster.
        # usage: imm_getMaxCluster <input.ext> <output.ext> [<threshold>]
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_getMaxCluster <input.ext> <output.ext> [<threshold>]" >&2
            return 1
        fi
        local input="$1" output="$2" threshold="${3:-1}"
        local cluster_img; cluster_img="$(dirname "$input")/clusters_$(date +%s).nii.gz"
        # BUGFIX B9: FSL 6 renamed `cluster` to `fsl-cluster`.
        local cluster_bin
        if   _reg_have fsl-cluster 2>/dev/null || command -v fsl-cluster >/dev/null 2>&1; then cluster_bin="fsl-cluster"
        else cluster_bin="cluster"; fi
        "$cluster_bin" -i "$input" -t "$threshold" -o "$cluster_img" >/dev/null
        local max_c; max_c="$( imm_max "$cluster_img" )"
        fslmaths "$cluster_img" -thr "$max_c" -uthr "$max_c" -bin "$output"
        rm -f "$cluster_img"
}

#########################################################################################################################
###   SECTION 3 -- former Python heredocs (via immpy.py)
#########################################################################################################################
imm_flip_as() {
        # Find the axis flip/permutation of <input.ext> most similar to <fixed.ext> and save it.
        # usage: imm_flip_as <input.ext> <fixed.ext> [<output.ext>]
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_flip_as <input.ext> <fixed.ext> [<output.ext>]" >&2
            return 1
        fi
        python3 "$IMMPY" flip_as "$1" "$2" "${3:-}"
}

imm_flip() {
        # Flip an image along an axis (X|Y|Z), optionally borrowing a reference's header/affine.
        # usage: imm_flip <input.ext> <axis X|Y|Z> [<output.ext>] [<reference.ext>]
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_flip <input.ext> <axis X|Y|Z> [<output.ext>] [<reference.ext>]" >&2
            return 1
        fi
        python3 "$IMMPY" flip "$1" "$2" "${3:-}" "${4:-}"
}

imm_header_as() {
        # Write <input.ext>'s data using <reference.ext>'s header/affine.
        # usage: imm_header_as <input.ext> <reference.ext> <output>
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_header_as <input.ext> <reference.ext> <output>" >&2
            return 1
        fi
        python3 "$IMMPY" header_as "$1" "$2" "${3:-}"
}

imm_minDist() {
        # Minimum Euclidean distance (mm) between the ==1 voxels of two masks.
        # usage: imm_minDist <imm1.ext> <imm2.ext>
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_minDist <imm1.ext> <imm2.ext>" >&2
            return 1
        fi
        python3 "$IMMPY" min_dist "$1" "$2"
}

imm_maxDist() {
        # Maximum Euclidean distance (mm) between the ==1 voxels of two masks.
        # usage: imm_maxDist <imm1.ext> <imm2.ext>            # BUGFIX B15: was "imm_minDist"
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_maxDist <imm1.ext> <imm2.ext>" >&2
            return 1
        fi
        python3 "$IMMPY" max_dist "$1" "$2"
}

imm_4D2RGB() {
        # Pack the first three volumes of a 4D image into an RGB NIfTI.
        # usage: imm_4D2RGB <input.ext> [<output.ext>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_4D2RGB <input.ext> [<output.ext>]" >&2
            return 1
        fi
        local input="$1" output="$2"
        [ -z "$output" ] && output="$( _reg_remove_ext "$input" 2>/dev/null || remove_ext "$input" )_RGB.nii.gz"
        python3 "$IMMPY" to_rgb "$input" "$output"
}

imm_hardcrop() {
        # Crop an image to its nonzero bounding box (see immpy.hardcrop for the margin note).
        # usage: imm_hardcrop <input.ext> [<output.ext>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_hardcrop <input.ext> [<output.ext>]" >&2
            return 1
        fi
        local input="$1" output="$2"
        [ -z "$output" ] && output="$( _reg_remove_ext "$input" 2>/dev/null || remove_ext "$input" )_cropped.nii.gz"
        python3 "$IMMPY" hardcrop "$input" "$output"
}

#########################################################################################################################
###   SECTION 4 -- connectome / ROI / DICOM / misc
#########################################################################################################################
imm_unique() {
        # List the unique intensity values of an image.
        # usage: imm_unique <image.ext>
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_unique <image.ext>" >&2
            return 1
        fi
        local result; result="$( python3 "$IMMPY" unique "$1" )"   # BUGFIX B21
        result="${result//]/}"
        echo "${result//[/}"
}

imm_reshapeConn() {
        # Reorder an interleaved L/R connectome CSV into hemisphere-blocked form (+ .npy).
        # usage: imm_reshapeConn <connectome_in.csv> [<connectome_out.csv>] [<LUT_in>] [<LUT_out>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_reshapeConn <connectome_in.csv> [<out.csv>] [<LUT_in>] [<LUT_out>]" >&2
            return 1
        fi
        local connectome_csv="$1" connectome_csv_new="$2" LUT="$3" LUT_new="$4"
        local scriptpydir; scriptpydir="$( dirname "$CSVPACK" )"
        local modulepy;    modulepy="$( fbasename "$CSVPACK" )"

        [ -z "$connectome_csv_new" ] && \
            connectome_csv_new="$(dirname "$connectome_csv")/$( fbasename "$connectome_csv" )_rsp.csv"
        local output_file; output_file="$(dirname "$connectome_csv_new")/$( fbasename "$connectome_csv_new" ).npy"

        python3 -c "
import sys; sys.path.append('${scriptpydir}')
from ${modulepy} import csv2array, array2csv
import numpy as np
c = csv2array('${connectome_csv}')
IntraDX=c[1::2,1::2]; InterDX=c[1::2,0::2]; MatrixDX=np.concatenate([IntraDX,InterDX],axis=1)
IntraSX=c[0::2,0::2]; InterSX=c[0::2,1::2]; matrixSX=np.concatenate([InterSX,IntraSX],axis=1)
M=np.concatenate([MatrixDX,matrixSX])
np.save('${output_file}', M)
array2csv(M, output='${connectome_csv_new}', separator=' ')
"
        rm -f "$output_file"

        if [ -n "$LUT" ]; then
            local array_LUT; readarray -t array_LUT < "$LUT"
            [ -z "$LUT_new" ] && LUT_new="$(dirname "$LUT")/$( fbasename "$LUT" )_rsp.$( fextension "$LUT" )"
            local N="${#array_LUT[@]}" j line_1 labels_L="" labels_R="" keep_list=""
            for (( j=0; j<N-1; j++ )); do
                line_1=( ${array_LUT[j]} )
                keep_list="${keep_list} ${line_1[0]}"
                if [ $(( j % 2 )) -eq 0 ]; then labels_L="${labels_L},'${line_1[1]}'"
                else                            labels_R="${labels_R},'${line_1[1]}'"; fi
            done
            labels_R="${labels_R:1}"
            echo "$labels_R"; echo "$labels_L"
        fi
}

imm_dcm2jpg() {
        # DICOM -> JPEG.  usage: imm_dcm2jpg <dcm_path> [<outputdir>] [<adjust_contrast>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_dcm2jpg <dcm_path> [<outputdir>] [<adjust_contrast>]" >&2
            return 1
        fi
        local dcm_path="$1" outputdir="${2:-None}" adjust_contrast="${3:-0}"
        local scriptpydir; scriptpydir="$( dirname "$IMAGECONVERT" )"
        local modulepy;    modulepy="$( fbasename "$IMAGECONVERT" )"
        if [ "$outputdir" = "None" ]; then
            python3 -c "import sys; sys.path.append('${scriptpydir}')
from ${modulepy} import dcm2jpg; dcm2jpg('${dcm_path}')"
        else
            python3 -c "import sys; sys.path.append('${scriptpydir}')
from ${modulepy} import dcm2jpg; dcm2jpg('${dcm_path}', '${outputdir}', ${adjust_contrast})"
        fi
}

imm_nii2dcm() {
        # NIfTI -> DICOM series.  usage: imm_nii2dcm <nii_path> [<outputdir>] [<fields_dict>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_nii2dcm <nii_path> [<outputdir>] [<fields_dict>]" >&2
            return 1
        fi
        local nii_path="$1" outputdir="${2:-None}" fields_dict="$3"
        local scriptpydir; scriptpydir="$( dirname "$IMAGECONVERT" )"
        local modulepy;    modulepy="$( fbasename "$IMAGECONVERT" )"
        if [ "$outputdir" = "None" ]; then
            python3 -c "import sys; sys.path.append('${scriptpydir}')
from ${modulepy} import nii2dcm; nii2dcm('${nii_path}')"
        elif [ -n "$fields_dict" ]; then
            # BUGFIX B17: was `fileds=${fields_dict}` (typo).
            python3 -c "import sys; sys.path.append('${scriptpydir}')
from ${modulepy} import nii2dcm; nii2dcm('${nii_path}', '${outputdir}', fields=${fields_dict})"
        else
            # BUGFIX B17: original had an unterminated string here -> syntax error.
            python3 -c "import sys; sys.path.append('${scriptpydir}')
from ${modulepy} import nii2dcm; nii2dcm('${nii_path}', '${outputdir}')"
        fi
}

imm_createSphere() {
        # Binary sphere ROI centred at a voxel coordinate.
        # usage: imm_createSphere <input.ext> <x,y,z> <radius> [<output.ext>]
        if [ "$#" -lt 3 ]; then
            echo "${FUNCNAME[0]}: usage: imm_createSphere <input.ext> <coordinates> <radius> [<output.ext>]" >&2
            return 1
        fi
        local input="$1" radius="$3" output="$4"
        local coordinate=( ${2//,/ } )
        # BUGFIX B19: original mapped rz=coord[1], ry=coord[2] (Y/Z swapped). Corrected:
        local rx="${coordinate[0]}" ry="${coordinate[1]}" rz="${coordinate[2]}"
        [ -z "$output" ] && output="$( remove_ext "$input" )_roi${rx}x${ry}x${rz}"
        fslmaths "$input" -mul 0 -add 1 -roi "$rx" 1 "$ry" 1 "$rz" 1 0 1 "$output"
        fslmaths "$output" -kernel sphere "$radius" -fmean "$output"
        fslmaths "$output" -thr "$( imm_max "$output" )" "$output" -odt float
        fslmaths "$output" -bin "$output"
}

imm_createSphereX() {
        # Binary sphere ROI via MRtrix3 `mredit` (requires MRtrix3).
        # usage: imm_createSphereX <input.ext> <x,y,z> <radius> [<output.ext>] [<flip X|Y|Z>]
        if [ "$#" -lt 3 ]; then
            echo "${FUNCNAME[0]}: usage: imm_createSphereX <input.ext> <coordinates> <radius> [<output.ext>] [<flip>]" >&2
            return 1
        fi
        command -v mredit >/dev/null 2>&1 || { echo "${FUNCNAME[0]}: requires MRtrix3 (mredit)" >&2; return 1; }
        local input="$1" coordinate="$2" radius="$3" output="$4" flip="$5"
        local coordinate_x="${coordinate//,/x}"
        [ -z "$output" ] && output="$(dirname "$input")/ROI${coordinate_x}.nii.gz"
        fslmaths "$input" -mul 0 "$output"
        mredit -sphere "$coordinate" "$radius" 1 "$output"
        if [ -n "$flip" ]; then
            local output_edit; output_edit="$( remove_ext "$output" )_edit.nii.gz"
            imm_flip "$output" "$flip" "$output_edit" >/dev/null
            mv "$output_edit" "$output"
        fi
}

imm_orient_as() {
        # Copy the s-form/q-form orientation of <file_target> onto <file_in>.
        # usage: imm_orient_as <file_in.ext> <file_target.ext> [<file_out.ext>]
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_orient_as <file_in.ext> <file_target.ext> [<file_out.ext>]" >&2
            return 1
        fi
        local imm1="$1" imm2="$2" immo="$3"
        [ -n "$immo" ] && { cp "$imm1" "$immo"; imm1="$immo"; }
        fslorient -deleteorient "$imm1"
        fslorient -setsform $( fslorient -getsform "$imm2" ) "$imm1"
        fslorient -setqform $( fslorient -getqform "$imm2" ) "$imm1"
}

imm_compare() {
        # Echo 1 if two images are (near-)identical after peak-normalization, else 0.
        # usage: imm_compare <file1.ext> <file2.ext>
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_compare <file1.ext> <file2.ext>" >&2
            return 1
        fi
        local imm1="$1" imm2="$2"
        local t1="/tmp/temp_img1$(date +%s%N).nii.gz" t2="/tmp/temp_img2$(date +%s%N).nii.gz"
        [ "$( imm_size "$imm1" )" = "$( imm_size "$imm2" )" ] || { echo 0; return 0; }

        local max_1 max_2
        max_1="$( imm_max "$imm1" )"; max_2="$( imm_max "$imm2" )"
        fslmaths "$imm1" -div "$max_1" "$t1"
        fslmaths "$imm2" -div "$max_2" "$t2"
        fslmaths "$t1" -sub "$t2" -abs "$t1"

        local max_tmp1; max_tmp1="$( imm_max "$t1" )"
        max_tmp1="$( echo "scale=6; ${max_tmp1}*1000000" | bc )"   # 0.1% tolerance
        max_tmp1="${max_tmp1%.*}"
        [ "$( exists "$t1" )" -eq 1 ] && rm -f "$t1"
        [ "$( exists "$t2" )" -eq 1 ] && rm -f "$t2"
        # BUGFIX B18: original ran `{ 1; } || { 0; }` (no output). Echo the result.
        [ "${max_tmp1:-0}" -eq 0 ] && echo 1 || echo 0
}

imm_GaussSmooth() {
        # Gaussian smooth by FWHM (mm).  usage: imm_GaussSmooth <input.ext> <output.ext> <FWHM>
        if [ "$#" -lt 3 ]; then
            echo "${FUNCNAME[0]}: usage: imm_GaussSmooth <input.ext> <output.ext> <FWHM>" >&2
            return 1
        fi
        local tosmooth="$1" smoothed="$2" FWHM="$3" std
        std="$( echo "scale=5; ${FWHM}/2.355" | bc )"
        fslmaths "$tosmooth" -kernel gauss "$std" -fmean "$smoothed"
}

imm_coord2int() {
        # Round a coordinate list (file or single "x,y,z") to integer voxel indices.
        # usage: imm_coord2int <list.ext|x,y,z> [<output.ext>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_coord2int <list.ext|x,y,z> [<output.ext>]" >&2
            return 1
        fi
        local st_list="$1" output="$2"
        _round3() { awk -v a="$1" -v b="$2" -v c="$3" \
                    'BEGIN{printf "%d,%d,%d\n", a+0.5, b+0.5, c+0.5}'; }
        local type_=""
        [ -f "$st_list" ] && type_="$( file --mime-type -b "$st_list" 2>/dev/null | cut -d/ -f1 )"
        if [ "$type_" = "text" ]; then
            local array_1; readarray -t array_1 < "$st_list"
            local N="${#array_1[@]}" j v out
            for (( j=0; j<N; j++ )); do
                v=( ${array_1[j]//,/ } )
                out="$( _round3 "${v[0]}" "${v[1]}" "${v[2]}" )"
                echo "$out"
                [ -n "$output" ] && echo "$out" >> "$output"
            done
        else
            local v=( ${st_list//,/ } ) out
            out="$( _round3 "${v[0]}" "${v[1]}" "${v[2]}" )"
            echo "$out"
            [ -n "$output" ] && echo "$out" >> "$output"
        fi
}

imm_mni2cor() {
        # Convert MNI(mm) coordinates to MNI152 voxel indices (2mm default template offsets).
        # usage: imm_mni2cor <list.ext|x,y,z> [<output.ext>] [<spacing>] [<inv>] [<neg>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_mni2cor <list.ext|x,y,z> [<output>] [<spacing>] [<inv>] [<neg>]" >&2
            return 1
        fi
        local st_list="$1" output="$2" spacing="$3" invert="$4" neg="$5"
        [ -n "$output" ] && printf "" > "$output"

        local x1=1 x2=1 x3=1
        if [ -n "$spacing" ]; then
            local sv=( ${spacing//[x,]/ } ); x1="${sv[0]}" x2="${sv[1]}" x3="${sv[2]}"
        fi

        local tx ty tz
        if [ "${invert:-0}" -eq 1 ]; then
            tx=61; ty=85; tz=49
            # BUGFIX B20: original computed 1/x1 for all three; use each axis.
            x1="$( awk -v v="$x1" 'BEGIN{print 1/v}' )"
            x2="$( awk -v v="$x2" 'BEGIN{print 1/v}' )"
            x3="$( awk -v v="$x3" 'BEGIN{print 1/v}' )"
        else
            tx=90; ty=126; tz=72
        fi

        local inv=" -"
        [ "${neg:-0}" -eq 1 ] && inv=" +"

        _conv() {  # x y z -> "vx,vy,vz"
            local X Y Z
            X="$( echo "$1 * -1 * ${x1} + ${tx}" | bc )"
            Y="$( echo "$2 * ${x2} ${inv} ${ty}" | bc )"
            Z="$( echo "$3 * ${x3} ${inv} ${tz}" | bc )"
            awk -v a="$X" -v b="$Y" -v c="$Z" 'BEGIN{printf "%d,%d,%d\n", a+0.5, b+0.5, c+0.5}'
        }

        local type_=""
        [ -f "$st_list" ] && type_="$( file --mime-type -b "$st_list" 2>/dev/null | cut -d/ -f1 )"
        if [ "$type_" = "text" ]; then
            local array_1; readarray -t array_1 < "$st_list"
            local N="${#array_1[@]}" j v out
            for (( j=0; j<N; j++ )); do
                v=( ${array_1[j]//,/ } )
                out="$( _conv "${v[0]}" "${v[1]}" "${v[2]}" )"
                echo "$out"
                [ -n "$output" ] && echo "$out" >> "$output"
            done
        else
            local v=( ${st_list//,/ } ) out
            out="$( _conv "${v[0]}" "${v[1]}" "${v[2]}" )"
            echo "$out"
            [ -n "$output" ] && echo "$out" >> "$output"
        fi
}

imm_points2roi() {
        # Mark each voxel coordinate in <list> as 1 in a copy of <template>.
        # usage: imm_points2roi <list.ext> <template.ext> <output.ext>
        if [ "$#" -lt 3 ]; then
            echo "${FUNCNAME[0]}: usage: imm_points2roi <list.ext> <template.ext> <output.ext>" >&2
            return 1
        fi
        local st_list="$1" input="$2" output="$3"
        fslmaths "$input" -mul 0 "$output"
        local array_1; readarray -t array_1 < "$st_list"
        local N="${#array_1[@]}" j v
        for (( j=0; j<N; j++ )); do
            v=( ${array_1[j]//,/ } )
            echo "add point ${array_1[j]}"
            fslmaths "$output" -add 1 -roi "${v[0]}" 1 "${v[1]}" 1 "${v[2]}" 1 0 1 -add "$output" "$output"
        done
}

imm_points2roi_filled() {
        # Convex-hull-filled ROI from a list of voxel coordinates.
        # usage: imm_points2roi_filled <list.ext> <template.ext> <output.ext>
        if [ "$#" -lt 3 ]; then
            echo "${FUNCNAME[0]}: usage: imm_points2roi_filled <list.ext> <template.ext> <output.ext>" >&2
            return 1
        fi
        python3 "$IMMPY" points2roi_filled "$1" "$2" "$3"   # BUGFIX B21/B22
}

imm_castType() {
        # Cast image datatype (fslmaths -odt). usage: imm_castType <input.ext> <type> [<output.ext>]
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_castType <input.ext> <output_type> [<output.ext>]" >&2
            return 1
        fi
        local input="$1" type="$2" output="${3:-$1}"
        fslmaths "$input" "$output" -odt "$type"
}

imm_sortLabels() {
        # Renumber the labels of a segmentation to consecutive integers starting at 1.
        # usage: imm_sortLabels <input.ext> [<output.ext>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_sortLabels <input.ext> [<output.ext>]" >&2
            return 1
        fi
        local input="$1" output="$2"
        [ -z "$output" ] && output="$( remove_ext "$input" )_sorted.nii.gz"
        local input_temp="/tmp/img$(date +%s%N).nii.gz"
        imm_castType "$input" int "$input_temp"
        local values=( $( imm_unique "$input_temp" ) )
        echo "values found: ${values[*]}"
        local cont=0 label="/tmp/label$(date +%s%N).nii.gz" i
        fslmaths "$input_temp" -sub "$input_temp" "$output"
        for i in "${values[@]}"; do
            cont=$(( cont + 1 ))
            ThresholdImage 3 "$input_temp" "$label" "$i" "$i"
            fslmaths "$label" -bin -mul "$cont" "$label"
            fslmaths "$output" -add "$label" "$output"
        done
        rm -f "$input_temp" "$label"
}

imm_createInclusionSphere() {
        # Build a sphere just large enough to include a peak blob (uses MRtrix3 mredit).
        # usage: imm_createInclusionSphere <peak.ext> [<output.ext>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: imm_createInclusionSphere <peak.ext> [<output.ext>]" >&2
            return 1
        fi
        local peak="$1" sphere_out="$2"
        [ -z "$sphere_out" ] && sphere_out="$( remove_ext "$peak" )_inclusionSphere.nii.gz"
        local cog_img; cog_img="$( remove_ext "$peak" )_COG.nii.gz"
        local cog=( $( fslstats "$peak" -C ) )
        imm_createSphereX "$peak" "${cog[0]},${cog[1]},${cog[2]}" 1 "$cog_img" X
        local maxd; maxd="$( imm_maxDist "$cog_img" "$peak" )"
        imm_createSphereX "$peak" "${cog[0]},${cog[1]},${cog[2]}" "$maxd" "$sphere_out" X
}

imm_T2Wsynth() {
        # Synthesize a pseudo-T2w image from a T1w via intensity inversion + normalization.
        # usage: imm_T2Wsynth <T1.ext> <basename> [<T1_mask.ext>]
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: imm_T2Wsynth <T1.ext> <basename> [<T1_mask.ext>]" >&2
            return 1
        fi
        local T1="$1" base="$2" T1_mask="$3"
        [ "$( str_index "$base" '/' )" -ne -1 ] && mkdir -p "$(dirname "$base")"
        if [ -z "$T1_mask" ]; then
            T1_mask="${base}_brain_mask.nii.gz"
            bet "$T1" "${base}_brain" -m
        fi
        local maskbin="${base}_maskbin.nii.gz"
        fslmaths "$T1" -thrp 5 -bin -add "$T1_mask" "$maskbin"
        local inv="${base}_inv.nii.gz"
        fslmaths "$T1" -mul -1 -add "$( imm_max "$T1" )" "$inv"
        local inv_p="${base}_inv_pthr001.nii.gz"
        fslmaths "$inv" -thr "$( fslstats "$inv" -p 0.01 )" "$inv_p"
        local inv_p_sub="${base}_inv_pthr001_sub.nii.gz"
        fslmaths "$inv_p" -sub "$( imm_min "$inv_p" )" "$inv_p_sub"
        local inv_p_sub_avg="${base}_inv_pthr001_sub_avg.nii.gz"
        imm_setAverage "$inv_p_sub" "$inv_p_sub_avg" 100
        local inv_p_sub_avg_bg="${base}_inv_pthr001_sub_avg_bg.nii.gz"
        fslmaths "$maskbin" -mul "$inv_p_sub_avg" "$inv_p_sub_avg_bg"
        cp "$inv_p_sub_avg_bg" "${base}.nii.gz"
}
