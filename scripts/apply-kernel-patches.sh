#!/usr/bin/env bash

set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 SOURCE_DIR PATCH..." >&2
    exit 2
fi

source_dir=$1
shift

for patch_file in "$@"; do
    # Force non-interactive behavior so a rejected or reversed patch fails the build immediately.
    patch -f -p1 -d "$source_dir" < "$patch_file"
done
