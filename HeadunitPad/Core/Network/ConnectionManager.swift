//
//  ConnectionManager.swift
//  HeadunitPad
//
//  Manages device discovery and connection lifecycle
//

import Foundation
import AVFoundation
import Network
import UIKit

enum ConnectionState: Equatable {
    case disconnected
    case discovering
    case waitingForWirelessHelper
    case connecting
    case handshaking
    case running
    case disconnecting
    case error(String)

    var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .discovering:
            return "Scanning..."
        case .waitingForWirelessHelper:
            return "Waiting for Wireless Helper..."
        case .connecting:
            return "Connecting..."
        case .handshaking:
            return "Handshaking..."
        case .running:
            return "Connected"
        case .disconnecting:
            return "Disconnecting..."
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

enum USBProbeState: Equatable {
    case idle
    case running(String)
    case succeeded
    case failed(String)
    case cancelled

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

protocol ConnectionManagerDelegate: AnyObject {
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState)
    func connectionManager(_ manager: ConnectionManager, didUpdateStatus status: String)
    func connectionManager(_ manager: ConnectionManager, didDiscoverDevice device: DiscoveredDevice)
    func connectionManager(_ manager: ConnectionManager, didReceiveVideoData data: Data)
    func connectionManager(_ manager: ConnectionManager, didReceiveAudioData data: Data, on channel: UInt8)
    func connectionManager(_ manager: ConnectionManager, didChangeUSBProbeState state: USBProbeState)
}

class ConnectionManager {
    weak var delegate: ConnectionManagerDelegate?

