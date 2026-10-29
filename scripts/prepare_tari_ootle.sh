#!/bin/bash
# Fetches the Tari Ootle (L2) Rust bridge into cw_tari_ootle/rust, generates the Dart bindings and
# builds the native libraries for the platforms this host can build.
#
#   ./scripts/prepare_tari_ootle.sh [--update]
#
# CW_TARI_OOTLE_PATH=/path/to/cw_tari_ootle_wallet uses a local checkout instead of cloning. Its
# tracked files are copied (not symlinked) so codegen and builds never write into that checkout.

set -eu

# Bump together with the bridge. Never build an unpinned HEAD.
CW_TARI_OOTLE_REPO_URL="https://github.com/tari-project/cw_tari_ootle_wallet.git"
CW_TARI_OOTLE_REV="3665de53ffc2ea7d9cfd21d4a1aa038d26bbc2f8"

UPDATE=0
for arg in "$@"; do
  [ "$arg" = "--update" ] && UPDATE=1
done

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)/cw_tari_ootle"
RUST_DIR="$PACKAGE_DIR/rust"

if [ -n "${CW_TARI_OOTLE_PATH:-}" ]; then
  echo "Copying tracked files of the local bridge checkout $CW_TARI_OOTLE_PATH"
  # Keep target/ so repeated runs build incrementally.
  mkdir -p "$RUST_DIR"
  find "$RUST_DIR" -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf {} +
  git -C "$CW_TARI_OOTLE_PATH" ls-files -z | (cd "$CW_TARI_OOTLE_PATH" && xargs -0 tar -cf -) | tar -xf - -C "$RUST_DIR"
else
  if [ "$UPDATE" -eq 1 ]; then
    rm -rf "$RUST_DIR"
  fi
  if [ ! -d "$RUST_DIR/.git" ]; then
    rm -rf "$RUST_DIR"
    git clone "$CW_TARI_OOTLE_REPO_URL" "$RUST_DIR"
  fi
  git -C "$RUST_DIR" cat-file -e "$CW_TARI_OOTLE_REV^{commit}" 2>/dev/null || git -C "$RUST_DIR" fetch origin
  git -C "$RUST_DIR" checkout --detach "$CW_TARI_OOTLE_REV"
fi

echo "Running flutter_rust_bridge_codegen generate"
(cd "$PACKAGE_DIR" && flutter_rust_bridge_codegen generate)

if [ -n "${ANDROID_HOME:-}" ] && [ -n "${ANDROID_NDK_VERSION:-}" ]; then
  "$SCRIPTS_DIR/android/build_tari_ootle.sh"
else
  echo "Skipping Android build (ANDROID_HOME or ANDROID_NDK_VERSION not set)"
fi

if command -v xcodebuild > /dev/null; then
  "$SCRIPTS_DIR/ios/build_tari_ootle.sh"
else
  echo "Skipping iOS build (xcodebuild not installed)"
fi

echo "Tari Ootle prepared"
