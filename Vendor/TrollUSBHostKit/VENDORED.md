# Vendored TrollUSBHostKit

Source: https://github.com/andyching168/TrollUSBHostKit, tag `v0.1.3`
(commit `ecfd7fbc59ec340509d568da2400d7f0d94a892e`), MIT licensed.

Vendored as a local Swift package so the iPadOS 14.3 port can change it in the
same commit as the app. Local changes:

- `Package.swift`: platform floor `.iOS(.v16)` lowered to `.iOS(.v14)`.
