# Installing HeadunitPad on iPadOS 14.3 (jailbroken, Taurine)

CI (or `scripts/package_ios14.sh`) produces two artifacts from the same build:

| Artifact | Bundle id | Home screen name | Install path |
|---|---|---|---|
| `HeadunitPad-iOS14-TrollStore.ipa` | original (`andyching168.HeadunitPad`) | HeadunitPad | TrollStore ("official" path) |
| `headunitpad-ios14_<version>_iphoneos-arm.deb` | original + `.jb` | Headunit JB | `/Applications` (jailbreak path) |

Both carry the same USB Host entitlements and can be installed side by side for A/B testing.
Avoid running both at once (they would compete for the same USB device).

## A. Rootful .deb (Taurine)

Over SSH (OpenSSH installed from Sileo; default user `root`, check your own password):

```sh
scp headunitpad-ios14_*_iphoneos-arm.deb root@<ipad-ip>:/var/mobile/Documents/
ssh root@<ipad-ip>
dpkg -i /var/mobile/Documents/headunitpad-ios14_*_iphoneos-arm.deb
uicache -p /Applications/HeadunitPad.app    # the postinst already does this; rerun if the icon is missing
```

Without SSH: put the .deb in Filza and tap it, then Install; or in Sileo use
Sources > Packages > "Open in Sileo" / Settings > Local packages. Respring if the icon does not appear.

## B. TrollStore IPA

1. On iOS 14.x install TrollStore through TrollHelper (Havoc "TrollHelper" package).
2. Open TrollHelper, tap **Install TrollStore**, then open the new TrollStore app.
3. Get the IPA onto the iPad (AirDrop, Filza, `scp`), then share/open it with TrollStore and tap Install.
   TrollStore keeps the embedded entitlements; no re-signing is needed.

## Verify entitlements on the device

```sh
# deb copy
ldid -e /Applications/HeadunitPad.app/HeadunitPad
# TrollStore copy
ldid -e /var/containers/Bundle/Application/*/HeadunitPad.app/HeadunitPad
```

Expect four keys: `com.apple.vm.device-access`, `com.apple.security.exception.iokit-user-client-class`
(`AppleUSBHostDeviceUserClient`, `AppleUSBHostInterfaceUserClient`),
`com.apple.system.diagnostics.iokit-properties`, `com.apple.private.iokit.IOServiceSetAuthorizationID`.
If `ldid` is missing: `apt install ldid`.

## Uninstall

- deb copy: `dpkg -r com.renner-c.headunitpad-ios14` (then `uicache -a` if the icon lingers), or remove it in Sileo.
- TrollStore copy: open TrollStore, swipe the app left in the list, tap Uninstall (or long-press its icon).

## Build the artifacts yourself

```sh
brew install ldid dpkg
# input: unsigned Release-iphoneos HeadunitPad.app, minos <= 14.3
scripts/package_ios14.sh path/to/HeadunitPad.app out/ [version]
scripts/tests/test_package_ios14.sh   # needs gh (downloads the upstream IPA as a fixture)
```

The script fails if any Mach-O (or `MinimumOSVersion`) is above 14.3; override with `MAX_MINOS=...` only for testing.
