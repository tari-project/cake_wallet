#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  echo "Build the Minotari Linux library in a Linux x86_64 environment." >&2
  exit 1
fi
export OPENSSL_STATIC=1
# openssl-sys' successful pkg-config fast path otherwise selects shared OpenSSL.
export OPENSSL_LIB_DIR=${OPENSSL_LIB_DIR:-$(pkg-config --variable=libdir openssl)}
export OPENSSL_INCLUDE_DIR=${OPENSSL_INCLUDE_DIR:-$(pkg-config --variable=includedir openssl)}
if [[ ! -f "$OPENSSL_LIB_DIR/libssl.a" || ! -f "$OPENSSL_LIB_DIR/libcrypto.a" ]]; then
  echo "Minotari Linux packaging requires OpenSSL static development libraries." >&2
  exit 1
fi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/minotari_desktop_common.sh"
xtm_desktop_prepare "${1:-mainnet}"
rustup target add x86_64-unknown-linux-gnu
xtm_desktop_build x86_64-unknown-linux-gnu
XTM_OUT="$XTM_PROJECT_ROOT/cw_minotari/linux/lib"
mkdir -p "$XTM_OUT"
XTM_STAGE=$(mktemp "$XTM_OUT/.xtm-library.XXXXXX")
trap 'rm -f "$XTM_STAGE"' EXIT
cp "$XTM_TARGET_DIR/x86_64-unknown-linux-gnu/release/lib$XTM_LIB.so" "$XTM_STAGE"
chmod 755 "$XTM_STAGE"
mv "$XTM_STAGE" "$XTM_OUT/lib$XTM_LIB.so"
echo "Minotari Linux x86_64 library ready ($TARI_NETWORK): $XTM_OUT"
