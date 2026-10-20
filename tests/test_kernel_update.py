"""Exercise kernel update preparation and dispatch without accessing GitHub."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/check-kernel-version.sh"
DISPATCH = ROOT / "scripts/dispatch-kernel-ci.sh"


class KernelUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.makefile = self.directory / "Makefile"
        self.source = (
            "# Kernel pin\n"
            "KERNEL_VERSION = linux-6.12.9 # stable series\n"
            "FULL_VERSION = 5.6.1\n"
            "REFERENCE = linux-6.12.9\n"
        )
        self.makefile.write_text(self.source)
        self.log = self.directory / "commands.jsonl"
        self.env = {
            **os.environ,
            "PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
            "COMMAND_LOG": str(self.log),
            "KERNEL_STABLE_REPO": "https://example.invalid/stable.git",
            "GITHUB_REPOSITORY": "example/libkrunfw",
            "FAKE_TAGS": "6.12.9\n6.12.10",
            "FAKE_GIT_STATUS": "0",
            "FAKE_GH_RUN_COUNT": "0",
            "FAKE_GH_QUERY_STATUS": "0",
            "FAKE_GH_DISPATCH_STATUS": "0",
        }
        self.install_command(
            "git",
            """
if sys.argv[1:4] != ["ls-remote", "--refs", "--tags"]:
    sys.exit("Unexpected git mutation or invocation")
for tag in os.environ["FAKE_TAGS"].splitlines():
    print("0" * 40 + "\\trefs/tags/v" + tag)
sys.exit(int(os.environ["FAKE_GIT_STATUS"]))
""",
        )
        self.install_command(
            "gh",
            """
if sys.argv[1] == "api":
    print(os.environ["FAKE_GH_RUN_COUNT"])
    sys.exit(int(os.environ["FAKE_GH_QUERY_STATUS"]))
if sys.argv[1:3] == ["workflow", "run"]:
    sys.exit(int(os.environ["FAKE_GH_DISPATCH_STATUS"]))
sys.exit("Unexpected GitHub mutation or invocation")
""",
        )

    def install_command(self, name, body):
        executable = self.directory / name
        executable.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            'with open(os.environ["COMMAND_LOG"], "a") as log:\n'
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            + body
        )
        executable.chmod(0o755)

    def run_check(self, update=False):
        arguments = ["bash", str(CHECK)]
        if update:
            arguments.append("--update")
        return subprocess.run(
            arguments + [str(self.makefile)],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def run_dispatch(self):
        return subprocess.run(
            ["bash", str(DISPATCH), "appcypher/kernel-stable-update", "a" * 40],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_check_still_rejects_outdated_kernel_without_editing(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.makefile.read_text(), self.source)
        self.assertEqual(result.stdout, "current=6.12.9\nlatest=6.12.10\n")

    def test_update_changes_only_pin_and_ignores_other_series_and_suffixes(self):
        self.env["FAKE_TAGS"] = (
            "6.12.9\n6.12.100\n6.12.11\n6.12.101-rc1\n6.12.999-extra\n"
            "6.12.999.1\n6.13.200\n7.0.1\n6.12.100^{}"
        )
        result = self.run_check(update=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "current=6.12.9\nlatest=6.12.100\n")
        self.assertEqual(
            self.makefile.read_text(),
            self.source.replace(
                "KERNEL_VERSION = linux-6.12.9",
                "KERNEL_VERSION = linux-6.12.100",
            ),
        )
        self.assertEqual(self.commands()[0][-1], "v6.12.*")

    def test_repeated_update_does_not_touch_current_file(self):
        first = self.run_check(update=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        before = self.makefile.stat().st_mtime_ns
        second = self.run_check(update=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, "current=6.12.10\nlatest=6.12.10\n")
        self.assertEqual(self.makefile.stat().st_mtime_ns, before)

    def test_update_preserves_assignment_spacing(self):
        source = self.source.replace("KERNEL_VERSION = ", "\tKERNEL_VERSION\t=\t")
        self.makefile.write_text(source)
        result = self.run_check(update=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.makefile.read_text(),
            source.replace("=\tlinux-6.12.9", "=\tlinux-6.12.10"),
        )

    def test_network_failure_cannot_modify_pin(self):
        self.env["FAKE_GIT_STATUS"] = "128"
        result = self.run_check(update=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.makefile.read_text(), self.source)
        self.assertEqual(result.stdout, "")

    def test_no_stable_tags_cannot_modify_pin(self):
        self.env["FAKE_TAGS"] = "6.12.10-rc1\n6.13.1"
        result = self.run_check(update=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.makefile.read_text(), self.source)

    def test_update_refuses_downgrade(self):
        self.env["FAKE_TAGS"] = "6.12.8"
        result = self.run_check(update=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Refusing to downgrade", result.stderr)
        self.assertEqual(self.makefile.read_text(), self.source)

    def test_invalid_pin_never_queries_remote(self):
        source = self.source.replace("linux-6.12.9", "linux-6.12")
        self.makefile.write_text(source)
        result = self.run_check(update=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.makefile.read_text(), source)
        self.assertFalse(self.log.exists())

    def test_ambiguous_assignments_cannot_be_partially_updated(self):
        source = self.source + "KERNEL_VERSION = linux-6.12.8\n"
        self.makefile.write_text(source)
        result = self.run_check(update=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one", result.stderr)
        self.assertEqual(self.makefile.read_text(), source)

    def test_new_revision_dispatches_existing_workflow_on_update_branch(self):
        result = self.run_dispatch()
        self.assertEqual(result.returncode, 0, result.stderr)
        query, dispatch = self.commands()
        self.assertIn("head_sha=" + "a" * 40, query)
        self.assertIn("branch=appcypher/kernel-stable-update", query)
        self.assertIn("event=workflow_dispatch", query)
        self.assertEqual(
            dispatch,
            [
                "workflow", "run", "kernel-ci.yml",
                "--repo", "example/libkrunfw",
                "--ref", "appcypher/kernel-stable-update",
            ],
        )

    def test_existing_revision_does_not_dispatch_duplicate_builds(self):
        self.env["FAKE_GH_RUN_COUNT"] = "1"
        result = self.run_dispatch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.commands()), 1)

    def test_failed_run_lookup_does_not_dispatch_blindly(self):
        self.env["FAKE_GH_QUERY_STATUS"] = "1"
        result = self.run_dispatch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.commands()), 1)

    def test_dispatch_failure_fails_monitor_and_can_be_retried(self):
        self.env["FAKE_GH_DISPATCH_STATUS"] = "1"
        result = self.run_dispatch()
        self.assertNotEqual(result.returncode, 0)
        self.env["FAKE_GH_DISPATCH_STATUS"] = "0"
        result = self.run_dispatch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.commands()), 4)


if __name__ == "__main__":
    unittest.main()
