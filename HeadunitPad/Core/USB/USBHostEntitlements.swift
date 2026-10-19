//
//  USBHostEntitlements.swift
//  HeadunitPad
//

import Foundation

/// Whether this install actually carries the USB Host entitlements.
///
/// Only a TrollStore install keeps them: an ordinary re-signed sideload has them
/// stripped, and the wired path then fails deep inside libusb with zero
/// enumerated devices, which reads as "no phone attached" and sends people
/// looking for a cable problem they do not have.
///
/// Read from the running binary's code signature rather than from the linker's
/// `__TEXT,__entitlements` section: the section survives re-signing, so it would
/// claim the entitlements are present on exactly the installs that lack them.
nonisolated enum USBHostEntitlements {
    enum Availability: Equatable {
        case present
        /// The signature was read and these required keys are not in it.
        case missing([String])
        /// Could not be determined. Never block the wired path on this.
        case unknown(String)

        /// One line for the diagnostics report and the launch log header.
        var summary: String {
            switch self {
            case .present:
                return "Present"
            case .missing(let keys):
                return "Missing (\(keys.joined(separator: ", ")))"
            case .unknown(let reason):
                return "Unknown (\(reason))"
            }
        }
    }

    static let requiredKeys = [
        "com.apple.vm.device-access",
        "com.apple.security.exception.iokit-user-client-class",
        "com.apple.system.diagnostics.iokit-properties",
    ]

    static func current() -> Availability {
        guard let executable = Bundle.main.executableURL else {
            return .unknown("The executable URL is unavailable")
        }
        guard let image = try? Data(contentsOf: executable, options: .mappedIfSafe) else {
            return .unknown("The executable could not be read")
        }
        return availability(inMachO: image)
    }

    static func availability(inMachO image: Data) -> Availability {
        switch entitlementsPlist(inMachO: image) {
        case .success(let plist):
            return availability(inEntitlementsPlist: plist)
        case .failure(let reason):
            return .unknown(reason)
        }
    }

    static func availability(inEntitlementsPlist plist: Data) -> Availability {
        guard let object = try? PropertyListSerialization.propertyList(
            from: plist,
            options: [],
            format: nil
        ), let entitlements = object as? [String: Any] else {
            return .unknown("The entitlements blob is not a property list")
        }

        let absent = requiredKeys.filter { key in
            guard let value = entitlements[key] else { return true }
            // A false boolean is as good as absent for the ones that gate access.
            if let flag = value as? Bool { return !flag }
            if let list = value as? [Any] { return list.isEmpty }
            return false
        }
        return absent.isEmpty ? .present : .missing(absent)
    }

    // MARK: - Mach-O

    private enum Magic {
        static let fat32: UInt32 = 0xCAFE_BABE
        static let fat64: UInt32 = 0xCAFE_BABF
        static let machO64: UInt32 = 0xFEED_FACF
        static let machO64Swapped: UInt32 = 0xCFFA_EDFE
        static let embeddedSignature: UInt32 = 0xFADE_0CC0
        static let embeddedEntitlements: UInt32 = 0xFADE_7171
        static let embeddedDEREntitlements: UInt32 = 0xFADE_7172
    }

    private static let loadCommandCodeSignature: UInt32 = 0x1D
    private static let slotEntitlements: UInt32 = 5
    private static let slotDEREntitlements: UInt32 = 7

    private enum Extraction {
        case success(Data)
        case failure(String)
    }

    private static func entitlementsPlist(inMachO image: Data) -> Extraction {
        guard let magic = image.readBigEndian(at: 0) else {
            return .failure("The executable is too small to be Mach-O")
        }

        if magic == Magic.fat32 || magic == Magic.fat64 {
            return entitlementsPlist(inFat: image, is64: magic == Magic.fat64)
        }
        return entitlementsPlist(inSlice: image, sliceStart: 0)
    }

    private static func entitlementsPlist(inFat image: Data, is64: Bool) -> Extraction {
        guard let count = image.readBigEndian(at: 4) else {
            return .failure("The universal binary header is truncated")
        }
        // cputype, cpusubtype, offset, size, align; 64-bit fat uses 8-byte fields.
        let entrySize = is64 ? 32 : 20
        let offsetField = is64 ? 8 : 8

        var lastFailure = "The universal binary contains no readable slice"
        for index in 0..<Int(count) {
            let entry = 8 + index * entrySize
            let sliceStart: Int
            if is64 {
                guard let high = image.readBigEndian(at: entry + offsetField),
                      let low = image.readBigEndian(at: entry + offsetField + 4) else { continue }
                sliceStart = Int(UInt64(high) << 32 | UInt64(low))
            } else {
                guard let offset = image.readBigEndian(at: entry + offsetField) else { continue }
                sliceStart = Int(offset)
            }
            switch entitlementsPlist(inSlice: image, sliceStart: sliceStart) {
            case .success(let plist):
                return .success(plist)
            case .failure(let reason):
                lastFailure = reason
            }
        }
        return .failure(lastFailure)
    }

    private static func entitlementsPlist(inSlice image: Data, sliceStart: Int) -> Extraction {
        guard let magic = image.readLittleEndian(at: sliceStart) else {
            return .failure("The Mach-O slice is truncated")
        }
        guard magic == Magic.machO64 || magic == Magic.machO64Swapped else {
            return .failure("Only 64-bit Mach-O images are supported")
        }
        guard let commandCount = image.readLittleEndian(at: sliceStart + 16) else {
            return .failure("The Mach-O header is truncated")
        }

        var cursor = sliceStart + 32 // past mach_header_64
        for _ in 0..<Int(commandCount) {
            guard let command = image.readLittleEndian(at: cursor),
                  let commandSize = image.readLittleEndian(at: cursor + 4),
                  commandSize >= 8 else {
                return .failure("A Mach-O load command is truncated")
            }
            if command == loadCommandCodeSignature {
                guard let dataOffset = image.readLittleEndian(at: cursor + 8) else {
                    return .failure("The code signature command is truncated")
                }
                return entitlementsPlist(
                    inSuperBlobAt: sliceStart + Int(dataOffset),
                    image: image
                )
            }
            cursor += Int(commandSize)
        }
        return .failure("The image is not signed")
    }

    private static func entitlementsPlist(inSuperBlobAt start: Int, image: Data) -> Extraction {
        guard let magic = image.readBigEndian(at: start),
              magic == Magic.embeddedSignature,
              let blobCount = image.readBigEndian(at: start + 8) else {
            return .failure("The code signature is not an embedded superblob")
        }

        var sawDEREntitlements = false
        for index in 0..<Int(blobCount) {
            let entry = start + 12 + index * 8
            guard let type = image.readBigEndian(at: entry),
                  let offset = image.readBigEndian(at: entry + 4) else {
                return .failure("The code signature blob index is truncated")
            }

            if type == slotDEREntitlements {
                sawDEREntitlements = true
                continue
            }
            guard type == slotEntitlements else { continue }

            let blob = start + Int(offset)
            guard let blobMagic = image.readBigEndian(at: blob),
                  blobMagic == Magic.embeddedEntitlements,
                  let length = image.readBigEndian(at: blob + 4),
                  length > 8 else {
                return .failure("The entitlements blob is malformed")
            }
            let payloadStart = blob + 8
            let payloadEnd = blob + Int(length)
            guard payloadEnd <= image.count, payloadStart < payloadEnd else {
                return .failure("The entitlements blob runs past the end of the image")
            }
            return .success(image.subdata(in: payloadStart..<payloadEnd))
        }

        if sawDEREntitlements {
            // DER-only signatures are readable, just not by this parser. Reporting
            // unknown keeps the wired path available instead of guessing.
            return .failure("Only DER entitlements are present")
        }
        return .failure("The signature carries no entitlements")
    }
}

private extension Data {
    func readBigEndian(at offset: Int) -> UInt32? {
        guard let value = readRaw(at: offset) else { return nil }
        return UInt32(bigEndian: value)
    }

    func readLittleEndian(at offset: Int) -> UInt32? {
        guard let value = readRaw(at: offset) else { return nil }
        return UInt32(littleEndian: value)
    }

    private func readRaw(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let start = index(startIndex, offsetBy: offset)
        return subdata(in: start..<index(start, offsetBy: 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
    }
}
