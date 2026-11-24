#!/usr/bin/env bash
#########################################################################################################################
#   title:        Array library
#   description:  Functions implementing 1D vector stats and 2D associative-array helpers.
#   version:      0.4.0   (modernized for Ubuntu 24.04+, GNU bash 5.x)
#   usage example:
#                 declare -A array
#                 array[0,0]=1
#                 array[1,1]=0
#                 value="${array[1,1]}"
#                 maximum=$( array_max "${array[@]}" )
#                 keys:  "${!array[@]}"
#   notes:        needs STRlib.sh
#   author:       gamorosino  (modernization pass 2026)
#   email:        g.amorosino@gmail.com
#
#   Changelog (0.3.1 -> 0.4.0)
#     * array_max/min/mean/stdev/stdevs/neg/count reimplemented as single-pass awk:
#         - correct for floating point AND scientific notation (1.2e-3, 1E5, ...);
#         - one process instead of one `bc` per element (orders of magnitude faster);
#         - empty-input guards (no more "bc: empty expression" / divide-by-zero).
#     * array_stdevs now guards N<2 (sample stdev is undefined for a single element).
#     * Removed the duplicated array_rows definition (the file defined it twice).
#     * array_shape: removed a stray `echo ${list[@]}` that leaked the key list into the result.
#     * Fixed invalid `return -1` (bash exit codes are 0-255; -1 became 255) -> `return 1`.
#     * Quoted every test/expansion; deprecated *_old shims kept but hardened.
#########################################################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/STRlib.sh"

# --- include guard ------------------------------------------------------------------------------------------------
[ -n "${__ARRAYLIB_SOURCED:-}" ] && return 0
__ARRAYLIB_SOURCED=1

array_max() {
        # Maximum of the given values (floats & scientific notation supported).
        # usage: array_max <v1> <v2> ...   e.g. array_max "${array[@]}"
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_max <array_values>" >&2
            return 1
        fi
        awk 'BEGIN{ m=""; for(i=1;i<ARGC;i++){ v=ARGV[i]+0; if(m==""||v>m) m=v } print m }' "$@"
}

array_min() {
        # Minimum of the given values.
        # usage: array_min <v1> <v2> ...
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_min <array_values>" >&2
            return 1
        fi
        awk 'BEGIN{ m=""; for(i=1;i<ARGC;i++){ v=ARGV[i]+0; if(m==""||v<m) m=v } print m }' "$@"
}

array_mean() {
        # Arithmetic mean of the given values.
        # usage: array_mean <v1> <v2> ...
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_mean <array_values>" >&2
            return 1
        fi
        awk 'BEGIN{ s=0; n=ARGC-1; if(n<1){print 0; exit}
                    for(i=1;i<ARGC;i++) s+=ARGV[i]+0; printf "%f\n", s/n }' "$@"
}

array_count() {
        # Number of occurrences of <element> within the remaining values (numeric compare).
        # usage: array_count <element> <v1> <v2> ...
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: array_count <element> <array_values>" >&2
            return 1
        fi
        local target="$1"; shift
        awk -v t="$target" 'BEGIN{ c=0; tv=t+0;
                    for(i=1;i<ARGC;i++){ d=(ARGV[i]+0)-tv; if(d<0)d=-d; if(d<1e-9) c++ }
                    print c }' "$@"
}

