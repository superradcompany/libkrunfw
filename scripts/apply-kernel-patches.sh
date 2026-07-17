#!/usr/bin/env bash

set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 SOURCE_DIR PATCH..." >&2
    exit 2
fi

source_dir=$1
shift

for patch_file in "$@"; do
    output=$(patch -f -p1 -d "$source_dir" < "$patch_file" 2>&1) || {
        status=$?
        printf '%s\n' "$output" >&2
        exit "$status"
    }
    printf '%s\n' "$output"

    # GNU and BSD patch use different messages for unsafe context or line-number adjustments.
    if grep -Eiq 'with fuzz|offset [-+]?[0-9]+ lines?|no such line [0-9]+ in input file, ignoring' <<< "$output"; then
        echo "Patch did not apply exactly: $patch_file" >&2
        exit 1
    fi
done
