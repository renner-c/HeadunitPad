## iPadOS 14 port (this fork)

This fork runs HeadunitPad on a jailbroken iPadOS 14.3 iPad. The target device is an iPad Pro 12.9" (3rd gen, A12X) with the Taurine jailbreak and TrollStore. Upstream requires iOS 16.6, so it cannot be installed on that iPad.

**Status.** The app builds and passes all CI checks. It has not been run on a real iOS 14.3 device yet. Wired USB on 14.3 is unproven; the main evidence it can work is that UTM's USB passthrough on jailbroken iOS 14 used the same IOKit user clients.

**Downloads.** Get the latest prerelease (tags `ios14-v*`) from this fork's Releases page:
- `HeadunitPad-iOS14-TrollStore.ipa` for TrollStore.
- `headunitpad-ios14_<ver>_iphoneos-arm.deb` for a rootful jailbreak. It installs as "Headunit JB" with bundle id suffix `.jb`, so it can sit next to the TrollStore copy.

See [docs/INSTALL-iOS14.md](docs/INSTALL-iOS14.md) to install and [docs/TESTING-iOS14.md](docs/TESTING-iOS14.md) for the test checklist.

### Car setup, wireless (try this first)
1. Turn on the phone's hotspot and join it from the iPad.
2. On the phone: Android Auto settings, tap "Version" 10 times to unlock developer settings, overflow menu, "Start head unit server".
3. In HeadunitPad tap "Wireless: Scan for Devices", or "Wireless: Enter IP Manually" with the phone's hotspot gateway IP.
4. Allow the Local Network prompt (Settings, Privacy, Local Network).

The app connects to the phone on TCP 5277. Android Auto 17.4+ removed the old "Wireless Helper" trigger path, so use the head unit server. Car-style wireless Android Auto (Bluetooth plus Wi-Fi handoff) is not possible on an iPad.

### Car setup, wired
Connect a USB-C data cable between phone and iPad. The iPad acts as USB host and powers the phone, so expect battery drain; a USB-C PD hub may help (untested). Wired needs the USB entitlements, so use the TrollStore IPA or the .deb.

### What changed vs upstream
- Deployment target is 14.3.
- Built with Xcode 26; the Swift 5.5 concurrency back-deploy library is embedded.
- `UIButton.Configuration` replaced by `HeadunitButton`.
- iOS 16 orientation and NowPlaying APIs are guarded, with iOS 14 fallbacks.
- SF Symbol fallback for an icon that exists only on iOS 15+.
- TrollUSBHostKit vendored with an iOS 14 floor and a NULL-deref fix (`kIOMainPortDefault`).
- Extra entitlement `com.apple.private.iokit.IOServiceSetAuthorizationID`.
- Persistent diagnostics log (`HeadunitPad-diagnostics.log`).
- CI: iOS 14.3 dyld import checker against iPhoneOS14.3.sdk stubs, SF Symbols availability check, unit tests, IPA and rootful .deb packaging, tag-triggered prerelease.

### Known limitations
- The orientation lock may be ignored on iPadOS < 16 because the app supports multitasking. Use the Control Center rotation lock in the car.
- Everything under Status: untested on real hardware, wired USB unproven.

---

*Upstream README follows.*

---

# HeadunitPad

**Transform your iPad into an Android Auto display screen.**

> This project enables iPads (especially iPad mini 6) to act as a Headunit display/host for Android Auto, over a USB cable or wirelessly.

> **Wired USB requires a TrollStore install.** It needs USB Host entitlements that an ordinary re-signed sideload cannot keep. Wireless works on any install.

## Features

### Core Functionality
- **Wired USB Connection** *(TrollStore only)* - Talks to the phone directly over the cable using Android Open Accessory, with no Android Auto Server, no WiFi, and no helper app
- **Wireless Connection** - Connects to Android Auto Server via WiFi (TCP port 5277)
- **Video Streaming** - Receives and renders H.264 video frames from Android Auto
- **Audio Playback** - PCM audio output via AVAudioEngine
- **Touch Input** - Sends touch events back to Android Auto
- **Microphone Support** - Captures and streams microphone input
- **GPS Location** - Shares iPad or phone GPS location with Android Auto

### Settings
- **Orientation** - Landscape or Portrait mode (Portrait has known issues)
- **Resolution** - Configurable video resolution
- **FPS** - 30 or 60 fps options
- **DPI** - Custom DPI adjustment
- **GPS Source** - Use iPad GPS or phone GPS

## How It Works

### Connection Flow

Two transports, one protocol. Both feed the same AAP session, so video, audio,
touch, microphone, and GPS behave identically once connected.

**Wired (USB)** — the iPad is the USB host:

```
┌─────────────┐   USB-C cable   ┌─────────────────┐
│    iPad     │ ◄─────────────► │  Android Phone  │
│   (host)    │                 │   (accessory)   │
└──────┬──────┘                 └────────┬────────┘
       │  1. AOA negotiation (GET_PROTOCOL, identity, START)
       │  2. Phone re-enumerates as 0x18D1:0x2D01
       │  3. Claim the accessory interface, bulk IN/OUT
       │  4. Same AAP handshake as below, over the bulk pipe
       ▼                                 ▼
```

**Wireless (WiFi)**:

