#!/usr/bin/env bash
# Build patched xray-core + mihomo into a single dynamic KeqCore.xcframework
# for iOS 15.0+ (shared by Runner.app and PacketTunnelExtension).
#
# Usage:
#   bash tool/build_ios_core.sh            # device slice only (ios-arm64)
#   bash tool/build_ios_core.sh device     # device slice only (ios-arm64)
#   bash tool/build_ios_core.sh simulator  # simulator slice (host arch)
#   bash tool/build_ios_core.sh all        # device + simulator slices
#
# Output goes to ios/Frameworks/KeqCore.xcframework (gitignored).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/tool/patches"
BRIDGE_SRC="$REPO_ROOT/ios/KeqCore"
OUT_DIR="$REPO_ROOT/ios/Frameworks"
OUT_XCFW="$OUT_DIR/KeqCore.xcframework"
MIN_IOS="15.0"

XRAY_MODULE="github.com/xtls/xray-core"
XRAY_VERSION="${XRAY_VERSION:-v1.260327.1-0.20261109052709-676eaf66f8f0}"
MIHOMO_MODULE="github.com/metacubex/mihomo"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.34}"
MIHOMO_TAGS="with_gvisor,no_tailscale,no_zerotier,no_easytier"

TARGET="${1:-device}"
case "$TARGET" in
  device) SLICES=(device) ;;
  simulator) SLICES=(simulator) ;;
  all) SLICES=(device simulator) ;;
  *)
    echo "Usage: $0 [device|simulator|all]" >&2
    exit 1
    ;;
esac

for cmd in go git xcrun xcodebuild; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required tool: $cmd" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keqdroid-ios-core.XXXXXX")"
trap 'chmod -R u+w "$WORK_DIR" 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT

apply_patches() {
  local src_dir="$1"
  local pattern="$2"
  local count=0
  for patch in "$PATCH_DIR"/$pattern; do
    [ -e "$patch" ] || continue
    echo "Applying $(basename "$patch") ..."
    (cd "$src_dir" && git apply --whitespace=nowarn "$patch")
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    echo "No patches matching $pattern in $PATCH_DIR" >&2
    exit 1
  fi
}

download_module() {
  local mod="$1"
  local ver="$2"
  local dst="$3"
  local dl_dir="$WORK_DIR/dl"
  mkdir -p "$dl_dir"
  if [ ! -f "$dl_dir/go.mod" ]; then
    (cd "$dl_dir" && go mod init keqdroid-ios-dl >/dev/null 2>&1)
  fi
  echo "Downloading $mod@$ver ..."
  (cd "$dl_dir" && go mod download "$mod@$ver")
  local mod_cache
  mod_cache="$(go env GOMODCACHE)"
  local cached="$mod_cache/$mod@$ver"
  if [ ! -d "$cached" ]; then
    echo "Downloaded module not found in cache: $cached" >&2
    exit 1
  fi
  cp -R "$cached" "$dst"
  chmod -R u+w "$dst"
}

# ---- Prepare patched sources -----------------------------------------------
XRAY_SRC="$WORK_DIR/xray-src"
download_module "$XRAY_MODULE" "$XRAY_VERSION" "$XRAY_SRC"
apply_patches "$XRAY_SRC" "xray-*.patch"

MIHOMO_SRC="$WORK_DIR/mihomo-src"
download_module "$MIHOMO_MODULE" "$MIHOMO_VERSION" "$MIHOMO_SRC"
apply_patches "$MIHOMO_SRC" "mihomo-*.patch"

SING_TUN_VERSION="$(awk '/github\.com\/metacubex\/sing-tun / {print $2; exit}' "$MIHOMO_SRC/go.mod")"
SING_TUN_SRC="$WORK_DIR/sing-tun-src"
if [ -n "$SING_TUN_VERSION" ]; then
  download_module "github.com/metacubex/sing-tun" "$SING_TUN_VERSION" "$SING_TUN_SRC"
  apply_patches "$SING_TUN_SRC" "sing-tun-*.patch"
  (cd "$MIHOMO_SRC" && go mod edit -replace "github.com/metacubex/sing-tun=../sing-tun-src")
fi

