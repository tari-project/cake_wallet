# Local mobile review of the Minotari integration

[Cake #47](https://github.com/tari-project/cake_wallet/pull/47) uses fee APIs introduced by [wrapper #22](https://github.com/tari-project/cw_tari_wallet/pull/22). The snippet below builds the mainnet native library and Dart bindings from wrapper commit `79f0b69bd7752839220e89b6ab8c380cf0a77afb`. Its Cargo lockfile pins [core #187](https://github.com/tari-project/minotari-cli/pull/187) at `bca85dde36519871598d3e6fb411c9a002d9c360`.

Use a fresh checkout of Cake #47. Follow the [iOS](IOS.md) or [Android](ANDROID.md) build guide. At the Minotari preparation step, run the following from the Cake repository root, setting `platform` to `ios` or `android`. On Android, run it inside the build environment with `ANDROID_NDK_HOME` set. iOS requires Xcode. Both builds use Rust with rustup, make, Python, Git and unzip.

```bash
(
  set -eu
  platform=ios
  wrapper=79f0b69bd7752839220e89b6ab8c380cf0a77afb
  bundle=$(mktemp -d)
  trap 'rm -rf "$bundle"' EXIT
  ./scripts/build_minotari_from_source.sh pr22 "$wrapper" "$bundle" dart "$platform"
  unzip -q "$bundle/cw_tari_wallet-pr22-dart.zip" -d "$bundle/bindings"
  unzip -q "$bundle/cw_tari_wallet-pr22-$platform.zip" -d "$bundle/native"
  rm "$bundle/bindings/dart/pubspec.yaml"
  mkdir -p cw_minotari/lib/src
  test ! -e cw_minotari/lib/src/rust
  case "$platform" in
    ios)
      test ! -e cw_minotari/ios/Frameworks
      mv "$bundle/native" cw_minotari/ios/Frameworks
      ;;
    android)
      mkdir -p cw_minotari/android/src/main
      test ! -e cw_minotari/android/src/main/jniLibs
      mv "$bundle/native/jniLibs" cw_minotari/android/src/main/
      ;;
  esac
  mv "$bundle/bindings/dart" cw_minotari/lib/src/rust
)
```

Resume the platform guide at the step following Minotari preparation, including `./model_generator.sh`. Running `prepare_minotari.sh` again, directly or through `build_all.sh`, installs the pinned v0.4.0 release over these review artifacts. The production release pin will be updated after the matching wrapper release.
