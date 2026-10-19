import UIKit

/// Decides whether the pre-iOS-16 orientation fallback needs to force a rotation.
///
/// The goal is to be harmless: if the screen is already in an allowed orientation do nothing
/// (never flip landscape-left to landscape-right), and when a rotation is needed prefer the
/// allowed side that matches how the device is physically held.
enum InterfaceOrientationPolicy {
    /// The interface orientation to force, or nil when nothing should be forced
    /// (already allowed, or the current orientation is unknown).
    static func orientationToForce(
        current: UIInterfaceOrientation?,
        device: UIDeviceOrientation,
        allowed: UIInterfaceOrientationMask,
        fallback: UIInterfaceOrientation
    ) -> UIInterfaceOrientation? {
        guard let current, current != .unknown, !allowed.contains(mask(for: current)) else { return nil }

        // UIDeviceOrientation and UIInterfaceOrientation name the landscape sides oppositely.
        let matchingDevice: UIInterfaceOrientation?
        switch device {
        case .portrait: matchingDevice = .portrait
        case .portraitUpsideDown: matchingDevice = .portraitUpsideDown
        case .landscapeLeft: matchingDevice = .landscapeRight
        case .landscapeRight: matchingDevice = .landscapeLeft
        default: matchingDevice = nil
        }
        if let matchingDevice, allowed.contains(mask(for: matchingDevice)) { return matchingDevice }
        if allowed.contains(mask(for: fallback)) { return fallback }
        let candidates: [UIInterfaceOrientation] = [.portrait, .landscapeRight, .landscapeLeft, .portraitUpsideDown]
        return candidates.first { allowed.contains(mask(for: $0)) }
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        UIInterfaceOrientationMask(rawValue: 1 << UInt(orientation.rawValue))
    }
}
