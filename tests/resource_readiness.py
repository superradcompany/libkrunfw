#!/usr/bin/env python3
"""Live readiness qualification against a disposable local microsandbox guest.

Requires a local msb supporting CPU/memory modify, the matching agentd, and the
firmware under test. Only the newly created private home and guest are changed.
Logs and the private home remain available for diagnosis; the guest is removed.
"""

import argparse
import json
from pathlib import Path
import platform
import socket
import hashlib
import os
import signal
import subprocess
import sqlite3
import tempfile
import time


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def environment(binary, firmware, home, agent=None):
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("MSB_")
        and key not in ("LD_PRELOAD", "DYLD_INSERT_LIBRARIES")
    }
    env.update(
        MSB_HOME=str(home),
        MSB_PATH=str(binary),
        MSB_BACKEND="local",
        MSB_CONFIG_PATH=str(home / "config.json"),
        MSB_LIBKRUNFW_PATH=str(firmware),
        NO_COLOR="1",
    )
    if agent:
        env["MSB_AGENTD_PATH"] = str(agent)
    return env


class Runner:
    def __init__(self, binary, env, output):
        self.binary, self.env, self.output = binary, env, output
        self.commands = []
        output.mkdir(parents=True, exist_ok=True)

    def run(self, label, *args, required=True):
        start = time.monotonic()
        command = [str(self.binary), *map(str, args)]
        # Bound each supervisor and reap its owned process group on interruption.
        # Persistent VMs have a separate lifecycle and are stopped in finally below.
        # No fixture command is interactive: never let a CLI consume the SSH shell
        # script from inherited stdin and silently skip the remaining matrix.
        with (
            (self.output / f"{label}.stdout").open("w") as stdout,
            (self.output / f"{label}.stderr").open("w") as stderr,
        ):
            with subprocess.Popen(
                command,
                env=self.env,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            ) as child:
                try:
                    code = child.wait(timeout=180)
                except BaseException:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    child.wait()
                    raise
        row = {
            "label": label,
            "command": command,
            "exit": code,
            "seconds": round(time.monotonic() - start, 3),
        }
        self.commands.append(row)
        (self.output / "commands.json").write_text(
            json.dumps(self.commands, indent=2) + "\n"
        )
        print(f"{label}: exit {code}", flush=True)
        if required and code:
            raise RuntimeError(
                f"{label} failed; see {self.output / (label + '.stderr')}"
            )
        return code


def cleanup(runner, prefix, sandbox):
    """Attempt both lifecycle operations even when the first command times out."""
    result = {}
    for operation in ("stop", "rm"):
        try:
            result[operation] = runner.run(
                prefix + "-cleanup-" + operation, operation, sandbox, required=False
            )
        except Exception as error:
            result[operation] = str(error)
    return result


p = argparse.ArgumentParser()
for name in ["binary", "firmware", "agent", "output", "temp-root"]:
    p.add_argument("--" + name, type=Path, required=True)
a = p.parse_args()
for key, value in vars(a).items():
    setattr(a, key, value.resolve())
a.output.mkdir(parents=True, exist_ok=False)
home = Path(tempfile.mkdtemp(prefix="msb-mr-", dir=a.temp_root)).resolve()
r = Runner(
    a.binary, environment(a.binary, a.firmware, home, a.agent), a.output / "commands"
)
report = {
    "host": platform.platform(),
    "home": str(home),
    "binary_sha256": digest(a.binary),
    "firmware_sha256": digest(a.firmware),
    "agent_sha256": digest(a.agent),
    "harness_sha256": digest(Path(__file__)),
    "status": "running",
    "observations": [],
}
name = "memory-readiness"
report["scope"] = "guest driver observation; host operation fencing not tested"


def guest(label, command):
    r.run(label, "exec", name, "--", "sh", "-ec", command)
    return (r.output / (label + ".stdout")).read_text()


def sample(label):
    output = guest(
        label,
        "uname -r; grep '^MemTotal:' /proc/meminfo; printf 'auto='; cat /sys/devices/system/memory/auto_online_blocks; for f in /sys/devices/system/memory/memory*/state; do printf '%s=' \"$f\"; cat \"$f\"; done",
    )
    return {
        "text": output,
        "total_kib": int(
            next(
                line.split()[1]
                for line in output.splitlines()
                if line.startswith("MemTotal:")
            )
        ),
        "offline_blocks": sum(
            line.startswith("/sys/devices/system/memory/memory")
            and line.endswith("=offline")
            for line in output.splitlines()
        ),
    }


