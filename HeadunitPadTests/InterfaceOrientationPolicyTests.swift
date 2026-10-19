import XCTest
import UIKit

final class InterfaceOrientationPolicyTests: XCTestCase {
    private func force(
        current: UIInterfaceOrientation?,
        device: UIDeviceOrientation = .unknown,
        allowed: UIInterfaceOrientationMask,
        fallback: UIInterfaceOrientation
    ) -> UIInterfaceOrientation? {
        InterfaceOrientationPolicy.orientationToForce(current: current, device: device, allowed: allowed, fallback: fallback)
    }

    func testNothingIsForcedWhenCurrentOrientationIsAllowed() {
        // Landscape-left must not be flipped to landscape-right.
        XCTAssertNil(force(current: .landscapeLeft, device: .landscapeRight, allowed: .landscape, fallback: .landscapeRight))
        XCTAssertNil(force(current: .landscapeRight, allowed: .landscape, fallback: .landscapeRight))
        XCTAssertNil(force(current: .portrait, allowed: .portrait, fallback: .portrait))
    }

    func testNothingIsForcedWhenCurrentOrientationIsUnknown() {
        XCTAssertNil(force(current: nil, allowed: .landscape, fallback: .landscapeRight))
        XCTAssertNil(force(current: .unknown, allowed: .landscape, fallback: .landscapeRight))
    }

    func testPortraitToLandscapeFollowsThePhysicalOrientation() {
        // Device landscapeLeft == interface landscapeRight, and vice versa.
        XCTAssertEqual(force(current: .portrait, device: .landscapeLeft, allowed: .landscape, fallback: .landscapeRight), .landscapeRight)
        XCTAssertEqual(force(current: .portrait, device: .landscapeRight, allowed: .landscape, fallback: .landscapeRight), .landscapeLeft)
    }

    func testFallbackIsUsedWhenDeviceOrientationDoesNotHelp() {
        XCTAssertEqual(force(current: .portrait, device: .faceUp, allowed: .landscape, fallback: .landscapeRight), .landscapeRight)
        XCTAssertEqual(force(current: .portrait, device: .portrait, allowed: .landscape, fallback: .landscapeRight), .landscapeRight)
        XCTAssertEqual(force(current: .portrait, device: .unknown, allowed: .landscape, fallback: .landscapeLeft), .landscapeLeft)
    }

    func testLandscapeToPortrait() {
        XCTAssertEqual(force(current: .landscapeLeft, device: .portraitUpsideDown, allowed: [.portrait, .portraitUpsideDown], fallback: .portrait), .portraitUpsideDown)
        XCTAssertEqual(force(current: .landscapeRight, device: .landscapeLeft, allowed: .portrait, fallback: .portrait), .portrait)
    }

    func testForcedOrientationIsAlwaysInsideTheMask() {
        // A fallback outside the mask is ignored in favor of an allowed orientation.
        XCTAssertEqual(force(current: .portrait, allowed: .landscapeLeft, fallback: .landscapeRight), .landscapeLeft)
    }
}
