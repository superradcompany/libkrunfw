#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Boot a supplied ARM64 kernel with disposable disks and test guest timestamps.
set -euo pipefail

if (( $# < 1 || $# > 2 )) || [[ ${2:-} != "" && ${2:-} != --expect-coarse ]]; then
    echo "Usage: $0 ARM64_KERNEL_IMAGE [--expect-coarse]" >&2
    exit 2
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
kernel=$(realpath "$1")
expect=${2:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Compile for the guest architecture, not the host when cross-compiling.
"${CC:-cc}" -O2 -Wall -Wextra -Werror -static "$repo/tests/multigrain.c" -o "$work/multigrain"
mkdir -p "$work/root"/{bin,dev,proc,sys,tmp,ext4,xfs,btrfs}
cp "${BUSYBOX:-/bin/busybox}" "$work/root/bin/busybox"
cp "$work/multigrain" "$work/root/bin/multigrain"
ln -s busybox "$work/root/bin/sh"
cat > "$work/root/init" <<'INIT'
#!/bin/sh
export PATH=/bin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
failed=0
# MMIO device discovery can reverse the order of QEMU's drive arguments.
# Use the virtio disk serial rather than assuming vda/vdb/vdc assignment.
for device in /sys/block/vd*; do
    fs=$(cat "$device/serial")
    case "$fs" in
        ext4|xfs|btrfs) mount -t "$fs" "/dev/${device##*/}" "/$fs" || failed=1 ;;
        *) echo "FAIL: unexpected disk serial $fs"; failed=1 ;;
    esac
done
expect=
grep -q 'mgtime_expect_coarse=1' /proc/cmdline && expect=--expect-coarse
uname -a
for fs in /tmp /ext4 /xfs /btrfs; do
    if grep -q " $fs " /proc/mounts; then
        /bin/multigrain "$fs" $expect || failed=1
    else
        echo "FAIL: $fs is not mounted"
        failed=1
    fi
done
sync
if dmesg | grep -E 'WARNING:|BUG:|Oops:|KASAN:|KCSAN:'; then
    failed=1
fi
if [ "$failed" -eq 0 ]; then
    echo MULTIGRAIN_TEST_PASS
else
    echo MULTIGRAIN_TEST_FAIL
fi
poweroff -f
INIT
chmod +x "$work/root/init"
(cd "$work/root" && find . -print0 | cpio --null -o --format=newc --quiet) | gzip > "$work/initramfs.gz"

truncate -s 256M "$work/ext4.img"
mkfs.ext4 -q -F -L mg-ext4 "$work/ext4.img"
truncate -s 512M "$work/xfs.img"
mkfs.xfs -q -f -L mg-xfs "$work/xfs.img"
truncate -s 256M "$work/btrfs.img"
mkfs.btrfs -q -f -L mg-btrfs "$work/btrfs.img"

cmdline="console=ttyAMA0 panic=-1"
[[ -z "$expect" ]] || cmdline+=" mgtime_expect_coarse=1"
accel=${QEMU_ACCEL:-tcg}
cpu=max
[[ "$accel" != kvm ]] || cpu=host
# TCG works without nested virtualization; KVM makes repeated local runs faster.
timeout 180 qemu-system-aarch64 -machine virt,gic-version=3 -accel "$accel" \
    -cpu "$cpu" -smp 2 -m 1024 -nographic -no-reboot \
    -kernel "$kernel" -initrd "$work/initramfs.gz" -append "$cmdline" \
    -drive "file=$work/ext4.img,format=raw,if=none,id=ext4" -device virtio-blk-device,drive=ext4,serial=ext4 \
    -drive "file=$work/xfs.img,format=raw,if=none,id=xfs" -device virtio-blk-device,drive=xfs,serial=xfs \
    -drive "file=$work/btrfs.img,format=raw,if=none,id=btrfs" -device virtio-blk-device,drive=btrfs,serial=btrfs \
    -nic none | tee "$work/console.log"
grep -q '^MULTIGRAIN_TEST_PASS' "$work/console.log"
! grep -q '^MULTIGRAIN_TEST_FAIL' "$work/console.log"
