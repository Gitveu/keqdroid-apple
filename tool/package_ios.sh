#!/usr/bin/env bash
# Build and package an unsigned iOS 15.0+ .ipa (arm64) into
# release/<version>/keqdroid-<version>-ios-arm64.ipa.
#
# Usage:
#   bash tool/package_ios.sh [--skip-core] [--skip-flutter]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_CORE=0
SKIP_FLUTTER=0

for arg in "$@"; do
  case "$arg" in
    --skip-core) SKIP_CORE=1 ;;
    --skip-flutter) SKIP_FLUTTER=1 ;;
    *)
      echo "Usage: $0 [--skip-core] [--skip-flutter]" >&2
      exit 1
      ;;
  esac
done

VERSION="$(awk '/^version:/ {sub(/\+.*/, "", $2); print $2; exit}' "$REPO_ROOT/pubspec.yaml")"
if [ -z "$VERSION" ]; then
  echo "Could not read version from pubspec.yaml" >&2
  exit 1
fi

XCFW_PATH="$REPO_ROOT/ios/Frameworks/KeqCore.xcframework"
if [ "$SKIP_CORE" -eq 0 ] || [ ! -d "$XCFW_PATH" ]; then
  bash "$REPO_ROOT/tool/build_ios_core.sh" device
fi

if [ "$SKIP_FLUTTER" -eq 0 ]; then
  echo "Building Flutter iOS release (unsigned) ..."
  (
    cd "$REPO_ROOT"
    flutter pub get
    flutter build ios --release --no-codesign
  )
fi

APP_SRC="$REPO_ROOT/build/ios/iphoneos/Runner.app"
if [ ! -d "$APP_SRC" ]; then
  echo "Built iOS app bundle not found: $APP_SRC" >&2
  exit 1
fi

if [ ! -f "$APP_SRC/Frameworks/KeqCore.framework/KeqCore" ]; then
  echo "Missing embedded KeqCore.framework inside $APP_SRC" >&2
  exit 1
fi

if [ ! -d "$APP_SRC/PlugIns/PacketTunnelExtension.appex" ]; then
  echo "Missing embedded PacketTunnelExtension.appex inside $APP_SRC" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keqdroid-ipa.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_DIR/Payload"
cp -R "$APP_SRC" "$STAGE_DIR/Payload/Runner.app"

OUT_DIR="$REPO_ROOT/release/$VERSION"
mkdir -p "$OUT_DIR"
IPA_PATH="$OUT_DIR/keqdroid-${VERSION}-ios-arm64.ipa"
rm -f "$IPA_PATH"

echo "Creating $IPA_PATH ..."
(
  cd "$STAGE_DIR"
  zip -r -y -9 -q "$IPA_PATH" Payload
)

echo "Done: $IPA_PATH ($(wc -c < "$IPA_PATH" | tr -d ' ') bytes)"
