# iPadOS 14.3 test checklist

Do these in order on the iPad. Note anything that fails and keep going. Install steps are in
[INSTALL-iOS14.md](INSTALL-iOS14.md).

## 0. Record the environment (SSH)

```sh
cat /System/Library/CoreServices/SystemVersion.plist
uname -a
dpkg -l | grep -iE 'taurine|libhooker|trollstore|appsync'
```

## 1. Install

1. Install the .deb ("Headunit JB") and the TrollStore IPA ("HeadunitPad") per the install doc.
2. Check entitlements on both copies with `ldid -e` (paths are in the install doc). Expect four keys,
   including `com.apple.private.iokit.IOServiceSetAuthorizationID`.

## 2. Launch each copy

Open each app once. If one crashes at launch, grab the crash report and send it:
Settings, Privacy, Analytics & Improvements, Analytics Data, `HeadunitPad*.ips`
(or `/var/mobile/Library/Logs/CrashReporter/`).

## 3. Wireless test

1. Phone hotspot on; iPad joins it.
2. Phone: Android Auto settings, tap "Version" 10 times, overflow menu, "Start head unit server".
3. HeadunitPad: "Wireless: Scan for Devices" (or "Wireless: Enter IP Manually" with the hotspot gateway IP).
4. Allow the Local Network prompt (Settings, Privacy, Local Network).

Expected, check each: video appears, touch works, audio plays, mic/voice works, GPS works.

## 4. Wired test

Run it with the TrollStore copy first, then with the Headunit JB copy (do not run both at once).
Plug the phone into the iPad with a USB-C data cable, tap "Wired: Connect via USB", and accept any
prompts on the phone. Note what the status text and the result alert say.

## 5. Collect the diagnostics log

- TrollStore copy: Files, On My iPad, HeadunitPad, `HeadunitPad-diagnostics.log`. Or tap
  "Share Log File" in the Diagnostics alert or the wired-failure alert.
- Headunit JB copy: the log path is printed at the top of the log and in the Diagnostics alert
  (expected `/var/mobile/Documents/HeadunitPad-diagnostics.log`). Read it over SSH or in Filza.

The log rotates to `HeadunitPad-diagnostics.log.1` at about 2 MB; send both if present.

## 6. What to send back

- The log file(s) and any crash reports.
- Which step failed, and which copy (TrollStore or Headunit JB).
- Phone model, Android version, Android Auto version.

## Wired failure triage

Look in the log for `usb` lines and the `report` block written when the wired attempt ends.

| Log shows | Meaning | Next step |
|---|---|---|
| "0 USB devices enumerated", or no IOUSBHostDevice in the IORegistry USB devices summary | The iPad sees no phone: cable, USB role, or enumeration problem | Try a data-capable cable, replug, unlock the phone, set the phone's USB mode to file transfer. Try a powered hub. |
| "Wired USB Needs TrollStore" alert, or `kIOReturnNotPermitted` / `0xe00002e2` | Signature or entitlements not honored | Re-check `ldid -e`; try the other install method. |
| No "GET_PROTOCOL returned version" line, or START fails | Phone side refused or ignored the accessory request | Unlock the phone, try another cable, retry. |
| "polling for an accessory device (VID 18D1, PID 2D00-2D05)" and no accessory ever found | Phone never re-enumerated as an accessory (0x18D1:0x2D00/0x2D01) | Replug and retry; send the log. |
| "interface N claim FAILED" with `kIOReturnExclusiveAccess` / `0xe00002c5` | An iOS driver owns the interface | Send the log; this needs a code change. |
| "interface N claimed" and "bulk read loop started", but no first bulk read, or "TLS handshake completed" never appears | USB link works; the problem is in the Android Auto protocol (AAP) | Send the log; the `aap` lines show how far the handshake got. |
