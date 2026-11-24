#!/bin/bash
# =============================================================================
# utils.sh
# PURPOSE: Helper functions shared by all the pipeline scripts (sourced, not run).
# =============================================================================

# first_match FILE...
# Takes the expansion of a glob and prints the first file that actually exists,
# or nothing if none exists (so that "[ -z ... ]" checks work with set -e).
# Prints a warning on stderr if more than one file matches.
first_match() {
    local matches=() f
    for f in "$@"; do
        if [[ -e "$f" ]]; then
            matches+=("$f")
        fi
    done
    if (( ${#matches[@]} == 0 )); then
        return 0
    fi
    if (( ${#matches[@]} > 1 )); then
        echo "[WARNING] ${#matches[@]} files match, using the first one: ${matches[0]}" >&2
    fi
    printf '%s\n' "${matches[0]}"
}

# already_done FILE
# True if FILE exists and OVERWRITE (config.sh) is not 1.
already_done() {
    [[ "${OVERWRITE:-0}" != "1" && -e "$1" ]]
}

# uses_flair_synth_t1 SESSION
# True if SESSION (e.g. ses-06) is listed in FLAIR_SYNTH_T1_SESSIONS (config.sh).
uses_flair_synth_t1() {
    local s
    for s in "${FLAIR_SYNTH_T1_SESSIONS[@]}"; do
        if [[ "$1" == "$s" ]]; then
            return 0
        fi
    done
    return 1
}

# session_of ANAT_FOLDER  -> prints "ses-XX"
session_of() {
    basename "$(dirname "$1")"
}

# subject_of ANAT_FOLDER  -> prints "sub-XXX"
subject_of() {
    basename "$(dirname "$(dirname "$1")")"
}
