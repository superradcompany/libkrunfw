#!/usr/bin/env bash

set -euo pipefail

if (( $# != 2 )); then
    echo "Usage: $0 BRANCH HEAD_SHA" >&2
    exit 2
fi

branch=$1
head_sha=$2
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

# Check the exact revision, so daily runs do not rebuild an unchanged PR. Ignore
# cancelled/skipped runs, and retry a dispatch that previously failed to start.
runs=$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/kernel-ci.yml/runs" \
    --method GET \
    -f branch="$branch" \
    -f head_sha="$head_sha" \
    -f event=workflow_dispatch \
    -f per_page=100 \
    --jq '[.workflow_runs[] | select(.conclusion != "cancelled" and .conclusion != "skipped")] | length')
if (( runs > 0 )); then
    echo "Kernel CI already ran or is running for $head_sha"
    exit 0
fi

# GITHUB_TOKEN-created PRs cannot start ordinary PR workflows without approval.
# An explicit dispatch runs the existing six-build matrix on the PR's own head.
gh workflow run kernel-ci.yml --repo "$GITHUB_REPOSITORY" --ref "$branch"
