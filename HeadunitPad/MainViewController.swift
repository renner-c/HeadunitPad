//
//  MainViewController.swift
//  HeadunitPad
//
//  Main screen with connection controls
//

import UIKit
import AVFoundation
import CoreLocation

class MainViewController: UIViewController {

    // MARK: - Properties

    private let connectionManager = ConnectionManager()
    private let videoRenderer = H264VideoRendererView()
    private let audioPlayer = PCMAudioPlayer()
    private let locationPermissionManager = CLLocationManager()
    private var videoWatchdogTimer: Timer?
    private var runningSinceTs: TimeInterval = 0
    private var lastVideoFrameTs: TimeInterval = 0
    private var hasReceivedFirstVideoFrame = false
    private var lastVideoRecoveryTs: TimeInterval = 0
    private var wasRunning = false

    // MARK: - UI Components

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "HeadunitPad"
        label.font = .systemFont(ofSize: 48, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let videoContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let touchOverlayView: TouchInputView = {
        let view = TouchInputView()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = "Android Auto for iPad"
        label.font = .systemFont(ofSize: 20, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private static let wiredConnectTitle = "Wired: Connect via USB"

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Ready to connect"
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var connectButton: UIButton = {
        let button = HeadunitButton(style: .filled, size: .large, title: "Wireless: Scan for Devices", systemImageName: "wifi")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(connectButtonTapped), for: .touchUpInside)
        return button
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private lazy var settingsButton: UIButton = {
        let button = HeadunitButton(style: .overlay, systemImageName: "gearshape.fill")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(settingsButtonTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    private lazy var manualIPButton: UIButton = {
        let button = HeadunitButton(style: .tinted, title: "Wireless: Enter IP Manually", systemImageName: "keyboard")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(manualIPButtonTapped), for: .touchUpInside)
        return button
    }()

    private lazy var usbProbeButton: UIButton = {
        let button = HeadunitButton(style: .tinted, title: Self.wiredConnectTitle, systemImageNames: ["cable.connector", "bolt.horizontal"])
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(usbProbeButtonTapped), for: .touchUpInside)
        return button
    }()

    private lazy var disconnectButton: UIButton = {
        let button = HeadunitButton(style: .filled, size: .large, title: "Disconnect", accent: .systemRed)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(disconnectButtonTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupConstraints()
        connectionManager.delegate = self
        videoRenderer.onFrameDisplayed = { [weak self] in
            guard let self else { return }
            if !self.hasReceivedFirstVideoFrame {
                DiagnosticsLog.shared.log("video", "first frame displayed by the renderer")
            }
            self.hasReceivedFirstVideoFrame = true
            self.lastVideoFrameTs = Date().timeIntervalSince1970
        }
        TrackpadInputBridge.shared.setTouchSender { [weak self] pointers, action, actionIndex in
            self?.connectionManager.sendTouchEvent(pointers: pointers, action: action, actionIndex: actionIndex)
        }
        requestMicrophonePermissionIfNeeded()
        connectionManager.requestLocationPermissionIfNeeded()
        updateUIForConnectionState(.disconnected)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyOrientationLock()
    }

    override var shouldAutorotate: Bool {
        if #available(iOS 16.0, *) { return false }
        // Before iOS 16 the supportedInterfaceOrientations mask does the locking, and rotation
        // (including the forced one in applyOrientationLock) only happens while this is true.
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch ProjectionSettings.orientation {
        case .landscape:
            return .landscape
        case .portrait:
            return .portrait
        }
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        switch ProjectionSettings.orientation {
        case .landscape:
            return .landscapeRight
        case .portrait:
            return .portrait
        }
    }

    private func applyOrientationLock() {
        touchOverlayView.isMultipleTouchEnabled = true

        let targetMask = supportedInterfaceOrientations
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            guard let scene = view.window?.windowScene else { return }
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetMask)
            scene.requestGeometryUpdate(prefs) { error in
                print("MainViewController: Failed to apply orientation lock: \(error)")
            }
        } else {
            // Best effort: before iOS 16, iPadOS ignores the orientation mask for apps that support
            // multitasking (UIRequiresFullScreen = NO), so this may do nothing. Only nudge when the
            // current orientation is outside the mask, so landscape-left is never flipped 180 degrees.
            let current = view.window?.windowScene?.interfaceOrientation
            guard let target = InterfaceOrientationPolicy.orientationToForce(
                current: current,
                device: UIDevice.current.orientation,
                allowed: targetMask,
                fallback: preferredInterfaceOrientationForPresentation
            ) else { return }
            // KVC "orientation" is fed the interface orientation's raw value (the usual "rotate to this" idiom).
            UIDevice.current.setValue(target.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func requestMicrophonePermissionIfNeeded() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                print("MainViewController: Microphone permission granted=\(granted)")
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                print("MainViewController: Microphone permission granted=\(granted)")
            }
        }
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        videoContainerView.addSubview(videoRenderer)
        videoContainerView.addSubview(touchOverlayView)
        videoRenderer.translatesAutoresizingMaskIntoConstraints = false
        touchOverlayView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(videoContainerView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(statusLabel)
        view.addSubview(connectButton)
        view.addSubview(activityIndicator)
        view.addSubview(settingsButton)
        view.addSubview(manualIPButton)
        view.addSubview(usbProbeButton)
        view.addSubview(disconnectButton)

        NSLayoutConstraint.activate([
            videoRenderer.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            videoRenderer.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            videoRenderer.topAnchor.constraint(equalTo: videoContainerView.topAnchor),
            videoRenderer.bottomAnchor.constraint(equalTo: videoContainerView.bottomAnchor),

            touchOverlayView.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            touchOverlayView.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            touchOverlayView.topAnchor.constraint(equalTo: videoContainerView.topAnchor),
            touchOverlayView.bottomAnchor.constraint(equalTo: videoContainerView.bottomAnchor)
        ])

        touchOverlayView.onTouch = { [weak self] pointers, action, actionIndex in
            guard let self = self else { return }
            var mappedPointers: [(id: Int, x: Int, y: Int)] = []
            for pointer in pointers {
                let mapped = self.mapTouchPointToAa(pointer.point)
                mappedPointers.append((id: pointer.id, x: mapped.x, y: mapped.y))
            }

            if action == .DOWN || action == .UP || action == .POINTER_DOWN || action == .POINTER_UP || action == .CANCEL {
                print("MainViewController: Touch action=\(action) pointers=\(mappedPointers.count) actionIndex=\(actionIndex)")
            }

            self.connectionManager.sendTouchEvent(pointers: mappedPointers, action: action, actionIndex: actionIndex)
        }

        videoContainerView.isHidden = true
    }

    /// Wide enough that the Wired and Wireless labels stay on one line (HeadunitButton shrinks longer titles).
    private let connectControlWidth: CGFloat = 340

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            videoContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            videoContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Title
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 100),

            // Subtitle
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),

            // Status
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 32),

