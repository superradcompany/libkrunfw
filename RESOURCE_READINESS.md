# Guest resource readiness observations

Patch 0036 exposes optional, read-only driver observations in the guest. These distinguish plugged memory from onlined memory and the requested CPU count from the actual online CPU set. They do not change virtio device layouts, feature bits, host enforcement, memory onlining policy, or the existing CPU acknowledgment field.

## Memory

Read `/sys/bus/virtio/devices/<device>/msb_memory_readiness` on the virtio-mem device:

```text
schema=1 addr=4294967296 region_size=536870912 requested_size=268435456 plugged_size=268435456 all_online=0
```

All sizes and addresses are decimal bytes. `requested_size` and `plugged_size` describe the virtio-mem region only; they exclude boot memory. `all_online=1` means all currently plugged capacity is online in Linux at the observation point. Zero plugged capacity satisfies that condition. It does not mean the requested target was reached: consumers must also compare requested and plugged sizes with the operation's expected target. This field is neither free memory nor `/proc/meminfo`'s `MemTotal`.

The observation excludes the whole resize worker, including partial-block fake-onlining, and concurrent memory notifiers. Small-block mode detects plugged or partly plugged offline blocks while ignoring empty offline blocks. Big-block mode also rejects fake-offline capacity. A failed or incomplete shrink remains pending when plugged size differs from the target; it must not be reported as a permanent refusal merely because it takes longer than a waiting deadline.

## CPU

Read `/sys/bus/virtio/devices/<device>/msb_cpu_readiness` on the Microsandbox CPU device:

```text
schema=1 possible=2 requested_online=2 actual_online=1 exact=0
```

`exact=1` means the online set is exactly CPU IDs `0..requested_online-1`. A count alone cannot establish that the guest's online set matches the host-enforced prefix. The observation excludes the convergence worker and CPU hotplug while reading. Guest state is evidence of completion, not authority to change host-enforced limits.

## Availability and host obligations

A read returns `EAGAIN` when the relevant locks are busy or driver work/configuration changes are pending. Memory observation returns `EOPNOTSUPP` in a kdump kernel and `EIO` for a broken/removing device. Invalid CPU configuration returns `EPROTO`. Attribute creation failure warns without failing device initialization. Older kernels and builds without these drivers have no attribute; consumers must report the stronger observation as unsupported instead of inventing completion.

Each successful line is one instantaneous device observation. CPU and memory are independent. The caller must bound reads, validate the schema and fields, select the correct device, and bracket the guest read with host runtime identity and per-resource operation generation. Both bracket checks must match the same operation and target; memory also requires matching device range. A changed runtime/generation invalidates the sample, including target ABA. Missing, busy, malformed or stale observations do not establish completion. These files alone do not implement operation retention, reconnects, waits, supersession, or exported metric semantics.

The guest can change resource state immediately after a sample. Consumers must retain observation age and distinguish historical completion from current capacity. An untrusted guest's report is not an isolation guarantee; host enforcement remains authoritative.

## Validation

Run `python3 -m unittest discover -s tests -p 'test_*.py'` for the synthetic classification and existing bundle tests. The classification test extracts the actual patched observer functions and checks block states, pending work, wrong CPU sets, error paths and lock cleanup.

Build the normal firmware and run the live test with a locally built `msb` that supports CPU/memory modification and its matching guest agent:

```sh
python3 tests/resource_readiness.py \
  --binary /absolute/path/msb \
  --firmware /absolute/path/libkrunfw.so.5 \
  --agent /absolute/path/agentd \
  --output /absolute/path/new-report-directory \
  --temp-root /absolute/path/private-test-parent
```

On macOS use the dylib and an entitled `msb` binary. The test creates its own private `MSB_HOME`, exercises a disposable Alpine guest and attempts stop/removal on failure as well as success. It retains logs and the private home for diagnosis. It checks plugged-but-offline growth, manual onlining, filling a partial online block, CPU grow/offline/online/shrink, repeated reads and catalog cleanup. The bounded shrink observation records whether the target was reached; it does not require an otherwise busy guest to shrink successfully. Kernel build, state-classification tests and this live test do not establish host operation fencing or every kernel race/failure mode.
