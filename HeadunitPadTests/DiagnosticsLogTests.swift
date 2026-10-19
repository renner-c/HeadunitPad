import XCTest
import Foundation
import USBHostKit

final class DiagnosticsLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(maxBytes: Int = DiagnosticsLog.defaultMaxBytes) -> DiagnosticsLog {
        DiagnosticsLog(directory: directory, maxBytes: maxBytes, mirrorToNSLog: false)
    }

    private func readLines(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Format

    func testAppendsTimestampCategoryMessageLines() throws {
        let log = makeLog()
        log.log("usb", "device found 18D1:4EE2")
        log.log("aap", "version response")
        log.flush()

        XCTAssertEqual(log.logURL.lastPathComponent, "HeadunitPad-diagnostics.log")
        let lines = try readLines(log.logURL)
        XCTAssertEqual(lines.count, 2)
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2}) \| (usb|aap) \| .+$"#
        for line in lines {
            XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), "bad line: \(line)")
        }
        XCTAssertTrue(lines[0].hasSuffix(" | usb | device found 18D1:4EE2"))
        XCTAssertTrue(lines[1].hasSuffix(" | aap | version response"))
    }

    func testAppendsToExistingFileAcrossInstances() throws {
        makeLog().log("a", "first")
        let second = makeLog()
        second.log("a", "second")
        second.flush()

        let lines = try readLines(second.logURL)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" | a | first"))
        XCTAssertTrue(lines[1].hasSuffix(" | a | second"))
    }

    func testMultilineMessageBecomesOneTimestampedLinePerLine() throws {
        let log = makeLog()
        log.log("usb", "registry:\nDevice A\r\nDevice B\n")
        log.flush()

        let lines = try readLines(log.logURL)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix(" | usb | registry:"))
        XCTAssertTrue(lines[1].hasSuffix(" | usb | Device A"))
        XCTAssertTrue(lines[2].hasSuffix(" | usb | Device B"))
    }

    func testCreatesMissingDirectory() throws {
        let nested = directory.appendingPathComponent("a/b", isDirectory: true)
        let log = DiagnosticsLog(directory: nested, mirrorToNSLog: false)
        log.log("x", "hello")
        log.flush()
        XCTAssertEqual(try readLines(log.logURL).count, 1)
    }

    // MARK: - Rotation

    func testRotatesToDotOneWhenThresholdWouldBeExceeded() throws {
        let log = makeLog(maxBytes: 600)
        for index in 0..<40 {
            log.log("rot", "line number \(index) with some padding text")
        }
        log.flush()

        let rotated = directory.appendingPathComponent("HeadunitPad-diagnostics.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let currentSize = try FileManager.default.attributesOfItem(atPath: log.logURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(currentSize, 0)
        XCTAssertLessThanOrEqual(currentSize, 600)

        // The newest line is always in the live file; nothing is split mid-line.
        let live = try readLines(log.logURL)
        XCTAssertTrue(live.last?.hasSuffix("line number 39 with some padding text") ?? false)
        for line in live + (try readLines(rotated)) {
            XCTAssertTrue(line.contains(" | rot | line number "), "torn line: \(line)")
        }
    }

    func testOnlyOneRotatedGenerationIsKept() throws {
        let log = makeLog(maxBytes: 300)
        for index in 0..<100 {
            log.log("rot", "line \(index) padding padding padding")
        }
        log.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["HeadunitPad-diagnostics.log", "HeadunitPad-diagnostics.log.1"])
    }

    func testRotationHappensAtTwoMegabytesByDefault() {
        XCTAssertEqual(DiagnosticsLog.defaultMaxBytes, 2 * 1024 * 1024)
    }

    // MARK: - Concurrency

    func testConcurrentAppendsNeverInterleaveLines() throws {
        let log = makeLog()
        let threads = 8
        let perThread = 200
        let payload = String(repeating: "x", count: 120)

        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for index in 0..<perThread {
                log.log("t\(thread)", "n=\(index) \(payload)")
            }
        }
        log.flush()

        let lines = try readLines(log.logURL)
        XCTAssertEqual(lines.count, threads * perThread)
        var seen = Set<String>()
        let pattern = #"^\S+ \| t(\d) \| n=(\d+) x{120}$"#
        let regex = try NSRegularExpression(pattern: pattern)
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else {
                XCTFail("interleaved or malformed line: \(line)")
                continue
            }
            let thread = (line as NSString).substring(with: match.range(at: 1))
            let index = (line as NSString).substring(with: match.range(at: 2))
            seen.insert("\(thread)-\(index)")
        }
        XCTAssertEqual(seen.count, threads * perThread)
    }

    // MARK: - Header

    private var sampleInfo: DiagnosticsLog.LaunchInfo {
        DiagnosticsLog.LaunchInfo(
            appVersion: "0.4.0",
            build: "7",
            bundleIdentifier: "andyching168.HeadunitPad.jb",
            executablePath: "/Applications/HeadunitPad.app/HeadunitPad",
            deviceModel: "iPad",
            systemName: "iPadOS",
            systemVersion: "14.3",
            machine: "iPad8,9",
            homeDirectory: "/var/mobile",
            logPath: "/var/mobile/Documents/HeadunitPad-diagnostics.log",
            usbEntitlements: "Present"
        )
    }

    func testHeaderLinesCarryEveryLaunchFact() {
        let text = DiagnosticsLog.headerLines(for: sampleInfo).joined(separator: "\n")
        XCTAssertTrue(text.contains("0.4.0"))
        XCTAssertTrue(text.contains("(7)"))
        XCTAssertTrue(text.contains("andyching168.HeadunitPad.jb"))
        XCTAssertTrue(text.contains("/Applications/HeadunitPad.app/HeadunitPad"))
        XCTAssertTrue(text.contains("iPad8,9"))
        XCTAssertTrue(text.contains("iPadOS 14.3"))
        XCTAssertTrue(text.contains("/var/mobile/Documents/HeadunitPad-diagnostics.log"))
        XCTAssertTrue(text.contains("USB host entitlements: Present"))
    }

    func testWriteLaunchHeaderLogsUnderLaunchCategory() throws {
        let log = makeLog()
        log.writeLaunchHeader(sampleInfo)
        log.flush()

        let lines = try readLines(log.logURL)
        XCTAssertGreaterThanOrEqual(lines.count, 6)
        XCTAssertTrue(lines.allSatisfy { $0.contains(" | launch | ") })
    }

    @MainActor
    func testCurrentLaunchInfoReadsRealDeviceAndBundle() {
        let info = DiagnosticsLog.currentLaunchInfo(usbEntitlements: "Unknown (test)", logPath: directory.path)
        XCTAssertFalse(info.deviceModel.isEmpty)
        XCTAssertFalse(info.systemVersion.isEmpty)
        XCTAssertFalse(info.machine.isEmpty)
        XCTAssertFalse(info.bundleIdentifier.isEmpty)
        XCTAssertEqual(info.usbEntitlements, "Unknown (test)")
    }

    // MARK: - Error description

    func testDescribeNamesLibusbErrorsAndCodes() {
        let text = DiagnosticsLog.describe(USBHostError.underlyingLibusb(-9))
        XCTAssertTrue(text.contains("LIBUSB_ERROR_PIPE"), text)
        XCTAssertTrue(text.contains("-9"), text)
    }

    func testDescribeShowsIOReturnInHex() {
        let error = NSError(domain: NSMachErrorDomain, code: Int(bitPattern: 0xE00002C5), userInfo: nil)
        XCTAssertTrue(DiagnosticsLog.describe(error).contains("0xE00002C5"))
    }

    func testDescribeShowsPOSIXErrno() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED), userInfo: nil)
        let text = DiagnosticsLog.describe(error)
        XCTAssertTrue(text.contains("errno 61"), text)
    }

    func testDescribeIncludesLocalizedDescription() {
        let text = DiagnosticsLog.describe(AOAError.noUSBDevices)
        XCTAssertTrue(text.contains("No USB device was found"), text)
    }
}
