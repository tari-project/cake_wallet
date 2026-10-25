#!/usr/bin/env bash
# Shared only by the Minotari desktop build scripts. Source from bash.

xtm_desktop_prepare() {
  local network=${1:-mainnet}
  case "$network" in
    mainnet) export TARI_NETWORK=mainnet TARI_TARGET_NETWORK=mainnet ;;
    esmeralda|esme) export TARI_NETWORK=esme TARI_TARGET_NETWORK=testnet ;;
    *) echo "Unsupported Minotari network: $network (mainnet or esmeralda)" >&2; return 2 ;;
  esac

  XTM_PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  if [[ $(flutter_rust_bridge_codegen --version) != 'flutter_rust_bridge_codegen 2.11.1' ]]; then
    echo "Minotari desktop requires flutter_rust_bridge_codegen 2.11.1." >&2
    return 1
  fi
  if [[ -n ${MINOTARI_RUST_DIR:-} ]]; then
    # Optional local development checkout. Production uses prepare's exact pin.
    XTM_RUST_DIR=$(cd "$MINOTARI_RUST_DIR" && pwd)
  else
    bash "$XTM_PROJECT_ROOT/scripts/prepare_minotari.sh" --source-only
    XTM_RUST_DIR="$XTM_PROJECT_ROOT/cw_minotari/rust"
  fi
  if [[ ! -f "$XTM_RUST_DIR/Cargo.lock" || ! -f "$XTM_RUST_DIR/Cargo.toml" ]]; then
    echo "Missing Minotari wrapper Cargo.toml/Cargo.lock: $XTM_RUST_DIR" >&2
    return 1
  fi
  XTM_TARGET_DIR=${CARGO_TARGET_DIR:-$XTM_RUST_DIR/target}
  mkdir -p "$XTM_TARGET_DIR"
  XTM_TARGET_DIR=$(cd "$XTM_TARGET_DIR" && pwd)
  XTM_LIB=rust_lib_flutter_rust_wallet

  # The wrapper's own generated bridge uses its verification-package namespace.
  # Generate Cake's cw_minotari symbols in an isolated source copy, preserving
  # both the pinned checkout and Cake's mobile generated files.
  local build_package="$XTM_PROJECT_ROOT/cw_minotari/.dart_tool/desktop-$(uname -s)/cw_minotari"
  local build_source="$build_package/rust"
  rm -rf "$build_package"
  mkdir -p "$build_source"
  cp "$XTM_PROJECT_ROOT/cw_minotari/pubspec.yaml" "$build_package/pubspec.yaml"
  tar -C "$XTM_RUST_DIR" --exclude=.git --exclude=target --exclude=.dart_tool -cf - . \
    | tar -C "$build_source" -xf -
  XTM_RUST_DIR="$build_source"
  (
    cd "$XTM_PROJECT_ROOT"
    export CARGO_TARGET_DIR="$XTM_TARGET_DIR"
    flutter_rust_bridge_codegen generate --rust-input crate::api \
      --rust-root "$XTM_RUST_DIR" --rust-output "$XTM_RUST_DIR/src/frb_generated.rs" \
      --dart-root "$build_package" --dart-output "$build_package/lib/src/rust" \
      --enable-lifetime --no-deps-check --no-auto-upgrade-dependency \
      --no-dart-format --no-dart-fix --no-build-runner
  )
  local generated="$build_package/lib/src/rust"
  local app_bridge="$XTM_PROJECT_ROOT/cw_minotari/lib/src/rust"
  if [[ -f "$app_bridge/frb_generated.dart" ]]; then
    local actual_hash expected_hash
    actual_hash=$(awk '/get rustContentHash/ {print $5}' "$generated/frb_generated.dart")
    expected_hash=$(awk '/get rustContentHash/ {print $5}' "$app_bridge/frb_generated.dart")
    if [[ -z "$actual_hash" || "$actual_hash" != "$expected_hash" ]]; then
      echo "Minotari native/Dart bridge mismatch. Regenerate Cake's bridge before building." >&2
      return 1
    fi
  else
    mkdir -p "$app_bridge"
    cp -R "$generated/." "$app_bridge/"
  fi
}

xtm_desktop_build() {
  local target=$1
  cargo build --manifest-path "$XTM_RUST_DIR/Cargo.toml" --locked --release --lib \
    --target "$target" --target-dir "$XTM_TARGET_DIR"
}
