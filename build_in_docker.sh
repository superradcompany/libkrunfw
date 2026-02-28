#!/bin/bash
set -euo pipefail

# This is a helper script for building the Linux kernel on macOS using
# a Docker container (Fedora-based).

SCRIPTPATH="$(cd "$(dirname "$0")" && pwd)"

docker run --rm \
    -v "$SCRIPTPATH:/work" \
    -w /work \
    fedora:latest \
    bash -c "
        dnf install -y 'dnf-command(builddep)' python3-pyelftools curl && \
        dnf builddep -y kernel && \
        make -j\$(nproc)
    "

if [ ! -e "$SCRIPTPATH/kernel.c" ]; then
    echo "There was a problem building the kernel bundle in Docker"
    exit 1
fi
