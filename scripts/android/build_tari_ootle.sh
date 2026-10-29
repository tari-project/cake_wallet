#!/bin/bash
# Builds librust_lib_cw_tari_ootle.so for Android into cw_tari_ootle/android/src/main/jniLibs.
# Run scripts/prepare_tari_ootle.sh first (it fetches the bridge into cw_tari_ootle/rust).
#
#   ./build_tari_ootle.sh [abi ...]   # default: armeabi-v7a arm64-v8a x86_64
#
# The bridge is pure Rust (rustls/aws-lc), so unlike Minotari it needs no OpenSSL build.
# NDK 28+ links with 16 KB page alignment by default.

set -e
cd "$(dirname "$0")"

PACKAGE_DIR="$(realpath ../..)/cw_tari_ootle"
RUST_DIR="${PACKAGE_DIR}/rust"
LIB_NAME="librust_lib_cw_tari_ootle.so"
if [[ $# -gt 0 ]]; then ABIS=("$@"); else ABIS=(armeabi-v7a arm64-v8a x86_64); fi
API_LEVEL=21

if [[ ! -d "$RUST_DIR" ]]; then
    echo "Rust directory not found: $RUST_DIR (run scripts/prepare_tari_ootle.sh first)"
    exit 1
fi
if [[ -z "$ANDROID_HOME" || -z "$ANDROID_NDK_VERSION" ]]; then
    echo "Set ANDROID_HOME and ANDROID_NDK_VERSION. Installed NDKs:"
    ls "${ANDROID_HOME:-/nonexistent}/ndk/" 2>/dev/null | sed 's/^/- /'
    exit 1
fi
export ANDROID_NDK_HOME="${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}"

if ! command -v cargo-ndk > /dev/null; then
    echo "cargo-ndk is missing: cargo install cargo-ndk"
    exit 1
fi

cd "$RUST_DIR"

targets=()
for abi in "${ABIS[@]}"; do
    case $abi in
        armeabi-v7a) targets+=(armv7-linux-androideabi) ;;
        arm64-v8a) targets+=(aarch64-linux-android) ;;
        x86_64) targets+=(x86_64-linux-android) ;;
        *) echo "Unknown ABI: $abi"; exit 1 ;;
    esac
done
rustup target add "${targets[@]}"

ndk_args=()
for abi in "${ABIS[@]}"; do ndk_args+=(-t "$abi"); done

cargo ndk "${ndk_args[@]}" -P "$API_LEVEL" build --release

# Copy only the bridge: cargo-ndk's -o would also ship the cdylibs some dependencies emit, which
# the bridge links statically anyway.
for i in "${!ABIS[@]}"; do
    dest="${PACKAGE_DIR}/android/src/main/jniLibs/${ABIS[$i]}"
    mkdir -p "$dest"
    cp "target/${targets[$i]}/release/${LIB_NAME}" "$dest/"
    ls -l "$dest/${LIB_NAME}"
done
echo "Tari Ootle Android libraries built: ${ABIS[*]}"