# ---- Assemble combined Go bridge module ------------------------------------
BRIDGE_WORK="$WORK_DIR/bridge"
mkdir -p "$BRIDGE_WORK"
cp "$BRIDGE_SRC"/*.go "$BRIDGE_WORK/"

cat >"$BRIDGE_WORK/go.mod" <<EOF
module keqcore

go 1.26

require (
	github.com/metacubex/mihomo $MIHOMO_VERSION
	github.com/xtls/xray-core $XRAY_VERSION
	golang.org/x/net v0.49.0
)

replace (
	github.com/metacubex/mihomo => ../mihomo-src
	github.com/xtls/xray-core => ../xray-src
	github.com/metacubex/sing-tun => ../sing-tun-src
)
EOF

echo "Resolving Go dependencies for KeqCore ..."
(cd "$BRIDGE_WORK" && go mod tidy)

# ---- Build slices ----------------------------------------------------------
build_slice() {
  local slice="$1"
  local sdk goarch target_triple min_flag platform_name
  case "$slice" in
    device)
      sdk="iphoneos"
      goarch="arm64"
      target_triple="arm64-apple-ios${MIN_IOS}"
      min_flag="-miphoneos-version-min=${MIN_IOS}"
      platform_name="iPhoneOS"
      ;;
    simulator)
      sdk="iphonesimulator"
      case "$(uname -m)" in
        arm64)
          goarch="arm64"
          target_triple="arm64-apple-ios${MIN_IOS}-simulator"
          ;;
        x86_64)
          goarch="amd64"
          target_triple="x86_64-apple-ios${MIN_IOS}-simulator"
          ;;
        *)
          echo "Unsupported simulator host arch: $(uname -m)" >&2
          exit 1
          ;;
      esac
      min_flag="-mios-simulator-version-min=${MIN_IOS}"
      platform_name="iPhoneSimulator"
      ;;
  esac

  local sdk_path clang
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clang="$(xcrun --sdk "$sdk" --find clang)"

  local slice_dir="$WORK_DIR/slice-$slice"
  mkdir -p "$slice_dir"

  local cc_wrapper="$slice_dir/cc.sh"
  cat >"$cc_wrapper" <<EOF
#!/usr/bin/env bash
exec "$clang" -target "$target_triple" -isysroot "$sdk_path" "$min_flag" -fembed-bitcode-marker "\$@"
EOF
  chmod +x "$cc_wrapper"

  echo "Compiling KeqCore static archive for $slice ($sdk/$goarch) ..."
  (
    cd "$BRIDGE_WORK"
    CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" \
      CC="$cc_wrapper" \
      CGO_CFLAGS="-target $target_triple -isysroot $sdk_path $min_flag" \
      CGO_LDFLAGS="-target $target_triple -isysroot $sdk_path $min_flag" \
      go build -trimpath -buildvcs=false \
      -tags "$MIHOMO_TAGS" \
      -ldflags "-s -w -checklinkname=0 -X github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION" \
      -buildmode=c-archive \
      -o "$slice_dir/libkeqcore.a" .
  )

  local fw_dir="$slice_dir/KeqCore.framework"
  mkdir -p "$fw_dir/Headers" "$fw_dir/Modules"
  cp "$slice_dir/libkeqcore.h" "$fw_dir/Headers/KeqCore.h"

  cat >"$fw_dir/Modules/module.modulemap" <<'EOF'
framework module KeqCore {
  umbrella header "KeqCore.h"
  export *
  module * { export * }
}
EOF

  cat >"$fw_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>KeqCore</string>
	<key>CFBundleIdentifier</key>
	<string>com.keqdroid.keqdroid.KeqCore</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>KeqCore</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platform_name</string>
	</array>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>$MIN_IOS</string>
</dict>
</plist>
EOF

  echo "Linking dynamic KeqCore.framework for $slice ..."
  "$clang" \
    -target "$target_triple" \
    -isysroot "$sdk_path" \
    "$min_flag" \
    -dynamiclib \
    -install_name "@rpath/KeqCore.framework/KeqCore" \
    -Wl,-force_load,"$slice_dir/libkeqcore.a" \
    -framework CoreFoundation \
    -framework Foundation \
    -framework Security \
    -framework Network \
    -lresolv \
    -o "$fw_dir/KeqCore"

  strip -x "$fw_dir/KeqCore"
  echo "  -> $fw_dir/KeqCore ($(wc -c < "$fw_dir/KeqCore" | tr -d ' ') bytes)"
  lipo -info "$fw_dir/KeqCore"
}

XCFW_ARGS=()
for slice in "${SLICES[@]}"; do
  build_slice "$slice"
  XCFW_ARGS+=(-framework "$WORK_DIR/slice-$slice/KeqCore.framework")
done

mkdir -p "$OUT_DIR"
rm -rf "$OUT_XCFW"
echo "Creating $OUT_XCFW ..."
xcodebuild -create-xcframework "${XCFW_ARGS[@]}" -output "$OUT_XCFW"

echo "Done. KeqCore.xcframework ready at $OUT_XCFW (target: $TARGET)."
