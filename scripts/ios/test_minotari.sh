#!/usr/bin/env bash
set -euo pipefail

# Always create our own Simulator. Never accept an existing device or app profile.
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <simulator-device-type-id> <ios-runtime-id> [wallet|logging]" >&2
  echo "List identifiers with: xcrun simctl list devicetypes; xcrun simctl list runtimes" >&2
  exit 2
fi

case "${3:-wallet}" in
  wallet)
    XTM_TEST_TARGET=integration_test/minotari/minotari_wallet_flow_test.dart
    XTM_TEST_DEFINE=MINOTARI_ESMERALDA_TESTS=true
    ;;
  logging)
    XTM_TEST_TARGET=integration_test/minotari/minotari_logging_test.dart
    XTM_TEST_DEFINE=MINOTARI_NATIVE_LOGGING_TESTS=true
    ;;
  *)
    echo "Unknown XTM suite: $3 (expected wallet or logging)" >&2
    exit 2
    ;;
esac

command -v flutter >/dev/null
command -v xcrun >/dev/null
XTM_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
XTM_TEST_DEVICE=$(xcrun simctl create "Cake XTM integration $(date +%s)" "$1" "$2")
cleanup() {
  xcrun simctl shutdown "$XTM_TEST_DEVICE" >/dev/null 2>&1 || true
  xcrun simctl delete "$XTM_TEST_DEVICE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun simctl boot "$XTM_TEST_DEVICE"
xcrun simctl bootstatus "$XTM_TEST_DEVICE" -b
cd "$XTM_ROOT"
# drive retries failed builds as prebuilt launches, which can run a stale bundle.
# Fail on compilation first, then drive exactly the successfully built binary.
flutter build ios --simulator --debug --no-pub \
  --target="$XTM_TEST_TARGET" \
  --dart-define="$XTM_TEST_DEFINE"
flutter drive --no-pub --keep-app-running \
  --use-application-binary="$XTM_ROOT/build/ios/iphonesimulator/Runner.app" \
  --driver=test_driver/integration_test.dart \
  --target="$XTM_TEST_TARGET" \
  --dart-define="$XTM_TEST_DEFINE" \
  -d "$XTM_TEST_DEVICE"
