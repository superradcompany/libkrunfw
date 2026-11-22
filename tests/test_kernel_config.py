"""Keep Windows and cloud guest kernel feature configs aligned."""

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

# Architecture-independent guest capabilities that must stay enabled and aligned
# across the cloud x86_64 and aarch64 presets.
CLOUD_SHARED_FEATURES = {
    # Security / LSM
    "CONFIG_SECURITY": "y",
    "CONFIG_SECURITYFS": "y",
    "CONFIG_SECURITY_PATH": "y",
    "CONFIG_SECURITY_LANDLOCK": "y",
    "CONFIG_SECURITY_YAMA": "y",
    "CONFIG_SECURITY_SELINUX": "y",
    "CONFIG_AUDIT": "y",
    "CONFIG_BPF_UNPRIV_DEFAULT_OFF": "y",
    "CONFIG_FANOTIFY_ACCESS_PERMISSIONS": "y",
    # Memory reclaim, zram swap, THP, telemetry
    "CONFIG_SWAP": "y",
    "CONFIG_ZRAM": "y",
    "CONFIG_ZRAM_BACKEND_ZSTD": "y",
    "CONFIG_ZRAM_DEF_COMP_ZSTD": "y",
    "CONFIG_LRU_GEN": "y",
    "CONFIG_LRU_GEN_ENABLED": "y",
    "CONFIG_PSI": "y",
    "CONFIG_VM_EVENT_COUNTERS": "y",
    "CONFIG_TRANSPARENT_HUGEPAGE": "y",
    "CONFIG_CGROUP_HUGETLB": "y",
    # Container / Kubernetes / VPN networking
    "CONFIG_TUN": "y",
    "CONFIG_WIREGUARD": "y",
    "CONFIG_VETH": "y",
    "CONFIG_BRIDGE": "y",
    "CONFIG_BRIDGE_NETFILTER": "y",
    "CONFIG_BRIDGE_VLAN_FILTERING": "y",
    "CONFIG_VLAN_8021Q": "y",
    "CONFIG_VXLAN": "y",
    "CONFIG_GENEVE": "y",
    "CONFIG_MACVLAN": "y",
    "CONFIG_IPVLAN": "y",
    "CONFIG_NET_IPIP": "y",
    "CONFIG_NET_IPGRE": "y",
    "CONFIG_IP_MULTICAST": "y",
    "CONFIG_IP_MULTIPLE_TABLES": "y",
    "CONFIG_IPV6_MULTIPLE_TABLES": "y",
    "CONFIG_NETFILTER_XT_MATCH_STATISTIC": "y",
    "CONFIG_NFT_NUMGEN": "y",
    "CONFIG_NF_CONNTRACK_MARK": "y",
    "CONFIG_NETFILTER_XT_CONNMARK": "y",
    "CONFIG_NETFILTER_XT_MATCH_OWNER": "y",
    "CONFIG_NFT_TPROXY": "y",
    "CONFIG_NFT_SOCKET": "y",
    "CONFIG_NETFILTER_NETLINK_QUEUE": "y",
    "CONFIG_IP_VS": "y",
    "CONFIG_IP_VS_RR": "y",
    "CONFIG_XFRM_USER": "y",
    "CONFIG_INET_ESP": "y",
    "CONFIG_INET6_ESP": "y",
    # Socket diagnostics
    "CONFIG_INET_DIAG": "y",
    "CONFIG_INET_TCP_DIAG": "y",
    "CONFIG_INET_UDP_DIAG": "y",
    "CONFIG_INET_RAW_DIAG": "y",
    "CONFIG_INET_DIAG_DESTROY": "y",
    "CONFIG_UNIX_DIAG": "y",
    "CONFIG_NETLINK_DIAG": "y",
    "CONFIG_PACKET_DIAG": "y",
    # eBPF, tracing, traffic control, TCP congestion
    "CONFIG_BPF_SYSCALL": "y",
    "CONFIG_BPF_JIT": "y",
    "CONFIG_BPF_JIT_ALWAYS_ON": "y",
    "CONFIG_CGROUP_BPF": "y",
    "CONFIG_KPROBES": "y",
    "CONFIG_UPROBES": "y",
    "CONFIG_FTRACE": "y",
    "CONFIG_DYNAMIC_FTRACE": "y",
    "CONFIG_BPF_EVENTS": "y",
    "CONFIG_DEBUG_INFO_BTF": "y",
    "CONFIG_NET_SCHED": "y",
    "CONFIG_NET_CLS_ACT": "y",
    "CONFIG_NET_SCH_FQ": "y",
    "CONFIG_NET_SCH_HTB": "y",
    "CONFIG_NET_SCH_NETEM": "y",
    "CONFIG_NET_CLS_BPF": "y",
    "CONFIG_NET_ACT_BPF": "y",
    "CONFIG_TCP_CONG_BBR": "y",
    "CONFIG_SYN_COOKIES": "y",
    # Filesystems, storage, crypto, introspection, systemd
    "CONFIG_EXT4_FS_POSIX_ACL": "y",
    "CONFIG_XFS_POSIX_ACL": "y",
    "CONFIG_BTRFS_FS_POSIX_ACL": "y",
    "CONFIG_SQUASHFS": "y",
    "CONFIG_SQUASHFS_ZSTD": "y",
    "CONFIG_OVERLAY_FS_INDEX": "y",
    "CONFIG_OVERLAY_FS_METACOPY": "y",
    "CONFIG_BLK_DEV_DM": "y",
    "CONFIG_DM_CRYPT": "y",
    "CONFIG_DM_THIN_PROVISIONING": "y",
    "CONFIG_DM_SNAPSHOT": "y",
    "CONFIG_DM_VERITY": "y",
    "CONFIG_BLK_DEV_LOOP_MIN_COUNT": "8",
    "CONFIG_BLK_DEV_NBD": "y",
    "CONFIG_BLK_DEV_THROTTLING": "y",
    "CONFIG_QUOTA": "y",
    "CONFIG_NFS_FS": "y",
    "CONFIG_NFS_V4": "y",
    "CONFIG_CIFS": "y",
    "CONFIG_ISO9660_FS": "y",
    "CONFIG_EXFAT_FS": "y",
    "CONFIG_NTFS3_FS": "y",
    "CONFIG_AUTOFS_FS": "y",
    "CONFIG_SCHEDSTATS": "y",
    "CONFIG_DEBUG_FS": "y",
    "CONFIG_CONFIGFS_FS": "y",
    "CONFIG_IKCONFIG": "y",
    "CONFIG_IKCONFIG_PROC": "y",
    "CONFIG_UDMABUF": "y",
    "CONFIG_CHECKPOINT_RESTORE": "y",
    "CONFIG_TLS": "y",
    "CONFIG_IP_SCTP": "y",
    "CONFIG_MPTCP": "y",
    "CONFIG_NET_VRF": "y",
    "CONFIG_SND_DUMMY": "y",
    "CONFIG_SND_ALOOP": "y",
    "CONFIG_CRYPTO_USER_API_HASH": "y",
    "CONFIG_CRYPTO_GCM": "y",
    "CONFIG_CRYPTO_CHACHA20POLY1305": "y",
    # Keep loadable kernel modules disabled
    "CONFIG_MODULES": "n",
}