def readiness(label, kind):
    # Read only the explicit driver attribute; absence or EAGAIN is not success.
    text = guest(
        label,
        f'for f in /sys/bus/virtio/devices/*/msb_{kind}_readiness; do test -f "$f" || continue; cat "$f"; done',
    )
    lines = text.strip().splitlines()
    if len(lines) != 1:
        raise RuntimeError(f"expected one {kind} observation, got {text!r}")
    values = dict(token.split("=", 1) for token in lines[0].split())
    result = {key: int(value) for key, value in values.items()}
    report.setdefault("readiness", {})[label] = result
    return result


def wait_ready(label, kind, predicate):
    deadline = time.monotonic() + 20
    index = 0
    while True:
        try:
            result = readiness(f"{label}-{index}", kind)
            if predicate(result):
                return result
        except Exception as error:
            report.setdefault("transient_observation_errors", []).append(str(error))
        if time.monotonic() > deadline:
            raise RuntimeError(f"{label} did not become ready")
        time.sleep(0.05)
        index += 1


def control(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(3)
        conn.connect(str(path))
        conn.sendall(b'{"op":"memory_state"}\n')
        with conn.makefile("rb") as f:
            value = json.loads(f.readline(65536))
    if not value.get("ok"):
        raise RuntimeError("memory state unavailable: " + json.dumps(value))
    report["observations"].append(
        {"monotonic": time.monotonic(), "memory": value["memory"]}
    )
    return value["memory"]


def wait_plugged(path, target, seconds=20, required=True):
    deadline = time.monotonic() + seconds
    while True:
        state = control(path)
        if state["target_mib"] == target and state["current_mib"] == target:
            return state
        if time.monotonic() >= deadline:
            if required:
                raise RuntimeError("device did not converge during probe")
            return state
        time.sleep(0.1)


try:
    r.run(
        "create",
        "create",
        "alpine:3.22",
        "--name",
        name,
        "--memory",
        "256M",
        "--max-memory",
        "768M",
        "--cpus",
        "1",
        "--max-cpus",
        "2",
        "--root-disk",
        "512M",
        "--max-duration",
        "5m",
    )
    candidates = list(home.rglob("control.sock"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one private control socket, got {candidates}")
    endpoint = candidates[0]
    report["baseline"] = sample("baseline")
    report["baseline_memory_readiness"] = wait_ready(
        "baseline-memory", "memory", lambda x: x["schema"] == 1 and x["all_online"] == 1
    )
    report["baseline_cpu_readiness"] = wait_ready(
        "baseline-cpu",
        "cpu",
        lambda x: (
            x["requested_online"] == 1 and x["actual_online"] == 1 and x["exact"] == 1
        ),
    )
    # One guest shell avoids charging host CLI startup time to every sysfs read.
    report["idle_read_loop"] = guest(
        "idle-read-loop",
        'f=; for p in /sys/bus/virtio/devices/*/msb_memory_readiness; do test -f "$p" && f="$p"; done; test -n "$f"; cat /proc/uptime; i=0; ok=0; failed=0; while test "$i" -lt 2000; do if IFS= read -r value < "$f"; then ok=$((ok+1)); else failed=$((failed+1)); fi; i=$((i+1)); done; echo "ok=$ok failed=$failed"; cat /proc/uptime; test "$ok" -eq 2000',
    )
    guest(
        "disable-auto-online",
        "echo offline > /sys/devices/system/memory/auto_online_blocks; cat /sys/devices/system/memory/auto_online_blocks",
    )
    r.run("grow", "modify", name, "--memory", "512M", "--format", "json")
    report["plugged_before_online"] = wait_plugged(endpoint, 512)
    report["guest_before_online"] = sample("plugged-but-offline")
    offline = wait_ready(
        "offline-memory",
        "memory",
        lambda x: (
            x["requested_size"] == 256 * 1024**2
            and x["plugged_size"] == 256 * 1024**2
            and x["all_online"] == 0
        ),
    )
    report["offline_memory_readiness"] = offline
    before = report["guest_before_online"]
    baseline = report["baseline"]
    if (
        before["offline_blocks"] == 0
        or abs(before["total_kib"] - baseline["total_kib"]) > 32768
    ):
        raise RuntimeError("fixture did not establish plugged-but-offline capacity")
    guest(
        "manual-online",
        'for f in /sys/devices/system/memory/memory*/state; do if test "$(cat "$f")" = offline; then echo online > "$f"; fi; done',
    )
    report["guest_after_online"] = sample("after-online")
    report["plugged_after_online"] = control(endpoint)
    if report["guest_after_online"]["total_kib"] - before["total_kib"] < 200 * 1024:
        raise RuntimeError("manual onlining did not expose the expected added capacity")
    if report["plugged_before_online"] != report["plugged_after_online"]:
        raise RuntimeError("host memory counters changed across manual onlining")
    report["online_memory_readiness"] = wait_ready(
        "online-memory",
        "memory",
        lambda x: (
            x["requested_size"] == 256 * 1024**2
            and x["plugged_size"] == 256 * 1024**2
            and x["all_online"] == 1
        ),
    )
    r.run("grow-partial", "modify", name, "--memory", "514M", "--format", "json")
    wait_plugged(endpoint, 514)
    report["partial_offline"] = wait_ready(
        "partial-offline",
        "memory",
        lambda x: x["plugged_size"] == 258 * 1024**2 and x["all_online"] == 0,
    )
    guest(
        "partial-manual-online",
        'for f in /sys/devices/system/memory/memory*/state; do if test "$(cat "$f")" = offline; then echo online > "$f"; fi; done',
    )
    report["partial_online"] = wait_ready(
        "partial-online",
        "memory",
        lambda x: x["plugged_size"] == 258 * 1024**2 and x["all_online"] == 1,
    )
    report["before_partial_fill"] = sample("before-partial-fill")
    r.run("grow-partial-fill", "modify", name, "--memory", "516M", "--format", "json")
    wait_plugged(endpoint, 516)
    report["partial_fill"] = wait_ready(
        "partial-fill",
        "memory",
        lambda x: x["plugged_size"] == 260 * 1024**2 and x["all_online"] == 1,
    )
    report["after_partial_fill"] = sample("after-partial-fill")
    if (
        report["after_partial_fill"]["total_kib"]
        - report["before_partial_fill"]["total_kib"]
        != 2048
    ):
        raise RuntimeError("online partial-block growth was not guest usable")
    r.run("cpu-grow", "modify", name, "--cpus", "2", "--format", "json")
    report["cpu_grown"] = wait_ready(
        "cpu-grown",
        "cpu",
        lambda x: (
            x["requested_online"] == 2 and x["actual_online"] == 2 and x["exact"] == 1
        ),
    )
    guest("cpu-manual-offline", "echo 0 > /sys/devices/system/cpu/cpu1/online")
    report["cpu_offline"] = wait_ready(
        "cpu-offline",
        "cpu",
        lambda x: (
            x["requested_online"] == 2 and x["actual_online"] == 1 and x["exact"] == 0
        ),
    )
    guest("cpu-manual-online", "echo 1 > /sys/devices/system/cpu/cpu1/online")
    report["cpu_online"] = wait_ready(
        "cpu-online",
        "cpu",
        lambda x: (
            x["requested_online"] == 2 and x["actual_online"] == 2 and x["exact"] == 1
        ),
    )
    r.run("cpu-shrink", "modify", name, "--cpus", "1", "--format", "json")
    report["cpu_shrunk"] = wait_ready(
        "cpu-shrunk",
        "cpu",
        lambda x: (
            x["requested_online"] == 1 and x["actual_online"] == 1 and x["exact"] == 1
        ),
    )
    r.run("shrink", "modify", name, "--memory", "256M", "--format", "json")
    report["shrink_reply"] = json.loads((r.output / "shrink.stdout").read_text())
    report["growth_reproduced"] = True
    report["shrink_state"] = wait_plugged(endpoint, 256, seconds=5, required=False)
    report["shrink_completed_within_5s"] = report["shrink_state"]["current_mib"] == 256
    report["guest_after_shrink"] = sample("after-shrink")
    report["status"] = "passed"
except BaseException as error:
    report["status"] = "failed"
    report["error"] = str(error)
    raise
finally:
    report["cleanup"] = cleanup(r, "final", name)
    if any(code != 0 for code in report["cleanup"].values()):
        report["status"] = "failed"
    db = home / "db/msb.db"
    if db.is_file():
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        try:
            report["remaining_sandboxes"] = conn.execute(
                "SELECT COUNT(*) FROM sandbox"
            ).fetchone()[0]
        finally:
            conn.close()
        if report["remaining_sandboxes"]:
            report["status"] = "failed"
    (a.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
if report["status"] != "passed":
    raise RuntimeError("probe or cleanup failed")
print(
    json.dumps(
        {
            "status": report["status"],
            "baseline_kib": report["baseline"]["total_kib"],
            "offline_kib": report["guest_before_online"]["total_kib"],
            "online_kib": report["guest_after_online"]["total_kib"],
        }
    )
)
