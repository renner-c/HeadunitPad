import Foundation
import USBHostKit

nonisolated struct AOAIdentity: Equatable, Sendable {
    let manufacturer: String
    let model: String
    let description: String
    let version: String
    let uri: String
    let serial: String

    static let androidAuto = AOAIdentity(
        manufacturer: "Android",
        model: "Android Auto",
        description: "Android Auto",
        version: "2.0.1",
        uri: "https://developer.android.com/auto/index.html",
        serial: "HU-AAAAAA001"
    )
}

nonisolated enum AOAStringIndex: UInt16, CaseIterable, Sendable {
    case manufacturer = 0
    case model = 1
    case description = 2
    case version = 3
    case uri = 4
    case serial = 5
}

nonisolated struct AOAControlRequest: Equatable, Sendable {
    let requestType: UInt8
    let request: UInt8
    let value: UInt16
    let index: UInt16
    let buffer: Data
}

nonisolated enum AOAError: Error, Equatable, Sendable {
    case invalidProtocolResponseLength(Int)
    case unsupportedProtocolVersion(UInt16)
    case noUSBDevices
    case noAOACapableDevice
    case deviceDetachedDuringNegotiation
    case accessoryReenumerationTimedOut
    case accessorySessionUnavailable
}

extension AOAError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidProtocolResponseLength(let length):
            return "Android returned an invalid AOA protocol response (\(length) bytes)."
        case .unsupportedProtocolVersion(let version):
            return "The connected device reported unsupported AOA protocol version \(version)."
        case .noUSBDevices:
            return "No USB device was found. Connect and unlock the Android phone, then try again."
        case .noAOACapableDevice:
            return "No connected USB device accepted the Android Open Accessory request."
        case .deviceDetachedDuringNegotiation:
            return "The USB device detached before the accessory START request completed."
        case .accessoryReenumerationTimedOut:
            return "Timed out waiting for the phone to reconnect in Android accessory mode."
        case .accessorySessionUnavailable:
            return "The Android accessory device could not be opened for USB bulk transfers."
        }
    }
}

nonisolated enum AOANegotiationStage: Equatable, Sendable {
    case protocolVersion(UInt16)
    case sendingIdentity
    case startingAccessory
    case startCompleted
    case startDetached
}

nonisolated enum AOANegotiationSequence {
    static let getProtocolRequest = AOAControlRequest(
        requestType: 0xC0,
        request: 51,
        value: 0,
        index: 0,
        buffer: Data(count: 2)
    )

    static let startRequest = AOAControlRequest(
        requestType: 0x40,
        request: 53,
        value: 0,
        index: 0,
        buffer: Data()
    )

    static func requests(for identity: AOAIdentity) -> [AOAControlRequest] {
        [getProtocolRequest] + identityRequests(for: identity) + [startRequest]
    }

    static func identityRequests(for identity: AOAIdentity) -> [AOAControlRequest] {
        let strings: [(AOAStringIndex, String)] = [
            (.manufacturer, identity.manufacturer),
            (.model, identity.model),
            (.description, identity.description),
            (.version, identity.version),
            (.uri, identity.uri),
            (.serial, identity.serial),
        ]

        return strings.map { index, value in
            AOAControlRequest(
                requestType: 0x40,
                request: 52,
                value: 0,
                index: index.rawValue,
                buffer: Data(value.utf8) + Data([0])
            )
        }
    }

    static func parseProtocolVersion(from data: Data) throws -> UInt16 {
        guard data.count == 2 else {
            throw AOAError.invalidProtocolResponseLength(data.count)
        }
        return UInt16(data[data.startIndex]) | (UInt16(data[data.index(after: data.startIndex)]) << 8)
    }
}

nonisolated protocol AOAControlTransferring: Sendable {
    func controlTransfer(
        requestType: UInt8,
        request: UInt8,
        value: UInt16,
        index: UInt16,
        buffer: Data,
        timeoutMilliseconds: UInt32
    ) async throws -> Data
}

extension USBDeviceSession: AOAControlTransferring {}

