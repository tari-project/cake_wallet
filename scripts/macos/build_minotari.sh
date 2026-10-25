#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
  echo "Build the Minotari macOS framework on macOS with Xcode installed." >&2
  exit 1
fi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/minotari_desktop_common.sh"
xtm_desktop_prepare "${1:-mainnet}"
export MACOSX_DEPLOYMENT_TARGET=12.0
rustup target add aarch64-apple-darwin x86_64-apple-darwin
xtm_desktop_build aarch64-apple-darwin
xtm_desktop_build x86_64-apple-darwin

XTM_FRAMEWORKS="$XTM_PROJECT_ROOT/cw_minotari/macos/Frameworks"
mkdir -p "$XTM_FRAMEWORKS"
XTM_STAGE=$(mktemp -d "$XTM_FRAMEWORKS/.xtm-framework.XXXXXX")
trap 'rm -rf "$XTM_STAGE"' EXIT
XTM_FRAMEWORK="$XTM_STAGE/$XTM_LIB.framework"
mkdir -p "$XTM_FRAMEWORK/Versions/A/Resources"
xcrun lipo -create \
  "$XTM_TARGET_DIR/aarch64-apple-darwin/release/lib$XTM_LIB.dylib" \
  "$XTM_TARGET_DIR/x86_64-apple-darwin/release/lib$XTM_LIB.dylib" \
  -output "$XTM_FRAMEWORK/Versions/A/$XTM_LIB"
xcrun lipo "$XTM_FRAMEWORK/Versions/A/$XTM_LIB" -verify_arch arm64 x86_64
xcrun install_name_tool -id "@rpath/$XTM_LIB.framework/Versions/A/$XTM_LIB" \
  "$XTM_FRAMEWORK/Versions/A/$XTM_LIB"
cat > "$XTM_FRAMEWORK/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$XTM_LIB</string>
  <key>CFBundleIdentifier</key><string>com.cakewallet.minotari.native</string>
  <key>CFBundleName</key><string>$XTM_LIB</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
EOF
ln -s A "$XTM_FRAMEWORK/Versions/Current"
ln -s "Versions/Current/$XTM_LIB" "$XTM_FRAMEWORK/$XTM_LIB"
ln -s Versions/Current/Resources "$XTM_FRAMEWORK/Resources"
codesign --force --sign - --timestamp=none "$XTM_FRAMEWORK"
# Replace the previous artifact only after both architectures and packaging succeed.
rm -rf "$XTM_FRAMEWORKS/$XTM_LIB.framework"
mv "$XTM_FRAMEWORK" "$XTM_FRAMEWORKS/"
echo "Minotari macOS universal framework ready ($TARI_NETWORK): $XTM_FRAMEWORKS"
