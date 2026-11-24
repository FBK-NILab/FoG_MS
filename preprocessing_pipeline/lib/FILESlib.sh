#!/usr/bin/env bash
#########################################################################################################################
#   title:        Files library
#   description:  Functions for file management.
#   version:      0.8.0   (modernized for Ubuntu 24.04+, GNU bash 5.x)
#   notes:        needs STRlib.sh
#   author:       gamorosino  (modernization pass 2026)
#   email:        g.amorosino@gmail.com
#
#   Changelog (0.7.1 -> 0.8.0)
#     * gdrive_download:  removed `exit 1` (it killed the *caller's* interactive shell inside a
#                         sourced lib). Now `return`s. Prefers `gdown` if installed; otherwise uses
#                         the current drive.usercontent.google.com confirm=t endpoint, since the old
#                         docs.google.com cookie/confirm-token scheme no longer works.
#     * cmpfolders:       dropped the `tree` dependency (not installed by default on Ubuntu 24, and
#                         its output format changed). Compares the recursive relative file list with
#                         `diff` (use cmpfolders <a> <b> 1 to also compare file *contents*).
#     * checkAbsPath:     replaced hand-rolled "." / ".." string math with `realpath -m` (coreutils),
#                         which canonicalizes robustly; falls back to PWD-prefixing if unavailable.
#     * merge_txtRows:    temp file via `mktemp` (no predictable /tmp name -> no race/symlink risk).
#     * dispLog/_old:     default poll interval so the tail loop no longer pegs a CPU core.
#     * exists:           single `[ -e ]` test (covers files, dirs and symlinks).
#     * Quoted every expansion; fixed invalid `return -1` -> `return 1`.
#########################################################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/STRlib.sh"

# --- include guard ------------------------------------------------------------------------------------------------
[ -n "${__FILESLIB_SOURCED:-}" ] && return 0
__FILESLIB_SOURCED=1

exists() {
        # Echo 1 if the path exists (file, directory or symlink), 0 otherwise.
        # usage: exists <path>
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: exists <path>" >&2
            return 1
        fi
        [ -e "$1" ] && echo 1 || echo 0
}

exists_old() {
        # Legacy two-argument form. usage: exists_old <path> [<type 0=file 1=dir>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: exists_old <path> [<type>]" >&2
            return 1
        fi
        local ftype="${2:-0}"
        if [ "$ftype" -eq 0 ]; then
            { [ -e "$1" ] && [ -f "$1" ]; } && echo 1 || echo 0
        else
            [ -d "$1" ] && echo 1 || echo 0
        fi
}

fbasename() {
        # Basename with directory and (FSL-style) extension removed: everything from the first dot.
        # NB: like the original, "a.b.txt" -> "a"; "img.nii.gz" -> "img".
        # usage: fbasename <path>
        basename "$1" | cut -d '.' -f 1
}

fextension() {
        # Last extension component of a filename (e.g. "img.nii.gz" -> "gz").
        # usage: fextension <path>
        local filename; filename="$( basename "$1" )"
        echo "${filename##*.}"
}

hnumb2tnumb() {
        # Human-readable size (K/M/G/T) -> plain number of bytes.
        # usage: hnumb2tnumb <human_size>
        local hnumber="$1" digits
        digits="${hnumber//[^0-9]/}"
        case "$hnumber" in
            *T*) echo "$( echo "scale=6; ${digits}*1000000000000" | bc )" ;;
            *G*) echo "$( echo "scale=6; ${digits}*1000000000"    | bc )" ;;
            *M*) echo "$( echo "scale=6; ${digits}*1000000"       | bc )" ;;
            *K*) echo "$( echo "scale=6; ${digits}*1000"          | bc )" ;;
            *)   echo "$hnumber" ;;
        esac
}

tnumb2hnumb() {
        # Plain number -> human-readable size (K/M/G/T).
        # usage: tnumb2hnumb <number>
        local tnumber="$1" order="${#1}" numba intg deci
        _trim_zeros() { numba="$1"; intg="${numba%.*}"; deci="${numba:${#intg}+1}"
                        [ "${#deci}" -eq "$( grep -o '0' <<<"$deci" | wc -l )" ] && numba="$intg"; }
        if   ( [ "$order" -gt 3 ]  && [ "$order" -lt 7 ]  ); then
            _trim_zeros "$( echo "scale=3; ${tnumber}/1000" | bc )";          echo "${numba}K"
        elif ( [ "$order" -gt 6 ]  && [ "$order" -lt 10 ] ); then
            _trim_zeros "$( echo "scale=3; ${tnumber}/1000000" | bc )";       echo "${numba}M"
        elif ( [ "$order" -gt 9 ]  && [ "$order" -lt 13 ] ); then
            _trim_zeros "$( echo "scale=3; ${tnumber}/1000000000" | bc )";    echo "${numba}G"
        elif   [ "$order" -gt 12 ]; then
            _trim_zeros "$( echo "scale=3; ${tnumber}/1000000000000" | bc )"; echo "${numba}T"
        else
            echo "$tnumber"
        fi
}

