//
//  USBAccessoryConnection.swift
//  HeadunitPad
//

import Foundation
import USBHostKit

nonisolated struct USBAccessoryReadResult: Equatable, Sendable {
    let data: Data
    let recoveredFromTimeout: Bool
}

nonisolated protocol USBAccessorySession: AnyObject, Sendable {
    func claimInterface(_ number: UInt8) async throws
    func releaseInterface(_ number: UInt8) async throws
    func read(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> USBAccessoryReadResult
    func write(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) async throws
    func close() async
}

extension USBDeviceSession: USBAccessorySession {
    func read(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> USBAccessoryReadResult {
        let result = try await bulkReadDetailed(
            endpoint: endpoint,
            length: length,
            timeoutMilliseconds: timeoutMilliseconds
        )
        return USBAccessoryReadResult(
            data: result.data,
            recoveredFromTimeout: result.recoveredFromTimeout
        )
    }

    func write(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) async throws {
        try await bulkWrite(
            endpoint: endpoint,
            data: data,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }
}

nonisolated enum USBAccessoryConnectionError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case alreadyConnected
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The USB accessory bulk endpoints are invalid."
        case .alreadyConnected:
            return "The USB accessory connection is already active."
        case .notConnected:
            return "The USB accessory connection is not active."
        }
    }
}

