#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$REPO_ROOT/macos"
OUT_DIR_DEFAULT="$MACOS_DIR/dist"
APP_NAME="SpiderApp"
EXECUTABLE_NAME="SpiderApp"
CLI_BINARY_NAME="spider"
GUI_BINARY_NAME="spider-gui"
APP_BUNDLE_ID="com.deanocalver.spiderapp"
PKG_ID="com.deanocalver.spiderapp.pkg"
ICON_SOURCE_DEFAULT="$REPO_ROOT/android/res/drawable/app_icon.png"
SHELL_SOURCES=("$MACOS_DIR/SpiderAppShellSupport.swift" "$MACOS_DIR/SpiderAppShellApp.swift")
VERSION_DEFAULT="$(sed -n 's/.*\.version = \"\(.*\)\".*/\1/p' "$REPO_ROOT/build.zig.zon" | head -n 1)"
CLANG_RT_PATH_DEFAULT="$(find /Library/Developer/CommandLineTools /Applications/Xcode.app -name 'libclang_rt.osx.a' 2>/dev/null | head -n 1)"

usage() {
  cat <<'EOF'
Build a signed macOS SpiderApp installer package for distribution outside the Mac App Store.

Usage:
  package-spiderapp-macos-release.sh [--version <version>] [--out-dir <dir>] [--skip-notarize] [--skip-build]

Signing configuration:
  The script reuses the same signing identities Spiderweb uses. It accepts either the
  SpiderApp-prefixed variables or the Spiderweb-prefixed ones, and auto-detects identities
  from the login keychain when they are omitted.

Optional environment:
  SPIDERAPP_MACOS_DEVELOPER_ID_APPLICATION
  SPIDERAPP_MACOS_DEVELOPER_ID_INSTALLER
  SPIDERAPP_MACOS_NOTARY_PROFILE
  SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION
  SPIDERWEB_MACOS_DEVELOPER_ID_INSTALLER
  SPIDERWEB_MACOS_NOTARY_PROFILE
  ICON_SOURCE
    Override the default app icon source image

Outputs:
  <out-dir>/SpiderApp-macos-<version>.pkg
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

detect_identity() {
  local label="$1"
  security find-identity -v -p basic | awk -F\" -v label="$label" '$2 ~ label { print $2; exit }'
}

resolve_signing_identity() {
  local primary_var="$1"
  local fallback_var="$2"
  local label="$3"
  local value="${!primary_var:-}"
  if [[ -z "$value" ]]; then
    value="${!fallback_var:-}"
  fi
  if [[ -z "$value" ]]; then
    value="$(detect_identity "$label")"
  fi
  [[ -n "$value" ]] || fail "unable to resolve signing identity matching: $label"
  printf '%s\n' "$value"
}

write_build_metadata() {
  local output_path="$1"
  local git_commit
  local git_short_commit
  local git_dirty
  local built_at_utc

  git_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  git_short_commit="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    git_dirty=true
  else
    git_dirty=false
  fi
  built_at_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  cat >"$output_path" <<EOF
{
  "version": "$version",
  "gitCommit": "$git_commit",
  "gitShortCommit": "$git_short_commit",
  "gitDirty": $git_dirty,
  "builtAtUTC": "$built_at_utc"
}
EOF
}

build_binaries() {
  (
    cd "$REPO_ROOT"
    zig build install --release=safe
    zig build gui --release=safe
  )
}

render_info_plist() {
  local output_path="$1"
  local app_version="$2"
  local build_version="$3"
  sed \
    -e "s/__APP_NAME__/$APP_NAME/g" \
    -e "s/__EXECUTABLE_NAME__/$EXECUTABLE_NAME/g" \
    -e "s/__BUNDLE_ID__/$APP_BUNDLE_ID/g" \
    -e "s/__APP_VERSION__/$app_version/g" \
    -e "s/__BUILD_VERSION__/$build_version/g" \
    "$MACOS_DIR/Info.plist.in" >"$output_path"
}

build_icon() {
  local resources_dir="$1"
  local info_plist="$2"
  local icon_source="$3"
  local tmp_dir="$4"

  [[ -f "$icon_source" ]] || return 0

  local iconset_dir="$tmp_dir/AppIcon.iconset"
  local icon_base="$tmp_dir/icon_1024.png"
  mkdir -p "$iconset_dir"

  sips -c 1024 1024 "$icon_source" --out "$icon_base" >/dev/null
  sips -z 16 16 "$icon_base" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$icon_base" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$icon_base" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$icon_base" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$icon_base" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$icon_base" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$icon_base" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$icon_base" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$icon_base" --out "$iconset_dir/icon_512x512.png" >/dev/null
  cp "$icon_base" "$iconset_dir/icon_512x512@2x.png"
  iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$info_plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$info_plist" >/dev/null
}

build_app_bundle() {
  local bundle_dir="$1"
  local app_version="$2"
  local build_version="$3"
  local icon_source="$4"
  local app_identity="$5"
  local app_tmp_dir="$6"

  local contents_dir="$bundle_dir/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"
  local info_plist="$contents_dir/Info.plist"
  local core_lib_path="$REPO_ROOT/zig-out/lib/libspider_core.a"
  local clang_rt_path="${CLANG_RT_PATH:-$CLANG_RT_PATH_DEFAULT}"

  rm -rf "$bundle_dir"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$REPO_ROOT/zig-out/bin/$CLI_BINARY_NAME" "$resources_dir/$CLI_BINARY_NAME"
  chmod 755 "$resources_dir/$CLI_BINARY_NAME"
  [[ -f "$core_lib_path" ]] || fail "missing Spider core library at $core_lib_path"
  [[ -f "$clang_rt_path" ]] || fail "missing libclang_rt.osx.a"

  swiftc \
    -O \
    -framework AppKit \
    -framework Foundation \
    -framework Security \
    -framework SwiftUI \
    "$core_lib_path" \
    "$clang_rt_path" \
    "${SHELL_SOURCES[@]}" \
    -o "$macos_dir/$EXECUTABLE_NAME"
  chmod 755 "$macos_dir/$EXECUTABLE_NAME"

  render_info_plist "$info_plist" "$app_version" "$build_version"
  build_icon "$resources_dir" "$info_plist" "$icon_source" "$app_tmp_dir"
  write_build_metadata "$resources_dir/build-info.json"

  codesign --force --sign "$app_identity" --timestamp --options runtime \
    "$macos_dir/$EXECUTABLE_NAME"
  codesign --force --sign "$app_identity" --timestamp --options runtime \
    "$resources_dir/$CLI_BINARY_NAME"
  codesign --force --sign "$app_identity" --timestamp --options runtime \
    "$bundle_dir"
}

version="${VERSION_DEFAULT:-0.2.0}"
out_dir="$OUT_DIR_DEFAULT"
skip_notarize=0
skip_build=0
icon_source="${ICON_SOURCE:-$ICON_SOURCE_DEFAULT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?missing value for --version}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --skip-notarize)
      skip_notarize=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

require_command zig
require_command git
require_command codesign
require_command pkgbuild
require_command security
require_command sips
require_command iconutil
require_command python3
require_command xattr
require_command swiftc

app_identity="$(resolve_signing_identity \
  SPIDERAPP_MACOS_DEVELOPER_ID_APPLICATION \
  SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION \
  "Developer ID Application:")"
installer_identity="$(resolve_signing_identity \
  SPIDERAPP_MACOS_DEVELOPER_ID_INSTALLER \
  SPIDERWEB_MACOS_DEVELOPER_ID_INSTALLER \
  "Developer ID Installer:")"
notary_profile="${SPIDERAPP_MACOS_NOTARY_PROFILE:-${SPIDERWEB_MACOS_NOTARY_PROFILE:-}}"

if [[ $skip_notarize -eq 0 && -n "$notary_profile" ]]; then
  require_command xcrun
fi

if [[ $skip_build -eq 0 ]]; then
  echo "==> Building SpiderApp CLI and GUI"
  build_binaries
fi

[[ -x "$REPO_ROOT/zig-out/bin/$CLI_BINARY_NAME" ]] || fail "missing CLI binary at zig-out/bin/$CLI_BINARY_NAME"

mkdir -p "$out_dir"
work_root="$(mktemp -d /tmp/spiderapp-macos-release.XXXXXX)"
trap 'rm -rf "$work_root"' EXIT

payload_root="$work_root/payload"
app_tmp_dir="$work_root/app"
scripts_root="$work_root/scripts"
component_plist="$work_root/Component.plist"
pkg_path="$out_dir/SpiderApp-macos-${version}.pkg"
bundle_dir="$payload_root/Applications/$APP_NAME.app"
app_version="$version"
build_version="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"

echo "==> Staging installer payload"
mkdir -p "$payload_root/Applications" "$payload_root/usr/local/bin" "$scripts_root"
cp "$REPO_ROOT/zig-out/bin/$CLI_BINARY_NAME" "$payload_root/usr/local/bin/$CLI_BINARY_NAME"
chmod 755 "$payload_root/usr/local/bin/$CLI_BINARY_NAME"
codesign --force --sign "$app_identity" --timestamp --options runtime \
  "$payload_root/usr/local/bin/$CLI_BINARY_NAME"

echo "==> Building signed SpiderApp.app"
build_app_bundle "$bundle_dir" "$app_version" "$build_version" "$icon_source" "$app_identity" "$app_tmp_dir"

pkgbuild --analyze --root "$payload_root" "$component_plist"
python3 - "$component_plist" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])

