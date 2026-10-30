# Intended to be sourced from any POSIX-like shell:
#   . scripts/prepare_minotari.sh [--update]
#   CW_TARI_WALLET_PATH=/path/to/cw_tari_wallet . scripts/prepare_minotari.sh

#######################################
# Safety
#######################################

set -u

#######################################
# Parse arguments (portable)
#######################################

UPDATE_CW=0

for arg in "$@"; do
  case "$arg" in
    --update)
      UPDATE_CW=1
      ;;
  esac
done

#######################################
# Resolve script directory (portable)
#######################################

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
  /*) ;;
  *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
esac

SCRIPTS_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

#######################################
# Paths
#######################################

# sibling: ./cw_minotari/rust
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
CW_PARENT_DIR="$PROJECT_ROOT/cw_minotari"
CW_RUST_DIR="$CW_PARENT_DIR/rust"
CW_REPO_URL="https://github.com/tari-project/cw_tari_wallet.git"
# Bump together with the bridge. Never build an unpinned HEAD.
CW_REV="1019d47aa6b996e7623e780dda1f4fabd3c42a7a"

#######################################
# cw_tari_wallet setup
#
# CW_TARI_WALLET_PATH=/path/to/cw_tari_wallet builds a local checkout instead of the
# pinned rev. Its tracked files are copied (keeping target/ for incremental builds), so
# codegen and builds never write into that checkout.
#######################################

mkdir -p "$CW_PARENT_DIR"

if [ -n "${CW_TARI_WALLET_PATH:-}" ]; then
  echo "Copying tracked files of the local bridge checkout $CW_TARI_WALLET_PATH"
  mkdir -p "$CW_RUST_DIR"
  find "$CW_RUST_DIR" -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf {} +
  git -C "$CW_TARI_WALLET_PATH" ls-files -z | (cd "$CW_TARI_WALLET_PATH" && xargs -0 tar -cf -) | tar -xf - -C "$CW_RUST_DIR"
else
  if [ "$UPDATE_CW" -eq 1 ]; then
    echo "🔄 --update specified: removing cw_minotari/rust"
    rm -rf "$CW_RUST_DIR"
  fi
  if [ ! -d "$CW_RUST_DIR/.git" ]; then
    rm -rf "$CW_RUST_DIR"
    git clone "$CW_REPO_URL" "$CW_RUST_DIR"
  fi
  git -C "$CW_RUST_DIR" cat-file -e "$CW_REV^{commit}" 2>/dev/null || git -C "$CW_RUST_DIR" fetch origin
  git -C "$CW_RUST_DIR" checkout --detach "$CW_REV"
fi

#######################################
# Build Rust code
#######################################

(
  cd "$CW_RUST_DIR" || exit 1
  cargo build
)

#######################################
# Flutter Rust Bridge codegen
#######################################

(
  cd "$CW_PARENT_DIR" || exit 0
  echo "⚙️  Running flutter_rust_bridge_codegen generate"

  if ! flutter_rust_bridge_codegen generate; then
    echo "⚠️  flutter_rust_bridge_codegen failed."
  fi
)

#######################################
# Build Android .so libraries
#######################################

# Only build Android libraries if ANDROID_HOME is set
if [ -n "${ANDROID_HOME:-}" ] && [ -n "${ANDROID_NDK_VERSION:-}" ]; then
  echo "📱 Building Android .so libraries..."
  (
    cd "$SCRIPTS_DIR/android" || exit 1
    if [ -f "build_minotari.sh" ]; then
      ./build_minotari.sh
    else
      echo "⚠️  build_minotari.sh not found, skipping Android build"
    fi
  )
else
  echo "⏭️  Skipping Android build (ANDROID_HOME or ANDROID_NDK_VERSION not set)"
fi

#######################################
# Build iOS xcframework
#######################################

# Only build iOS libraries is xcodebuild is installed
if command -v xcodebuild &> /dev/null; then
  echo "🍎 Building iOS xcframework..."
  (
    cd "$SCRIPTS_DIR/ios" || exit 1
    if [ -f "build_minotari.sh" ]; then
      if ./build_minotari.sh; then
        echo "✅ iOS xcframework prepared"
      else
        echo "⚠️  iOS build failed"
      fi
    else
      echo "⚠️  build_minotari.sh not found, skipping iOS build"
    fi
  )
else
  echo "⏭️  Skipping iOS build (xcodebuild not installed)"
fi

#######################################
# Done
#######################################

echo "✅ Minotari prepared"
if [ "$UPDATE_CW" -eq 1 ]; then
  echo "✅ cw_tari_wallet refreshed, codegen run, and built"
else
  echo "✅ cw_tari_wallet codegen run and built"
fi
echo "DATABASE_URL remains exported in this shell"
