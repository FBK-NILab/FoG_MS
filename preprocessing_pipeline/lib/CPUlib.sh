#!/usr/bin/env bash
#########################################################################################################################
#   title:        CPU library
#   description:  Functions for multi-process management and resource probing.
#   version:      0.3.0   (modernized for Ubuntu 24.04+, GNU bash 5.x, procps-ng 4.x)
#   author:       gamorosino  (modernization pass 2026)
#   email:        g.amorosino@gmail.com
#
#   Changelog (0.2.1.1 -> 0.3.0)
#     * CPUs_available:   no longer parses `top` by fixed columns (which breaks across procps
#                         versions and locales that print a comma decimal separator). Now samples
#                         /proc/stat over a short interval -> idle fraction * nproc. Locale-proof.
#     * memory_available: no longer indexes `free -m` by position (memo_vect[7]/[8], wrong on
#                         procps-ng 4.x) and no longer returns total-used. Reads MemAvailable from
#                         /proc/meminfo, the kernel's own estimate of reclaimable+free memory (MB).
#     * waiting4script / waiting4children(/_old): added a poll interval so the loops no longer
#                         spin a core at 100% CPU; quoted all tests.
#     * elapsed_time:     same output, computed with a single locale-independent arithmetic pass.
#     * date_ms:          documented (returns whole seconds, as before); date_ms_real added for ms.
#########################################################################################################################

# --- include guard ------------------------------------------------------------------------------------------------
[ -n "${__CPULIB_SOURCED:-}" ] && return 0
__CPULIB_SOURCED=1

CPUs_available() {
        ###################################################################################
        #   Estimate the number of free logical CPUs from instantaneous load.
        #   Samples /proc/stat over POLL seconds (locale-independent, no `top` dependency).
        ###################################################################################
        local poll="${1:-0.3}"
        local ncpu; ncpu="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"

        read -r _ a b c d e f g h _ < /proc/stat        # first 'cpu' aggregate line
        local idle1=$(( d + e )) total1=$(( a + b + c + d + e + f + g + h ))
        sleep "$poll"
        read -r _ a b c d e f g h _ < /proc/stat
        local idle2=$(( d + e )) total2=$(( a + b + c + d + e + f + g + h ))

        local dt=$(( total2 - total1 )) di=$(( idle2 - idle1 ))
        [ "$dt" -le 0 ] && { echo "$ncpu"; return 0; }
        # free = round(ncpu * idle_fraction)
        awk -v n="$ncpu" -v di="$di" -v dt="$dt" 'BEGIN{ printf "%d\n", (n*di/dt)+0.5 }'
}

memory_available() {
        ###################################################################################
        #   Available RAM in MB, as reported by the kernel (MemAvailable in /proc/meminfo).
        #   This accounts for reclaimable page cache, unlike a naive total-used subtraction.
        ###################################################################################
        local kb
        kb="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)"
        if [ -z "$kb" ]; then
            # Fallback for ancient kernels without MemAvailable: MemFree + Buffers + Cached.
            kb="$(awk '/^MemFree:|^Buffers:|^Cached:/{s+=$2} END{print s}' /proc/meminfo)"
        fi
        echo "$(( kb / 1024 ))"
}

waiting4script() {
        ###################################################################################
        #   Block until fewer than <process_number> processes matching <script_name> remain.
        #   usage: waiting4script <script_name> <process_number> [ global ]
        #          global=1 -> count across the whole machine; otherwise only descendants of $$.
        ###################################################################################
        if [ "$#" -lt 2 ]; then
            echo "${FUNCNAME[0]}: usage: waiting4script <script_name> <process_number> [ global ]" >&2
            return 1
        fi
        local script_name="$1" script_number="$2" global="${3:-0}"
        local scope=()
        [ "$global" -ne 1 ] && scope=( -P "$$" )
        while :; do
            local pids=( $( pgrep "${scope[@]}" -f "$script_name" ) )
            [ "${#pids[@]}" -lt "$script_number" ] && break
            sleep 0.2
        done
}

waiting4children() {
        ###################################################################################
        #   Block until fewer than <process_number> child processes (optionally named
        #   <cmd_name>) of the current shell remain.
        #   usage: waiting4children <process_number> [ cmd_name ]
        ###################################################################################
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: waiting4children <process_number> [ cmd_name ]" >&2
            return 1
        fi
        local script_number="$1" cmd_name="$2"
        while :; do
            local pids
            if [ -z "$cmd_name" ]; then
                pids=( $( pgrep -P "$$" ) )
            else
                pids=( $( pgrep -P "$$" -x "$cmd_name" ) )
            fi
            [ "${#pids[@]}" -lt "$script_number" ] && break
            sleep 0.2
        done
}

waiting4children_old() {
        ###################################################################################
        #   Legacy variant kept for compatibility: counts children via /proc/$$/task.
        #   usage: waiting4children_old <process_number> [ cmd_name ]
        ###################################################################################
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: waiting4children_old <process_number> [ cmd_name ]" >&2
            return 1
        fi
        local script_number="$1" cmd_name="$2"
        while :; do
            local children; children="$( cat /proc/$$/task/$$/children 2>/dev/null )"
            local cnt
            if [ -z "$cmd_name" ]; then
                local arr=( $children ); cnt="${#arr[@]}"
            else
                if [ -z "$children" ]; then
                    cnt=0
                else
                    cnt="$( ps -o cmd= -p $children 2>/dev/null | grep -c -- "$cmd_name" )"
                fi
            fi
            [ "$cnt" -lt "$script_number" ] && break
            sleep 0.2
        done
}

date_ms() {
        # Current Unix time in WHOLE SECONDS (unchanged for backward compatibility).
        date +%s
}

date_ms_real() {
        # Current Unix time in milliseconds (new helper).
        date +%s%3N
}

elapsed_time() {
        ###################################################################################
        #   Human-readable elapsed time since <start_epoch_seconds>.
        #   usage: elapsed_time <start_epoch_seconds>
        ###################################################################################
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: elapsed_time <start_epoch_seconds>" >&2
            return 1
        fi
        local start="$1" end; end="$(date +%s)"
        local sec=$(( end - start ))
        local h=$(( sec / 3600 ))
        local m=$(( (sec % 3600) / 60 ))
        local s=$(( sec % 60 ))
        echo "${h}h ${m}m ${s}s"
}

setITKthreads() {
        ###################################################################################
        #   Set OMP / ITK thread counts (e.g. for ANTs).  usage: setITKthreads <n>
        ###################################################################################
        if [ "$#" -lt 1 ]; then
            echo "${FUNCNAME[0]}: usage: setITKthreads <n>" >&2
            return 1
        fi
        export OMP_NUM_THREADS="$1"
        export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$1"
}
