"""Exercise actual patched sysfs functions with synthetic kernel state/locks.

This covers classification and refusal paths, not real kernel scheduling or
memory hotplug. resource_readiness.py separately exercises live guests.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PATCH = (
    Path(__file__).resolve().parents[1]
    / "patches/0036-virtio-expose-guest-resource-readiness.patch"
)


def implementation(name):
    lines = PATCH.read_text().splitlines()
    starts = [
        index
        for index, line in enumerate(lines)
        if line.startswith(f"+static ssize_t {name}_show(")
    ]
    if len(starts) != 1:
        raise ValueError(f"expected one implementation of {name}")
    output = []
    for line in lines[starts[0] :]:
        if line == f"+static DEVICE_ATTR_RO({name});":
            return "\n".join(output)
        if not line.startswith("+"):
            raise ValueError("implementation must be extracted completely")
        output.append(line[1:])
    raise ValueError("missing implementation terminator")


class ResourceReadinessTests(unittest.TestCase):
    def test_classification_and_lock_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="msb-readiness-test-") as directory:
            root = Path(directory)
            (root / "observers.inc").write_text(
                implementation("msb_memory_readiness")
                + "\n"
                + implementation("msb_cpu_readiness")
            )
            command = [
                os.environ.get("CC", "cc"),
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wno-unused-parameter",
                "-I",
                str(root),
                str(Path(__file__).with_suffix(".c")),
                "-o",
                str(root / "test"),
            ]
            subprocess.run(command, check=True, timeout=60)
            subprocess.run([str(root / "test")], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
