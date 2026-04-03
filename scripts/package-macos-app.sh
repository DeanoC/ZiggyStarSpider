#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-SpiderApp}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-SpiderApp}"
BUNDLE_ID="${BUNDLE_ID:-com.deanocalver.spiderapp}"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
ICON_SOURCE="${ICON_SOURCE:-$ROOT_DIR/android/res/drawable/app_icon.png}"
SKIP_BUILD="${SKIP_BUILD:-0}"

cd "$ROOT_DIR"

build_release_mode() {
    case "$OPTIMIZE" in
        Debug)
            zig build install
            zig build gui
            ;;
        ReleaseSafe)
            zig build install --release=safe
            zig build gui --release=safe
            ;;
        ReleaseFast)
            zig build install --release=fast
            zig build gui --release=fast
            ;;
        ReleaseSmall)
            zig build install --release=small
            zig build gui --release=small
            ;;
        *)
            echo "Unsupported OPTIMIZE value: $OPTIMIZE" >&2
            exit 1
            ;;
    esac
}

if [ "$SKIP_BUILD" != "1" ]; then
    build_release_mode
fi

CLI_BIN_PATH="$ROOT_DIR/zig-out/bin/spider"
CORE_LIB_PATH="$ROOT_DIR/zig-out/lib/libspider_core.a"
SHELL_SOURCES=(
    "$ROOT_DIR/macos/SpiderAppShellSupport.swift"
    "$ROOT_DIR/macos/SpiderAppShellApp.swift"
)
BUNDLE_DIR="$ROOT_DIR/zig-out/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TMP_DIR="$ROOT_DIR/zig-out/.macos-package"
ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
INFO_TEMPLATE="$ROOT_DIR/macos/Info.plist.in"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
ZIP_PATH="$ROOT_DIR/zig-out/${APP_NAME}-macos-$(uname -m).zip"
CLANG_RT_PATH="${CLANG_RT_PATH:-$(find /Library/Developer/CommandLineTools /Applications/Xcode.app -name 'libclang_rt.osx.a' 2>/dev/null | head -n 1)}"

[ -f "$CLI_BIN_PATH" ] || { echo "Missing CLI binary at $CLI_BIN_PATH" >&2; exit 1; }
[ -f "$CORE_LIB_PATH" ] || { echo "Missing Spider core library at $CORE_LIB_PATH" >&2; exit 1; }
[ -f "$CLANG_RT_PATH" ] || { echo "Missing libclang_rt.osx.a" >&2; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "Missing swiftc" >&2; exit 1; }

APP_VERSION="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$ROOT_DIR/build.zig.zon" | head -n 1)"
if [ -z "$APP_VERSION" ]; then
    APP_VERSION="0.2.0"
fi

BUILD_VERSION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"

rm -rf "$BUNDLE_DIR" "$TMP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

cp "$CLI_BIN_PATH" "$RESOURCES_DIR/spider"
chmod +x "$RESOURCES_DIR/spider"

swiftc \
    -O \
    -framework AppKit \
    -framework Foundation \
    -framework Security \
    -framework SwiftUI \
    "$CORE_LIB_PATH" \
    "$CLANG_RT_PATH" \
    "${SHELL_SOURCES[@]}" \
    -o "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

sed \
    -e "s/__APP_NAME__/$APP_NAME/g" \
    -e "s/__EXECUTABLE_NAME__/$EXECUTABLE_NAME/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__APP_VERSION__/$APP_VERSION/g" \
    -e "s/__BUILD_VERSION__/$BUILD_VERSION/g" \
    "$INFO_TEMPLATE" > "$INFO_PLIST"

if [ -f "$ICON_SOURCE" ]; then
    ICON_BASE="$TMP_DIR/icon_1024.png"
    sips -c 1024 1024 "$ICON_SOURCE" --out "$ICON_BASE" >/dev/null
    sips -z 16 16 "$ICON_BASE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_BASE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_BASE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_BASE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_BASE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_BASE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_BASE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_BASE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_BASE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    cp "$ICON_BASE" "$ICONSET_DIR/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$INFO_PLIST" >/dev/null
fi

codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null
codesign --verify --deep --strict "$BUNDLE_DIR"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$BUNDLE_DIR" "$ZIP_PATH"

echo "Created app bundle: $BUNDLE_DIR"
echo "Created zip archive: $ZIP_PATH"
