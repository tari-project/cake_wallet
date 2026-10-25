# Minotari desktop builds

Supported targets: macOS arm64 + x86_64 in one universal framework, and Linux
x86_64 (GNU/glibc). Windows and Linux arm64 are outside this build configuration.

Run commands below from the Cake Wallet repository root. Native build artifacts
are generated locally and must not be committed.

## Prerequisites

- Rust stable with Cargo, rustfmt, and cargo-expand (`cargo install --locked
  cargo-expand --version 1.0.126`).
- Flutter/Dart and `flutter_rust_bridge_codegen` **2.11.1**, matching the bridge
  runtime (`cargo install --locked flutter_rust_bridge_codegen --version 2.11.1`).
- Git and a C/C++ toolchain. macOS needs Xcode; Linux needs a native x86_64 build
  environment, pkg-config, OpenSSL development/static libraries, and protoc with
  its standard definitions (Debian/Ubuntu: `libssl-dev protobuf-compiler
  libprotobuf-dev`). Building the Flutter app additionally needs its normal
  GTK/CMake/Ninja dependencies and the other enabled currencies' native artifacts.

## Build

```sh
bash scripts/macos/build_minotari.sh mainnet
# On Linux x86_64:
bash scripts/linux/build_minotari.sh mainnet
```

Both scripts also accept `esmeralda` (or `esme`). The default is `mainnet`.
The network is a compile-time choice; use the matching network when opening or
creating accounts. Do not point a test build at an existing personal profile.

The default source is the exact wrapper revision in `scripts/prepare_minotari.sh`.
Its `--source-only` mode prepares that checkout without invoking mobile builds.
For local wrapper development, `MINOTARI_RUST_DIR=/absolute/checkout` explicitly
overrides the source; `CARGO_TARGET_DIR` can select a build cache.

The scripts copy source into `cw_minotari/.dart_tool/desktop-<OS>/`, then generate
the **Cake** bridge namespace in that copy. The wrapper's verification bridge
uses a different namespace for opaque-type symbols and cannot be packaged
directly. Existing Cake Dart bindings are preserved and checked for the same
API content hash. A fresh checkout receives the generated bindings. Neither the
wrapper checkout nor the mobile generated Rust code is rewritten by this step.
As in the normal Cake build, run `./model_generator.sh` before compiling the app
or running the smoke check on a fresh checkout; it supplies the Freezed/MobX
generated files in addition to the FRB bindings.

Outputs:

- `cw_minotari/macos/Frameworks/rust_lib_flutter_rust_wallet.framework`:
  versioned, universal, with an `@rpath` install name. The build applies an ad-hoc
  signature; the application's normal CocoaPods embed/sign step handles its
  distribution signature.
- `cw_minotari/linux/lib/librust_lib_flutter_rust_wallet.so`: installed by the
  Flutter FFI plugin into the app bundle's `lib/`. OpenSSL is linked statically;
  the application still requires the platform's usual system runtime libraries.

The macOS podspec and Linux FFI CMake configuration deliver these artifacts to
the installed app. FRB uses the framework on macOS and the bundled `.so` on Linux;
the shipped app must not depend on a source checkout or development library path.

`scripts/{macos,linux}/build_all.sh` includes the XTM build after the existing
native steps. The Linux Docker dependency cache includes a separate Minotari
stage, its generated Dart bindings, and the `.so`; its key includes the wrapper
pin, desktop scripts, and package metadata. The other currency stages are retained.

## Native smoke check

After resolving Cake's Dart dependencies, with a **mainnet** native artifact
(use the Esmeralda UI suite below for an Esmeralda build):

```sh
dart run cw_minotari/tool/desktop_smoke.dart \
  cw_minotari/macos/Frameworks/rust_lib_flutter_rust_wallet.framework/rust_lib_flutter_rust_wallet
# Linux:
dart run cw_minotari/tool/desktop_smoke.dart \
  cw_minotari/linux/lib/librust_lib_flutter_rust_wallet.so
```

This checks create, restore, encrypted reopen, zero balance, and sign/verify using
new temporary databases. It does not connect to a node or print seed/private keys.
It loads the specified binary explicitly, so it complements rather than replaces
testing the packaged Flutter/Cake application from outside the repository.

## Packaged Cake integration check

The existing `integration_test/minotari/minotari_wallet_flow_test.dart` also
runs on desktop. It uses the real Cake screens and wallet service to create,
restore and reopen an Esmeralda wallet, then checks zero and controlled nonzero
balances on Home. This is not a live-chain or transaction-broadcast test.

Use a separate disposable app checkout/profile, with an Esmeralda native build.
Keep Bitcoin enabled in the Cake configuration: the existing XTM restore form
uses its BIP39 word list. This suite only exercises XTM wallet operations.
Build the target as a separate checked step before `flutter drive`; otherwise a
failed build can cause the driver to retry an old application binary. Always pass
`--keep-app-running` to avoid the driver's default uninstall. On macOS give the
test app its own bundle ID and use the ordinary app signing/build prerequisites.

On Linux, build the target with `flutter build linux --debug --no-pub
--target integration_test/minotari/minotari_wallet_flow_test.dart
--dart-define=MINOTARI_ESMERALDA_TESTS=true`, then run in a disposable desktop
environment/container:

```sh
xtm_profile=$(mktemp -d /tmp/xtm-integration-XXXXXX)
CAKE_WALLET_DIR="$xtm_profile" \
XDG_DATA_HOME="$xtm_profile.xdg-data" \
XDG_CONFIG_HOME="$xtm_profile.xdg-config" \
flutter drive --no-pub --keep-app-running -d linux \
  --use-application-binary=build/linux/x64/debug/bundle/cake_wallet \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/minotari/minotari_wallet_flow_test.dart \
  --dart-define=MINOTARI_ESMERALDA_TESTS=true
```

The Linux test rejects a missing, nonempty, symlinked or non-temporary profile,
and requires those XDG overrides before initializing Cake. Linux root selection
bypasses `path_provider`; its environment override is essential for isolation.
An Xvfb session can provide the display in CI. Stop the test app before removing
its temporary directories. Rebuild for mainnet before using an ordinary profile.

Build-script failure/preservation checks need only Python's standard library:

```sh
python3 scripts/tests/test_minotari_desktop_build.py
```