nonisolated final class USBAccessoryConnection: ByteStreamConnection, @unchecked Sendable {
    private enum State {
        case idle
        case connecting
        case connected
        case disconnecting
        case disconnected
    }

    private struct PendingWrite {
        let data: Data
        let completion: ((Error?) -> Void)?
    }

    private struct DisconnectTasks {
        let read: Task<Void, Never>?
        let write: Task<Void, Never>?
    }

    weak var delegate: ByteStreamConnectionDelegate?

    private let session: any USBAccessorySession
    private let interfaceNumber: UInt8
    private let inputEndpoint: UInt8
    private let outputEndpoint: UInt8
    private let readLength: Int
    private let readTimeoutMilliseconds: UInt32
    private let writeTimeoutMilliseconds: UInt32
    private let staleDrainReadTimeoutMilliseconds: UInt32
    private let staleDrainQuietReads: Int
    private let staleDrainBudgetMilliseconds: UInt64
    private var staleBytesDrained = 0
    private var staleDrainHitBudget = false
    private var bytesRead = 0
    private var bytesWritten = 0

    var drainedStaleBytes: Int {
        withLock { staleBytesDrained }
    }

    /// True when the pipe was still delivering the old session's bytes when the
    /// drain budget ran out, so the handshake started against a dirty stream.
    var staleDrainRanOutOfBudget: Bool {
        withLock { staleDrainHitBudget }
    }
    private let lock = NSLock()
    private var state: State = .idle
    private var interfaceClaimed = false
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var pendingWrites: [PendingWrite] = []

    var isConnected: Bool {
        withLock { state == .connected }
    }

    init(
        session: any USBAccessorySession,
        interfaceNumber: UInt8,
        inputEndpoint: UInt8,
        outputEndpoint: UInt8,
        readLength: Int = 64 * 1024,
        readTimeoutMilliseconds: UInt32 = 1_000,
        writeTimeoutMilliseconds: UInt32 = 5_000,
        staleDrainReadTimeoutMilliseconds: UInt32 = 150,
        staleDrainQuietReads: Int = 3,
        staleDrainBudgetMilliseconds: UInt64 = 6_000
    ) throws {
        guard inputEndpoint & 0x80 != 0,
              outputEndpoint & 0x80 == 0,
              readLength > 0 else {
            throw USBAccessoryConnectionError.invalidEndpoint
        }
        self.session = session
        self.interfaceNumber = interfaceNumber
        self.inputEndpoint = inputEndpoint
        self.outputEndpoint = outputEndpoint
        self.readLength = readLength
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.writeTimeoutMilliseconds = writeTimeoutMilliseconds
        self.staleDrainReadTimeoutMilliseconds = staleDrainReadTimeoutMilliseconds
        self.staleDrainQuietReads = staleDrainQuietReads
        self.staleDrainBudgetMilliseconds = staleDrainBudgetMilliseconds
    }

    func connect() async throws {
        let canStart = withLock { () -> Bool in
            guard state == .idle || state == .disconnected else { return false }
            state = .connecting
            return true
        }
        guard canStart else {
            throw USBAccessoryConnectionError.alreadyConnected
        }

        let endpoints = "bulk IN \(String(format: "0x%02X", inputEndpoint)), OUT \(String(format: "0x%02X", outputEndpoint))"
        DiagnosticsLog.shared.log("usb", "claiming interface \(interfaceNumber) (\(endpoints))")
        do {
            try await session.claimInterface(interfaceNumber)
        } catch {
            DiagnosticsLog.shared.log("usb", "interface \(interfaceNumber) claim FAILED: \(DiagnosticsLog.describe(error))")
            withLock { state = .disconnected }
            await session.close()
            throw error
        }
        DiagnosticsLog.shared.log("usb", "interface \(interfaceNumber) claimed")

        await drainStaleInput()
        DiagnosticsLog.shared.log(
            "usb",
            "stale input drain finished: \(drainedStaleBytes) byte(s) discarded, budget exhausted: \(staleDrainRanOutOfBudget ? "yes" : "no")"
        )

        let didConnect = withLock { () -> Bool in
            guard state == .connecting, !Task.isCancelled else { return false }
            interfaceClaimed = true
            state = .connected
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runReadLoop()
            }
            readTask = task
            return true
        }
        guard didConnect else {
            DiagnosticsLog.shared.log("usb", "connect cancelled after claim; releasing interface \(interfaceNumber)")
            try? await session.releaseInterface(interfaceNumber)
            await session.close()
            throw CancellationError()
        }
        DiagnosticsLog.shared.log("usb", "bulk read loop started")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.byteStreamConnectionDidConnect(self)
        }
    }

    func send(_ data: Data, completion: ((Error?) -> Void)?) {
        let accepted = withLock { () -> Bool in
            guard state == .connected else { return false }
            guard !data.isEmpty else { return true }
            pendingWrites.append(PendingWrite(data: data, completion: completion))
            if writeTask == nil {
                writeTask = Task { [weak self] in
                    guard let self else { return }
                    await self.drainWrites()
                }
            }
            return true
        }
        guard accepted else {
            completion?(USBAccessoryConnectionError.notConnected)
            return
        }
        if data.isEmpty {
            completion?(nil)
        }
    }

    func disconnect() {
        requestDisconnect(error: nil)
    }

    /// Empties whatever a previous session left in the bulk IN pipe and waits for
    /// it to fall quiet. Those bytes belong to a stream this connection has no keys
    /// for, and starting the handshake while they are still arriving is what makes
    /// a reconnect fail. Quiet means several consecutive reads delivering nothing,
    /// not just one: the old stream arrives in bursts with gaps between them.
    /// Bounded by `staleDrainBudgetMilliseconds` so a phone that never stops
    /// cannot stall the connect indefinitely.
    private func drainStaleInput() async {
        guard staleDrainQuietReads > 0 else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + staleDrainBudgetMilliseconds * 1_000_000
        var quietReads = 0

        while quietReads < staleDrainQuietReads {
            if Task.isCancelled { return }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                withLock { staleDrainHitBudget = true }
                return
            }
            do {
                let result = try await session.read(
                    endpoint: inputEndpoint,
                    length: readLength,
                    timeoutMilliseconds: staleDrainReadTimeoutMilliseconds
                )
                if result.data.isEmpty {
                    quietReads += 1
                } else {
                    quietReads = 0
                    withLock { staleBytesDrained += result.data.count }
                }
            } catch USBHostError.timeout {
                quietReads += 1
            } catch {
                // Anything else is a real failure; leave it for the read loop to
                // surface with its normal disconnect handling.
                return
            }
        }
    }

    private func runReadLoop() async {
        while !Task.isCancelled {
            do {
                let result = try await session.read(
                    endpoint: inputEndpoint,
                    length: readLength,
                    timeoutMilliseconds: readTimeoutMilliseconds
                )
                if !result.data.isEmpty {
                    let isFirstRead = withLock { () -> Bool in
                        defer { bytesRead += result.data.count }
                        return bytesRead == 0
                    }
                    if isFirstRead {
                        DiagnosticsLog.shared.log(
                            "usb",
                            "first bulk read: \(result.data.count) byte(s)\(result.recoveredFromTimeout ? " (recovered from timeout)" : "")"
                        )
                    }
                    delegate?.byteStreamConnection(self, didReceive: result.data)
                }
            } catch USBHostError.timeout {
                continue
            } catch USBHostError.cancelled {
                return
            } catch is CancellationError {
                return
            } catch {
                requestDisconnect(error: error)
                return
            }
        }
    }

    private func drainWrites() async {
        while !Task.isCancelled {
            let pending = withLock { () -> PendingWrite? in
                guard state == .connected, !pendingWrites.isEmpty else {
                    writeTask = nil
                    return nil
                }
                return pendingWrites.removeFirst()
            }
            guard let pending else { return }

            do {
                try await session.write(
                    endpoint: outputEndpoint,
                    data: pending.data,
                    timeoutMilliseconds: writeTimeoutMilliseconds
                )
                let isFirstWrite = withLock { () -> Bool in
                    defer { bytesWritten += pending.data.count }
                    return bytesWritten == 0
                }
                if isFirstWrite {
                    DiagnosticsLog.shared.log("usb", "first bulk write: \(pending.data.count) byte(s)")
                }
                pending.completion?(nil)
            } catch {
                pending.completion?(error)
                requestDisconnect(error: error)
                return
            }
        }
    }

    private func requestDisconnect(error: Error?) {
        let tasks: DisconnectTasks? = withLock {
            guard state != .disconnecting, state != .disconnected else { return nil }
            state = .disconnecting
            return DisconnectTasks(read: readTask, write: writeTask)
        }
        guard let tasks else { return }

        let totals = withLock { (bytesRead, bytesWritten) }
        DiagnosticsLog.shared.log(
            "usb",
            "disconnecting (\(error.map { DiagnosticsLog.describe($0) } ?? "requested")); bulk bytes read \(totals.0), written \(totals.1)"
        )
        tasks.read?.cancel()
        tasks.write?.cancel()
        Task { [weak self] in
            await tasks.read?.value
            await tasks.write?.value
            await self?.finishDisconnect(error: error)
        }
    }

    private func finishDisconnect(error: Error?) async {
        let cleanup = withLock { () -> (Bool, [PendingWrite]) in
            let shouldRelease = interfaceClaimed
            interfaceClaimed = false
            let abandonedWrites = pendingWrites
            pendingWrites.removeAll()
            readTask = nil
            writeTask = nil
            return (shouldRelease, abandonedWrites)
        }

        if cleanup.0 {
            do {
                try await session.releaseInterface(interfaceNumber)
                DiagnosticsLog.shared.log("usb", "interface \(interfaceNumber) released")
            } catch {
                DiagnosticsLog.shared.log("usb", "interface \(interfaceNumber) release failed: \(DiagnosticsLog.describe(error))")
            }
        }
        await session.close()
        DiagnosticsLog.shared.log("usb", "USB session closed")

        withLock { state = .disconnected }

        for pending in cleanup.1 {
            pending.completion?(USBHostError.cancelled)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.byteStreamConnection(self, didDisconnect: error)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
