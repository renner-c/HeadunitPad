import XCTest
import UIKit

@MainActor
final class HeadunitButtonTests: XCTestCase {
    func testTitleCanBeChangedLater() {
        let button = HeadunitButton(style: .tinted, title: "Before", systemImageName: "keyboard")

        button.setTitle("After", for: .normal)

        XCTAssertEqual(button.title(for: .normal), "After")
    }

    func testSymbolIsShownWhenRequestedAndAbsentOtherwise() {
        XCTAssertNotNil(HeadunitButton(style: .filled, title: "Go", systemImageName: "wifi").image(for: .normal))
        XCTAssertNil(HeadunitButton(style: .filled, title: "Go").image(for: .normal))
    }

    func testEveryStyleKeepsA44PointTouchTarget() {
        let buttons = [
            HeadunitButton(style: .overlay, systemImageName: "gearshape.fill"),
            HeadunitButton(style: .tinted, title: "Medium", systemImageName: "keyboard"),
            HeadunitButton(style: .filled, size: .large, title: "Large"),
        ]

        for button in buttons {
            let size = button.intrinsicContentSize
            XCTAssertGreaterThanOrEqual(size.width, 44)
            XCTAssertGreaterThanOrEqual(size.height, 44)
        }
    }

    func testFilledButtonUsesAccentUntilDisabled() {
        let button = HeadunitButton(style: .filled, title: "Disconnect", accent: .systemRed)
        XCTAssertEqual(button.backgroundColor, .systemRed)

        button.isEnabled = false
        XCTAssertNotEqual(button.backgroundColor, .systemRed)

        button.isEnabled = true
        XCTAssertEqual(button.backgroundColor, .systemRed)
    }

    func testOverlayButtonBecomesACapsule() {
        let button = HeadunitButton(style: .overlay, systemImageName: "gearshape.fill")
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)

        button.layoutIfNeeded()

        XCTAssertEqual(button.layer.cornerRadius, 22)
    }
}
