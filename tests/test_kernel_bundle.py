"""Exercise bundle reuse through make and the Windows packaging entry point."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")


class KernelBundleTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for name in ("Makefile", "bin2cbundle.py", "libkrunfw.def"):
            shutil.copy(ROOT / name, self.root / name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        self.version = re.search(r"^KERNEL_VERSION = linux-(.+)$", (self.root / "Makefile").read_text(), re.M)[1]
        self.payload = f"fixture\0Linux version {self.version} (builder)\0".encode()
        (self.root / "Image").write_bytes(self.payload)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        if PWSH:
            self.script("powershell.exe", f"exec {shlex.quote(PWSH)} \"$@\"")

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        path.chmod(0o755)
        return path

    def run_command(self, *args):
        return subprocess.run(args, cwd=self.root, env=self.env, text=True,
                              capture_output=True, timeout=60)

    def generate(self, version=None):
        image = self.root / "old-Image"
        image.write_bytes(f"fixture\0Linux version {version or self.version} (builder)\0".encode())
        result = self.run_command(sys.executable, "bin2cbundle.py", "-t", "Image", str(image), "kernel.c")
        self.assertEqual(result.returncode, 0, result.stderr)

    def legacy_bundle(self):
        self.generate("6.12.109")
        path = self.root / "kernel.c"
        path.write_text(re.sub(r"^/\* libkrunfw kernel version: .*? \*/\n", "", path.read_text()))

    def builder(self, image="Image"):
        path = self.root / "build_in_docker.sh"
        path.write_text("#!/bin/sh\nset -eu\necho build >> builds.log\n" +
                        f"exec {shlex.quote(sys.executable)} bin2cbundle.py -t Image {image} kernel.c\n")
        path.chmod(0o755)

    def test_macos_rebuilds_stale_and_legacy_bundles_even_when_newer(self):
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                self.legacy_bundle() if legacy else self.generate("6.12.109")
                result = self.run_command("cc", "-shared", "-fPIC", "-DABI_VERSION=5", "kernel.c", "-o", "libkrunfw.5.dylib")
                self.assertEqual(result.returncode, 0, result.stderr)
                # A copied old bundle/library can be newer than every source file.
                os.utime(self.root / "kernel.c", (2000000000, 2000000000))
                os.utime(self.root / "libkrunfw.5.dylib", (2000000001, 2000000001))
                self.builder()
                result = self.run_command("make", "OS=Darwin", "CC=cc")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # Inspect the actual library in a fresh process, avoiding dlopen caching.
                probe = """
import ctypes
lib = ctypes.CDLL('./libkrunfw.5.dylib')
get = lib.krunfw_get_kernel
get.restype = ctypes.c_void_p
values = [ctypes.c_size_t() for _ in range(3)]
ptr = get(*(ctypes.byref(value) for value in values))
print(ctypes.string_at(ptr, values[2].value).split(b'\\0')[1].decode())
"""
                loaded = self.run_command(sys.executable, "-c", probe)
                self.assertEqual(loaded.returncode, 0, loaded.stderr)
                self.assertIn(f"Linux version {self.version} ", loaded.stdout)

    def test_macos_rejects_builder_that_returns_an_old_bundle(self):
        self.generate("6.12.109")
        self.builder("old-Image")
        result = self.run_command("make", "OS=Darwin", "CC=cc")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Kernel bundle version mismatch", result.stderr)
        self.assertFalse((self.root / "libkrunfw.5.dylib").exists())

    @unittest.skipUnless(PWSH, "PowerShell is required for Windows entry-point checks")
    def test_native_windows_make_checks_existing_library(self):
        for version in ("6.12.109", None, self.version):
            with self.subTest(version=version):
                self.legacy_bundle() if version is None else self.generate(version)
                (self.root / "libkrunfw-windows.dll").write_text("cached library")
                os.utime(self.root / "libkrunfw-windows.dll", (2000000001, 2000000001))
                result = self.run_command("make", "OS=Windows", "HOSTOS=Windows_NT")
                if version == self.version:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"not Linux {self.version}", result.stdout + result.stderr)

    @unittest.skipUnless(PWSH, "PowerShell is required for Windows entry-point checks")
    def test_windows_skip_bundle_rejects_stale_before_packaging(self):
        # Only replace unavailable native compiler tools; run the real packaging script.
        (self.root / "scripts/msvc-env.ps1").write_text("function Set-MsvcEnvironment {}\n")
        self.script("rc.exe", 'touch "$3"')
        self.script("cl.exe", "echo linked >> linked.log")
        for version in ("6.12.109", None, self.version):
            with self.subTest(version=version):
                self.legacy_bundle() if version is None else self.generate(version)
                result = self.run_command(PWSH, "-NoProfile", "-File", "scripts/build-windows.ps1",
                                          "-SkipKernelBundle", "-SkipVerify", "-Architecture", "x64",
                                          "-HostArchitecture", "x64", "-GuestArchitecture", "x86_64")
                if version == self.version:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue((self.root / "linked.log").exists())
                    self.assertTrue((self.root / "build/windows/kernel.bin").read_bytes().startswith(self.payload))
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"not Linux {self.version}", result.stdout + result.stderr)
                    self.assertFalse((self.root / "linked.log").exists())


if __name__ == "__main__":
    unittest.main()