    private let discovery = Discovery()
    private let tcpHandler = TcpHandler()
    private let wirelessHelperServer = WirelessHelperServer()
    private let microphoneCapture = MicrophoneCapture()
    private let locationCapture = LocationCapture()
    private var aapTransport: AapTransport?
    private var activeConnection: ByteStreamConnection?
    private var usbAccessoryConnection: USBAccessoryConnection?
    private var usbHost: (any AOAUSBHosting)?
    private var reconnectWorkItem: DispatchWorkItem?
    private var isUserInitiatedDisconnect = false
    private var hasTriggeredWirelessHelper = false
    private var hasReceivedAaMediaMetadata = false
    private let reconnectDelay: TimeInterval = 2.0
    private var usbProbeTask: Task<Void, Never>?
    private var usbCleanupTask: Task<Void, Never>?
    private(set) var usbProbeState: USBProbeState = .idle {
        didSet {
            logUSBProbeState(usbProbeState)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.connectionManager(self, didChangeUSBProbeState: self.usbProbeState)
            }
        }
    }
    private(set) var usbProbeDiagnostics = AOAProbeDiagnostics()
    /// Survives the probe reset in startUSBProbe: a failed reconnect is usually
    /// explained by how the session before it ended.
    private var lastSessionTeardownLines: [String] = []

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            print("ConnectionManager: state changed from \(oldValue.description) to \(state.description)")
            DiagnosticsLog.shared.log("state", "\(oldValue.description) -> \(state.description)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.connectionManager(self, didChangeState: self.state)
            }
        }
    }

    private(set) var discoveredDevices: [DiscoveredDevice] = []
    private(set) var connectedDevice: DiscoveredDevice?
    private(set) var statusDetail = "Ready to connect"

    init() {
        discovery.delegate = self
        wirelessHelperServer.delegate = self
        installAapTransport(connection: tcpHandler)
        microphoneCapture.onPCMData = { [weak self] data in
            self?.aapTransport?.sendMicrophoneAudioData(data)
        }
        locationCapture.onLocation = { [weak self] location in
            self?.aapTransport?.sendLocationUpdate(location)
        }
        NowPlayingCoordinator.shared.onRemoteCommand = { [weak self] command in
            self?.sendRemoteMediaCommand(command)
        }
    }

    func requestLocationPermissionIfNeeded() {
        guard ProjectionSettings.gpsSource == .ipad else { return }
        guard ProjectionSettings.supportsCellularIpad() else { return }
        locationCapture.requestPermissionIfNeeded()
    }

    func startUSBProbe() {
        guard usbProbeTask == nil, usbCleanupTask == nil else {
            DiagnosticsLog.shared.log("mode", "wired USB start ignored: a wired attempt or cleanup is already in progress")
            return
        }
        switch state {
        case .disconnected, .error:
            break
        default:
            DiagnosticsLog.shared.log("mode", "wired USB start refused: current state is \(state.description)")
            usbProbeState = .failed("Disconnect the current session before connecting over USB.")
            return
        }
        DiagnosticsLog.shared.log("mode", "wired USB start (AOA identity \(AOAIdentity.androidAuto.logSummary))")

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        isUserInitiatedDisconnect = false
        usbProbeDiagnostics = AOAProbeDiagnostics()
        usbProbeState = .running("Searching for USB devices")
        let identity = AOAIdentity.androidAuto
        let switcher = AOAModeSwitcher(
            identity: identity,
            onStage: { [weak self] stage in
                guard let self else { return }
                await self.handleUSBProbeStage(stage)
            }
        )

        usbProbeTask = Task { [weak self] in
            guard let self else { return }
            do {
                state = .connecting
                updateStatus("Searching for a wired Android device...")
                let prepared = try await switcher.prepareFirstAvailableAccessory()
                guard !Task.isCancelled else {
                    await prepared.close()
                    throw CancellationError()
                }

                let connection = try USBAccessoryConnection(
                    session: prepared.session,
                    interfaceNumber: prepared.result.interfaceNumber,
                    inputEndpoint: prepared.result.bulkInputEndpoint,
                    outputEndpoint: prepared.result.bulkOutputEndpoint
                )
                usbHost = prepared.host
                usbAccessoryConnection = connection
                installAapTransport(connection: connection)
                usbProbeDiagnostics.recordAAPHandshaking()
                usbProbeState = .running(usbProbeDiagnostics.status)
                state = .handshaking
                updateStatus("Performing Android Auto handshake over USB...")
                try await connection.connect()
                usbProbeTask = nil
            } catch is CancellationError {
                usbProbeTask = nil
                usbProbeState = .cancelled
                state = .disconnected
                updateStatus("USB connection cancelled")
            } catch {
                DiagnosticsLog.shared.log("error", "wired attempt failed: \(DiagnosticsLog.describe(error))")
                usbProbeDiagnostics.record(error: error)
                usbProbeTask = nil
                usbProbeState = .failed(error.localizedDescription)
                await cleanupUSBResources()
                installAapTransport(connection: tcpHandler)
                state = .error(error.localizedDescription)
                updateStatus(error.localizedDescription)
            }
        }
    }

    func stopUSBProbe() {
        guard let usbProbeTask else { return }
        DiagnosticsLog.shared.log("mode", "wired USB stop requested")
        usbProbeState = .running("Cancelling wired connection...")
        usbProbeTask.cancel()
    }

    func startDiscovery() {
        print("ConnectionManager: startDiscovery called")
        guard usbProbeTask == nil else {
            print("ConnectionManager: Cannot start wireless discovery while a wired connection is in progress")
            DiagnosticsLog.shared.log("mode", "wireless start ignored: a wired connection is in progress")
            return
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        isUserInitiatedDisconnect = false
        let canStart: Bool
        switch state {
        case .disconnected, .error:
            canStart = true
        case .waitingForWirelessHelper:
            canStart = true
        default:
            canStart = false
        }

        guard canStart else {
            print("ConnectionManager: Cannot start discovery, current state: \(state.description)")
            DiagnosticsLog.shared.log("mode", "wireless start ignored: current state is \(state.description)")
            return
        }
        DiagnosticsLog.shared.log(
            "mode",
            "wireless start (mode \(ProjectionSettings.connectionMode.title), auto reconnect \(ProjectionSettings.autoReconnect ? "on" : "off"), local IP \(localIPv4Address() ?? "unknown"))"
        )

        discoveredDevices.removeAll()
        hasTriggeredWirelessHelper = false
        state = .discovering

        switch ProjectionSettings.connectionMode {
        case .auto:
            updateStatus("Listening on 5288, scanning for Wireless Helper and Headunit Server...")
            wirelessHelperServer.start()
            discovery.startScan(ports: [Discovery.launcherPort, Discovery.headunitPort])
        case .wirelessHelper:
            updateStatus("Listening on 5288 and looking for Wireless Helper...")
            wirelessHelperServer.start()
            discovery.startScan(ports: [Discovery.launcherPort])
        case .directHeadunit:
            updateStatus("Scanning for Headunit Server on 5277...")
            wirelessHelperServer.stop()
            discovery.startScan(ports: [Discovery.headunitPort])
        }
    }

    func stopDiscovery() {
        print("ConnectionManager: stopDiscovery called")
        DiagnosticsLog.shared.log("mode", "wireless stop (state \(state.description))")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        discovery.stopScan()
        if state == .discovering || state == .waitingForWirelessHelper {
            state = .disconnected
            updateStatus("Ready to connect")
        }
    }

    func connect(to device: DiscoveredDevice) {
        print("ConnectionManager: connect(to:) called with device: \(device.displayName)")
        DiagnosticsLog.shared.log("mode", "wireless connect to \(device.ip):\(device.port) (\(device.displayName))")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        isUserInitiatedDisconnect = false
        let preparedConnection = discovery.takePreparedConnection(ip: device.ip, port: device.port)
        stopDiscovery()
        state = .connecting
        connectedDevice = device
        updateStatus("Connecting to \(device.displayName)...")
        installAapTransport(connection: tcpHandler)
        aapTransport?.configurePeer(host: device.ip, port: device.port)

        if let preparedConnection = preparedConnection {
            print("ConnectionManager: Using prepared connection from discovery for \(device.ip):\(device.port)")
            DiagnosticsLog.shared.log("net", "reusing the TCP connection the scan already opened to \(device.ip):\(device.port)")
            tcpHandler.adoptConnection(preparedConnection, host: device.ip, port: device.port)
        } else {
            print("ConnectionManager: Calling tcpHandler.connect(host: \(device.ip), port: \(device.port))")
            tcpHandler.connect(host: device.ip, port: device.port)
        }
    }

    func connect(to ip: String, port: UInt16 = 5277) {
        print("ConnectionManager: connect(to:port:) called with ip: \(ip), port: \(port)")
        let device = DiscoveredDevice(ip: ip, port: port, name: nil)
        connect(to: device)
    }

    func disconnect() {
        print("ConnectionManager: disconnect called")
        DiagnosticsLog.shared.log("mode", "user disconnect (state \(state.description))")
        guard usbCleanupTask == nil else { return }
        isUserInitiatedDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stopUSBProbe()
        NowPlayingCoordinator.shared.deactivate()
        microphoneCapture.stop()
        locationCapture.stop()
        wirelessHelperServer.stop()
        if usbAccessoryConnection != nil, let transport = aapTransport {
            usbProbeState = .running("Releasing wired USB resources...")
            state = .disconnecting
            updateStatus("Requesting Android Auto shutdown...")
            transport.requestGracefulDisconnect { [weak self, weak transport] in
                guard let self, let transport, self.aapTransport === transport else { return }
                self.activeConnection?.disconnect()
            }
            return
        }
        activeConnection?.disconnect()
        connectedDevice = nil
        state = .disconnected
        updateStatus("Ready to connect")
    }

    func send(_ data: Data) {
        guard state == .running else { return }
        aapTransport?.send(message: AapMessage(channel: 0, flags: 0, type: 0, payload: data))
    }

    func sendTouchEvent(x: Int, y: Int, action: TouchAction) {
        guard state == .running else { return }
        aapTransport?.sendTouchEvent(x: x, y: y, action: action)
    }

    func sendTouchEvent(pointers: [(id: Int, x: Int, y: Int)], action: TouchAction, actionIndex: Int) {
        guard state == .running else { return }
        aapTransport?.sendTouchEvent(pointers: pointers, action: action, actionIndex: actionIndex)
    }

    func requestVideoRecovery() {
        guard state == .running else { return }
        aapTransport?.requestVideoRecovery()
    }

    func requestVideoRecoveryForNewDisplay() {
        guard state == .running else { return }
        aapTransport?.requestVideoRecoveryForNewDisplay()
    }

    func sendRemoteMediaCommand(_ command: RemoteMediaCommand) {
        guard state == .running else { return }
        let keyCode: Int
        switch command {
        case .play:
            keyCode = 126
        case .pause:
            keyCode = 127
        case .playPause:
            keyCode = 85
        case .next:
            keyCode = 87
        case .previous:
            keyCode = 88
        case .stop:
            keyCode = 86
        }
        aapTransport?.sendMediaKeyEvent(keyCode: keyCode)
    }

    func diagnosticLines() -> [String] {
        let device = connectedDevice
        let liveVideoLines = usbProbeDiagnostics.aapVideoDiagnostics.isEmpty
            ? (aapTransport?.videoDiagnosticLines() ?? [])
            : []
        let entitlements = USBHostEntitlements.current().summary
        let connectionLines = [
            "State: \(state.description)",
            "Status: \(statusDetail)",
            "Mode: \(ProjectionSettings.connectionMode.title)",
            "Auto reconnect: \(ProjectionSettings.autoReconnect ? "On" : "Off")",
            "Local IP: \(localIPv4Address() ?? "Unknown")",
            "Wireless listener: \(wirelessHelperServer.isRunning ? "Listening" : "Stopped")",
            "Wireless listener port: \(WirelessHelperServer.port)",
            "Bonjour service: \(WirelessHelperServer.serviceType)",
            "Audio output: \(currentAudioOutputDescription())",
            "Now Playing owner: \(state == .running ? "HeadunitPad" : "Inactive")",
            "Discovered headunits: \(discoveredDevices.count)",
            "Helper triggered: \(hasTriggeredWirelessHelper ? "Yes" : "No")",
            "Connected device: \(device?.displayName ?? "None")",
            "Connected endpoint: \(device.map { "\($0.ip):\($0.port)" } ?? "None")",
            "USB host entitlements: \(entitlements)",
            "",
        ]
        var usbLines = usbProbeDiagnostics
        if let usbAccessoryConnection {
            usbLines.recordStaleDrain(
                bytes: usbAccessoryConnection.drainedStaleBytes,
                ranOutOfBudget: usbAccessoryConnection.staleDrainRanOutOfBudget
            )
        }
        return connectionLines
            + liveVideoLines
            + [""]
            + usbLines.lines
            + (lastSessionTeardownLines.isEmpty ? [] : [""] + lastSessionTeardownLines)
    }

    /// A finished wired attempt leaves the whole report in the log: it carries the
    /// registry summary, libusb log and video counters a remote reader needs.
    private func logUSBProbeState(_ probeState: USBProbeState) {
        switch probeState {
        case .failed(let message):
            DiagnosticsLog.shared.log("usb", "wired attempt failed: \(message)")
            DiagnosticsLog.shared.log("report", diagnosticLines().joined(separator: "\n"))
        case .succeeded:
            DiagnosticsLog.shared.log("usb", "wired attempt succeeded")
            DiagnosticsLog.shared.log("report", diagnosticLines().joined(separator: "\n"))
        case .cancelled:
            DiagnosticsLog.shared.log("usb", "wired attempt cancelled")
        case .idle, .running:
            break
        }
    }

    private func handleUSBProbeStage(_ stage: AOAModeSwitchStage) {
        usbProbeDiagnostics.record(stage)
        switch stage {
        case .registrySummary, .libusbLog:
            DiagnosticsLog.shared.log("usb", stage.logDetail)
        default:
            DiagnosticsLog.shared.log("usb", "\(usbProbeDiagnostics.status) | \(stage.logDetail)")
        }
        if case .libusbLog = stage {
            return
        }
        usbProbeState = .running(usbProbeDiagnostics.status)
    }

    private func installAapTransport(connection: ByteStreamConnection) {
        activeConnection = connection
        let transport = AapTransport(
            connection: connection,
            handshakeProfile: connection is USBAccessoryConnection ? .wired : .network
        )
        transport.delegate = self
        aapTransport = transport
    }

    private func cleanupUSBResources() async {
        let host = usbHost
        usbHost = nil
        usbAccessoryConnection = nil
        activeConnection = nil
        await host?.stop()
    }

    private func updateStatus(_ status: String) {
        statusDetail = status
        print("ConnectionManager: status = \(status)")
        DiagnosticsLog.shared.log("status", status)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.connectionManager(self, didUpdateStatus: status)
        }
    }

    private func scheduleReconnectIfNeeded(reason: String) {
        guard ProjectionSettings.autoReconnect else { return }
        guard !isUserInitiatedDisconnect else { return }
        guard reconnectWorkItem == nil else { return }

        updateStatus("\(reason). Reconnecting soon...")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.reconnectWorkItem = nil
            switch self.state {
            case .disconnected, .error:
                self.startDiscovery()
            default:
                break
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: workItem)
    }

    private func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        while let addr = current {
            defer { current = addr.pointee.ifa_next }

            let name = String(cString: addr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            guard addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr.pointee.ifa_addr,
                socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                return String(cString: hostname)
            }
        }

        return nil
    }

    private func currentAudioOutputDescription() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else {
            return "None"
        }
        return outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    }
}

