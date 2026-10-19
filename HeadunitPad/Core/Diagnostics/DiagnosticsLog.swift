//
//  DiagnosticsLog.swift
//  HeadunitPad
//
//  Persistent, timestamped connection trail for runs without a debugger.
//  Appends `ISO8601 timestamp | category | message` lines to
//  <Documents>/HeadunitPad-diagnostics.log, rotating to `.1` at ~2 MB.
//

import Foundation
import Network
import UIKit
import USBHostKit

/// Safe to call from any thread or actor: every write is serialised on a private
/// queue and reaches the file (and fsync) before the next line starts.
nonisolated final class DiagnosticsLog: @unchecked Sendable {
    static let fileName = "HeadunitPad-diagnostics.log"
    static let rotatedFileName = "HeadunitPad-diagnostics.log.1"
    static let defaultMaxBytes = 2 * 1024 * 1024

    static let shared = DiagnosticsLog(directory: defaultDirectory())

    /// `Documents` of the running app. For an install without a data container
    /// (a /Applications jailbreak install) this resolves under the mobile home.
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    let logURL: URL
    let rotatedURL: URL

    private let maxBytes: Int
    private let mirrorToNSLog: Bool
    private let queue = DispatchQueue(label: "com.headunitpad.diagnostics-log", qos: .utility)
    private let formatter = ISO8601DateFormatter()
    private var descriptor: Int32 = -1
    private var size = 0

    init(directory: URL, maxBytes: Int = DiagnosticsLog.defaultMaxBytes, mirrorToNSLog: Bool = true) {
        logURL = directory.appendingPathComponent(Self.fileName)
        rotatedURL = directory.appendingPathComponent(Self.rotatedFileName)
        self.maxBytes = maxBytes
        self.mirrorToNSLog = mirrorToNSLog
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Queues one entry. A multi-line message becomes one timestamped line per
    /// line, so every line in the file stands alone.
    func log(_ category: String, _ message: String) {
        let date = Date()
        queue.async { self.append(date: date, category: category, message: message) }
    }

    /// Blocks until everything queued so far is on disk.
    func flush() {
        queue.sync {}
    }

    // MARK: - Writing (queue only)

    private func append(date: Date, category: String, message: String) {
        formatter.timeZone = .current
        let stamp = formatter.string(from: date)
        let category = category.replacingOccurrences(of: "\n", with: " ")
        let normalized = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.isEmpty { lines = [""] }

        var block = ""
        for line in lines {
            block += "\(stamp) | \(category) | \(line)\n"
        }
        write(Array(block.utf8))

        if mirrorToNSLog {
            for line in lines {
                NSLog("[HeadunitPad] %@ | %@", category, line)
            }
        }
    }

    private func write(_ bytes: [UInt8]) {
        openIfNeeded()
        if size > 0, size + bytes.count > maxBytes {
            rotate()
        }
        guard descriptor >= 0 else { return }

        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                break
            }
            offset += written
        }
        size += offset
        fsync(descriptor)
    }

    private func openIfNeeded() {
        guard descriptor < 0 else { return }
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if descriptor >= 0 {
            size = Int(max(lseek(descriptor, 0, SEEK_END), 0))
        }
    }

    private func rotate() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: logURL, to: rotatedURL)
        size = 0
        openIfNeeded()
    }
}

// MARK: - Launch header

nonisolated extension DiagnosticsLog {
    nonisolated struct LaunchInfo: Equatable, Sendable {
        let appVersion: String
        let build: String
        let bundleIdentifier: String
        let executablePath: String
        let deviceModel: String
        let systemName: String
        let systemVersion: String
        let machine: String
        let homeDirectory: String
        let logPath: String
        let usbEntitlements: String
    }

    @MainActor
    static func currentLaunchInfo(usbEntitlements: String, logPath: String) -> LaunchInfo {
        let bundle = Bundle.main
        let device = UIDevice.current
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return LaunchInfo(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            bundleIdentifier: bundle.bundleIdentifier ?? "?",
            executablePath: bundle.executablePath ?? "?",
            deviceModel: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            machine: machine,
            homeDirectory: NSHomeDirectory(),
            logPath: logPath,
            usbEntitlements: usbEntitlements
        )
    }

    static func headerLines(for info: LaunchInfo) -> [String] {
        [
            "==== HeadunitPad launch ====",
            "App: \(info.appVersion) (\(info.build)), bundle id \(info.bundleIdentifier)",
            "Device: \(info.deviceModel) (\(info.machine)), \(info.systemName) \(info.systemVersion)",
            "Executable: \(info.executablePath)",
            "Home: \(info.homeDirectory)",
            "Log file: \(info.logPath)",
            "USB host entitlements: \(info.usbEntitlements)",
        ]
    }

    func writeLaunchHeader(_ info: LaunchInfo) {
        for line in Self.headerLines(for: info) {
            log("launch", line)
        }
    }
}