with plist_path.open('rb') as fh:
    components = plistlib.load(fh)

for component in components:
    root_path = component.get("RootRelativeBundlePath")
    if root_path == "Applications/SpiderApp.app":
        component["BundleIsRelocatable"] = False
        component["BundleHasStrictIdentifier"] = True
        component["BundleIsVersionChecked"] = True
        component["BundleOverwriteAction"] = "upgrade"

with plist_path.open('wb') as fh:
    plistlib.dump(components, fh)
PY

echo "==> Verifying signatures"
codesign --verify --deep --strict "$bundle_dir"
codesign --verify --strict "$payload_root/usr/local/bin/$CLI_BINARY_NAME"

find "$payload_root" -name '._*' -delete
xattr -cr "$payload_root"

echo "==> Building signed installer package"
rm -f "$pkg_path"
pkgbuild \
  --root "$payload_root" \
  --filter '(^|/)\._' \
  --filter '(^|/)\.DS_Store$' \
  --component-plist "$component_plist" \
  --identifier "$PKG_ID" \
  --ownership recommended \
  --version "$version" \
  --install-location "/" \
  --sign "$installer_identity" \
  "$pkg_path"

if [[ $skip_notarize -eq 0 && -n "$notary_profile" ]]; then
  echo "==> Notarizing installer package"
  xcrun notarytool submit "$pkg_path" --keychain-profile "$notary_profile" --wait
  echo "==> Stapling installer package"
  xcrun stapler staple "$pkg_path"
fi

echo "==> Final package"
echo "$pkg_path"