transfperc() {
        # Live progress estimate of a copy/delete/download toward <target_size>.
        # usage: transfperc <target_size> [<filename>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: transfperc <target_size> [<filename>]" >&2
            return 1
        fi
        local filename="$2" type
        if [ -n "$filename" ]; then
            if [ -d "$filename" ]; then type=0
            elif [ "$( exists "$filename" )" -eq 1 ]; then type=1
            else echo "file or directory does not exist!" >&2; return 1; fi
        else
            type=2
        fi
        while [ -z "$( sync )" ]; do
            local tnumber target="$1"
            case "$type" in
                0) tnumber=( $( du "$filename" -h --total | grep total ) ) ;;
                1) tnumber=( $( ls -sh "$filename" ) ) ;;
                2) tnumber=( $( du -h --total | grep total ) ) ;;
                *) echo "error" >&2; return 1 ;;
            esac
            tnumber="${tnumber[0]}"
            local wtnumber wtarget diff_tnumber
            wtnumber="$( str_strip "$( hnumb2tnumb "$tnumber" )" )"
            wtarget="$(  str_strip "$( hnumb2tnumb "$target" )" )"
            tnumber="$( tnumb2hnumb "$wtnumber" )"
            target="$(  tnumb2hnumb "$wtarget" )"
            wtnumber="$( echo "scale=4; ${wtnumber} / ${wtarget}" | bc )"
            diff_tnumber="$( echo "scale=4; ${wtarget} - ${wtnumber}" | bc )"
            wtnumber="$( echo "scale=4; ${wtnumber} * 100" | bc )"
            diff_tnumber="${diff_tnumber%.*}"
            [ "${diff_tnumber:-0}" -le 0 ] && { echo "done"; break; }
            echo -ne "${wtnumber:0:-2}% done (${tnumber} of ${target})\033[0K\r"
        done
}

cmpfolders() {
        # Echo 1 if two folders contain the same files, else 0.
        # usage: cmpfolders <dirA> <dirB> [<compare_contents 0|1>]
        # With compare_contents=1 the file *contents* are compared too (recursive diff).
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: cmpfolders <dirA> <dirB> [<compare_contents 0|1>]" >&2
            return 1
        fi
        local a="$1" b="$2" deep="${3:-0}"
        if [ "$deep" -eq 1 ]; then
            diff -rq "$a" "$b" >/dev/null 2>&1 && echo 1 || echo 0
        else
            local la lb
            la="$( cd "$a" 2>/dev/null && find . | sort )"
            lb="$( cd "$b" 2>/dev/null && find . | sort )"
            [ "$la" = "$lb" ] && echo 1 || echo 0
        fi
}