CLOUD_X86_FEATURES = {
    "CONFIG_MTRR": "y",
    "CONFIG_X86_PAT": "y",
    "CONFIG_IA32_EMULATION": "y",
    "CONFIG_CRYPTO_AES_NI_INTEL": "y",
    "CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL": "y",
    "CONFIG_CRYPTO_SHA256_SSSE3": "y",
    "CONFIG_CRYPTO_SHA512_SSSE3": "y",
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


class CloudKernelConfigTests(unittest.TestCase):
    def setUp(self):
        self.cloud_x86 = read_config("config-libkrunfw_x86_64")
        self.cloud_windows = read_config("config-libkrunfw-windows_x86_64")
        self.cloud_aarch64 = read_config("config-libkrunfw_aarch64")

    def test_cloud_presets_align_shared_guest_features(self):
        for arch_name, cfg in (
            ("x86_64", self.cloud_x86),
            ("windows_x86_64", self.cloud_windows),
            ("aarch64", self.cloud_aarch64),
        ):
            for name, expected in sorted(CLOUD_SHARED_FEATURES.items()):
                with self.subTest(arch=arch_name, option=name):
                    self.assertEqual(cfg.get(name, "n"), expected)
            with self.subTest(arch=arch_name, option="CONFIG_LSM"):
                lsm = cfg.get("CONFIG_LSM", "").strip('"').split(",")
                self.assertIn("landlock", lsm)

    def test_cloud_x86_specific_features_enabled(self):
        for arch_name, cfg in (
            ("x86_64", self.cloud_x86),
            ("windows_x86_64", self.cloud_windows),
        ):
            for name, expected in sorted(CLOUD_X86_FEATURES.items()):
                with self.subTest(arch=arch_name, option=name):
                    self.assertEqual(cfg.get(name, "n"), expected)


if __name__ == "__main__":
    unittest.main()