extension ConnectionManager: DiscoveryDelegate {
    func discoveryDidFindDevice(_ device: DiscoveredDevice) {
        DiagnosticsLog.shared.log("net", "discovery found \(device.ip):\(device.port)")
        if device.port == Discovery.launcherPort {
            print("ConnectionManager: triggered wireless helper launcher at \(device.ip):\(device.port)")
            hasTriggeredWirelessHelper = true
            updateStatus("Wireless Helper triggered at \(device.ip). Waiting for phone...")
            return
        }

        print("ConnectionManager: discovered device: \(device.displayName)")
        discoveredDevices.append(device)
        updateStatus("Found Headunit Server at \(device.ip):\(device.port)")
        delegate?.connectionManager(self, didDiscoverDevice: device)
    }

    func discoveryDidFinish() {
        print("ConnectionManager: discovery finished, found \(discoveredDevices.count) devices")
        DiagnosticsLog.shared.log("net", "discovery finished: \(discoveredDevices.count) headunit server(s), helper triggered \(hasTriggeredWirelessHelper ? "yes" : "no")")
        if state == .discovering {
            if !discoveredDevices.isEmpty {
                state = .disconnected
                let suffix = discoveredDevices.count == 1 ? "" : "s"
                updateStatus("Found \(discoveredDevices.count) Headunit Server\(suffix)")
                return
            }

            switch ProjectionSettings.connectionMode {
            case .wirelessHelper:
                state = .waitingForWirelessHelper
                updateStatus(hasTriggeredWirelessHelper ? "Waiting for Wireless Helper to connect..." : "Listening on 5288. Open Wireless Helper on the phone.")
            case .auto where wirelessHelperServer.isRunning:
                state = .waitingForWirelessHelper
                updateStatus(hasTriggeredWirelessHelper ? "Waiting for Wireless Helper to connect..." : "No direct server found. Waiting for Wireless Helper on 5288.")
            case .auto, .directHeadunit:
                state = .disconnected
                updateStatus("No devices found")
                scheduleReconnectIfNeeded(reason: "Scan finished")
            }
        }
    }

