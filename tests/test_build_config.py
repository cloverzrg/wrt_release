"""Offline regression checks for firmware build presets (Bash >= 4.3)."""

import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
CORE = REPO / "wrt_core"
BASH = os.environ.get("WRT_TEST_BASH", "bash")
DISKMAN_PACKAGES = (
    "luci-app-diskman", "luci-i18n-diskman-zh-cn", "kmod-fs-exfat",
    "kmod-fs-msdos", "kmod-fs-ntfs3", "kmod-nls-cp932", "kmod-nls-cp936",
    "kmod-nls-cp950",
)


def build_config(model, **fragments):
    env = {**os.environ, "ADD_CONFIG_FRAGMENTS": "", "REMOVE_CONFIG_FRAGMENTS": "", **fragments}
    preview = subprocess.run(
        [BASH, str(REPO / "build.sh"), model, "config_preview"],
        cwd=REPO, env=env, text=True, capture_output=True, check=True,
    ).stdout
    paths = re.findall(r"^  \d+\) (.+)$", preview, re.MULTILINE)
    settings = {}
    for path in paths:
        for line in Path(path).read_text().splitlines():
            if line.startswith("CONFIG_") and "=" in line:
                key, value = line.split("=", 1)
                settings[key] = value
            elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
                settings[line[2:-11]] = "n"
    return preview, settings


class BuildConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wrt-config-test-")
        self.build = Path(self.temp.name) / "build"
        self.build.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, module, command, enabled="0", check=True):
        env = dict(os.environ, ENABLE_EBPF_PROXY_DEPS=enabled, BUILD_DIR=str(self.build),
                   BASE_PATH=str(CORE))
        script = "set -eu\nsource " + shlex.quote(str(CORE / "modules" / module))
        return subprocess.run(
            [BASH, "-c", script + "\n" + command],
            env=env, text=True, capture_output=True, check=check,
        )

    def write_config(self, config):
        path = self.build / ".config"
        path.write_text("".join(f"{key}={value}\n" for key, value in config.items()))
        return path

    def test_devices_share_defaults_with_legacy_compatibility(self):
        for profile in sorted((CORE / "compilecfg").glob("*.ini")):
            with self.subTest(model=profile.stem):
                preview, config = build_config(profile.stem)
                self.assertEqual(config["CONFIG_PACKAGE_luci-app-passwall"], "n")
                for package in DISKMAN_PACKAGES:
                    self.assertEqual(config["CONFIG_PACKAGE_" + package], "y", package)
                if profile.stem == "supergateway_s20m_immwrt":
                    self.assertEqual(config["CONFIG_USE_APK"], "n")
                    self.assertNotIn("ebpf_proxy_deps", preview)
                else:
                    self.assertEqual(config["CONFIG_USE_APK"], "y")
                    self.assertIn("ebpf_proxy_deps", preview)
                    self.assertEqual(config["CONFIG_KERNEL_DEBUG_INFO_BTF"], "y")
                    self.assertEqual(config["CONFIG_PACKAGE_honk"], "n")

    def test_ap8220_uses_libwrt_and_nss(self):
        model = "aliyun_ap8220_libwrt"
        ini = (CORE / f"compilecfg/{model}.ini").read_text()
        self.assertIn("REPO_BRANCH=25.12-nss\n", ini)
        _, config = build_config(model)
        self.assertEqual(config["CONFIG_TARGET_DEVICE_qualcommax_ipq807x_DEVICE_aliyun_ap8220"], "y")
        self.assertEqual(config["CONFIG_PACKAGE_luci-app-dockerman"], "y")
        self.assertIn("ipq-wifi-aliyun_ap8220",
                      config["CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq807x_DEVICE_aliyun_ap8220"])
        self.write_config(config)
        self.shell("verify.sh", 'verify_nss_config "$BUILD_DIR"')
        config["CONFIG_PACKAGE_kmod-qca-nss-ecm"] = "m"
        self.write_config(config)
        result = self.shell("verify.sh", 'verify_nss_config "$BUILD_DIR"', check=False)
        self.assertIn("kmod-qca-nss-ecm", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        for workflow in ("build_wrt.yml", "release_wrt.yml"):
            content = (REPO / ".github/workflows" / workflow).read_text()
            self.assertIn(f"          - {model}\n", content)

    def test_explicit_fragments_override_defaults(self):
        _, config = build_config("jdcloud_ax6000_immwrt", ADD_CONFIG_FRAGMENTS="proxy",
                                 REMOVE_CONFIG_FRAGMENTS="ebpf_proxy_deps")
        self.assertEqual(config["CONFIG_PACKAGE_luci-app-passwall"], "y")
        self.assertNotIn("CONFIG_KERNEL_DEBUG_INFO_BTF", config)

    def test_shared_config_rejects_missing_apk_and_diskman_dependencies(self):
        _, config = build_config("aliyun_ap8220_libwrt")
        original = self.build / "config-input"
        original.write_text("".join(f"{key}={value}\n" for key, value in config.items()))
        verify = 'verify_shared_config "$BUILD_DIR" "$BUILD_DIR/config-input"'
        self.write_config(config)
        self.shell("verify.sh", verify)
        for setting in ["CONFIG_USE_APK", *("CONFIG_PACKAGE_" + pkg for pkg in DISKMAN_PACKAGES)]:
            with self.subTest(setting=setting):
                self.write_config({**config, setting: "n"})
                result = self.shell("verify.sh", verify, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(setting, result.stderr)

    def test_honk_checks_the_selected_target_and_repo_arch(self):
        _, config = build_config("aliyun_ap8220_libwrt")
        config.update(CONFIG_TARGET_BOARD='"qualcommax"', CONFIG_TARGET_SUBTARGET='"ipq807x"',
                      CONFIG_TARGET_ARCH_PACKAGES='"aarch64_cortex-a53"')
        target = self.build / "target/linux/qualcommax/Makefile"
        target.parent.mkdir(parents=True)
        target.write_text("KERNEL_PATCHVER:=6.6\n")
        subtarget = target.parent / "ipq807x/target.mk"
        subtarget.parent.mkdir()
        subtarget.write_text("KERNEL_PATCHVER:=6.12\n")
        self.write_config(config)
        fragment = shlex.quote(str(CORE / "deconfig/fragments/ebpf_proxy_deps.config"))
        verify = 'verify_ebpf_proxy_deps_config "$BUILD_DIR" ' + fragment
        self.shell("verify.sh", verify)
        for setting, value, error in [("CONFIG_PACKAGE_v2ray-geoip", "n", "v2ray-geoip"),
                                      ("CONFIG_PACKAGE_honk", "y", "CONFIG_PACKAGE_honk"),
                                      ("CONFIG_TARGET_ARCH_PACKAGES", '"mips"', "mips")]:
            self.write_config({**config, setting: value})
            result = self.shell("verify.sh", verify, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        self.write_config(config)
        subtarget.unlink()
        result = self.shell("verify.sh", verify, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("6.6", result.stderr)

    def test_honk_uses_the_real_kernel_config(self):
        self.write_config({"CONFIG_TARGET_BOARD": '"qualcommax"', "CONFIG_TARGET_SUBTARGET": '"ipq807x"'})
        target = self.build / "target/linux/qualcommax/Makefile"
        target.parent.mkdir(parents=True)
        target.write_text("KERNEL_PATCHVER:=6.12\n")
        generic = target.parent.parent / "generic/kernel-6.12"
        generic.parent.mkdir()
        generic.write_text("LINUX_VERSION-6.12 = .103\n")
        actual = self.build / "build_dir/target-aarch64/linux-qualcommax_ipq807x/linux-6.12.103/.config"
        actual.parent.mkdir(parents=True)
        actual.write_text("# CONFIG_DEBUG_INFO_BTF is not set\n")
        result = self.shell("verify.sh", 'verify_ebpf_proxy_kernel "$BUILD_DIR"', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONFIG_BPF=y", result.stderr)

    def feeds_fixture(self):
        target = self.build / "include/feeds.mk"
        target.parent.mkdir()
        shutil.copyfile(REPO / "tests/fixtures/feeds.mk", target)
        return target

    def generate_feeds(self, source_type, custom_enabled):
        output = self.build / "distfeeds.list"
        output.unlink(missing_ok=True)
        harness = self.build / "test.mk"
        harness.write_text(f"include {self.build}/include/feeds.mk\n"
                           f"all:\n\t$(call FeedSourcesAppend{source_type},$(OUT))\n")
        subprocess.run(["make", "-s", "-f", str(harness), "all",
                        "TOPDIR=" + str(self.build), "TMP_DIR=" + str(self.build),
                        "SCRIPT_DIR=" + str(self.build), "OUT=" + str(output),
                        "FEEDS_AVAILABLE=luci packages custom_feed nss_packages sqm_scripts_nss",
                        "CONFIG_PER_FEED_REPO=y",
                        "CONFIG_FEED_luci=y", "CONFIG_FEED_packages=y",
                        "CONFIG_FEED_nss_packages=y", "CONFIG_FEED_sqm_scripts_nss=m",
                        "CONFIG_FEED_custom_feed=" + custom_enabled],
                       text=True, capture_output=True, check=True)
        return output.read_text()

    def test_apk_sources_exclude_local_feed_for_enabled_and_commented_cases(self):
        target = self.feeds_fixture()
        self.assertIn("custom_feed", self.generate_feeds("APK", "m"))
        self.shell("feeds.sh", "omit_unpublished_apk_feeds")
        patched = target.read_bytes()
        self.shell("feeds.sh", "omit_unpublished_apk_feeds")
        self.assertEqual(patched, target.read_bytes())
        for enabled in ["y", "m"]:
            with self.subTest(enabled=enabled):
                generated = self.generate_feeds("APK", enabled)
                for feed in ("custom_feed", "nss_packages", "sqm_scripts_nss"):
                    self.assertNotIn(feed, generated)
                self.assertIn("/luci/packages.adb", generated)
                self.assertIn("/packages/packages.adb", generated)
        self.assertIn("custom_feed", self.generate_feeds("OPKG", "m"))

    def test_source_filter_rejects_unknown_generators(self):
        target = self.feeds_fixture()
        target.write_text("define FeedSourcesAppendAPK\nunknown generator\nendef\n")
        original = target.read_bytes()
        result = self.shell("feeds.sh", "omit_unpublished_apk_feeds", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original, target.read_bytes())

    def test_reset_keeps_branch_and_tag_checkouts_shallow_and_pinned(self):
        origin = Path(self.temp.name) / "origin"
        origin.mkdir()
        def git(*args, cwd=origin):
            return subprocess.run(["git", *args], cwd=cwd, text=True,
                                  capture_output=True, check=True).stdout.strip()
        git("init")
        package = origin / "package/base-files"
        package.mkdir(parents=True)
        for value in ["initial", "updated"]:
            (package / "Makefile").write_text(value)
            git("add", ".")
            git("-c", "commit.gpgsign=false", "-c", "user.name=Build Test", "-c", "user.email=test@example.invalid",
                "commit", "-m", value)
        git("tag", "build-tag")
        (origin / "unrelated").write_text("later source revision")
        git("add", ".")
        git("-c", "commit.gpgsign=false", "-c", "user.name=Build Test", "-c", "user.email=test@example.invalid",
            "commit", "-m", "unrelated change")
        git("branch", "build-branch")
        expected = {reference: git("rev-parse", reference)
                    for reference in ["build-tag", "build-branch"]}
        shutil.rmtree(self.build)
        git("clone", "--depth", "1", "--branch", "build-branch",
            origin.as_uri(), str(self.build))
        for reference, revision in expected.items():
            with self.subTest(reference=reference):
                self.shell("repo.sh", 'git_retry() { git "$@"; }\ncd "$BUILD_DIR"\n'
                           f'REPO_BRANCH={reference} COMMIT_HASH=none reset_feeds_conf')
                self.assertEqual(git("rev-parse", "HEAD", cwd=self.build), revision)
                self.assertEqual(git("rev-parse", "--is-shallow-repository",
                                     cwd=self.build), "true")
                self.assertEqual(git("rev-list", "--count", "HEAD", cwd=self.build), "1")

    def test_daeuniverse_source_matches_apk_arch(self):
        base_files = self.build / "package/base-files/files"
        base_files.mkdir(parents=True)
        self.shell("ebpf_proxy_deps.sh", "prepare_ebpf_proxy_dependencies", enabled="1")
        source = base_files / "etc/apk/repositories.d/daeuniverse.list"
        show_source = 'source "$BASE_PATH/modules/verify.sh"\nconfigure_daeuniverse_apk_source "$BUILD_DIR"'
        self.assertTrue((base_files / "etc/apk/keys/daeuniverse.pem").is_file())
        for arch in ["aarch64_cortex-a53", "aarch64_generic", "x86_64"]:
            with self.subTest(arch=arch):
                self.write_config({"CONFIG_TARGET_ARCH_PACKAGES": f'"{arch}"'})
                self.shell("ebpf_proxy_deps.sh", show_source)
                expected = f"@daeuniverse https://openwrt.daeuniverse.org/25.12/packages/{arch}/packages.adb\n"
                self.assertEqual(source.read_text(), expected)

    def test_built_repository_guard_rejects_even_commented_local_feed(self):
        self.write_config({"CONFIG_TARGET_BOARD": '"qualcommax"'})
        target = self.build / "build_dir/target/root-qualcommax/etc/apk/repositories.d/distfeeds.list"
        target.parent.mkdir(parents=True)
        target.write_text("https://mirror.example/releases/25.12.2/packages/arch/luci/packages.adb\n")
        self.shell("verify.sh", 'verify_apk_repositories "$BUILD_DIR"')
        with target.open("a") as stream:
            stream.write("# https://mirror.example/packages/arch/custom_feed/packages.adb\n")
        result = self.shell("verify.sh", 'verify_apk_repositories "$BUILD_DIR"', check=False)
        self.assertNotEqual(result.returncode, 0)

if __name__ == "__main__":
    unittest.main()
