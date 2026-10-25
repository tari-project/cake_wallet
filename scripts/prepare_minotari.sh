# Run from the Cake Wallet root:
#   bash scripts/prepare_minotari.sh [--update] [--source-only]

#######################################
# Safety
#######################################

set -u

#######################################
# Parse arguments (portable)
#######################################

UPDATE_CW=0
SOURCE_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --update)
      UPDATE_CW=1
      ;;
    --source-only)
      SOURCE_ONLY=1
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
CW_REPO_URL="https://github.com/0xskr33p/cw_tari_wallet.git"
# Update this pin after pushing the corresponding wrapper changes.
CW_REPO_REV="349f4fdbf0b63f764697c2dae020368d92b77788"


#######################################
# cw_tari_wallet setup
#######################################

mkdir -p "$CW_PARENT_DIR"

if [ "$UPDATE_CW" -eq 1 ] && [ -d "$CW_RUST_DIR" ]; then
  echo "🔄 --update specified: removing cw_minotari/rust"
  rm -rf "$CW_RUST_DIR"
fi

if [ ! -d "$CW_RUST_DIR" ]; then
  git clone "$CW_REPO_URL" "$CW_RUST_DIR" || { return 1 2>/dev/null || exit 1; }
fi

#######################################
# Select the pinned wrapper and build Rust code
#######################################

(
  cd "$CW_RUST_DIR" || exit 1
  if ! git cat-file -e "${CW_REPO_REV}^{commit}" 2>/dev/null; then
    git fetch "$CW_REPO_URL" "$CW_REPO_REV" || exit 1
  fi
  git checkout --detach "$CW_REPO_REV" || exit 1
  if [ "$SOURCE_ONLY" -eq 0 ]; then
    cargo build --locked
  fi
) || { return 1 2>/dev/null || exit 1; }

if [ "$SOURCE_ONLY" -eq 1 ]; then
  echo "Minotari wrapper source ready at ${CW_REPO_REV}"
  return 0 2>/dev/null || exit 0
fi

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