    func discoveryDidFail(_ error: Error) {
        print("ConnectionManager: discovery failed with error: \(error.localizedDescription)")
        DiagnosticsLog.shared.log("error", "discovery failed: \(DiagnosticsLog.describe(error))")
        state = .error(error.localizedDescription)
        updateStatus(error.localizedDescription)
        scheduleReconnectIfNeeded(reason: "Discovery failed")
    }
}

extension ConnectionManager: AapTransportDelegate {
    func aapTransport(_ transport: AapTransport, didRequestMicrophoneCapture isOpen: Bool) {
        if isOpen {
            microphoneCapture.start(sampleRate: 16_000, channels: 1)
        } else {
            microphoneCapture.stop()
        }
    }

    func aapTransport(_ transport: AapTransport, didRequestLocationUpdates isEnabled: Bool) {
        if isEnabled {
            locationCapture.start()
        } else {
            locationCapture.stop()
        }
    }

    func aapTransport(_ transport: AapTransport, didReceiveVideoData data: Data) {
        delegate?.connectionManager(self, didReceiveVideoData: data)
    }

    func aapTransport(_ transport: AapTransport, didReceiveAudioData data: Data, on channel: UInt8) {
        delegate?.connectionManager(self, didReceiveAudioData: data, on: channel)
    }

