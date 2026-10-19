#!/usr/bin/env bash
# Fetch the iPhoneOS 14.3 SDK stubs (.tbd text stubs only) for scripts/check_ios14_imports.py.
#
# Usage: scripts/fetch_ios14_sdk.sh <dest-dir>
# Result: <dest-dir>/iPhoneOS14.3.sdk  (also printed on the last stdout line)
#
# Source (pinned):
#   repo    https://github.com/xybp888/iOS-SDKs
#   commit  ad607cb07fe4ad1c9b91cf970bd228c2a9253207
#   SDK     iPhoneOS14.3.sdk
# theos/sdks was checked first but only carries iPhoneOS14.5.sdk (no 14.0-14.4), so the
# exact-match 14.3 SDK from xybp888/iOS-SDKs is used.
#
# Only *.tbd files and SDKSettings.* are checked out (partial clone + sparse checkout);
# headers and binaries are never downloaded. Nothing is committed to this repo.
#
# Caveats:
#  * Community-hosted SDK, not Apple-signed; treat as a best-effort reference.
#  * .tbd stubs list exported symbols but carry NO per-symbol availability (no
#    "introduced in iOS X"). A symbol present in the 14.3 SDK is assumed to be in
#    the 14.3 runtime. A symbol absent here is a strong signal of a dyld
#    "Symbol not found" at launch.
#  * If the pin is ever swapped for 14.4/14.5 (e.g. theos/sdks iPhoneOS14.5.sdk),
#    symbols added after 14.3 will NOT be caught. The pin is 14.3 exactly today.
#  * Swift back-deployment dylibs embedded in the .app (libswift_Concurrency.dylib,
#    ...) are checked against their own exports, not the SDK.
set -euo pipefail

REPO_URL="https://github.com/xybp888/iOS-SDKs.git"
COMMIT="ad607cb07fe4ad1c9b91cf970bd228c2a9253207"
SDK_NAME="iPhoneOS14.3.sdk"

if [ $# -ne 1 ]; then
  echo "usage: $0 <dest-dir>" >&2
  exit 2
fi
mkdir -p "$1"
DEST="$(cd "$1" && pwd)"

if [ -d "$DEST/$SDK_NAME/usr/lib" ] && [ -f "$DEST/.sdk-commit" ] \
   && [ "$(cat "$DEST/.sdk-commit")" = "$COMMIT" ]; then
  echo "SDK already present at $DEST/$SDK_NAME" >&2
  echo "$DEST/$SDK_NAME"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ios14sdk.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Run git against the scratch repo explicitly (never the caller's repo).
G=(git -C "$WORK/repo")
git init -q "$WORK/repo"
"${G[@]}" remote add origin "$REPO_URL"
"${G[@]}" config core.sparseCheckout true
printf '%s\n' \
  "/$SDK_NAME/SDKSettings.*" \
  "/$SDK_NAME/**/*.tbd" > "$WORK/repo/.git/info/sparse-checkout"
"${G[@]}" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
"${G[@]}" checkout -q FETCH_HEAD

rm -rf "$DEST/$SDK_NAME"
mv "$WORK/repo/$SDK_NAME" "$DEST/$SDK_NAME"
echo "$COMMIT" > "$DEST/.sdk-commit"
echo "fetched $SDK_NAME @ $COMMIT ($(find "$DEST/$SDK_NAME" -name '*.tbd' | wc -l | tr -d ' ') tbd files)" >&2
echo "$DEST/$SDK_NAME"