nonisolated struct AOANegotiator: Sendable {
    let transfer: any AOAControlTransferring
    let onStage: (@Sendable (AOANegotiationStage) async -> Void)?

    init(
        transfer: any AOAControlTransferring,
        onStage: (@Sendable (AOANegotiationStage) async -> Void)? = nil
    ) {
        self.transfer = transfer
        self.onStage = onStage
    }

    func negotiate(
        identity: AOAIdentity,
        timeoutMilliseconds: UInt32 = 1_000
    ) async throws -> UInt16 {
        let protocolData = try await perform(
            AOANegotiationSequence.getProtocolRequest,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let protocolVersion = try AOANegotiationSequence.parseProtocolVersion(from: protocolData)
        guard protocolVersion > 0 else {
            throw AOAError.unsupportedProtocolVersion(protocolVersion)
        }
        await onStage?(.protocolVersion(protocolVersion))

        await onStage?(.sendingIdentity)
        for request in AOANegotiationSequence.identityRequests(for: identity) {
            _ = try await perform(request, timeoutMilliseconds: timeoutMilliseconds)
        }
        await onStage?(.startingAccessory)
        do {
            _ = try await perform(
                AOANegotiationSequence.startRequest,
                timeoutMilliseconds: timeoutMilliseconds
            )
            await onStage?(.startCompleted)
        } catch USBHostError.disconnected {
            // AOA START can reset the device before the control transfer replies.
            // The caller must continue by waiting for accessory re-enumeration.
            await onStage?(.startDetached)
        }
        return protocolVersion
    }

    private func perform(
        _ request: AOAControlRequest,
        timeoutMilliseconds: UInt32
    ) async throws -> Data {
        try await transfer.controlTransfer(
            requestType: request.requestType,
            request: request.request,
            value: request.value,
            index: request.index,
            buffer: request.buffer,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }
}

nonisolated struct AOAUSBEndpoint: Equatable, Sendable {
    let address: UInt8
    let attributes: UInt8

    var isBulk: Bool { attributes & 0x03 == 0x02 }
    var isInput: Bool { address & 0x80 != 0 }
}

nonisolated struct AOAUSBInterface: Equatable, Sendable {
    let number: UInt8
    let endpoints: [AOAUSBEndpoint]

    var bulkEndpointPair: (input: UInt8, output: UInt8)? {
        guard let input = endpoints.first(where: { $0.isBulk && $0.isInput }),
              let output = endpoints.first(where: { $0.isBulk && !$0.isInput }) else {
            return nil
        }
        return (input.address, output.address)
    }
}

nonisolated struct AOAUSBDevice: Equatable, Sendable {
    let busNumber: UInt8
    let deviceAddress: UInt8
    let vendorID: UInt16
    let productID: UInt16
    let interfaces: [AOAUSBInterface]

    var id: String { "\(busNumber).\(deviceAddress)" }

    var accessoryInterface: AOAUSBInterface? {
        guard vendorID == 0x18D1, (0x2D00...0x2D05).contains(productID) else {
            return nil
        }
        return interfaces.first(where: { $0.bulkEndpointPair != nil })
    }
}

nonisolated struct AOAModeSwitchResult: Equatable, Sendable {
    let sourceDevice: AOAUSBDevice?
    let protocolVersion: UInt16?
    let accessoryDevice: AOAUSBDevice
    let interfaceNumber: UInt8
    let bulkInputEndpoint: UInt8
    let bulkOutputEndpoint: UInt8
}

nonisolated struct AOAPreparedAccessory: Sendable {
    let result: AOAModeSwitchResult
    let session: any USBAccessorySession
    let host: any AOAUSBHosting

    func close() async {
        await session.close()
        await host.stop()
    }
}

nonisolated enum AOAModeSwitchStage: Equatable, Sendable {
    case searching
    case devicesFound([AOAUSBDevice])
    case restartingExistingAccessory(AOAUSBDevice)
    case accessoryDetachObserved
    case deviceReset(String)
    case softReconfigure(String)
    case negotiating(AOAUSBDevice)
    case protocolVersion(UInt16)
    case sendingIdentity
    case startingAccessory
    case startCompleted
    case startDetached
    case waitingForReenumeration
    case accessoryReady(AOAModeSwitchResult)
    case registrySummary(String)
    case libusbLog(String)
}

// MARK: - Diagnostics log text

extension AOAIdentity {
    nonisolated var logSummary: String {
        "manufacturer=\(manufacturer) model=\(model) description=\(description) version=\(version) uri=\(uri) serial=\(serial)"
    }
}

extension AOAUSBDevice {
    /// "18D1:4EE2 bus 1 addr 3 interfaces 0[81/02 01/02]" — endpoint address/attributes in hex.
    nonisolated var logSummary: String {
        let interfaceText = interfaces.map { interface in
            let endpoints = interface.endpoints
                .map { String(format: "%02X/%02X", $0.address, $0.attributes) }
                .joined(separator: " ")
            return "\(interface.number)[\(endpoints)]"
        }.joined(separator: " ")
        return String(format: "%04X:%04X", vendorID, productID)
            + " bus \(busNumber) addr \(deviceAddress) interfaces \(interfaceText.isEmpty ? "none" : interfaceText)"
    }
}

extension AOAModeSwitchStage {
    /// What happened at this stage, with the ids and codes a remote reader needs.
    nonisolated var logDetail: String {
        switch self {
        case .searching:
            return "searching for USB devices"
        case .devicesFound(let devices):
            if devices.isEmpty { return "0 USB devices enumerated" }
            return "\(devices.count) USB device(s): " + devices.map { $0.logSummary }.joined(separator: "; ")
        case .restartingExistingAccessory(let device):
            return "device already in accessory mode, restarting it: \(device.logSummary)"
        case .accessoryDetachObserved:
            return "device left the USB bus"
        case .deviceReset(let result):
            return "device re-enumerate request: \(result)"
        case .softReconfigure(let result):
            return "SET_CONFIGURATION request: \(result)"
        case .negotiating(let device):
            return "AOA negotiation with \(device.logSummary)"
        case .protocolVersion(let version):
            return "GET_PROTOCOL returned version \(version)"
        case .sendingIdentity:
            return "sending the six accessory identity strings"
        case .startingAccessory:
            return "sending START"
        case .startCompleted:
            return "START control transfer completed"
        case .startDetached:
            return "device detached while START was in flight (expected)"
        case .waitingForReenumeration:
            return "polling for an accessory device (VID 18D1, PID 2D00-2D05)"
        case .accessoryReady(let result):
            return "accessory \(result.accessoryDevice.logSummary), claiming interface \(result.interfaceNumber), bulk IN \(String(format: "0x%02X", result.bulkInputEndpoint)) OUT \(String(format: "0x%02X", result.bulkOutputEndpoint))"
        case .registrySummary(let summary):
            return "IORegistry USB devices:\n\(summary)"
        case .libusbLog(let log):
            return "libusb log:\n\(log)"
        }
    }
}

nonisolated struct AOAProbeDiagnostics: Equatable, Sendable {
    private(set) var status = "Not started"
    private(set) var sourceDevice: AOAUSBDevice?
    private(set) var protocolVersion: UInt16?
    private(set) var didSendStart = false
    private(set) var didRestartExistingAccessory = false
    private(set) var didObserveAccessoryDetach = false
    private(set) var deviceResetResult: String?
    private(set) var softReconfigureResult: String?
    private(set) var didDetachAfterStart = false
    private(set) var didReenumerateAfterStart = false
    private(set) var result: AOAModeSwitchResult?
    private(set) var enumeratedDeviceCount: Int?
    private(set) var registrySummary: String?
    private(set) var libusbLog: String?
    private(set) var errorMessage: String?
    private(set) var drainedStaleBytes: Int?
    private(set) var staleDrainRanOutOfBudget = false
    private(set) var aapVideoDiagnostics: [String] = []

    mutating func record(_ stage: AOAModeSwitchStage) {
        switch stage {
        case .searching:
            status = "Searching for USB devices"
        case .devicesFound(let devices):
            enumeratedDeviceCount = devices.count
            status = "Found \(devices.count) USB device(s)"
        case .restartingExistingAccessory:
            didRestartExistingAccessory = true
            status = "Restarting the phone's accessory session"
        case .accessoryDetachObserved:
            didObserveAccessoryDetach = true
            status = "Phone accessory detached, waiting for it to return"
        case .deviceReset(let result):
            deviceResetResult = result
            status = "Re-enumerating the phone's USB device"
        case .softReconfigure(let result):
            softReconfigureResult = result
            status = "Re-configuring the phone's USB gadget"
        case .negotiating(let device):
            sourceDevice = device
            status = "Switching Android accessory mode"
        case .protocolVersion(let version):
            protocolVersion = version
            status = "AOA protocol version \(version)"
        case .sendingIdentity:
            status = "Sending Android accessory identity"
        case .startingAccessory:
            didSendStart = true
            status = "Sending Android accessory START"
        case .startCompleted:
            status = "Accessory START completed"
        case .startDetached:
            didDetachAfterStart = true
            status = "Phone detached after START"
        case .waitingForReenumeration:
            status = "Waiting for USB re-enumeration"
        case .accessoryReady(let result):
            self.result = result
            didReenumerateAfterStart = didSendStart
            status = "Accessory mode ready"
        case .registrySummary(let summary):
            registrySummary = summary
        case .libusbLog(let log):
            libusbLog = log
        }
    }

    mutating func record(error: Error) {
        errorMessage = error.localizedDescription
        status = "USB connection failed"
    }

    mutating func recordAAPHandshaking(_ detail: String = "Performing Android Auto handshake") {
        status = detail
    }

    mutating func recordAAPRunning() {
        status = "Connected via USB"
    }

    mutating func recordAAPVideoDiagnostics(_ lines: [String]) {
        aapVideoDiagnostics = lines
    }

    mutating func recordStaleDrain(bytes: Int, ranOutOfBudget: Bool) {
        drainedStaleBytes = bytes
        staleDrainRanOutOfBudget = ranOutOfBudget
    }

    var lines: [String] {
        let accessory = result?.accessoryDevice
        var output = [
            "Connection kind: USB",
            "USB connection status: \(status)",
            "Enumerated USB devices: \(enumeratedDeviceCount.map(String.init) ?? "Unknown")",
            "Source VID/PID: \(sourceDevice.map { Self.hex($0.vendorID) + ":" + Self.hex($0.productID) } ?? "Unknown")",
            "Source bus/address: \(sourceDevice.map { "\($0.busNumber)/\($0.deviceAddress)" } ?? "Unknown")",
            "AOA protocol version: \(protocolVersion.map(String.init) ?? "Unknown")",
            "AOA START sent: \(didSendStart ? "Yes" : "No")",
            "Restarted existing accessory: \(didRestartExistingAccessory ? "Yes" : "No")",
            "Accessory detach observed after restart: \(didObserveAccessoryDetach ? "Yes" : "No")",
            "USB device re-enumerate: \(deviceResetResult ?? "Not attempted")",
            "Soft USB re-configure: \(softReconfigureResult ?? "Not attempted")",
            "Detach during START response: \(didDetachAfterStart ? "Yes" : "No")",
            "Re-enumeration after START: \(didReenumerateAfterStart ? "Yes" : "No")",
            "Accessory VID/PID: \(accessory.map { Self.hex($0.vendorID) + ":" + Self.hex($0.productID) } ?? "Unknown")",
            "Accessory bus/address: \(accessory.map { "\($0.busNumber)/\($0.deviceAddress)" } ?? "Unknown")",
            "Interface: \(result.map { String($0.interfaceNumber) } ?? "Unknown")",
            "Bulk IN: \(result.map { Self.hex($0.bulkInputEndpoint, width: 2) } ?? "Unknown")",
            "Bulk OUT: \(result.map { Self.hex($0.bulkOutputEndpoint, width: 2) } ?? "Unknown")",
        ]
        if let drainedStaleBytes {
            output.append("Stale USB bytes drained: \(drainedStaleBytes)")
            output.append("Stale drain hit budget: \(staleDrainRanOutOfBudget ? "Yes" : "No")")
        }
        if let errorMessage {
            output.append("USB error: \(errorMessage)")
        }
        if let registrySummary, !registrySummary.isEmpty {
            output.append("IORegistry USB devices:\n\(registrySummary)")
        } else {
            output.append("IORegistry USB devices: No entries returned")
        }
        if let libusbLog, !libusbLog.isEmpty {
            output.append("libusb log:\n\(libusbLog)")
        }
        output.append(contentsOf: aapVideoDiagnostics)
        return output
    }

    private static func hex<T: FixedWidthInteger>(_ value: T, width: Int = 4) -> String {
        String(format: "0x%0*llX", width, UInt64(value))
    }
}

nonisolated protocol AOAUSBDeviceSession: AOAControlTransferring {
    /// Re-enumerates the device so the phone sees an unplug and starts over.
    /// The session does not survive it; close and re-probe afterwards.
    func resetDevice() async throws
    func close() async
}

extension USBDeviceSession: AOAUSBDeviceSession {}

nonisolated protocol AOAUSBHosting: Sendable {
    func start() async throws
    func stop() async
    func probeDevices() async throws -> [AOAUSBDevice]
    func open(_ device: AOAUSBDevice) async throws -> any AOAUSBDeviceSession
    func registrySummary() async -> String?
    func libusbLog() async -> String?
}

actor TrollUSBHost: AOAUSBHosting {
    private let controller = USBHostController()

    func start() async throws {
        try await controller.start()
    }

    func stop() async {
        await controller.stop()
    }

    func probeDevices() async throws -> [AOAUSBDevice] {
        try await controller.probeDevices().map { device in
            AOAUSBDevice(
                busNumber: device.busNumber,
                deviceAddress: device.deviceAddress,
                vendorID: device.descriptor.vendorID,
                productID: device.descriptor.productID,
                interfaces: device.interfaces.map { interface in
                    AOAUSBInterface(
                        number: interface.interface.interfaceNumber,
                        endpoints: interface.endpoints.map {
                            AOAUSBEndpoint(address: $0.endpointAddress, attributes: $0.attributes)
                        }
                    )
                }
            )
        }
    }

    func open(_ device: AOAUSBDevice) async throws -> any AOAUSBDeviceSession {
        try await controller.open(
            busNumber: device.busNumber,
            deviceAddress: device.deviceAddress
        )
    }

    func libusbLog() async -> String? {
        await controller.libusbLog()
    }

    func registrySummary() async -> String? {
        await controller.registrySummary()
    }
}

nonisolated enum AccessoryRestartOutcome: Sendable {
    /// The phone let go and came back already in accessory mode.
    case restarted(AOAModeSwitchResult)
    /// The phone let go and came back in normal mode: negotiate from scratch.
    case rescan([AOAUSBDevice])
    /// The phone never let go, so nothing was restarted.
    case unchanged
}

nonisolated struct AOAModeSwitcher: Sendable {
    let host: any AOAUSBHosting
    let identity: AOAIdentity
    let transferTimeoutMilliseconds: UInt32
    let reenumerationPollNanoseconds: UInt64
    let maximumReenumerationPolls: Int
    let accessoryRestartSettleNanoseconds: UInt64
    let accessoryRestartReenumerationPolls: Int
    let softReconfigureValue: UInt8
    let onStage: (@Sendable (AOAModeSwitchStage) async -> Void)?

    init(
        host: any AOAUSBHosting = TrollUSBHost(),
        identity: AOAIdentity,
        transferTimeoutMilliseconds: UInt32 = 1_000,
        reenumerationPollNanoseconds: UInt64 = 250_000_000,
        maximumReenumerationPolls: Int = 40,
        // No blind settle: polling starts immediately so a fast re-enumeration
        // gap cannot slip past unobserved.
        accessoryRestartSettleNanoseconds: UInt64 = 0,
        accessoryRestartReenumerationPolls: Int = 24,
        softReconfigureValue: UInt8 = 1,
        onStage: (@Sendable (AOAModeSwitchStage) async -> Void)? = nil
    ) {
        self.host = host
        self.identity = identity
        self.transferTimeoutMilliseconds = transferTimeoutMilliseconds
        self.reenumerationPollNanoseconds = reenumerationPollNanoseconds
        self.maximumReenumerationPolls = maximumReenumerationPolls
        self.accessoryRestartSettleNanoseconds = accessoryRestartSettleNanoseconds
        self.accessoryRestartReenumerationPolls = accessoryRestartReenumerationPolls
        self.softReconfigureValue = softReconfigureValue
        self.onStage = onStage
    }

    func switchFirstAvailableDevice() async throws -> AOAModeSwitchResult {
        await onStage?(.searching)
        do {
            try await host.start()
            let result = try await runStartedHost()
            if let summary = await host.registrySummary(), !summary.isEmpty {
                await onStage?(.registrySummary(summary))
            }
            if let log = await host.libusbLog(), !log.isEmpty {
                await onStage?(.libusbLog(log))
            }
            await host.stop()
            return result
        } catch {
            if let summary = await host.registrySummary(), !summary.isEmpty {
                await onStage?(.registrySummary(summary))
            }
            if let log = await host.libusbLog(), !log.isEmpty {
                await onStage?(.libusbLog(log))
            }
            await host.stop()
            throw error
        }
    }

    func prepareFirstAvailableAccessory() async throws -> AOAPreparedAccessory {
        await onStage?(.searching)
        do {
            try await host.start()
            let result = try await runStartedHost()
            let openedSession = try await host.open(result.accessoryDevice)
            guard let bulkSession = openedSession as? any USBAccessorySession else {
                await openedSession.close()
                throw AOAError.accessorySessionUnavailable
            }
            if let summary = await host.registrySummary(), !summary.isEmpty {
                await onStage?(.registrySummary(summary))
            }
            if let log = await host.libusbLog(), !log.isEmpty {
                await onStage?(.libusbLog(log))
            }
            return AOAPreparedAccessory(result: result, session: bulkSession, host: host)
        } catch {
            if let summary = await host.registrySummary(), !summary.isEmpty {
                await onStage?(.registrySummary(summary))
            }
            if let log = await host.libusbLog(), !log.isEmpty {
                await onStage?(.libusbLog(log))
            }
            await host.stop()
            throw error
        }
    }

    private func runStartedHost() async throws -> AOAModeSwitchResult {
        var devices = try await host.probeDevices()
        await onStage?(.devicesFound(devices))
        guard !devices.isEmpty else {
            throw AOAError.noUSBDevices
        }

        // A device already in accessory mode is left over from an earlier session.
        // The phone still believes that session is live and keeps writing its old
        // encrypted stream into the bulk pipe, which no fresh handshake can
        // decode, so it has to be made to start over before anything else.
        if let existing = Self.accessoryResult(in: devices) {
            switch try await restartExistingAccessory(existing.accessoryDevice) {
            case .restarted(let result):
                return result
            case .rescan(let refreshed):
                // Re-enumeration brings the phone back in normal mode, so fall
                // through to the ordinary negotiation with the new device list.
                devices = refreshed
                await onStage?(.devicesFound(devices))
            case .unchanged:
                await onStage?(.accessoryReady(existing))
                return existing
            }
        }

        for device in devices {
            try Task.checkCancellation()
            await onStage?(.negotiating(device))
            let session: any AOAUSBDeviceSession
            do {
                session = try await host.open(device)
            } catch USBHostError.permission {
                throw USBHostError.permission
            } catch {
                continue
            }

            let protocolVersion: UInt16
            do {
                protocolVersion = try await AOANegotiator(
                    transfer: session,
                    onStage: { stage in
                        switch stage {
                        case .protocolVersion(let version): await self.onStage?(.protocolVersion(version))
                        case .sendingIdentity: await self.onStage?(.sendingIdentity)
                        case .startingAccessory: await self.onStage?(.startingAccessory)
                        case .startCompleted: await self.onStage?(.startCompleted)
                        case .startDetached: await self.onStage?(.startDetached)
                        }
                    }
                ).negotiate(identity: identity, timeoutMilliseconds: transferTimeoutMilliseconds)
            } catch is CancellationError {
                await session.close()
                throw CancellationError()
            } catch USBHostError.permission {
                await session.close()
                throw USBHostError.permission
            } catch USBHostError.timeout {
                await session.close()
                throw USBHostError.timeout
            } catch USBHostError.disconnected {
                await session.close()
                throw AOAError.deviceDetachedDuringNegotiation
            } catch {
                await session.close()
                continue
            }

            await session.close()
            await onStage?(.waitingForReenumeration)
            return try await waitForAccessory(
                sourceDevice: device,
                protocolVersion: protocolVersion
            )
        }

        throw AOAError.noAOACapableDevice
    }

    /// Returns the freshly restarted accessory, or nil when the phone would not
    /// restart and the caller should fall back to the accessory it already found.
    private func restartExistingAccessory(
        _ device: AOAUSBDevice
    ) async throws -> AccessoryRestartOutcome {
        await onStage?(.restartingExistingAccessory(device))

        // Re-enumeration first. It is the only thing that reaches a phone which
        // believes it is still connected to the same host: the device leaves the
        // bus and comes back, which is exactly what an unplug looks like from the
        // phone's side, so Android Auto tears its session down and re-arms.
        if try await requestDeviceReset(device),
           let outcome = try await awaitDeviceReturn(protocolVersion: nil) {
            return outcome
        }

        let session: any AOAUSBDeviceSession
        do {
            session = try await host.open(device)
        } catch USBHostError.permission {
            throw USBHostError.permission
        } catch {
            return .unchanged
        }

        // The full sequence, not START on its own: restarting the accessory
        // function clears the identity strings, and Android Auto only projects to
        // an accessory that identifies itself as Android/Android Auto. A phone
        // handed a bare START comes back up as an unrecognised accessory.
        let protocolVersion: UInt16
        do {
            protocolVersion = try await AOANegotiator(
                transfer: session,
                onStage: { [onStage] stage in
                    switch stage {
                    case .protocolVersion(let version): await onStage?(.protocolVersion(version))
                    case .sendingIdentity: await onStage?(.sendingIdentity)
                    case .startingAccessory: await onStage?(.startingAccessory)
                    case .startCompleted: await onStage?(.startCompleted)
                    case .startDetached: await onStage?(.startDetached)
                    }
                }
            ).negotiate(identity: identity, timeoutMilliseconds: transferTimeoutMilliseconds)
        } catch is CancellationError {
            await session.close()
            throw CancellationError()
        } catch {
            await session.close()
            return .unchanged
        }
        await session.close()

        if accessoryRestartSettleNanoseconds > 0 {
            try await Task.sleep(nanoseconds: accessoryRestartSettleNanoseconds)
        }

        await onStage?(.waitingForReenumeration)

        if let outcome = try await awaitDeviceReturn(protocolVersion: protocolVersion) {
            return outcome
        }

        // AOA START alone does not dislodge a phone that is already in accessory
        // mode. Re-selecting the USB configuration does more: the gadget runs
        // set_config, which disables every function first, and that is what tells
        // the accessory side its connection went away.
        if try await requestSoftReconfigure(device),
           let outcome = try await awaitDeviceReturn(protocolVersion: protocolVersion) {
            return outcome
        }

        // Adopting whatever the phone is still exposing beats failing outright.
        return .unchanged
    }

    /// Waits for the device to leave the bus and come back. A restart is only real
    /// if that happens: a device that stays present the whole time never restarted,
    /// and the caller must not be told the pipe is fresh when it is not.
    ///
    /// Returns nil when nothing left, or when it left and never returned. A device
    /// that returns in normal mode means the caller has to negotiate from scratch,
    /// which is what `.rescan` carries.
    private func awaitDeviceReturn(
        protocolVersion: UInt16?
    ) async throws -> AccessoryRestartOutcome? {
        var sawDetach = false
        for poll in 0..<max(accessoryRestartReenumerationPolls, 1) {
            try Task.checkCancellation()
            let devices = try await host.probeDevices()

            if devices.isEmpty {
                if !sawDetach {
                    sawDetach = true
                    await onStage?(.accessoryDetachObserved)
                }
            } else if sawDetach {
                if let accessory = Self.accessoryResult(in: devices, protocolVersion: protocolVersion) {
                    await onStage?(.accessoryReady(accessory))
                    return .restarted(accessory)
                }
                return .rescan(devices)
            } else if Self.accessoryResult(in: devices) == nil {
                // Still on the bus but no longer an accessory: the gadget was torn
                // down and rebuilt without the device ever vanishing from a poll.
                sawDetach = true
                await onStage?(.accessoryDetachObserved)
                return .rescan(devices)
            }

            if poll + 1 < accessoryRestartReenumerationPolls, reenumerationPollNanoseconds > 0 {
                try await Task.sleep(nanoseconds: reenumerationPollNanoseconds)
            }
        }
        return nil
    }

    /// Returns true when the reset was accepted, so it is worth waiting for the
    /// device to come back. Whether iOS lets a userspace client re-enumerate is
    /// gated by the USB host user client, so a refusal is recorded and treated as
    /// "nothing happened" rather than as a failure.
    private func requestDeviceReset(_ device: AOAUSBDevice) async throws -> Bool {
        let session: any AOAUSBDeviceSession
        do {
            session = try await host.open(device)
        } catch USBHostError.permission {
            throw USBHostError.permission
        } catch {
            await onStage?(.deviceReset("Rejected (\(errorLabel(error)))"))
            return false
        }

        do {
            try await session.resetDevice()
            await onStage?(.deviceReset("Accepted"))
            await session.close()
            return true
        } catch USBHostError.disconnected {
            // The device left the bus mid-request, which is the whole point.
            await onStage?(.deviceReset("Accepted (device left the bus)"))
            await session.close()
            return true
        } catch is CancellationError {
            await session.close()
            throw CancellationError()
        } catch {
            await onStage?(.deviceReset("Rejected (\(errorLabel(error)))"))
            await session.close()
            return false
        }
    }

    /// Returns true when the device accepted SET_CONFIGURATION, so it is worth
    /// waiting for it to come back. Whether iOS forwards a standard request that
    /// changes device state is not documented, so a rejection is recorded and
    /// treated as "nothing happened" rather than as a failure.
    private func requestSoftReconfigure(_ device: AOAUSBDevice) async throws -> Bool {
        let session: any AOAUSBDeviceSession
        do {
            session = try await host.open(device)
        } catch {
            await onStage?(.softReconfigure("Rejected (\(errorLabel(error)))"))
            return false
        }

        do {
            _ = try await session.controlTransfer(
                requestType: 0x00, // host-to-device, standard, device
                request: 0x09, // SET_CONFIGURATION
                value: UInt16(softReconfigureValue),
                index: 0,
                buffer: Data(),
                timeoutMilliseconds: transferTimeoutMilliseconds
            )
            await onStage?(.softReconfigure("Accepted"))
            await session.close()
            return true
        } catch USBHostError.disconnected {
            // The device dropped off the bus mid-request, which is the outcome
            // this request is trying to provoke.
            await onStage?(.softReconfigure("Accepted (device detached)"))
            await session.close()
            return true
        } catch is CancellationError {
            await session.close()
            throw CancellationError()
        } catch {
            await onStage?(.softReconfigure("Rejected (\(errorLabel(error)))"))
            await session.close()
            return false
        }
    }

    private func errorLabel(_ error: Error) -> String {
        if let hostError = error as? USBHostError {
            return String(describing: hostError)
        }
        return String(describing: type(of: error))
    }

    private func waitForAccessory(
        sourceDevice: AOAUSBDevice?,
        protocolVersion: UInt16?,
        maximumPolls: Int? = nil
    ) async throws -> AOAModeSwitchResult {
        let maximumReenumerationPolls = maximumPolls ?? self.maximumReenumerationPolls
        for poll in 0..<maximumReenumerationPolls {
            try Task.checkCancellation()
            let devices = try await host.probeDevices()
            if let result = Self.accessoryResult(
                in: devices,
                sourceDevice: sourceDevice,
                protocolVersion: protocolVersion
            ) {
                await onStage?(.accessoryReady(result))
                return result
            }
            if poll + 1 < maximumReenumerationPolls, reenumerationPollNanoseconds > 0 {
                try await Task.sleep(nanoseconds: reenumerationPollNanoseconds)
            }
        }
        throw AOAError.accessoryReenumerationTimedOut
    }

    private static func accessoryResult(
        in devices: [AOAUSBDevice],
        sourceDevice: AOAUSBDevice? = nil,
        protocolVersion: UInt16? = nil
    ) -> AOAModeSwitchResult? {
        for device in devices {
            guard let interface = device.accessoryInterface,
                  let endpoints = interface.bulkEndpointPair else {
                continue
            }
            return AOAModeSwitchResult(
                sourceDevice: sourceDevice,
                protocolVersion: protocolVersion,
                accessoryDevice: device,
                interfaceNumber: interface.number,
                bulkInputEndpoint: endpoints.input,
                bulkOutputEndpoint: endpoints.output
            )
        }
        return nil
    }
}