array_rows() {
        # Number of rows of a 2D associative array, inferred from its keys ("r,c").
        # usage: array_rows "${!array[@]}"
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_rows <array_keys>" >&2
            return 1
        fi
        local keys="${*//,/ }"
        # shellcheck disable=SC2206
        local arr=( $keys )
        local max=0 i
        for (( i=0; i<${#arr[@]}; i+=2 )); do
            [ "${arr[i]}" -gt "$max" ] 2>/dev/null && max="${arr[i]}"
        done
        echo "$(( max + 1 ))"
}

array_columns() {
        # Number of columns of a 2D associative array, inferred from its keys ("r,c").
        # usage: array_columns "${!array[@]}"
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_columns <array_keys>" >&2
            return 1
        fi
        local keys="${*//,/ }"
        # shellcheck disable=SC2206
        local arr=( $keys )
        local max=0 i
        for (( i=1; i<${#arr[@]}; i+=2 )); do
            [ "${arr[i]}" -gt "$max" ] 2>/dev/null && max="${arr[i]}"
        done
        echo "$(( max + 1 ))"
}

array_shape() {
        # Shape of a 2D associative array from its keys.
        # usage: array_shape <array_keys> [<dim>]
        #        <dim>=1 -> rows ; <dim>=2 -> columns ; omitted -> "rows,cols"
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_shape <array_keys> [<dim>]" >&2
            return 1
        fi
        local list=( "$@" )
        local last_idx=$(( ${#list[@]} - 1 ))
        local roc="${list[$last_idx]}"
        local re='^[12]$'
        if [[ "$roc" =~ $re ]]; then
            unset 'list[last_idx]'
            if [ "$roc" -eq 1 ]; then
                array_rows "${list[@]}"
            else
                array_columns "${list[@]}"
            fi
        else
            local maxr maxc
            maxr="$( array_rows "${list[@]}" )"
            maxc="$( array_columns "${list[@]}" )"
            echo "${maxr},${maxc}"
        fi
}

array_zeros() {
        # Emit dim1*dim2 zeros (space-separated), mirroring the values of a zero matrix.
        # usage: array_zeros <dim1> <dim2>
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: array_zeros <dim1> <dim2>" >&2
            return 1
        fi
        local dim1="$1" dim2="$2" i j
        declare -A zeros
        for (( i=0; i<dim1; i++ )); do
            for (( j=0; j<dim2; j++ )); do
                zeros[$i,$j]=0
            done
        done
        echo "${zeros[@]}"
}

array_neg() {
        # Element-wise negation of the given values.
        # usage: array_neg <v1> <v2> ...
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_neg <vect>" >&2
            return 1
        fi
        awk 'BEGIN{ out="";
                    for(i=1;i<ARGC;i++){ v=-(ARGV[i]+0); out=(out==""?sprintf("%f",v):out " " sprintf("%f",v)) }
                    print out }' "$@"
}

array_iselement() {
        # 1 if <value> is present among the remaining values (string compare), else 0.
        # usage: array_iselement <value> <v1> <v2> ...
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: array_iselement <value> <vect>" >&2
            return 1
        fi
        local value="$1"; shift
        local v
        for v in "$@"; do
            [ "$v" = "$value" ] && { echo 1; return 0; }
        done
        echo 0
}

array_stdev() {
        # Population standard deviation (divisor N).
        # usage: array_stdev <v1> <v2> ...
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_stdev <vect>" >&2
            return 1
        fi
        awk 'BEGIN{ n=ARGC-1; if(n<1){print 0; exit}
                    s=0; for(i=1;i<ARGC;i++) s+=ARGV[i]+0; m=s/n;
                    ss=0; for(i=1;i<ARGC;i++){ d=(ARGV[i]+0)-m; ss+=d*d }
                    printf "%f\n", sqrt(ss/n) }' "$@"
}

array_stdevs() {
        # Sample standard deviation (divisor N-1). Requires at least 2 values.
        # usage: array_stdevs <v1> <v2> ...
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: array_stdevs <vect>" >&2
            return 1
        fi
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: sample stdev needs >= 2 values" >&2
            return 1
        fi
        awk 'BEGIN{ n=ARGC-1; s=0; for(i=1;i<ARGC;i++) s+=ARGV[i]+0; m=s/n;
                    ss=0; for(i=1;i<ARGC;i++){ d=(ARGV[i]+0)-m; ss+=d*d }
                    printf "%f\n", sqrt(ss/(n-1)) }' "$@"
}

#########################################################################################################################
# Deprecated shims (kept for backward compatibility; prefer the names above).
#########################################################################################################################
array_columns_old()   { array_columns "$@"; }
array_iselement_old() { array_iselement "$@"; }
