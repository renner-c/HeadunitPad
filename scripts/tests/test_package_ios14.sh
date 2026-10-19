#!/bin/bash
# Tests for scripts/package_ios14.sh (plain bash, no framework).
#
#   scripts/tests/test_package_ios14.sh
#
# Fixture: the upstream release IPA (minos 16.6) is downloaded with `gh` into a
# fresh temp dir and unzipped into another. Set HEADUNITPAD_TEST_APP=/path/to/
# HeadunitPad.app to reuse an existing unsigned/signed app instead. The fixture
# is treated as untrusted data: only static inspection tools ever touch it, it
# is never executed, and the packager only copies it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGER="$ROOT_DIR/scripts/package_ios14.sh"
ENTITLEMENTS="$ROOT_DIR/HeadunitPad/HeadunitPad.entitlements"
# shellcheck source=../lib/entitlements.sh
source "$ROOT_DIR/scripts/lib/entitlements.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/package-ios14-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASSES=0
FAILS=0
ok()   { PASSES=$((PASSES + 1)); echo "  ok   - $1"; }
bad()  { FAILS=$((FAILS + 1));  echo "  FAIL - $1" >&2; }
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
check_not() { # check_not <description> <command...>  (command must fail)
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}
eq() { # eq <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
contains() { # contains <description> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing '$3')"; fi
}
section() { echo; echo "== $1"; }

# --- fixture -----------------------------------------------------------------
if [[ -n "${HEADUNITPAD_TEST_APP:-}" ]]; then
  FIXTURE_APP="$HEADUNITPAD_TEST_APP"
else
  command -v gh >/dev/null 2>&1 || { echo "error: gh required to download fixture (or set HEADUNITPAD_TEST_APP)" >&2; exit 1; }
  mkdir "$WORK/download" "$WORK/unzipped"
  gh release download -R andyching168/HeadunitPad --pattern '*.ipa' -D "$WORK/download"
  ipas=("$WORK"/download/*.ipa)
  unzip -q "${ipas[0]}" -d "$WORK/unzipped"
  FIXTURE_APP="$WORK/unzipped/Payload/HeadunitPad.app"
fi
[[ -f "$FIXTURE_APP/Info.plist" ]] || { echo "error: fixture app not found: $FIXTURE_APP" >&2; exit 1; }

ORIG_ID="$(plutil -extract CFBundleIdentifier raw -o - "$FIXTURE_APP/Info.plist")"
ORIG_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$FIXTURE_APP/Info.plist")"
BIN_SUM_BEFORE="$(shasum "$FIXTURE_APP/HeadunitPad" | cut -d' ' -f1)"

run_packager() { # run_packager <logname> <outdir> [env assignments...] -- <args...>
  local log="$WORK/$1.log" out="$2"; shift 2
  local -a envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  set +e
  env ${envs[@]+"${envs[@]}"} "$PACKAGER" "$@" >"$log" 2>&1
  RC=$?
  set -e
  LOG="$(cat "$log")"
  : "$out"
}

is_macho() { file -b "$1" | grep -q 'Mach-O'; }

assert_all_machos_signed() { # <label> <app dir>
  local label="$1" app="$2" n=0 unsigned=0 f
  while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    n=$((n + 1))
    if ! ldid -h "$f" 2>&1 | grep -q 'CodeDirectory'; then
      unsigned=$((unsigned + 1)); echo "    unsigned: $f" >&2
    fi
  done < <(find "$app" -type f -print0)
  if [[ $n -ge 2 && $unsigned -eq 0 ]]; then ok "$label: all $n Mach-O files carry a CodeDirectory"
  else bad "$label: $unsigned of $n Mach-O files unsigned (expected >= 2 Mach-O)"; fi
}

assert_entitlements() { # <label> <binary>
  local label="$1" bin="$2" ent="$WORK/ent.$$.plist"
  ldid -e "$bin" >"$ent" 2>/dev/null || true
  if verify_entitlements "$ent" 2>"$WORK/ent.err"; then ok "$label: all 4 entitlement keys present"
  else bad "$label: entitlements incomplete: $(cat "$WORK/ent.err")"; fi
}

# --- 1. usage ----------------------------------------------------------------
section "usage and argument validation"
run_packager usage1 "" -- ; eq "no args exits 2" "2" "$RC"
run_packager usage2 "" -- "$WORK/does-not-exist.app" "$WORK/o-missing"
check_not "missing app dir fails" test "$RC" -eq 0
contains "missing app dir explains" "$LOG" "error:"
run_packager badver "" MAX_MINOS=99 -- "$FIXTURE_APP" "$WORK/o-badver" "bad version!"
check_not "invalid Debian version rejected" test "$RC" -eq 0
check_not "no artifacts for invalid version" test -e "$WORK/o-badver/HeadunitPad-iOS14-TrollStore.ipa"

# --- 2. entitlements lib -----------------------------------------------------
section "verify_entitlements"
check "repo entitlements file passes" verify_entitlements "$ENTITLEMENTS"
cp "$ENTITLEMENTS" "$WORK/missing-new-key.plist"
/usr/libexec/PlistBuddy -c "Delete :com.apple.private.iokit.IOServiceSetAuthorizationID" "$WORK/missing-new-key.plist"
check_not "plist lacking IOServiceSetAuthorizationID fails" verify_entitlements "$WORK/missing-new-key.plist"
cp "$ENTITLEMENTS" "$WORK/missing-array.plist"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.exception.iokit-user-client-class" "$WORK/missing-array.plist"
check_not "plist lacking iokit-user-client-class fails" verify_entitlements "$WORK/missing-array.plist"
: >"$WORK/empty.plist"
check_not "empty plist fails" verify_entitlements "$WORK/empty.plist"
check "entitlements file lints" plutil -lint "$ENTITLEMENTS"

# --- 3. minos gate (fixture is minos 16.6) -------------------------------------
section "minos gate"
run_packager gate "" -- "$FIXTURE_APP" "$WORK/o-gate"
check_not "default gate (14.3) rejects the minos-16.6 fixture" test "$RC" -eq 0
contains "gate message names minos" "$LOG" "minos"
contains "gate message names offending version" "$LOG" "16.6"
check_not "no IPA produced when gate fails" test -e "$WORK/o-gate/HeadunitPad-iOS14-TrollStore.ipa"
check_not "no deb produced when gate fails" bash -c 'ls "$1"/*.deb' _ "$WORK/o-gate"

# --- 4. full packaging with the gate skipped ----------------------------------
section "package (MAX_MINOS=99)"
OUT="$WORK/out"
run_packager full "$OUT" MAX_MINOS=99 -- "$FIXTURE_APP" "$OUT" "0.4.0~ios14.1"
if [[ $RC -ne 0 ]]; then bad "packager exit 0 (rc=$RC)"; echo "$LOG" >&2; fi
IPA="$OUT/HeadunitPad-iOS14-TrollStore.ipa"
DEB="$OUT/headunitpad-ios14_0.4.0~ios14.1_iphoneos-arm.deb"
check "IPA exists" test -s "$IPA"
check "deb exists" test -s "$DEB"
contains "log prints minos per Mach-O" "$LOG" "minos 16.6"
check "fixture binary untouched" test "$(shasum "$FIXTURE_APP/HeadunitPad" | cut -d' ' -f1)" = "$BIN_SUM_BEFORE"
eq "fixture bundle id untouched" "$ORIG_ID" "$(plutil -extract CFBundleIdentifier raw -o - "$FIXTURE_APP/Info.plist")"

section "IPA contents"
mkdir "$WORK/ipa-x"
unzip -q "$IPA" -d "$WORK/ipa-x"
IPA_APP="$WORK/ipa-x/Payload/HeadunitPad.app"
check "Payload/HeadunitPad.app/HeadunitPad present" test -f "$IPA_APP/HeadunitPad"
check "IPA has only Payload at top level" test "$(ls "$WORK/ipa-x")" = "Payload"
assert_entitlements "IPA main binary" "$IPA_APP/HeadunitPad"
assert_all_machos_signed "IPA" "$IPA_APP"
eq "IPA keeps original bundle id" "$ORIG_ID" "$(plutil -extract CFBundleIdentifier raw -o - "$IPA_APP/Info.plist")"
check "frameworks carry no entitlements" test -z "$(ldid -e "$IPA_APP/Frameworks/OpenSSL.framework/OpenSSL" 2>/dev/null)"
check_not "stale _CodeSignature removed" test -e "$IPA_APP/Frameworks/OpenSSL.framework/_CodeSignature"

section "deb contents"
DEB_X="$WORK/deb-x"
mkdir "$DEB_X"
dpkg-deb -x "$DEB" "$DEB_X"
dpkg-deb -e "$DEB" "$DEB_X/DEBIAN"
LISTING="$(dpkg-deb -c "$DEB")"
contains "installs to ./Applications/HeadunitPad.app/" "$LISTING" "./Applications/HeadunitPad.app/"
check_not "nothing outside ./Applications" bash -c "dpkg-deb -c \"\$1\" | awk '{print \$6}' | grep -v '^\./\(Applications\(/.*\)\?\)\?\$'" _ "$DEB"
check "executable is 0755 root/root" bash -c "dpkg-deb -c \"\$1\" | grep -q '^-rwxr-xr-x root/root .* \./Applications/HeadunitPad.app/HeadunitPad\$'" _ "$DEB"
check "Info.plist is 0644" bash -c "dpkg-deb -c \"\$1\" | grep -q '^-rw-r--r-- root/root .* \./Applications/HeadunitPad.app/Info.plist\$'" _ "$DEB"
eq "Package"      "com.renner-c.headunitpad-ios14" "$(dpkg-deb -f "$DEB" Package)"
eq "Version"      "0.4.0~ios14.1" "$(dpkg-deb -f "$DEB" Version)"
eq "Architecture" "iphoneos-arm" "$(dpkg-deb -f "$DEB" Architecture)"
eq "Depends"      "firmware (>= 14.0)" "$(dpkg-deb -f "$DEB" Depends)"
for field in Name Section Maintainer Author Description; do
  check "control has $field" test -n "$(dpkg-deb -f "$DEB" "$field")"
done
contains "Maintainer is renner-c" "$(dpkg-deb -f "$DEB" Maintainer)" "renner-c"
for script in postinst postrm; do
  f="$DEB_X/DEBIAN/$script"
  check "$script exists" test -f "$f"
  eq "$script mode is 0755" "755" "$(stat -f '%Lp' "$f")"
  eq "$script shebang" "#!/bin/sh" "$(head -n1 "$f")"
  check "$script parses with sh -n" sh -n "$f"
  contains "$script calls uicache" "$(cat "$f")" "uicache"
  check "$script exits 0 when uicache is absent" env PATH=/usr/bin:/bin "$f" configure
done

DEB_APP="$DEB_X/Applications/HeadunitPad.app"
assert_entitlements "deb main binary" "$DEB_APP/HeadunitPad"
assert_all_machos_signed "deb" "$DEB_APP"
eq "deb bundle id is original + .jb" "${ORIG_ID}.jb" "$(plutil -extract CFBundleIdentifier raw -o - "$DEB_APP/Info.plist")"
eq "deb display name" "Headunit JB" "$(plutil -extract CFBundleDisplayName raw -o - "$DEB_APP/Info.plist")"
check "deb Info.plist lints" plutil -lint "$DEB_APP/Info.plist"

# --- 5. default gate passes on a minos-14.3 build ------------------------------
section "default gate passes at minos 14.3 (synthetic retarget of the fixture)"
RETARGET="$WORK/retarget/HeadunitPad.app"
mkdir "$WORK/retarget"
cp -R "$FIXTURE_APP" "$RETARGET"
retarget_ok=1
while IFS= read -r -d '' f; do
  is_macho "$f" || continue
  xcrun vtool -set-build-version 2 14.3 14.3 -replace -output "$f.new" "$f" >/dev/null 2>&1 || { retarget_ok=0; break; }
  cat "$f.new" >"$f"; rm -f "$f.new"
done < <(find "$RETARGET" -type f -print0)
if [[ $retarget_ok -eq 1 ]]; then
  plutil -replace MinimumOSVersion -string 14.0 "$RETARGET/Info.plist"
  OUT2="$WORK/out2"
  run_packager retarget "$OUT2" -- "$RETARGET" "$OUT2"
  if [[ $RC -ne 0 ]]; then bad "packager accepts minos 14.3 with default gate (rc=$RC)"; echo "$LOG" >&2; else ok "packager accepts minos 14.3 with default gate"; fi
  check "default version IPA exists" test -s "$OUT2/HeadunitPad-iOS14-TrollStore.ipa"
  check "default version is <short>~ios14.1" test -s "$OUT2/headunitpad-ios14_${ORIG_VERSION}~ios14.1_iphoneos-arm.deb"
else
  echo "  skip - xcrun vtool could not retarget the fixture"
fi

echo
echo "passed: $PASSES  failed: $FAILS"
[[ $FAILS -eq 0 ]]