    func aapTransport(_ transport: AapTransport, didReceiveMediaMetadata metadata: AapMediaMetadata) {
        hasReceivedAaMediaMetadata = true
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = metadata.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artwork = metadata.albumArt.flatMap { UIImage(data: $0) }

        NowPlayingCoordinator.shared.updateMetadata(
            NowPlayingMetadata(
                title: title?.isEmpty == false ? title! : "Android Auto",
                artist: artist?.isEmpty == false ? artist! : "Unknown Artist",
                album: album?.isEmpty == false ? album! : "Projection",
                durationSeconds: metadata.durationSeconds,
                artworkImage: artwork
            )
        )
    }

    func aapTransport(_ transport: AapTransport, didReceivePlaybackStatus status: AapPlaybackStatus) {
        let isPlaying = status.state != .paused && status.state != .stopped
        if !hasReceivedAaMediaMetadata,
           let source = status.mediaSource?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty {
            NowPlayingCoordinator.shared.updateMetadata(
                NowPlayingMetadata(
                    title: source,
                    artist: "Android Auto",
                    album: "Projection",
                    durationSeconds: nil,
                    artworkImage: nil
                )
            )
        }
        NowPlayingCoordinator.shared.updatePlaybackState(
            NowPlayingPlaybackState(
                isPlaying: isPlaying,
                elapsedSeconds: status.playbackSeconds ?? 0
            )
        )
    }