// MARK: - Error description

nonisolated extension DiagnosticsLog {
    /// One line with everything that helps a remote reader: the Swift case, the
    /// localized text, and the numeric code in the form the platform documents
    /// (libusb name, IOReturn hex, errno text).
    static func describe(_ error: Error) -> String {
        var parts = ["\(type(of: error)).\(String(describing: error))"]

        let localized = error.localizedDescription
        if !localized.isEmpty, !parts[0].contains(localized) {
            parts.append("\"\(localized)\"")
        }

        if let usb = error as? USBHostError {
            switch usb {
            case .underlyingLibusb(let code):
                parts.append("libusb \(code) \(libusbName(code))")
            case .permission:
                parts.append("libusb \(libusbName(-3))")
            case .disconnected:
                parts.append("libusb \(libusbName(-4))/\(libusbName(-5))")
            case .interfaceUnavailable:
                parts.append("libusb \(libusbName(-6))")
            case .timeout:
                parts.append("libusb \(libusbName(-7))")
            case .cancelled:
                parts.append("libusb \(libusbName(-10))")
            case .notStarted, .unknown:
                break
            }
        }

        if let network = error as? NWError {
            switch network {
            case .posix(let code):
                parts.append("errno \(code.rawValue) (\(posixText(code.rawValue)))")
            case .dns(let code):
                parts.append("dns error \(code)")
            case .tls(let status):
                parts.append("tls OSStatus \(status)")
            @unknown default:
                break
            }
        }

        if type(of: error) is NSError.Type {
            let nsError = error as NSError
            parts.append("domain=\(nsError.domain) code=\(nsError.code)")
            switch nsError.domain {
            case NSMachErrorDomain:
                parts.append("IOReturn \(hex32(nsError.code))")
            case NSOSStatusErrorDomain:
                parts.append("OSStatus \(nsError.code) \(hex32(nsError.code))")
            case NSPOSIXErrorDomain:
                parts.append("errno \(nsError.code) (\(posixText(Int32(truncatingIfNeeded: nsError.code))))")
            default:
                break
            }
        }

        return parts.joined(separator: " | ")
    }

    static func libusbName(_ code: Int32) -> String {
        switch code {
        case 0: return "LIBUSB_SUCCESS"
        case -1: return "LIBUSB_ERROR_IO"
        case -2: return "LIBUSB_ERROR_INVALID_PARAM"
        case -3: return "LIBUSB_ERROR_ACCESS"
        case -4: return "LIBUSB_ERROR_NO_DEVICE"
        case -5: return "LIBUSB_ERROR_NOT_FOUND"
        case -6: return "LIBUSB_ERROR_BUSY"
        case -7: return "LIBUSB_ERROR_TIMEOUT"
        case -8: return "LIBUSB_ERROR_OVERFLOW"
        case -9: return "LIBUSB_ERROR_PIPE"
        case -10: return "LIBUSB_ERROR_INTERRUPTED"
        case -11: return "LIBUSB_ERROR_NO_MEM"
        case -12: return "LIBUSB_ERROR_NOT_SUPPORTED"
        case -99: return "LIBUSB_ERROR_OTHER"
        default: return "LIBUSB_ERROR_UNKNOWN"
        }
    }

    private static func hex32(_ code: Int) -> String {
        String(format: "0x%08X", UInt32(truncatingIfNeeded: code))
    }

    private static func posixText(_ code: Int32) -> String {
        strerror(code).map { String(cString: $0) } ?? "unknown"
    }
}
