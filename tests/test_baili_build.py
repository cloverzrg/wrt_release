"""Offline regression checks for the Baili build preset (Bash >= 4.3)."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
CORE = REPO / "wrt_core"
BASH = os.environ.get("WRT_TEST_BASH", "bash")


def baili_config():
    ini = (CORE / "compilecfg/jdcloud_ax6000_immwrt.ini").read_text()
    fragments = next(line.split("=", 1)[1] for line in ini.splitlines()
                     if line.startswith("CONFIG_FRAGMENTS=")).split(",")
    paths = [CORE / "deconfig/jdcloud_ax6000_immwrt.config",
             CORE / "deconfig/compile_base.config"]
    paths += [CORE / f"deconfig/fragments/{name}.config" for name in fragments]
    config = {}
    for path in paths:
        for line in path.read_text().splitlines():
            if line.startswith("CONFIG_") and "=" in line:
                key, value = line.split("=", 1)
                config[key] = value
            elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
                config[line[2:-11]] = "n"
    return fragments, config


class BailiBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wrt-baili-test-")
        self.build = Path(self.temp.name) / "build"
        self.build.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, module, command, enabled="1", check=True):
        env = dict(os.environ, ENABLE_BAILI_APPS=enabled, BUILD_DIR=str(self.build))
        script = "set -eu\nsource " + shlex.quote(str(CORE / "modules" / module))
        return subprocess.run(
            [BASH, "-c", script + "\n" + command],
            env=env, text=True, capture_output=True, check=check,
        )

    def test_preset_excludes_passwall_and_preserves_shared_dependencies(self):
        fragments, config = baili_config()
        self.assertNotIn("proxy", fragments)
        for package in ["luci-app-passwall", "luci-i18n-passwall-zh-cn", "xray-core",
                        "chinadns-ng", "dns2socks", "geoview", "ipt2socks",
                        "microsocks", "tcping", "smartdns"]:
            self.assertEqual(config.get("CONFIG_PACKAGE_" + package), "n", package)
        ebpf = (CORE / "deconfig/fragments/ebpf_proxy_deps.config").read_text()
        required = [line[:-2] for line in ebpf.splitlines()
                    if line.startswith("CONFIG_") and line.endswith("=y")]
        required += ["CONFIG_PACKAGE_dnsmasq-full", "CONFIG_PACKAGE_kmod-tun",
                     "CONFIG_PACKAGE_luci-app-dockerman", "CONFIG_PACKAGE_luci-theme-argon"]
        for setting in required:
            self.assertEqual(config.get(setting), "y", setting)
        preview = subprocess.run([BASH, str(REPO / "build.sh"),
                                  "jdcloud_ax6000_immwrt", "config_preview"],
                                 cwd=REPO, text=True, capture_output=True, check=True)
        self.assertIn("Effective fragments: " + ",".join(fragments), preview.stdout)
        self.assertTrue((CORE / "deconfig/fragments/proxy.config").exists())

    def test_config_guard_rejects_lost_shared_dependency_and_reenabled_passwall(self):
        _, config = baili_config()
        config["CONFIG_aarch64"] = "y"
        config["CONFIG_TARGET_ARCH_PACKAGES"] = '"aarch64_cortex-a53"'
        kernel = self.build / "target/linux/mediatek/Makefile"
        kernel.parent.mkdir(parents=True)
        kernel.write_text("KERNEL_PATCHVER:=6.12\n")
        config_path = self.build / ".config"
        def write_config():
            config_path.write_text("".join(f"{key}={value}\n" for key, value in config.items()))
        write_config()
        ebpf = shlex.quote(str(CORE / "deconfig/fragments/ebpf_proxy_deps.config"))
        verify_ebpf = 'verify_ebpf_proxy_deps_config "$BUILD_DIR" ' + ebpf
        self.shell("verify.sh", verify_ebpf)
        config["CONFIG_PACKAGE_v2ray-geoip"] = "n"
        write_config()
        result = self.shell("verify.sh", verify_ebpf, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v2ray-geoip", result.stderr)
        config["CONFIG_PACKAGE_v2ray-geoip"] = "y"
        config["CONFIG_PACKAGE_luci-app-passwall"] = "y"
        write_config()
        preset = shlex.quote(str(CORE / "deconfig/fragments/baili_apps.config"))
        result = self.shell("verify.sh", 'verify_baili_apps_config "$BUILD_DIR" ' + preset,
                            check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("luci-app-passwall", result.stderr)

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
                        "FEEDS_AVAILABLE=luci packages custom_feed", "CONFIG_PER_FEED_REPO=y",
                        "CONFIG_FEED_luci=y", "CONFIG_FEED_packages=y",
                        "CONFIG_FEED_custom_feed=" + custom_enabled],
                       text=True, capture_output=True, check=True)
        return output.read_text()

    def test_apk_sources_exclude_local_feed_for_enabled_and_commented_cases(self):
        target = self.feeds_fixture()
        self.assertIn("custom_feed", self.generate_feeds("APK", "m"))
        self.shell("feeds.sh", "omit_baili_local_apk_feed")
        patched = target.read_bytes()
        self.shell("feeds.sh", "omit_baili_local_apk_feed")
        self.assertEqual(patched, target.read_bytes())
        for enabled in ["y", "m"]:
            with self.subTest(enabled=enabled):
                generated = self.generate_feeds("APK", enabled)
                self.assertNotIn("custom_feed", generated)
                self.assertIn("/luci/packages.adb", generated)
                self.assertIn("/packages/packages.adb", generated)
        self.assertIn("custom_feed", self.generate_feeds("OPKG", "m"))

    def test_source_filter_does_not_change_other_presets_or_unknown_generators(self):
        target = self.feeds_fixture()
        original = target.read_bytes()
        self.shell("feeds.sh", "omit_baili_local_apk_feed", enabled="0")
        self.assertEqual(original, target.read_bytes())
        target.write_text("define FeedSourcesAppendAPK\nunknown generator\nendef\n")
        original = target.read_bytes()
        result = self.shell("feeds.sh", "omit_baili_local_apk_feed", check=False)
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

    def test_baili_keeps_native_argon_and_dockerman_sources(self):
        marker = self.build / "native-feed"
        marker.write_text("fixed upstream source")
        self.shell("package_source_updates.sh",
                   "git_retry() { exit 99; }\nupdate_argon\nupdate_dockerman")
        self.assertEqual(marker.read_text(), "fixed upstream source")

    def test_built_repository_guard_rejects_even_commented_local_feed(self):
        target = self.build / "build_dir/target/root-mediatek/etc/apk/repositories.d/distfeeds.list"
        target.parent.mkdir(parents=True)
        target.write_text("https://mirror.example/releases/25.12.2/packages/arch/luci/packages.adb\n")
        self.shell("verify.sh", 'verify_baili_apk_repositories "$BUILD_DIR"')
        with target.open("a") as stream:
            stream.write("# https://mirror.example/packages/arch/custom_feed/packages.adb\n")
        result = self.shell("verify.sh", 'verify_baili_apk_repositories "$BUILD_DIR"', check=False)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
