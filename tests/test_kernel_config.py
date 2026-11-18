"""Keep Windows guest features aligned with the generic x86_64 kernel."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
WINDOWS_HYPERV = {
    "CONFIG_HYPERV",
    "CONFIG_HYPERV_TIMER",
    "CONFIG_HYPERV_UTILS",
    "CONFIG_PCI_HYPERV",
}


def read_config(name):
    values = {}
    for line in (ROOT / name).read_text().splitlines():
        enabled = re.fullmatch(r"(CONFIG_\w+)=(.*)", line)
        disabled = re.fullmatch(r"# (CONFIG_\w+) is not set", line)
        if enabled:
            values[enabled[1]] = enabled[2]
        elif disabled:
            values[disabled[1]] = "n"
    return values


class KernelConfigTests(unittest.TestCase):
    def setUp(self):
        self.generic = read_config("config-libkrunfw_x86_64")
        self.windows = read_config("config-libkrunfw-windows_x86_64")

    def test_windows_matches_generic_except_hyperv(self):
        # Compare every setting, so future generic updates cannot silently leave
        # Windows without guest features such as Docker networking or IPC.
        for name in sorted((self.generic.keys() | self.windows.keys()) - WINDOWS_HYPERV):
            with self.subTest(option=name):
                self.assertEqual(self.windows.get(name, "n"), self.generic.get(name, "n"))

    def test_windows_retains_hyperv_settings(self):
        # KVM alone does not enable the Hyper-V enlightened VMCS path needed by
        # Intel nested snapshot capture. Preserve the Windows Hyper-V preset.
        for name in sorted(WINDOWS_HYPERV):
            with self.subTest(option=name):
                self.assertEqual(self.windows.get(name), "y")


if __name__ == "__main__":
    unittest.main()
