#!/usr/bin/env bash

set -euo pipefail

makefile=${1:-Makefile}
stable_repo=${KERNEL_STABLE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}

current=$(awk '$1 == "KERNEL_VERSION" && $2 == "=" { sub(/^linux-/, "", $3); print $3; exit }' "$makefile")
if [[ ! $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Could not read a stable kernel version from $makefile" >&2
    exit 2
fi

series=${current%.*}
if ! tags=$(git ls-remote --refs --tags "$stable_repo" "v${series}.*"); then
    echo "Could not query stable kernel tags from $stable_repo" >&2
    exit 2
fi

# Ignore release candidates and non-stable suffixes, then compare patch numbers numerically.
latest=$(awk -v series="$series" '
    {
        tag = $2
        sub(/^refs\/tags\/v/, "", tag)
        count = split(tag, part, ".")
        if (count == 3 && part[1] "." part[2] == series && part[3] ~ /^[0-9]+$/) {
            patch = part[3] + 0
            if (!found || patch > newest) {
                newest = patch
                found = 1
            }
        }
    }
    END {
        if (found) {
            printf "%s.%d\n", series, newest
        }
    }
' <<< "$tags")

if [[ -z $latest ]]; then
    echo "No stable v${series}.y tags were found in $stable_repo" >&2
    exit 2
fi

echo "current=$current"
echo "latest=$latest"

if [[ $current != "$latest" ]]; then
    echo "Kernel $current is not the latest ${series}.y release; update to $latest" >&2
    exit 1
fi
