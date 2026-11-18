#!/usr/bin/env bash

set -euo pipefail

update=false
if [[ ${1:-} == --update ]]; then
    update=true
    shift
fi
if (( $# > 1 )); then
    echo "Usage: $0 [--update] [MAKEFILE]" >&2
    exit 2
fi

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
    if [[ $update == false ]]; then
        echo "Kernel $current is not the latest ${series}.y release; update to $latest" >&2
        exit 1
    fi

    # A stale mirror must never turn an automated update into a kernel downgrade.
    if (( 10#${current##*.} > 10#${latest##*.} )); then
        echo "Refusing to downgrade kernel $current to $latest" >&2
        exit 2
    fi

    python3 - "$makefile" "$current" "$latest" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
current, latest = sys.argv[2:]
source = path.read_text()
# Preserve comments and formatting, and refuse ambiguous version declarations.
pattern = r"(?m)^([ \t]*KERNEL_VERSION[ \t]*=[ \t]*)linux-([0-9]+\.[0-9]+\.[0-9]+)(?=[ \t]*(?:#.*)?$)"
matches = list(re.finditer(pattern, source))
if len(matches) != 1 or matches[0].group(2) != current:
    sys.exit("Expected exactly one unchanged KERNEL_VERSION assignment")
updated = re.sub(pattern, lambda match: match.group(1) + "linux-" + latest, source)
path.write_text(updated)
PY
    echo "Updated kernel $current to $latest" >&2
fi
