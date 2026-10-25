"""XTM desktop failure/preservation checks; no real compiler or network."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class DesktopBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xtm-desktop-build-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ["prepare_minotari.sh", "minotari_desktop_common.sh", "linux/build_minotari.sh"]:
            dest = self.root / "scripts" / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "scripts" / name, dest)
        self.source = self.root / "wrapper"
        (self.source / "src").mkdir(parents=True)
        (self.source / "Cargo.toml").write_text("[package]\nname='fixture'\nversion='0.1.0'\n")
        (self.source / "Cargo.lock").write_text("version = 3\n")
        (self.source / "src/frb_generated.rs").write_text("original-wrapper-namespace")
        self.package = self.root / "cw_minotari"
        (self.package / "lib/src/rust").mkdir(parents=True)
        (self.package / "pubspec.yaml").write_text("name: cw_minotari\n")
        self.bridge = self.package / "lib/src/rust/frb_generated.dart"
        self.bridge.write_text("int get rustContentHash => 1;\n")
        self.artifact = self.package / "linux/lib/librust_lib_flutter_rust_wallet.so"
        self.artifact.parent.mkdir(parents=True)
        self.artifact.write_text("previous-working-artifact")
        self.trace = self.root / "trace"
        ssl = self.root / "openssl"
        ssl.mkdir()
        (ssl / "libssl.a").touch()
        (ssl / "libcrypto.a").touch()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        MINOTARI_RUST_DIR=str(self.source), CARGO_TARGET_DIR=str(self.root / "target"),
                        OPENSSL_LIB_DIR=str(ssl), OPENSSL_INCLUDE_DIR=str(ssl),
                        XTM_TEST_TRACE=str(self.trace))
        self.stub("uname", 'if [ "$1" = -m ]; then echo x86_64; else echo Linux; fi')
        self.stub("rustup", "exit 0")
        self.stub("git", 'echo "git $*" >> "$XTM_TEST_TRACE"')
        self.stub("cargo", '''
echo "cargo $* static=$OPENSSL_STATIC" >> "$XTM_TEST_TRACE"
if [ "${XTM_TEST_FAIL:-}" = 1 ]; then exit 19; fi
mkdir -p "$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release"
echo new-library > "$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release/librust_lib_flutter_rust_wallet.so"
''')
        self.stub("flutter_rust_bridge_codegen", '''
if [ "$1" = --version ]; then echo 'flutter_rust_bridge_codegen 2.11.1'; exit 0; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dart-output) shift; output=$1 ;;
    --rust-output) shift; rust_output=$1 ;;
  esac
  shift
done
mkdir -p "$output"
echo "int get rustContentHash => ${XTM_TEST_HASH:-1};" > "$output/frb_generated.dart"
echo cake-namespace > "$rust_output"
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_linux(self, network="mainnet"):
        return subprocess.run(["bash", str(self.root / "scripts/linux/build_minotari.sh"), network],
                              env=self.env, text=True, capture_output=True)

    def assert_preserved(self):
        self.assertEqual(self.artifact.read_text(), "previous-working-artifact")
        self.assertEqual((self.source / "src/frb_generated.rs").read_text(), "original-wrapper-namespace")

    def test_source_only_prepares_pin_without_host_mobile_builds(self):
        (self.package / "rust").mkdir()
        result = subprocess.run(["bash", str(self.root / "scripts/prepare_minotari.sh"), "--source-only"],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.trace.read_text()
        self.assertIn("checkout --detach", calls)
        self.assertNotIn("cargo", calls)
        self.assertEqual(self.bridge.read_text(), "int get rustContentHash => 1;\n")

    def test_invalid_network_does_not_touch_artifacts(self):
        result = self.run_linux("invalid-network")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.trace.exists())
        self.assert_preserved()

    def test_bridge_mismatch_fails_before_compilation(self):
        self.env["XTM_TEST_HASH"] = "2"
        result = self.run_linux()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native/Dart bridge mismatch", result.stderr)
        self.assertFalse(self.trace.exists())
        self.assert_preserved()

    def test_failed_compilation_preserves_last_working_artifact(self):
        self.env["XTM_TEST_FAIL"] = "1"
        result = self.run_linux()
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assert_preserved()

    def test_missing_static_openssl_fails_before_compilation(self):
        (Path(self.env["OPENSSL_LIB_DIR"]) / "libssl.a").unlink()
        result = self.run_linux()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OpenSSL static development libraries", result.stderr)
        self.assertFalse(self.trace.exists())
        self.assert_preserved()

    def test_fresh_checkout_receives_dart_bindings(self):
        self.bridge.unlink()
        result = self.run_linux()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bridge.read_text(), "int get rustContentHash => 1;\n")
        self.assertEqual((self.source / "src/frb_generated.rs").read_text(), "original-wrapper-namespace")

    def test_success_uses_locked_library_build_and_preserves_source_and_bindings(self):
        result = self.run_linux()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.artifact.read_text(), "new-library\n")
        self.assertIn("--locked --release --lib --target x86_64-unknown-linux-gnu", self.trace.read_text())
        self.assertIn("static=1", self.trace.read_text())
        self.assertEqual(self.bridge.read_text(), "int get rustContentHash => 1;\n")
        self.assertEqual((self.source / "src/frb_generated.rs").read_text(), "original-wrapper-namespace")

    def test_existing_desktop_dependency_failure_prevents_xtm_build(self):
        for platform in ["linux", "macos"]:
            with self.subTest(platform=platform):
                work = self.root / platform
                work.mkdir()
                shutil.copy2(REPO / f"scripts/{platform}/build_all.sh", work / "build_all.sh")
                for name in ["build_torch.sh", "build_decred.sh", "build_minotari.sh"]:
                    p = work / name
                    p.write_text('#!/bin/bash\necho ' + name + ' >> "$XTM_TEST_TRACE"\n')
                    p.chmod(0o755)
                p = work / "build_monero_all.sh"
                p.write_text('#!/bin/bash\nexit 23\n')
                p.chmod(0o755)
                self.trace.unlink(missing_ok=True)
                result = subprocess.run(["bash", "build_all.sh"], cwd=work, env=self.env)
                self.assertEqual(result.returncode, 23)
                calls = self.trace.read_text() if self.trace.exists() else ""
                self.assertNotIn("build_minotari", calls)
                self.assertNotIn("build_decred", calls)


if __name__ == "__main__":
    unittest.main()
