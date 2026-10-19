# Vendored TrollUSBHostKit

Source: https://github.com/andyching168/TrollUSBHostKit, tag `v0.1.3`
(commit `ecfd7fbc59ec340509d568da2400d7f0d94a892e`), MIT licensed.

Vendored as a local Swift package so the iPadOS 14.3 port can change it in the
same commit as the app. Local changes:

- `Package.swift`: platform floor `.iOS(.v16)` lowered to `.iOS(.v14)`.
- `CUSBShim/usbhost_shim.c`: `uhs_usb_registry_summary` passes `MACH_PORT_NULL`
  instead of `kIOMainPortDefault` (iOS 15+ data symbol, weak-linked NULL on 14).
- `Package.swift`: C targets build with `-Werror=unguarded-availability-new` so
  newer-than-iOS-14 APIs fail the build instead of weak-linking to NULL.