    func aapTransport(_ transport: AapTransport, didChangeState state: AapTransportState) {
        guard transport === aapTransport else { return }
        switch state {
        case .running:
            NowPlayingCoordinator.shared.activate()
            self.state = .running
            if usbAccessoryConnection != nil {
                usbProbeDiagnostics.recordAAPRunning()
                usbProbeState = .succeeded
                updateStatus("Android Auto is running over USB")
            } else {
                updateStatus("Android Auto is running over wireless")
            }
        case .error(let msg):
            DiagnosticsLog.shared.log("error", "AAP transport error: \(msg)")
            NowPlayingCoordinator.shared.deactivate()
            microphoneCapture.stop()
            locationCapture.stop()
            self.state = .error(msg)
            updateStatus(msg)
            if let usbAccessoryConnection {
                usbProbeDiagnostics.record(error: NSError(
                    domain: "HeadunitPad.USB",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                ))
                usbProbeState = .failed(msg)
                usbAccessoryConnection.disconnect()
            } else {
                scheduleReconnectIfNeeded(reason: "Android Auto error")
            }
        case .waitingForVersion, .versionSent:
            updateUSBHandshakeStatus("Negotiating Android Auto version over USB")
        case .tlsHandshaking:
            updateUSBHandshakeStatus("Establishing Android Auto TLS over USB")
        case .authenticating, .authenticatingComplete:
            updateUSBHandshakeStatus("Authenticating Android Auto over USB")
        case .binding:
            updateUSBHandshakeStatus("Binding Android Auto services over USB")
        default:
            break
        }
    }