            // Connect Button
            connectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 48),
            connectButton.widthAnchor.constraint(equalToConstant: connectControlWidth),

            // Manual IP Button
            manualIPButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            manualIPButton.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 16),
            manualIPButton.widthAnchor.constraint(equalToConstant: connectControlWidth),

            // Wired USB Probe Button
            usbProbeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            usbProbeButton.topAnchor.constraint(equalTo: manualIPButton.bottomAnchor, constant: 12),
            usbProbeButton.widthAnchor.constraint(equalToConstant: connectControlWidth),

            // Disconnect Button
            disconnectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            disconnectButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 48),
            disconnectButton.widthAnchor.constraint(equalToConstant: 200),

            // Activity Indicator
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: usbProbeButton.bottomAnchor, constant: 24),

            // Settings Button
            settingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
    }

    // MARK: - UI Updates

    private func updateUIForConnectionState(_ state: ConnectionState) {
        switch state {
        case .disconnected:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            videoRenderer.reset()
            audioPlayer.reset()
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = connectionManager.statusDetail
            statusLabel.textColor = .tertiaryLabel
            connectButton.isHidden = false
            connectButton.isEnabled = true
            updateConnectButtonTitle()
            manualIPButton.isHidden = false
            usbProbeButton.isHidden = false
            disconnectButton.isHidden = true
            activityIndicator.stopAnimating()

        case .discovering:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = connectionManager.statusDetail
            statusLabel.textColor = .secondaryLabel
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            usbProbeButton.isHidden = true
            disconnectButton.isHidden = true
            activityIndicator.startAnimating()

        case .waitingForWirelessHelper:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = connectionManager.statusDetail
            statusLabel.textColor = .secondaryLabel
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            usbProbeButton.isHidden = true
            disconnectButton.isHidden = false
            activityIndicator.startAnimating()

        case .connecting:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = connectionManager.statusDetail
            statusLabel.textColor = .secondaryLabel
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            usbProbeButton.isHidden = !connectionManager.usbProbeState.isRunning
            disconnectButton.isHidden = true
            activityIndicator.startAnimating()

        case .handshaking:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = connectionManager.statusDetail
            statusLabel.textColor = .systemBlue
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            usbProbeButton.isHidden = true
            disconnectButton.isHidden = false
            activityIndicator.startAnimating()

        case .running:
            startVideoWatchdog()
            videoContainerView.isHidden = false
            settingsButton.isHidden = false
            titleLabel.isHidden = true
            subtitleLabel.isHidden = true
            statusLabel.isHidden = true
            statusLabel.text = "Connected to \(connectionManager.connectedDevice?.displayName ?? "device")"
            statusLabel.textColor = .systemGreen
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            usbProbeButton.isHidden = true
            disconnectButton.isHidden = true
            activityIndicator.stopAnimating()

        case .disconnecting:
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            audioPlayer.reset()
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = connectionManager.statusDetail
            statusLabel.textColor = .secondaryLabel
            connectButton.isHidden = true
            manualIPButton.isHidden = true
            usbProbeButton.isHidden = true
            disconnectButton.isHidden = true
            activityIndicator.startAnimating()

        case .error(let message):
            stopVideoWatchdog()
            videoContainerView.isHidden = true
            audioPlayer.reset()
            settingsButton.isHidden = false
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            statusLabel.isHidden = false
            statusLabel.text = connectionManager.statusDetail.isEmpty ? message : connectionManager.statusDetail
            statusLabel.textColor = .systemRed
            connectButton.isHidden = false
            connectButton.isEnabled = true
            updateConnectButtonTitle()
            manualIPButton.isHidden = false
            usbProbeButton.isHidden = false
            disconnectButton.isHidden = true
            activityIndicator.stopAnimating()
        }
    }

    /// The connection mode setting only selects between wireless strategies, so
    /// every title here stays under the Wireless label. The wired path has its own
    /// button and does not participate in the mode.
    private func updateConnectButtonTitle() {
        let title: String
        switch ProjectionSettings.connectionMode {
        case .auto:
            title = "Wireless: Auto Connect"
        case .wirelessHelper:
            title = "Wireless: Start Helper"
        case .directHeadunit:
            title = "Wireless: Scan Headunit"
        }
        connectButton.setTitle(title, for: .normal)
    }

    private func startVideoWatchdog() {
        if videoWatchdogTimer != nil {
            return
        }

        runningSinceTs = Date().timeIntervalSince1970
        lastVideoFrameTs = 0
        hasReceivedFirstVideoFrame = false
        lastVideoRecoveryTs = 0

        videoWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkVideoWatchdog()
        }
    }

    private func stopVideoWatchdog() {
        videoWatchdogTimer?.invalidate()
        videoWatchdogTimer = nil
        runningSinceTs = 0
        lastVideoFrameTs = 0
        hasReceivedFirstVideoFrame = false
        lastVideoRecoveryTs = 0
    }

    private func checkVideoWatchdog() {
        guard connectionManager.state == .running else {
            return
        }

        let now = Date().timeIntervalSince1970
        if !hasReceivedFirstVideoFrame {
            if now - runningSinceTs > 3.0, now - lastVideoRecoveryTs > 1.5 {
                lastVideoRecoveryTs = now
                print("MainViewController: Video watchdog requesting first-frame recovery")
                connectionManager.requestVideoRecovery()
            }
            return
        }

        if now - lastVideoFrameTs > 6.0, now - lastVideoRecoveryTs > 2.0 {
            lastVideoRecoveryTs = now
            print("MainViewController: Video watchdog detected frame stall, requesting recovery")
            connectionManager.requestVideoRecovery()
        }
    }

    // MARK: - Actions

    @objc private func connectButtonTapped() {
        connectionManager.startDiscovery()
    }

    @objc private func manualIPButtonTapped() {
        let alert = UIAlertController(title: "Enter IP Address",
                                      message: "Enter the IP address of your Android phone or headunit server",
                                      preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "192.168.0.189"
            textField.keyboardType = .decimalPad
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            guard let ip = alert.textFields?.first?.text, !ip.isEmpty else { return }
            self?.connectionManager.connect(to: ip, port: Discovery.headunitPort)
        })

        present(alert, animated: true)
    }

    @objc private func usbProbeButtonTapped() {
        if connectionManager.usbProbeState.isRunning {
            connectionManager.stopUSBProbe()
            return
        }
        guard case .missing = USBHostEntitlements.current() else {
            connectionManager.startUSBProbe()
            return
        }
        presentMissingUSBEntitlementsAlert()
    }

    /// Without the entitlements libusb simply enumerates nothing, which reads as
    /// "no phone attached" and sends people looking for a cable fault they do not
    /// have. Say what is actually wrong instead of starting a doomed attempt.
    private func presentMissingUSBEntitlementsAlert() {
        let alert = UIAlertController(
            title: "Wired USB Needs TrollStore",
            message: "This copy of HeadunitPad was installed without the USB Host "
                + "entitlements, so it cannot talk to the phone over the cable. "
                + "Install the TrollStore IPA to use the wired connection. "
                + "Wireless Android Auto works either way.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func disconnectButtonTapped() {
        connectionManager.disconnect()
    }

    @objc private func settingsButtonTapped() {
        presentSettingsMenu()
    }

    private func presentSettingsMenu() {
        let orientation = ProjectionSettings.orientation.title
        let resolution = ProjectionSettings.videoResolution.title(for: ProjectionSettings.orientation)
        let fps = ProjectionSettings.fpsLimit.title
        let effectiveFps = ProjectionSettings.effectiveFpsLimit.title
        let gpsSource = ProjectionSettings.gpsSource.title
        let dpi = ProjectionSettings.dpi
        let effectiveDpi = ProjectionSettings.effectiveDpi
        let connectionMode = ProjectionSettings.connectionMode.title
        let autoReconnect = ProjectionSettings.autoReconnect ? "On" : "Off"

        let alert = UIAlertController(
            title: "Settings",
            message: "Changes apply on next connection.\nMode: \(connectionMode)\nAuto reconnect: \(autoReconnect)\nOrientation: \(orientation)\nResolution: \(resolution)\nFPS: \(fps)\(fps != effectiveFps ? " (effective: \(effectiveFps))" : "")\nDPI: \(dpi)\(dpi != effectiveDpi ? " (effective: \(effectiveDpi))" : "")\nGPS: \(gpsSource)",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Connection Mode", style: .default) { [weak self] _ in
            self?.presentConnectionModeMenu()
        })

        let autoReconnectTitle = ProjectionSettings.autoReconnect ? "Auto Reconnect: On" : "Auto Reconnect: Off"
        alert.addAction(UIAlertAction(title: autoReconnectTitle, style: .default) { [weak self] _ in
            ProjectionSettings.autoReconnect.toggle()
            self?.updateConnectButtonTitle()
            self?.presentSettingsMenu()
        })

        alert.addAction(UIAlertAction(title: "Orientation", style: .default) { [weak self] _ in
            self?.presentOrientationMenu()
        })

        alert.addAction(UIAlertAction(title: "Resolution", style: .default) { [weak self] _ in
            self?.presentResolutionMenu()
        })

        alert.addAction(UIAlertAction(title: "FPS", style: .default) { [weak self] _ in
            self?.presentFpsMenu()
        })

        alert.addAction(UIAlertAction(title: "DPI", style: .default) { [weak self] _ in
            self?.presentDpiMenu()
        })

        let gpsAction = UIAlertAction(title: "GPS Source", style: .default) { [weak self] _ in
            self?.presentGpsMenu()
        }
        gpsAction.isEnabled = ProjectionSettings.supportsCellularIpad()
        alert.addAction(gpsAction)

        alert.addAction(UIAlertAction(title: "Diagnostics", style: .default) { [weak self] _ in
            self?.presentDiagnostics()
        })

        if !ProjectionSettings.supportsCellularIpad() {
            alert.addAction(UIAlertAction(title: "GPS Source: Phone only (non-cellular iPad)", style: .default))
        }

        if connectionManager.state == .running {
            alert.addAction(UIAlertAction(title: "Connection Details", style: .default) { [weak self] _ in
                self?.presentConnectionDetails()
            })
            alert.addAction(UIAlertAction(title: "Open Video-Only Window", style: .default) { [weak self] _ in
                self?.openVideoOnlyWindow()
            })
            alert.addAction(UIAlertAction(title: "Open Trackpad Window", style: .default) { [weak self] _ in
                self?.openTrackpadWindow()
            })
            alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in
                self?.connectionManager.disconnect()
            })
        }

        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentConnectionModeMenu() {
        let alert = UIAlertController(title: "Connection Mode", message: nil, preferredStyle: .actionSheet)

        for option in [ProjectionConnectionMode.auto, .wirelessHelper, .directHeadunit] {
            let title = option == ProjectionSettings.connectionMode ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                ProjectionSettings.connectionMode = option
                self?.updateConnectButtonTitle()
                self?.updateUIForConnectionState(self?.connectionManager.state ?? .disconnected)
                self?.presentSettingsMenu()
            })
        }

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentResolutionMenu() {
        let alert = UIAlertController(title: "Resolution", message: nil, preferredStyle: .actionSheet)

        let orientation = ProjectionSettings.orientation
        let options = ProjectionSettings.availableResolutions(for: orientation)

        for option in options {
            let optionTitle = option.title(for: orientation)
            let title = option == ProjectionSettings.videoResolution ? "\(optionTitle) (Current)" : optionTitle
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                ProjectionSettings.videoResolution = option
                self?.presentSettingsMenu()
            })
        }

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentOrientationMenu() {
        let alert = UIAlertController(title: "Orientation", message: nil, preferredStyle: .actionSheet)

        for option in [ProjectionOrientation.landscape, .portrait] {
            let title = option == ProjectionSettings.orientation ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                ProjectionSettings.orientation = option
                self?.applyOrientationLock()
                self?.presentSettingsMenu()
            })
        }

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentFpsMenu() {
        let alert = UIAlertController(title: "FPS", message: nil, preferredStyle: .actionSheet)

        for option in [ProjectionFpsLimit.fps30, .fps60] {
            let title = option == ProjectionSettings.fpsLimit ? "\(option.title) (Current)" : option.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                ProjectionSettings.fpsLimit = option
                self?.presentSettingsMenu()
            })
        }

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentDpiMenu() {
        let alert = UIAlertController(
            title: "DPI",
            message: "Enter custom DPI (\(ProjectionSettings.minDpi)-\(ProjectionSettings.maxDpi)).",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.keyboardType = .numberPad
            textField.placeholder = "\(ProjectionSettings.defaultDpi)"
            textField.text = "\(ProjectionSettings.dpi)"
        }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let raw = alert?.textFields?.first?.text,
                  let value = Int(raw) else {
                self?.presentSettingsMenu()
                return
            }

            ProjectionSettings.dpi = value
            self?.presentSettingsMenu()
        })

        alert.addAction(UIAlertAction(title: "Reset Default", style: .destructive) { [weak self] _ in
            ProjectionSettings.resetDpiToDefault()
            self?.presentSettingsMenu()
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        present(alert, animated: true)
    }

    private func presentGpsMenu() {
        let alert = UIAlertController(title: "GPS Source", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: ProjectionGpsSource.phone == ProjectionSettings.gpsSource ? "Use Phone GPS (Current)" : "Use Phone GPS", style: .default) { [weak self] _ in
            ProjectionSettings.gpsSource = .phone
            self?.presentSettingsMenu()
        })

        let ipadActionTitle = ProjectionGpsSource.ipad == ProjectionSettings.gpsSource ? "Use iPad GPS (Current)" : "Use iPad GPS"
        let ipadAction = UIAlertAction(title: ipadActionTitle, style: .default) { [weak self] _ in
            ProjectionSettings.gpsSource = .ipad
            self?.locationPermissionManager.requestWhenInUseAuthorization()
            self?.connectionManager.requestLocationPermissionIfNeeded()
            self?.presentSettingsMenu()
        }
        ipadAction.isEnabled = ProjectionSettings.supportsCellularIpad()
        alert.addAction(ipadAction)

        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.presentSettingsMenu()
        })

        configurePopoverSource(for: alert)
        present(alert, animated: true)
    }

    private func presentConnectionDetails() {
        let device = connectionManager.connectedDevice
        let details = [
            "State: \(connectionManager.state.description)",
            "Status: \(connectionManager.statusDetail)",
            "Device: \(device?.displayName ?? "Unknown")",
            "IP: \(device?.ip ?? "Unknown")",
            "Port: \(device?.port ?? 0)"
        ].joined(separator: "\n")

        let alert = UIAlertController(title: "Connection", message: details, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    private func presentDiagnostics() {
        let alert = UIAlertController(
            title: "Diagnostics",
            message: combinedDiagnosticLines().joined(separator: "\n"),
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { [weak self] _ in
            UIPasteboard.general.string = self?.combinedDiagnosticLines().joined(separator: "\n")
        })
        alert.addAction(UIAlertAction(title: "Share Log File", style: .default) { [weak self] _ in
            self?.shareDiagnosticsLog()
        })
        present(alert, animated: true)
    }

    /// The persistent trail written by DiagnosticsLog, newest file first. It is
    /// also reachable from the Files app and over SSH; this is the quick route.
    private func shareDiagnosticsLog() {
        let log = DiagnosticsLog.shared
        log.flush()
        let items: [URL] = [log.logURL, log.rotatedURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty else { return }

        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = settingsButton
            popover.sourceRect = settingsButton.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        present(activity, animated: true)
    }

    private func updateUSBProbeUI(_ state: USBProbeState) {
        switch state {
        case .idle:
            usbProbeButton.setTitle(Self.wiredConnectTitle, for: .normal)
        case .running(let status):
            usbProbeButton.setTitle("Cancel Wired Connection", for: .normal)
            connectButton.isEnabled = false
            manualIPButton.isEnabled = false
            statusLabel.text = status
            statusLabel.textColor = .systemBlue
            activityIndicator.startAnimating()
        case .succeeded:
            // No alert on success: the video has just appeared and an alert would
            // cover it. Settings > Diagnostics still has the full report.
            finishUSBProbeUI(status: "Android Auto is running over USB", color: .systemGreen)
        case .failed(let message):
            finishUSBProbeUI(status: message, color: .systemRed)
            presentUSBProbeResult(title: "Wired Connection Failed")
        case .cancelled:
            finishUSBProbeUI(status: "Wired connection cancelled", color: .secondaryLabel)
        }
    }

    private func finishUSBProbeUI(status: String, color: UIColor) {
        usbProbeButton.setTitle(Self.wiredConnectTitle, for: .normal)
        connectButton.isEnabled = true
        manualIPButton.isEnabled = true
        statusLabel.text = status
        statusLabel.textColor = color
        activityIndicator.stopAnimating()
    }

    private func presentUSBProbeResult(title: String) {
        let details = combinedDiagnosticLines().joined(separator: "\n")
        let alert = UIAlertController(title: title, message: details, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Copy Diagnostics", style: .default) { [weak self] _ in
            UIPasteboard.general.string = self?.combinedDiagnosticLines().joined(separator: "\n")
        })
        alert.addAction(UIAlertAction(title: "Share Log File", style: .default) { [weak self] _ in
            self?.shareDiagnosticsLog()
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    private func combinedDiagnosticLines() -> [String] {
        connectionManager.diagnosticLines()
            + [""]
            + videoRenderer.diagnosticLines()
            + ["", "Diagnostics log: \(DiagnosticsLog.shared.logURL.path)"]
    }

    private func configurePopoverSource(for alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = settingsButton
            popover.sourceRect = settingsButton.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
    }

    private func openVideoOnlyWindow() {
        let activity = NSUserActivity(activityType: AppDelegate.videoOnlyWindowActivityType)
        activity.title = "HeadunitPad Video Only"
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { error in
            print("MainViewController: Failed to open video-only window: \(error)")
        }
        connectionManager.requestVideoRecoveryForNewDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.connectionManager.requestVideoRecoveryForNewDisplay()
        }
    }

    private func openTrackpadWindow() {
        let activity = NSUserActivity(activityType: AppDelegate.trackpadWindowActivityType)
        activity.title = "HeadunitPad Trackpad"
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { error in
            print("MainViewController: Failed to open trackpad window: \(error)")
        }
    }

    private func mapTouchPointToAa(_ point: CGPoint) -> (x: Int, y: Int) {
        let targetSize = ProjectionSettings.effectiveVideoDimensions
        let width = max(touchOverlayView.bounds.width, 1)
        let height = max(touchOverlayView.bounds.height, 1)

        // Match AVSampleBufferDisplayLayer.resizeAspect: map only inside active video rect.
        let targetAspect = CGFloat(targetSize.width) / CGFloat(targetSize.height)
        let viewAspect = width / height

        let activeRect: CGRect
        if viewAspect > targetAspect {
            let contentWidth = height * targetAspect
            let x = (width - contentWidth) / 2
            activeRect = CGRect(x: x, y: 0, width: contentWidth, height: height)
        } else {
            let contentHeight = width / targetAspect
            let y = (height - contentHeight) / 2
            activeRect = CGRect(x: 0, y: y, width: width, height: contentHeight)
        }

        let clampedX = min(max(point.x, activeRect.minX), activeRect.maxX)
        let clampedY = min(max(point.y, activeRect.minY), activeRect.maxY)

        let nx = (clampedX - activeRect.minX) / activeRect.width
        let ny = (clampedY - activeRect.minY) / activeRect.height

        let x = Int(nx * CGFloat(targetSize.width - 1))
        let y = Int(ny * CGFloat(targetSize.height - 1))
        return (x, y)
    }
}

// MARK: - ConnectionManagerDelegate

extension MainViewController: ConnectionManagerDelegate {
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState) {
        if state == .running {
            wasRunning = true
        } else if wasRunning {
            // Snapshot before the .disconnected branch resets the renderer.
            wasRunning = false
            DiagnosticsLog.shared.log(
                "video",
                "renderer snapshot on leaving running (now \(state.description))\n"
                    + videoRenderer.diagnosticLines().joined(separator: "\n")
            )
        }
        updateUIForConnectionState(state)
    }

    func connectionManager(_ manager: ConnectionManager, didUpdateStatus status: String) {
        switch manager.state {
        case .disconnected, .discovering, .waitingForWirelessHelper, .connecting, .handshaking, .disconnecting, .error:
            statusLabel.text = status
        case .running:
            break
        }
    }

    func connectionManager(_ manager: ConnectionManager, didDiscoverDevice device: DiscoveredDevice) {
        if manager.discoveredDevices.count == 1 {
            statusLabel.text = "Found: \(device.displayName)"
            statusLabel.textColor = .systemBlue
        }

        let alert = UIAlertController(title: "Device Found",
                                      message: "Would you like to connect to \(device.displayName)?",
                                      preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            self?.connectionManager.connect(to: device)
        })

        alert.addAction(UIAlertAction(title: "Continue Scanning", style: .cancel))

        present(alert, animated: true)
    }

    func connectionManager(_ manager: ConnectionManager, didReceiveVideoData data: Data) {
        VideoFrameBus.shared.publish(frame: data)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.videoRenderer.enqueueAnnexBFrame(data)
        }
    }

    func connectionManager(_ manager: ConnectionManager, didReceiveAudioData data: Data, on channel: UInt8) {
        audioPlayer.playPCM(data, on: channel)
    }

    func connectionManager(_ manager: ConnectionManager, didChangeUSBProbeState state: USBProbeState) {
        updateUSBProbeUI(state)
    }
}
