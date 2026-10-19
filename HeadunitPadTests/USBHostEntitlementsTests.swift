import XCTest
import Foundation

final class USBHostEntitlementsTests: XCTestCase {
    func testSummaryNamesEachAvailability() {
        XCTAssertEqual(USBHostEntitlements.Availability.present.summary, "Present")
        XCTAssertEqual(
            USBHostEntitlements.Availability.missing(["a", "b"]).summary,
            "Missing (a, b)"
        )
        XCTAssertEqual(
            USBHostEntitlements.Availability.unknown("no signature").summary,
            "Unknown (no signature)"
        )
    }

    func testPlistWithEveryRequiredKeyIsPresent() {
        let plist = makePlist([
            "com.apple.vm.device-access": true,
            "com.apple.security.exception.iokit-user-client-class": [
                "AppleUSBHostDeviceUserClient",
                "AppleUSBHostInterfaceUserClient",
            ],
            "com.apple.system.diagnostics.iokit-properties": true,
        ])

        XCTAssertEqual(USBHostEntitlements.availability(inEntitlementsPlist: plist), .present)
    }

    func testStrippedSideloadReportsEveryMissingKey() {
        // What an ordinary re-signed sideload keeps: nothing this feature needs.
        let plist = makePlist([
            "application-identifier": "ABCDE12345.andyching168.HeadunitPad",
            "get-task-allow": true,
        ])

        XCTAssertEqual(
            USBHostEntitlements.availability(inEntitlementsPlist: plist),
            .missing(USBHostEntitlements.requiredKeys)
        )
    }

    func testFalseAndEmptyValuesCountAsMissing() {
        let plist = makePlist([
            "com.apple.vm.device-access": false,
            "com.apple.security.exception.iokit-user-client-class": [String](),
            "com.apple.system.diagnostics.iokit-properties": true,
        ])

        XCTAssertEqual(
            USBHostEntitlements.availability(inEntitlementsPlist: plist),
            .missing([
                "com.apple.vm.device-access",
                "com.apple.security.exception.iokit-user-client-class",
            ])
        )
    }

    func testGarbageBlobIsUnknownRatherThanMissing() {
        // Unknown must never block the wired path; only a readable signature that
        // genuinely lacks the keys may.
        guard case .unknown = USBHostEntitlements.availability(
            inEntitlementsPlist: Data([0xFF, 0x00, 0xFF])
        ) else {
            return XCTFail("A malformed blob must not be reported as missing")
        }
    }

    func testReadsEntitlementsOutOfASignedMachO() throws {
        let plist = makePlist(["com.apple.vm.device-access": true,
                               "com.apple.security.exception.iokit-user-client-class": ["A"],
                               "com.apple.system.diagnostics.iokit-properties": true])
        let image = makeSignedMachO(entitlements: plist)

        XCTAssertEqual(USBHostEntitlements.availability(inMachO: image), .present)
    }

    func testUnsignedMachOIsUnknown() {
        let image = makeMachOHeader(commandCount: 0, commands: Data())

        guard case .unknown = USBHostEntitlements.availability(inMachO: image) else {
            return XCTFail("An unsigned image must not be reported as missing")
        }
    }

    func testTruncatedImageIsUnknown() {
        guard case .unknown = USBHostEntitlements.availability(inMachO: Data([0xCF, 0xFA])) else {
            return XCTFail("A truncated image must not be reported as missing")
        }
    }

    // MARK: - Fixtures

    private func makePlist(_ entries: [String: Any]) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: entries,
            format: .xml,
            options: 0
        )
    }

    private func makeMachOHeader(commandCount: UInt32, commands: Data) -> Data {
        var image = Data()
        image.appendLittleEndian(0xFEED_FACF) // MH_MAGIC_64
        image.appendLittleEndian(0x0100_000C) // cputype arm64
        image.appendLittleEndian(0)           // cpusubtype
        image.appendLittleEndian(2)           // filetype
        image.appendLittleEndian(commandCount)
        image.appendLittleEndian(UInt32(commands.count))
        image.appendLittleEndian(0)           // flags
        image.appendLittleEndian(0)           // reserved
        image.append(commands)
        return image
    }

    /// A minimal image carrying LC_CODE_SIGNATURE and an embedded superblob whose
    /// entitlements slot holds `entitlements`.
    private func makeSignedMachO(entitlements: Data) -> Data {
        var blob = Data()
        blob.appendBigEndian(0xFADE_7171) // CSMAGIC_EMBEDDED_ENTITLEMENTS
        blob.appendBigEndian(UInt32(8 + entitlements.count))
        blob.append(entitlements)

        // superblob: magic, length, count, then one (type, offset) index entry.
        let indexSize = 12 + 8
        var superBlob = Data()
        superBlob.appendBigEndian(0xFADE_0CC0) // CSMAGIC_EMBEDDED_SIGNATURE
        superBlob.appendBigEndian(UInt32(indexSize + blob.count))
        superBlob.appendBigEndian(1)
        superBlob.appendBigEndian(5) // CSSLOT_ENTITLEMENTS
        superBlob.appendBigEndian(UInt32(indexSize))
        superBlob.append(blob)

        var command = Data()
        command.appendLittleEndian(0x1D) // LC_CODE_SIGNATURE
        command.appendLittleEndian(16)
        let signatureOffset = 32 + 16
        command.appendLittleEndian(UInt32(signatureOffset))
        command.appendLittleEndian(UInt32(superBlob.count))

        var image = makeMachOHeader(commandCount: 1, commands: command)
        image.append(superBlob)
        return image
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