    func aapTransportDidDisconnect(_ transport: AapTransport) {
        guard transport === aapTransport else { return }
        let wasUSB = usbAccessoryConnection != nil
        DiagnosticsLog.shared.log("aap", "transport disconnected (\(wasUSB ? "USB" : "network"), reached running: \(transport.didReachRunning ? "yes" : "no"), user initiated: \(isUserInitiatedDisconnect ? "yes" : "no"))")
        if transport.didReachRunning {
            lastSessionTeardownLines = transport.teardownDiagnosticLines()
            DiagnosticsLog.shared.log("aap", lastSessionTeardownLines.joined(separator: "\n"))
        }
        DiagnosticsLog.shared.log("video", transport.videoDiagnosticLines().joined(separator: "\n"))
        if let usbAccessoryConnection {
            usbProbeDiagnostics.recordAAPVideoDiagnostics(transport.videoDiagnosticLines())
            usbProbeDiagnostics.recordStaleDrain(
                bytes: usbAccessoryConnection.drainedStaleBytes,
                ranOutOfBudget: usbAccessoryConnection.staleDrainRanOutOfBudget
            )
        }
        aapTransport = nil
        NowPlayingCoordinator.shared.deactivate()
        microphoneCapture.stop()
        locationCapture.stop()
        if wasUSB {
            usbAccessoryConnection?.disconnect()
            let finalProbeState: USBProbeState
            if isUserInitiatedDisconnect {
                finalProbeState = .cancelled
            } else if case .failed = usbProbeState {
                finalProbeState = usbProbeState
            } else {
                let message: String
                if case .succeeded = usbProbeState {
                    message = "The USB device disconnected."
                } else if usbProbeDiagnostics.didRestartExistingAccessory,
                          !usbProbeDiagnostics.didObserveAccessoryDetach {
                    // The phone never let go of the accessory, so it never armed a
                    // new session. Nothing here can force it; say what will.
                    message = "The phone is still holding its previous Android Auto session. Unplug the USB cable and plug it back in."
                } else {
                    message = "The wired Android Auto session disconnected before reaching running."
                }
                usbProbeDiagnostics.record(error: NSError(
                    domain: "HeadunitPad.USB",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
                finalProbeState = .failed(message)
            }
            state = .disconnecting
            updateStatus("Releasing wired USB resources...")
            let cleanupTask = Task { [weak self] in
                guard let self else { return }
                await self.cleanupUSBResources()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.usbCleanupTask = nil
                    self.installAapTransport(connection: self.tcpHandler)
                    self.connectedDevice = nil
                    switch finalProbeState {
                    case .cancelled:
                        self.state = .disconnected
                        self.updateStatus("Ready to connect")
                    case .failed(let message):
                        self.state = .error(message)
                        self.updateStatus(message)
                    default:
                        self.state = .disconnected
                        self.updateStatus("Wired Android Auto disconnected")
                    }
                    self.usbProbeState = finalProbeState
                }
            }
            usbCleanupTask = cleanupTask
            return
        }
        connectedDevice = nil
        state = .disconnected
        updateStatus("Android Auto disconnected")
        scheduleReconnectIfNeeded(reason: "Android Auto disconnected")
    }

    private func updateUSBHandshakeStatus(_ status: String) {
        guard usbAccessoryConnection != nil else { return }
        usbProbeDiagnostics.recordAAPHandshaking(status)
        usbProbeState = .running(status)
        state = .handshaking
        updateStatus(status)
    }
}

extension ConnectionManager: WirelessHelperServerDelegate {
    func wirelessHelperServer(_ server: WirelessHelperServer, didAccept connection: NWConnection, remoteHost: String?) {
        let canAccept: Bool
        switch state {
        case .discovering, .waitingForWirelessHelper, .disconnected, .error:
            canAccept = true
        case .connecting, .handshaking, .running, .disconnecting:
            canAccept = false
        }

        DiagnosticsLog.shared.log("net", "wireless helper connection from \(remoteHost ?? "unknown") (\(canAccept ? "accepted" : "dropped") in state \(state.description))")
        guard canAccept else {
            print("ConnectionManager: dropping inbound wireless helper connection while state=\(state.description)")
            connection.cancel()
            return
        }

        discovery.stopScan()
        state = .connecting

        let host = remoteHost ?? "Wireless Helper"
        connectedDevice = DiscoveredDevice(ip: host, port: WirelessHelperServer.port, name: "Wireless Helper")
        updateStatus("Wireless Helper connected. Starting Android Auto...")
        installAapTransport(connection: tcpHandler)
        aapTransport?.configurePeer(host: host, port: WirelessHelperServer.port)
        tcpHandler.acceptConnection(connection, host: host, port: WirelessHelperServer.port)
    }

    func wirelessHelperServer(_ server: WirelessHelperServer, didFail error: Error) {
        print("ConnectionManager: wireless helper server failed with error: \(error.localizedDescription)")
        DiagnosticsLog.shared.log("error", "wireless helper listener failed: \(DiagnosticsLog.describe(error))")
        if state == .discovering {
            state = .error(error.localizedDescription)
            updateStatus(error.localizedDescription)
            scheduleReconnectIfNeeded(reason: "Wireless Helper listener failed")
        }
    }
}
