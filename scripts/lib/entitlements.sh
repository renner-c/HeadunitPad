#!/bin/bash
# Shared entitlement verification for the HeadunitPad packaging scripts.
# Source this file; do not execute it.
#
#   verify_entitlements <entitlements.plist>
#
# Returns 0 when every USB Host entitlement HeadunitPad needs is present in the
# plist (typically the output of `ldid -e <binary>`), otherwise prints one error
# per missing/incorrect key to stderr and returns 1.

_ent_plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

verify_entitlements() {
  local plist="$1"
  local failed=0

  if [[ ! -s "$plist" ]]; then
    echo "error: entitlements plist is missing or empty: $plist" >&2
    return 1
  fi

  _ent_expect() {
    local key="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
      echo "error: $key is missing or not '$expected' (got '${actual:-<absent>}')" >&2
      failed=1
    fi
  }

  _ent_expect "com.apple.vm.device-access" "true" \
    "$(_ent_plist_get "$plist" 'com.apple.vm.device-access')"
  _ent_expect "com.apple.security.exception.iokit-user-client-class[0]" \
    "AppleUSBHostDeviceUserClient" \
    "$(_ent_plist_get "$plist" 'com.apple.security.exception.iokit-user-client-class:0')"
  _ent_expect "com.apple.security.exception.iokit-user-client-class[1]" \
    "AppleUSBHostInterfaceUserClient" \
    "$(_ent_plist_get "$plist" 'com.apple.security.exception.iokit-user-client-class:1')"
  _ent_expect "com.apple.system.diagnostics.iokit-properties" "true" \
    "$(_ent_plist_get "$plist" 'com.apple.system.diagnostics.iokit-properties')"
  _ent_expect "com.apple.private.iokit.IOServiceSetAuthorizationID" "true" \
    "$(_ent_plist_get "$plist" 'com.apple.private.iokit.IOServiceSetAuthorizationID')"

  unset -f _ent_expect
  return "$failed"
}
