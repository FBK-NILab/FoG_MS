#!/bin/bash
# =============================================================================
# run_all.sh
# PURPOSE: Runs the whole preprocessing pipeline (scripts 00-14) in order.
#          Stops at the first script that fails.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for script in "$SCRIPT_DIR"/[0-9][0-9]_*.sh; do
    echo
    echo "=================================================================="
    echo " $(basename "$script")"
    echo "=================================================================="
    bash "$script"
done
