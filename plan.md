# libkrunfw Release Workflow Plan

## Overview

Replace the existing GitHub workflows with a single release workflow that produces bare library files for all supported platforms. These artifacts are downloaded directly by `microsandbox`'s `build.rs` — no tarballs, no decompression dependencies.

The `krunfw` branch is the default branch for this fork. `main` tracks upstream `containers/libkrunfw`.

---

## 1. Disable Existing Workflows

Comment out the triggers in all current workflows so they're disabled but kept for reference:

- `.github/workflows/build-x86_64.yml`
- `.github/workflows/build-aarch64.yml`
- `.github/workflows/build-sev.yml`
- `.github/workflows/build-tdx.yml`
- `.github/workflows/cross-build-riscv64.yml`
- `.github/workflows/publish-release.yml`

Comment out the entire contents of each file so GitHub won't run them. We don't need SEV, TDX, or riscv64 for microsandbox. PR validation can be re-added later if needed.

---

## 2. New Release Workflow

**File:** `.github/workflows/release.yml`

**Trigger:** GitHub release `published` event (tag a release → workflow runs → artifacts uploaded).

### Architecture

Two-stage pipeline. The kernel can only be compiled on Linux, but the `.dylib` must be linked on macOS (for correct Mach-O format). So:

```
Stage 1 (Linux runners)                    Stage 2 (macOS runners)
┌──────────────────────────┐
│ linux-x86_64             │
│ Build kernel + kernel.c  │───┐
│ Compile .so              │   │  upload kernel.c as job artifact
│ Upload .so to release    │   │
└──────────────────────────┘   │    ┌───────────────────────────┐
                               ├───→│ macos-x86_64              │
                               │    │ Download x86_64 kernel.c  │
                               │    │ cc -shared → .dylib       │
                               │    │ Upload .dylib to release  │
                               │    └───────────────────────────┘
┌──────────────────────────┐   │
│ linux-aarch64            │   │    ┌───────────────────────────┐
│ Build kernel + kernel.c  │───┼───→│ macos-aarch64             │
│ Compile .so              │   │    │ Download aarch64 kernel.c │
│ Upload .so to release    │   │    │ cc -shared → .dylib       │
└──────────────────────────┘   │    │ Upload .dylib to release  │
                               │    └───────────────────────────┘
                               │
                          (job artifacts)
```

Each Linux job:
1. Builds the kernel natively (x86_64 on `ubuntu-latest`, aarch64 on `ubuntu-24.04-arm`)
2. Generates `kernel.c` via `bin2cbundle.py`
3. Compiles and strips the `.so`
4. Uploads the `.so` to the GitHub release
5. Uploads `kernel.c` as a **job artifact** for the macOS stage

Each macOS job:
1. Downloads the matching `kernel.c` job artifact
2. Compiles: `cc -fPIC -DABI_VERSION=5 -shared -o <name>.dylib kernel.c`
3. Uploads the `.dylib` to the GitHub release

### Runners

| Job | Runner | Notes |
|-----|--------|-------|
| linux-x86_64 | `ubuntu-latest` | x86_64 native |
| linux-aarch64 | `ubuntu-24.04-arm` | aarch64 native |
| macos-aarch64 | `macos-latest` | Apple Silicon (M-series) |
| macos-x86_64 | `macos-13` | Last Intel macOS runner |

---

## 3. Release Artifacts

Bare library files with arch-differentiated names:

| Artifact | Platform | Architecture |
|----------|----------|-------------|
| `libkrunfw-linux-x86_64.so.5.2.1` | Linux | x86_64 |
| `libkrunfw-linux-aarch64.so.5.2.1` | Linux | aarch64 |
| `libkrunfw-macos-aarch64.5.dylib` | macOS | aarch64 (Apple Silicon) |
| `libkrunfw-macos-x86_64.5.dylib` | macOS | x86_64 (Intel) |

The naming convention is `libkrunfw-{os}-{arch}.{extension}` where the extension includes the version as per platform convention.

---

## 4. Version Extraction

The ABI version (`5`) and full version (`5.2.1`) are defined in the `Makefile`. The workflow should extract these from the Makefile rather than hardcoding them, so a version bump in the Makefile is the single source of truth:

```bash
ABI_VERSION=$(grep '^ABI_VERSION' Makefile | awk '{print $3}')
FULL_VERSION=$(grep '^FULL_VERSION' Makefile | awk '{print $3}')
```

---

## 5. Release Process

1. Bump `ABI_VERSION` / `FULL_VERSION` in `Makefile` if needed
2. Tag: `git tag v5.2.1`
3. Push: `git push origin krunfw --tags`
4. Create GitHub release from the tag (or use `gh release create`)
5. Workflow runs automatically, uploads all 4 artifacts

---

## 6. Replace `build_on_krunvm.sh` with Docker

The Makefile's macOS code path (line 100-102) calls `build_on_krunvm.sh` to compile the kernel inside a krunvm VM. We replace this with Docker so libkrunfw is self-contained and buildable on macOS without krunvm.

### What to remove

- `build_on_krunvm.sh`
- `build_on_krunvm_fedora.sh`
- `build_on_krunvm_debian.sh`

### What to add

**`build_in_docker.sh`** — drop-in replacement that does the same thing via Docker:

```bash
#!/bin/bash
set -euo pipefail

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
```

### Makefile change

Update the macOS path (line 100-102) from:

```makefile
$(KERNEL_C_BUNDLE):
	@echo "Building on macOS, using ./build_on_krunvm.sh"
	./build_on_krunvm.sh
```

To:

```makefile
$(KERNEL_C_BUNDLE):
	@echo "Building on macOS, using ./build_in_docker.sh"
	./build_in_docker.sh
```

### Why this lives in libkrunfw

- The Makefile already has the macOS branch — Docker is a direct swap for krunvm
- libkrunfw stays self-contained: clone → `make` → works on macOS
- microsandbox's justfile stays thin: just `cd lib/libkrunfw && make`
- Single source of truth — no duplicated Docker logic between repos

---

## 7. Implementation Steps

1. Comment out the entire contents of all existing workflow files
2. Remove `build_on_krunvm.sh`, `build_on_krunvm_fedora.sh`, `build_on_krunvm_debian.sh`
3. Add `build_in_docker.sh`
4. Update the Makefile macOS path to call `build_in_docker.sh`
5. Create `.github/workflows/release.yml` with the two-stage pipeline described above
6. Verify the workflow by creating a test release
