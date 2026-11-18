# Multigrain timestamp backport

The 6.12 firmware uses coarse inode timestamps by default. A write followed by `stat`, another write and another `stat` can return identical modification timestamps even though the contents changed. Patches 0036–0050 backport upstream multigrain timestamps without changing `CONFIG_HZ`. Filesystems opt in through `FS_MGTIME`: ext4, XFS, Btrfs and tmpfs are included.

When a file's mtime or ctime has been queried, a subsequent update can use a fine timestamp. A shared timekeeping floor preserves timestamp ordering between files that use coarse and fine timestamps. This is not a unique identifier for every write, and applications must retain the timestamp's nanosecond precision. Host-shared virtio-fs paths have a separate timestamp path and are not covered by this guest-filesystem test.

## Upstream provenance and follow-up audit

The original series is the 13 non-merge commits in [Linux's multigrain merge](https://github.com/torvalds/linux/commit/6ac81fd55e8af8e78a716b4ba213c8c6381d94fd). Each patch retains its upstream commit ID, author, description and sign-offs. The patches are applied after the existing firmware series.

| Firmware patch | Upstream commit | Purpose |
|---|---|---|
| 0036 | `4e40eff0b5737c0de39e1ae5812509efbc0b986e` | VFS timestamp infrastructure |
| 0037 | `b82f92d5dd1a365ab1e13518c8bf799f6fec4518` | Attribute updates |
| 0038 | `ee3283c608dfa21251b0821d7bb198c7ae3189f6` | Timekeeping floor |
| 0039 | `2a15385742c689a271345dcbb4c28b9c568bc7ce` | Floor counters |
| 0040 | `7f2c86cba3c584c7227cddaabdf0ab54c8151e60` | Delegated timestamp handling |
| 0041 | `c86e3c47187ad7fa17f8533a4142453991684b46` | Tracepoints |
| 0042 | `73a47cf40f84312cb6ea2b3583825d671930b24f` | VFS counters |
| 0043 | `e3fad0376d80f91b45e0db3f3634f15e1dd22768` | Kernel documentation |
| 0044 | `1cf7e834a6fb84de9d1e038d6cf4c5bd0d202ffa` | XFS integration |
| 0045 | `d0382c698f9c9c80483987e1b4661b5d97a805d4` | ext4 integration |
| 0046 | `e2e801d6e62507c297ec2c102e24d09c90618e8b` | Btrfs integration |
| 0047 | `234d8895e3ad8ddb93d687d665086bd303901d87` | tmpfs integration |
| 0048 | `9fed2c0f2f0771b990d068ef0a2b32e770ae6d48` | Cache filesystem opt-in on the inode |
| 0049 | `12f2930f5f91bc0d67794c69d1961098c7c72040` | Make XFS start-commit observe timestamps for change detection |
| 0050 | `c610d2d0787961cdd6fc1de69d9be1ff3687e1a6` | Annotate concurrent timestamp accesses with READ_ONCE/WRITE_ONCE |

The follow-up audit on 2026-11-17 checked upstream multigrain, timestamp-floor and setattr history, including references to the original commits. The ksmbd fix `21e46a79bbe6c4e1aa73b3ed998130f2ff07b128` and overlayfs fix `03dbab3bba5f009d053635c729d1244f2c8bad38` are already present in the 6.12 stable source and are not duplicated. Later NFS delegated-attribute feature work (`ATTR_CTIME_SET`) is outside this backport; the firmware disables network filesystems. The later F2FS opt-in is also outside this series.

## Local regression test

On an ARM64 Linux host, install a compiler with static libc, BusyBox static, QEMU, cpio, gzip, e2fsprogs, xfsprogs and btrfs-progs. Build the firmware using its normal config, then run:

```sh
make -j"$(nproc)" kernel.c
scripts/test-multigrain.sh linux-6.12.118/arch/arm64/boot/Image
```

The test boots the supplied kernel in QEMU with a minimal initramfs and three disposable disk images. It verifies tmpfs, ext4, XFS and Btrfs mounts before running the checks. The host filesystem's timestamp behaviour does not affect the guest test. QEMU uses software emulation by default, including in CI; `QEMU_ACCEL=kvm` can be used when local virtualization is available. `CC` and `BUSYBOX` can select ARM64 binaries when running from another architecture.

For each filesystem, the test checks 10,000 observed writes, cross-file timestamp ordering, explicit `futimens` values, `UTIME_NOW`, `UTIME_OMIT`, chmod, truncation and concurrent stat/write access. The guest must report success and must not emit a kernel warning, BUG or Oops. The elapsed time printed by the reproducer is diagnostic output, not a controlled performance benchmark.

To demonstrate the original bug, pass an unpatched firmware image and `--expect-coarse`. This mode requires actual timestamp collisions instead of treating them as success accidentally:

```sh
scripts/test-multigrain.sh /path/to/baseline/Image --expect-coarse
```

The local 6.12.117 before/after run used identical ARM64 configs at 100 Hz. Each filesystem reported 9,999 mtime and ctime collisions in 10,000 writes before the backport and zero afterward. The patched kernel also passed the software-emulated CI path. Full ARM64 and x86_64 kernel builds passed. With Microsandbox v0.7.15 on macOS ARM64, the backport passed boot, command execution, DNS/HTTP, timestamp checks on the root overlay and tmpfs, full snapshot/restore, repeated timestamp checks after restore, and graceful shutdown.

## Host-runtime compatibility and rollout

The kernel pin is 6.12.118. The complete patch series, including the four TEE patches, applies to this version; ARM64 and x86_64 builds and the QEMU timestamp suite pass. The stable update adds virtio-fs response validation, which exposed a pre-existing host bug: released `msb_krun_devices` 0.1.45 reports zero used length for every filesystem response. With that host, the guest reports `virtio-fs: response too short (0)` and cannot execute `/init.krun`.

The companion libkrun fix publishes the byte count returned by the FUSE server, preserving zero for requests that have no reply. The corrected host paired with this 6.12.118 firmware passed Microsandbox boot, command execution, DNS/HTTP, 10,000-write timestamp checks on both root overlay and tmpfs, full snapshot/restore, repeated checks after restore, and graceful shutdown on macOS ARM64. The root-overlay run exercises Microsandbox integration; the separate QEMU disk tests establish guest ext4, XFS and Btrfs behaviour independently of host-backed virtio-fs timestamps.

Ship this firmware with a Microsandbox runtime containing the companion host fix. Do not replace firmware independently for older runtimes that still report zero completion lengths. The kernel's response validation remains enabled. The corrected host also passed the same lifecycle checks with 6.12.117 and restored a 6.12.117 full snapshot created by the released v0.7.15 host; the restored guest correctly retained its older kernel.

Use a freshly booted guest when validating new firmware. A running guest or saved guest-memory snapshot retains its existing kernel; replacing the firmware library does not upgrade that kernel in place.
