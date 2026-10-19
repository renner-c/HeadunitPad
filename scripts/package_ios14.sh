#!/bin/bash
# Turn an UNSIGNED built HeadunitPad.app into two installable iOS 14 artifacts:
#
#   <output-dir>/HeadunitPad-iOS14-TrollStore.ipa
#       Payload/HeadunitPad.app, fakesigned with ldid + the USB Host entitlements.
#   <output-dir>/headunitpad-ios14_<version>_iphoneos-arm.deb
#       Rootful jailbreak package installing /Applications/HeadunitPad.app, with
#       bundle id "<original>.jb" and display name "Headunit JB" so it can sit
#       next to the TrollStore copy for A/B testing.
#
# Usage: scripts/package_ios14.sh <path/to/HeadunitPad.app> <output-dir> [version]
#
# Environment:
#   MAX_MINOS     highest allowed Mach-O minos / MinimumOSVersion (default 14.3)
#   ENTITLEMENTS  entitlements plist to sign with
#                 (default HeadunitPad/HeadunitPad.entitlements)
#
# [version] is the Debian package version; default "<CFBundleShortVersionString>~ios14.1".
# Requires: ldid, dpkg-deb, zip, unzip, plutil, otool, file, PlistBuddy (macOS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/entitlements.sh
source "$SCRIPT_DIR/lib/entitlements.sh"

APP_BUNDLE="HeadunitPad.app"
IPA_NAME="HeadunitPad-iOS14-TrollStore.ipa"
DEB_PACKAGE="com.renner-c.headunitpad-ios14"
DEB_FILE_PREFIX="headunitpad-ios14"
DEB_DISPLAY_NAME="Headunit JB"
DEB_ID_SUFFIX=".jb"
MAX_MINOS="${MAX_MINOS:-14.3}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/HeadunitPad/HeadunitPad.entitlements}"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

