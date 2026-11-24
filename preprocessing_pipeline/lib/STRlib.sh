#!/usr/bin/env bash
#########################################################################################################################
#   title:        String library
#   description:  Library of functions for string manipulations
#   version:      0.3.0   (modernized for Ubuntu 24.04+, GNU bash 5.x)
#   notes:        No external dependencies.
#   author:       gamorosino  (modernization pass 2026)
#   email:        g.amorosino@gmail.com
#
#   Changelog (0.2 -> 0.3.0)
#     * str_index:   literal (non-glob) substring search; quoted comparison; safe with special chars.
#     * str_indices: quoted/empty-safe separator handling; no leading-separator artefact.
#     * str_strip:   uses printf instead of `echo -e` so backslashes in input are preserved.
#     * Added an include guard so repeated sourcing is a no-op.
#########################################################################################################################

# --- include guard ------------------------------------------------------------------------------------------------
[ -n "${__STRLIB_SOURCED:-}" ] && return 0
__STRLIB_SOURCED=1

str_index() {
        ###################################################################################
        #   Index of the first occurrence of a substring inside a string (-1 if absent).
        #   usage: str_index <string> <substring>
        ###################################################################################
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: str_index <string> <substring>" >&2
            return 1
        fi
        local string="$1" needle="$2" head
        # Quoting "$needle" makes the pattern literal (no globbing of *, ?, [ ).
        head="${string%%"$needle"*}"
        if [ "$head" = "$string" ]; then
            echo -1
        else
            echo "${#head}"
        fi
}

str_indices() {
        ###################################################################################
        #   All indices of a single character inside a string, joined by <sep>.
        #   usage: str_indices <string> <target_char> [<sep>]
        #          <sep> defaults to "," ; the literal word "space" means a space.
        ###################################################################################
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: str_indices <string> <target_char> [<sep>]" >&2
            return 1
        fi
        local string="$1" target="$2" sep="${3:-,}"
        [ "$sep" = "space" ] && sep=" "
        local N="${#string}" i out=""
        for (( i=0; i<N; i++ )); do
            if [ "$target" = "${string:i:1}" ]; then
                if [ -z "$out" ]; then out="$i"; else out="${out}${sep}${i}"; fi
            fi
        done
        echo "$out"
}

str_strip() {
        ###################################################################################
        #   Remove all occurrences of a character class (default: whitespace) from a string.
        #   usage: str_strip <string> [<char_or_class>]
        #          <char_or_class> is passed to `tr -d`; defaults to "[:space:]".
        ###################################################################################
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: str_strip <string> [<char_or_class>]" >&2
            return 1
        fi
        local char="${2:-[:space:]}"
        # printf '%s' avoids `echo -e` mangling backslashes/escape sequences in the input.
        printf '%s' "$1" | tr -d "$char"
}
