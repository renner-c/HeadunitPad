#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/TrollStoreIPA}"
DERIVED_DATA="$ROOT_DIR/.build/TrollStoreDerivedData"
APP_NAME="HeadunitPad"
ENTITLEMENTS="$ROOT_DIR/HeadunitPad/HeadunitPad.entitlements"

# shellcheck source=lib/entitlements.sh
source "$ROOT_DIR/scripts/lib/entitlements.sh"

for tool in xcodebuild ldid zip unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool not found: $tool" >&2
    exit 1
  fi
done

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: entitlements file not found: $ENTITLEMENTS" >&2
  exit 1
fi

echo "==> Building unsigned Release app"
xcodebuild clean build \
  -workspace "$ROOT_DIR/HeadunitPad.xcworkspace" \
  -scheme HeadunitPad \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/$APP_NAME.app"
BINARY="$APP/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
  echo "error: expected app executable not found: $BINARY" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headunitpad-ipa.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Applying TrollStore entitlements"
ldid -S"$ENTITLEMENTS" "$BINARY"
ldid -e "$BINARY" > "$WORK_DIR/embedded-entitlements.plist"
verify_entitlements "$WORK_DIR/embedded-entitlements.plist"

echo "==> Packaging IPA"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR/Payload"
cp -R "$APP" "$WORK_DIR/Payload/$APP_NAME.app"
IPA="$OUTPUT_DIR/$APP_NAME.ipa"
rm -f "$IPA"
(
  cd "$WORK_DIR"
  zip -qry "$IPA" Payload
)

echo "==> Verifying packaged executable"
mkdir "$WORK_DIR/verification"
unzip -q "$IPA" -d "$WORK_DIR/verification"
PACKAGED_APP="$WORK_DIR/verification/Payload/$APP_NAME.app"
PACKAGED_BINARY="$PACKAGED_APP/$APP_NAME"
ldid -e "$PACKAGED_BINARY" > "$WORK_DIR/packaged-entitlements.plist"
verify_entitlements "$WORK_DIR/packaged-entitlements.plist"
test -f "$PACKAGED_APP/Info.plist"
test -d "$PACKAGED_APP/Frameworks"

echo "==> IPA: $IPA"
echo "==> Verified USB Host entitlements:"
ldid -e "$PACKAGED_BINARY"