checkAbsPath() {
        # Canonicalize <path> to an absolute path (does not require the path to exist).
        # usage: checkAbsPath <path>
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: checkAbsPath <path>" >&2
            return 1
        fi
        if command -v realpath >/dev/null 2>&1; then
            realpath -m -- "$1"
        else
            case "$1" in
                /*) echo "$1" ;;
                *)  echo "${PWD}/$1" ;;
            esac
        fi
}

dispLog_old() {
        # Legacy single-file log tailer. usage: dispLog_old <file_log> [<last_flag>] [<sleep_time>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: dispLog_old <file_log> [<last_flag>] [<sleep_time>]" >&2
            return 1
        fi
        local file_in_1="$1" last_flag="${2:-0}" sleep_time="${3:-0.5}" last_line=""
        while :; do
            mapfile -t array_1 < "$file_in_1"
            if [ "$last_flag" -eq 1 ]; then
                echo -ne "${array_1[-1]}\033[0K\r"
            else
                local this_line="${array_1[-1]}"; this_line="${this_line//   /}"
                [ "$this_line" = "$last_line" ] || echo "${array_1[-1]}"
                last_line="$this_line"
            fi
            sleep "$sleep_time"
        done
}

checkAbsPath_old() {
        # Original hand-rolled canonicalizer, kept for reference/compatibility.
        local data="$1" data_dir; data_dir="$( dirname "$data" )"
        if   [ "$data_dir" = "." ]; then data="${PWD}/$( basename "$data" )"
        elif [ "${data_dir:0:2}" = ".." ]; then data="$( dirname "$PWD" )${data:2}"
        elif [ "${data_dir:0:1}" = "." ];  then data="${PWD}${data:1}"
        else case "$data" in /*) : ;; *) data="${PWD}/${data}" ;; esac
        fi
        echo "$data"
}

dispLog() {
        # Dynamically print the last line of a log (and optional error) file as it changes.
        # usage: dispLog <file_log> [<file_err>] [<sleep_time>]
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: dispLog <file_log> [<file_err>] [<sleep_time>]" >&2
            return 1
        fi
        local file_in_1="$1" file_in_2="$2" sleep_time="${3:-0.5}"
        local last_line_1="" last_line_2=""
        while :; do
            mapfile -t array_1 < "$file_in_1"
            local this_line_1="${array_1[-1]}"; this_line_1="${this_line_1// /}"
            [ "$this_line_1" = "$last_line_1" ] || echo "${array_1[-1]}"
            last_line_1="$this_line_1"
            if [ -n "$file_in_2" ]; then
                mapfile -t array_2 < "$file_in_2"
                local this_line_2="${array_2[-1]}"; this_line_2="${this_line_2// /}"
                [ "$this_line_2" = "$last_line_2" ] || echo "${array_2[-1]}"
                last_line_2="$this_line_2"
            fi
            sleep "$sleep_time"
        done
}

merge_txtRows() {
        # Concatenate the rows of several text files side by side (paste-like).
        # usage: merge_txtRows <file1,file2,...> <file_out> [<sep>]   (sep "null" -> no separator)
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: merge_txtRows <file_list> <file_out> [<sep>]" >&2
            return 1
        fi
        local file_list="$1" file_out="$2" sep="$3"
        if   [ -z "$sep" ];        then sep="    "
        elif [ "$sep" = "null" ];  then sep=""
        fi
        local file_vect=( ${file_list//,/ } )
        local file_final; file_final="$( mktemp )"
        : > "$file_final"
        cp "${file_vect[0]}" "$file_out"
        local M="${#file_vect[@]}" i j
        for (( i=1; i<M; i++ )); do
            mapfile -t array_1 < "$file_out"
            mapfile -t array_2 < "${file_vect[$i]}"
            local N="${#array_1[@]}"
            for (( j=0; j<N; j++ )); do
                local new_line="${array_1[j]}${sep}${array_2[j]}"
                local ary=( $new_line ); new_line="${ary[*]}"
                echo "$new_line" >> "$file_final"
            done
            cp "$file_final" "$file_out"
            : > "$file_final"
        done
        rm -f "$file_final"
}

gdrive_getID() {
        # Extract a Google Drive file ID from a share URL (echoes "None" if not found).
        # usage: gdrive_getID <url>
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: gdrive_getID <url>" >&2
            return 1
        fi
        local url="$1" fileid="" i
        local patterns=( "s/.*\/file\/d\/\(.*\)\/.*/\1/p" "s/.*id=\(.*\)/\1/p" "s/\(.*\)/\1/p" )
        for i in "${patterns[@]}"; do
            fileid="$( echo "$url" | sed -n "$i" )"
            [ -n "$fileid" ] && break
        done
        [ -z "$fileid" ] && fileid="None"
        echo "$fileid"
}

gdrive_download() {
        # Download a public Google Drive file.  usage: gdrive_download <url> <filename>
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: gdrive_download <url> <filename>" >&2
            return 1
        fi
        local url="$1" filename="$2" fileid
        fileid="$( gdrive_getID "$url" )"
        [ "$fileid" = "None" ] && { echo "Could not find Google ID" >&2; return 1; }
        echo "File ID: $fileid" >&2

        # Preferred: gdown handles the current confirm/virus-scan flow and large files.
        if command -v gdown >/dev/null 2>&1; then
            gdown --id "$fileid" -O "$filename"
            return $?
        fi

        # Fallback: current usercontent endpoint with confirm=t (replaces the old, now-broken
        # docs.google.com cookie/confirm-token scheme).
        local cookies; cookies="$( mktemp )"
        if command -v wget >/dev/null 2>&1; then
            wget --quiet --save-cookies "$cookies" --keep-session-cookies \
                 "https://drive.usercontent.google.com/download?id=${fileid}&export=download&confirm=t" \
                 -O "$filename"
        elif command -v curl >/dev/null 2>&1; then
            curl -L -c "$cookies" \
                 "https://drive.usercontent.google.com/download?id=${fileid}&export=download&confirm=t" \
                 -o "$filename"
        else
            echo "Need gdown, wget or curl to download." >&2
            rm -f "$cookies"; return 1
        fi
        rm -f "$cookies"
}