```
┌─────────────┐         WiFi          ┌─────────────────┐
│   iPad      │ ◄──────────────────► │ Android Phone   │
│  (Client)   │                     │  (Server)       │
│             │   Port 5277/TCP      │                 │
└──────┬──────┘                     └────────┬────────┘
       │                                       │
       │  1. TCP Connection                    │
       │  2. Version Request/Response          │
       │  3. TLS Handshake (wrapped in AAP)    │
       │  4. Status OK                         │
       │  5. BINDING_RESPONSE                  │
       │  6. Running (encrypted AAP messages)  │
       ▼                                       ▼
┌─────────────────────────────────────────────────────┐
│                   iPad Display                       │
│  • Renders H.264 video frames                        │
│  • Sends touch events to phone                      │
│  • Plays audio from phone                           │
│  • Provides microphone and GPS data                  │
└─────────────────────────────────────────────────────┘
```

### Protocol Details

The Android Auto Protocol (AAP) uses:
- **Channel 0** - Control messages (handshake, binding)
- **Channel 1** - Sensor data
- **Channel 2** - Video stream (H.264)
- **Channel 3** - Input (touch, key events)
- **Channel 4/5** - Audio streams
- **Channel 6** - Primary audio
- **Channel 7** - Microphone

TLS is encapsulated inside AAP messages (Channel 0, Type 3), not at the socket layer.

## Known Issues
Well, You told me

## Requirements

- **iPad** (iPad mini 6 recommended for best performance)
- **iOS/iPadOS 16.6+**
- **Android phone** with Android Auto

For **wired USB**:

- **TrollStore**, to install the IPA with its USB Host entitlements intact
- A **USB-C data cable** (charge-only cables do not enumerate)
- A **USB-C iPad**; the iPad acts as USB host, so the phone appears as an accessory

For **wireless**:

- **Android Auto Server** from the phone's developer options, or Headunit Revived's Wireless Helper
- **WiFi network** (both devices on the same network)

## Installation

### TrollStore (required for wired USB)

1. Download `HeadunitPad.ipa` from the [latest release](https://github.com/andyching168/HeadunitPad/releases/latest)
2. Open it with TrollStore and install

The wired path needs three entitlements that only a TrollStore install keeps:
`com.apple.vm.device-access`, the `AppleUSBHostDeviceUserClient` /
`AppleUSBHostInterfaceUserClient` IOKit user-client exceptions, and
`com.apple.system.diagnostics.iokit-properties`. The app reads its own code
signature at launch, so on an install without them the wired button says so
instead of failing with a misleading "no USB device found".

To build the IPA yourself:

```bash
scripts/build_trollstore_ipa.sh
```

It builds unsigned, applies the entitlements with `ldid`, and refuses to produce
an IPA whose packaged executable lost any of them.

### Sideloading (wireless only)

1. Clone this repository
2. Open `iPadOS/HeadunitPad/HeadunitPad.xcworkspace` in Xcode
3. Configure your development team in Signing & Capabilities
4. Build and run on your iPad

Re-signing strips the USB Host entitlements, so the wired button will tell you
it needs TrollStore. Everything wireless works normally.

### Dependencies

- [OpenSSL-Universal](https://github.com/krzyzanowskim/OpenSSL) via CocoaPods
- [Socket.io](https://github.com/mikezellers/SocketIO-Android-Swift) (not currently used, for future WiFi Direct)
- [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) (not currently used)

## Architecture

```
iPadOS/HeadunitPad/HeadunitPad/
├── Core/
│   ├── AAP/
│   │   ├── AapTransport.swift      # Main transport layer with TLS
│   │   ├── AapMessage.swift        # Message framing
│   │   └── Protocol/Channel.swift   # Channel definitions
│   ├── Network/
│   │   ├── TcpHandler.swift        # TCP connection management
│   │   ├── OpenSslTlsHandler.swift # OpenSSL TLS implementation
│   │   ├── Discovery.swift          # Network device discovery
│   │   └── ConnectionManager.swift  # Connection lifecycle
│   ├── Audio/
│   │   ├── PCMAudioPlayer.swift     # PCM audio playback
│   │   └── MicrophoneCapture.swift  # Microphone input
│   ├── Video/
│   │   └── H264VideoRendererView.swift # Video rendering
│   └── Location/
│       └── LocationCapture.swift     # GPS location
└── Resources/Raw/
    ├── cert                          # Client certificate
    └── privkey                       # Private key
```

## Disclaimer

This project is for educational and personal use only. Android Auto is a trademark of Google LLC. This project is not affiliated with or endorsed by Google.

## Acknowledgments

### Special Thanks

- **Andre Knieriem** - Developer of [Headunit Revived](https://github.com/andreknieriem/headunit-revived), the Android Auto Server application that makes this project possible

### Inspiration

- **Mike Reid** - Original [Headunit](https://github.com/mikereidis/headunit) developer. His pioneering work on the Android Auto protocol laid the foundation for all subsequent projects in this space. Mike passed away; his contributions to the open-source community will be remembered.

### Open Source Libraries

- [OpenSSL](https://www.openssl.org/) - Cryptography toolkit
- [VideoToolbox](https://developer.apple.com/documentation/videotoolbox) - Apple's hardware-accelerated video decoding

## License

AGPL-v3 - See LICENSE file for details.

---

**If you find this project useful, consider supporting the developers of Headunit Revived who make this ecosystem possible.**