usage() {
  cat <<EOF
usage: $(basename "$0") <path/to/HeadunitPad.app> <output-dir> [version]
  env MAX_MINOS=$MAX_MINOS (highest allowed minos), ENTITLEMENTS=<plist>
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then usage >&2; exit 2; fi

APP_IN="${1%/}"
OUT_ARG="$2"
VERSION_ARG="${3:-}"

for tool in ldid dpkg-deb zip unzip plutil otool file; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool (macOS runner: brew install ldid dpkg)"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "required tool not found: /usr/libexec/PlistBuddy"

[[ -d "$APP_IN" && -f "$APP_IN/Info.plist" ]] || die "not an app bundle (no Info.plist): $APP_IN"
[[ -f "$ENTITLEMENTS" ]] || die "entitlements file not found: $ENTITLEMENTS"
verify_entitlements "$ENTITLEMENTS" || die "entitlements file is missing required keys: $ENTITLEMENTS"

APP_IN="$(cd "$APP_IN" && pwd)"
mkdir -p "$OUT_ARG"
OUT_DIR="$(cd "$OUT_ARG" && pwd)"

plist_raw() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

EXEC_NAME="$(plist_raw "$APP_IN/Info.plist" CFBundleExecutable)"
[[ -n "$EXEC_NAME" && -f "$APP_IN/$EXEC_NAME" ]] || die "CFBundleExecutable missing or executable not found in $APP_IN"
ORIG_ID="$(plist_raw "$APP_IN/Info.plist" CFBundleIdentifier)"
[[ -n "$ORIG_ID" ]] || die "CFBundleIdentifier missing from $APP_IN/Info.plist"
SHORT_VERSION="$(plist_raw "$APP_IN/Info.plist" CFBundleShortVersionString)"

VERSION="${VERSION_ARG:-${SHORT_VERSION:+${SHORT_VERSION}~ios14.1}}"
[[ -n "$VERSION" ]] || die "no version given and CFBundleShortVersionString is absent"
[[ "$VERSION" =~ ^[0-9][A-Za-z0-9.+~-]*$ ]] || die "not a Debian-safe version: '$VERSION' (expected e.g. 0.4.0~ios14.1)"

IPA="$OUT_DIR/$IPA_NAME"
DEB="$OUT_DIR/${DEB_FILE_PREFIX}_${VERSION}_iphoneos-arm.deb"

# --- helpers -----------------------------------------------------------------

# true when $1 > $2 (dotted numeric versions)
version_gt() {
  local IFS=.
  local -a a=($1) b=($2)
  local n=${#a[@]} i x y
  ((${#b[@]} > n)) && n=${#b[@]}
  for ((i = 0; i < n; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 1
}

# Print one minos per architecture slice of Mach-O $1 (LC_BUILD_VERSION minos or
# LC_VERSION_MIN_IPHONEOS version). Uses `xcrun vtool` when available, else otool.
macho_minos() {
  local f="$1" out=""
  if command -v xcrun >/dev/null 2>&1; then
    out="$(xcrun vtool -show-build "$f" 2>/dev/null || true)"
  fi
  if ! grep -q 'LC_BUILD_VERSION\|LC_VERSION_MIN' <<<"$out"; then
    out="$(otool -l "$f" 2>/dev/null || true)"
  fi
  awk '
    /cmd LC_VERSION_MIN_IPHONEOS/ { legacy = 1 }
    $1 == "minos"               { print $2; legacy = 0 }
    legacy && $1 == "version"   { print $2; legacy = 0 }
  ' <<<"$out"
}

is_macho() { file -b "$1" | grep -q 'Mach-O'; }

# Mach-O files under $1, deepest paths first (so nested code is signed before its parents).
list_machos() {
  local f
  while IFS= read -r -d '' f; do
    is_macho "$f" && printf '%s\n' "$f"
  done < <(find "$1" -type f -print0) |
    awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-
}

check_minos() { # <app dir>
  local app="$1" f m bad=0 any
  step "Checking minos (max allowed $MAX_MINOS)"
  while IFS= read -r f; do
    any=0
    while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      any=1
      printf '    minos %-6s %s\n' "$m" "${f#"$app"/}"
      if version_gt "$m" "$MAX_MINOS"; then
        echo "error: ${f#"$app"/} has minos $m > $MAX_MINOS (set MAX_MINOS to override)" >&2
        bad=1
      fi
    done < <(macho_minos "$f")
    if [[ $any -eq 0 ]]; then
      echo "error: could not read minos of ${f#"$app"/}" >&2
      bad=1
    fi
  done < <(list_machos "$app")
  local plist_min
  plist_min="$(plist_raw "$app/Info.plist" MinimumOSVersion)"
  if [[ -n "$plist_min" ]]; then
    printf '    MinimumOSVersion %s (Info.plist)\n' "$plist_min"
    if version_gt "$plist_min" "$MAX_MINOS"; then
      echo "error: Info.plist MinimumOSVersion $plist_min > $MAX_MINOS (minos gate)" >&2
      bad=1
    fi
  fi
  [[ $bad -eq 0 ]] || die "minos gate failed: the build targets newer than iOS $MAX_MINOS"
}

# Fakesign every Mach-O: nested first with no entitlements, main executable last with them.
sign_app() { # <app dir>
  local app="$1" f main="$1/$EXEC_NAME"
  find "$app" -name _CodeSignature -type d -prune -exec rm -rf {} +
  find "$app" \( -name .DS_Store -o -name __MACOSX \) -exec rm -rf {} + 2>/dev/null || true
  while IFS= read -r f; do
    [[ "$f" == "$main" ]] && continue
    ldid -S "$f" 2>/dev/null || die "ldid failed on ${f#"$app"/}"
  done < <(list_machos "$app")
  ldid -S"$ENTITLEMENTS" "$main" 2>/dev/null || die "ldid failed on $EXEC_NAME"
}

# Every Mach-O must carry a code signature; the main executable must carry all entitlements.
verify_app() { # <label> <app dir>
  local label="$1" app="$2" f n=0 ent
  ent="$(mktemp "${TMPDIR:-/tmp}/headunitpad-ent.XXXXXX")"
  while IFS= read -r f; do
    n=$((n + 1))
    ldid -h "$f" 2>&1 | grep -q CodeDirectory || { rm -f "$ent"; die "$label: no code signature on ${f#"$app"/}"; }
  done < <(list_machos "$app")
  ldid -e "$app/$EXEC_NAME" >"$ent" 2>/dev/null || true
  if ! verify_entitlements "$ent"; then rm -f "$ent"; die "$label: packaged $EXEC_NAME lacks required entitlements"; fi
  rm -f "$ent"
  echo "    $label: $n Mach-O files signed; entitlements verified on $EXEC_NAME"
}

# Install modes: dirs 0755, Mach-O 0755, everything else 0644.
normalize_modes() { # <app dir>
  local app="$1" f
  find "$app" -type d -exec chmod 755 {} +
  find "$app" -type f -exec chmod 644 {} +
  while IFS= read -r f; do chmod 755 "$f"; done < <(list_machos "$app")
}

copy_app() { # <dest dir>
  mkdir -p "$1"
  cp -R "$APP_IN" "$1/$APP_BUNDLE"
  xattr -cr "$1/$APP_BUNDLE" 2>/dev/null || true
}

# --- main --------------------------------------------------------------------

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headunitpad-package.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

check_minos "$APP_IN"

# IPA ------------------------------------------------------------------------
step "Building TrollStore IPA"
copy_app "$WORK_DIR/ipa/Payload"
sign_app "$WORK_DIR/ipa/Payload/$APP_BUNDLE"
rm -f "$IPA"
(cd "$WORK_DIR/ipa" && zip -qryX "$IPA" Payload)
mkdir "$WORK_DIR/ipa-verify"
unzip -q "$IPA" -d "$WORK_DIR/ipa-verify"
[[ "$(ls "$WORK_DIR/ipa-verify")" == "Payload" ]] || die "IPA must contain only Payload/"
verify_app "IPA" "$WORK_DIR/ipa-verify/Payload/$APP_BUNDLE"

# deb ------------------------------------------------------------------------
step "Building rootful deb ($DEB_PACKAGE $VERSION)"
DEB_ROOT="$WORK_DIR/deb"
copy_app "$DEB_ROOT/Applications"
DEB_APP="$DEB_ROOT/Applications/$APP_BUNDLE"
case "$ORIG_ID" in
  *"$DEB_ID_SUFFIX") DEB_ID="$ORIG_ID" ;;
  *) DEB_ID="${ORIG_ID}${DEB_ID_SUFFIX}" ;;
esac
plutil -replace CFBundleIdentifier -string "$DEB_ID" "$DEB_APP/Info.plist"
plutil -replace CFBundleDisplayName -string "$DEB_DISPLAY_NAME" "$DEB_APP/Info.plist"
[[ "$(plist_raw "$DEB_APP/Info.plist" CFBundleIdentifier)" == "$DEB_ID" ]] || die "failed to set CFBundleIdentifier"
[[ "$(plist_raw "$DEB_APP/Info.plist" CFBundleDisplayName)" == "$DEB_DISPLAY_NAME" ]] || die "failed to set CFBundleDisplayName"
sign_app "$DEB_APP"
normalize_modes "$DEB_APP"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/Applications"

mkdir -p "$DEB_ROOT/DEBIAN"
INSTALLED_KB="$(du -sk "$DEB_ROOT/Applications" | cut -f1)"
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: $DEB_PACKAGE
Name: $DEB_DISPLAY_NAME
Version: $VERSION
Architecture: iphoneos-arm
Depends: firmware (>= 14.0)
Section: Utilities
Priority: optional
Installed-Size: $INSTALLED_KB
Maintainer: renner-c
Author: renner-c
Description: Android Auto head unit for iPad (iOS 14 jailbreak build, bundle id $DEB_ID)
EOF
cat >"$DEB_ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
if command -v uicache >/dev/null 2>&1; then
  uicache -p /Applications/HeadunitPad.app || uicache -a || uicache || true
fi
exit 0
EOF
cat >"$DEB_ROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
if command -v uicache >/dev/null 2>&1; then
  uicache -a || uicache || true
fi
exit 0
EOF
chmod 755 "$DEB_ROOT/DEBIAN" "$DEB_ROOT/DEBIAN/postinst" "$DEB_ROOT/DEBIAN/postrm"
chmod 644 "$DEB_ROOT/DEBIAN/control"

rm -f "$DEB"
dpkg-deb --root-owner-group -Zxz -b "$DEB_ROOT" "$DEB" >/dev/null

step "Verifying deb"
[[ "$(dpkg-deb -f "$DEB" Package)" == "$DEB_PACKAGE" ]] || die "deb Package field wrong"
[[ "$(dpkg-deb -f "$DEB" Version)" == "$VERSION" ]] || die "deb Version field wrong"
[[ "$(dpkg-deb -f "$DEB" Architecture)" == "iphoneos-arm" ]] || die "deb Architecture field wrong"
DEB_LISTING="$(dpkg-deb -c "$DEB")"
grep -q " \./Applications/$APP_BUNDLE/\$" <<<"$DEB_LISTING" || die "deb does not install ./Applications/$APP_BUNDLE/"
mkdir "$WORK_DIR/deb-verify"
dpkg-deb -x "$DEB" "$WORK_DIR/deb-verify"
verify_app "deb" "$WORK_DIR/deb-verify/Applications/$APP_BUNDLE"
[[ "$(plist_raw "$WORK_DIR/deb-verify/Applications/$APP_BUNDLE/Info.plist" CFBundleIdentifier)" == "$DEB_ID" ]] || die "deb bundle id wrong"

step "Done"
echo "    IPA: $IPA"
echo "    deb: $DEB"
