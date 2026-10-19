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

    // MARK: - Symbol candidates

    func testFirstResolvableSymbolWins() {
        var asked: [String] = []
        let resolved = HeadunitButton.resolveSymbol(from: ["new.only", "old.one", "never.asked"]) { name in
            asked.append(name)
            return name == "new.only" ? nil : UIImage(systemName: "wifi")
        }

        XCTAssertEqual(resolved?.name, "old.one")
        XCTAssertNotNil(resolved?.image)
        XCTAssertEqual(asked, ["new.only", "old.one"], "later candidates must not be looked up once one resolves")
    }

    func testNoCandidateResolvingIsNilSafe() {
        XCTAssertNil(HeadunitButton.resolveSymbol(from: ["a", "b"]) { _ in nil })
        XCTAssertNil(HeadunitButton.resolveSymbol(from: []) { _ in UIImage(systemName: "wifi") })

        let button = HeadunitButton(style: .tinted, title: "Still fine", systemImageNames: ["a", "b"], symbolLookup: { _ in nil })
        XCTAssertNil(button.resolvedSymbolName)
        XCTAssertNil(button.image(for: .normal))
        XCTAssertEqual(button.title(for: .normal), "Still fine")
        XCTAssertGreaterThanOrEqual(button.intrinsicContentSize.height, 44)
    }

    func testButtonFallsBackToTheNextSymbolWhenTheFirstIsMissingOnThisOS() {
        let button = HeadunitButton(
            style: .tinted,
            title: "Wired",
            systemImageNames: ["cable.connector", "bolt.horizontal"],
            symbolLookup: { $0 == "cable.connector" ? nil : UIImage(systemName: $0) }
        )

        XCTAssertEqual(button.resolvedSymbolName, "bolt.horizontal")
        XCTAssertNotNil(button.image(for: .normal))
    }

    func testRealUIImageLookupSkipsUnknownNames() {
        let button = HeadunitButton(style: .filled, systemImageNames: ["definitely.not.a.symbol", "wifi"])

        XCTAssertEqual(button.resolvedSymbolName, "wifi")
        XCTAssertNotNil(button.image(for: .normal))
    }

    // MARK: - Intrinsic size

    private func titleWidth(_ title: String, of button: HeadunitButton) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: button.titleLabel!.font!]).width
    }

    func testIntrinsicWidthIncludesImageSpacingTitleAndInsets() {
        let title = "Wireless: Enter IP Manually"
        let button = HeadunitButton(style: .tinted, title: title, systemImageName: "keyboard", imagePadding: 8)
        let imageWidth = button.image(for: .normal)!.size.width

        // medium insets are 16 left/right, plus the image/title spacing.
        let expected = 16 + imageWidth + 8 + titleWidth(title, of: button) + 16

        XCTAssertEqual(button.intrinsicContentSize.width, expected, accuracy: 2)
    }

    func testIntrinsicWidthOfTitleOnlyAndImageOnlyButtons() {
        let title = "Disconnect"
        let titleOnly = HeadunitButton(style: .filled, size: .large, title: title)
        XCTAssertEqual(titleOnly.intrinsicContentSize.width, 20 + titleWidth(title, of: titleOnly) + 20, accuracy: 2)

        let imageOnly = HeadunitButton(style: .overlay, systemImageName: "gearshape.fill")
        let imageWidth = imageOnly.image(for: .normal)!.size.width
        XCTAssertEqual(imageOnly.intrinsicContentSize.width, max(44, 10 + imageWidth + 10), accuracy: 0.5)
    }

    func testWiderImagePaddingWidensTheButton() {
        let narrow = HeadunitButton(style: .tinted, title: "Same", systemImageNames: ["wifi"], imagePadding: 4)
        let wide = HeadunitButton(style: .tinted, title: "Same", systemImageNames: ["wifi"], imagePadding: 20)

        XCTAssertEqual(wide.intrinsicContentSize.width - narrow.intrinsicContentSize.width, 16, accuracy: 0.5)
    }

    // MARK: - Appearance

    private func rgba(_ color: UIColor?) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    func testTintedButtonUsesTranslucentAccentBackgroundAndAccentTitle() {
        let accent = UIColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        let button = HeadunitButton(style: .tinted, title: "T", accent: accent)

        XCTAssertEqual(rgba(button.backgroundColor), [0, 0.5, 1, 0.15])
        XCTAssertEqual(rgba(button.titleColor(for: .normal)), [0, 0.5, 1, 1])
    }

    func testDisabledAppearanceUsesNeutralColorsForEveryStyleAndRestoresOnEnable() {
        for style in [HeadunitButton.Style.filled, .tinted, .overlay] {
            let button = HeadunitButton(style: style, title: "D", systemImageName: "wifi", accent: .systemRed)
            let enabledBackground = button.backgroundColor

            button.isEnabled = false
            XCTAssertEqual(button.backgroundColor, .tertiarySystemFill)
            XCTAssertEqual(button.titleColor(for: .disabled), .tertiaryLabel)
            XCTAssertNotNil(button.image(for: .disabled))

            button.isEnabled = true
            XCTAssertEqual(button.backgroundColor, enabledBackground)
            XCTAssertEqual(button.titleColor(for: .normal), style == .tinted ? .systemRed : .white)
        }
    }

    func testHighlightDimsAndRestores() {
        let button = HeadunitButton(style: .filled, title: "H")

        button.isHighlighted = true
        XCTAssertEqual(button.alpha, 0.7, accuracy: 0.001)

        button.isHighlighted = false
        XCTAssertEqual(button.alpha, 1, accuracy: 0.001)
    }

    func testHighlightKeepsTheCallersAlpha() {
        let button = HeadunitButton(style: .filled, title: "H")
        button.alpha = 0.5

        button.isHighlighted = true
        XCTAssertEqual(button.alpha, 0.35, accuracy: 0.001)
        button.isHighlighted = true
        XCTAssertEqual(button.alpha, 0.35, accuracy: 0.001, "repeated highlight must not compound")

        button.isHighlighted = false
        XCTAssertEqual(button.alpha, 0.5, accuracy: 0.001)
    }

    // MARK: - Hit area

    private func host(_ button: HeadunitButton, in size: CGSize = CGSize(width: 400, height: 300)) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.addSubview(button)
        return (window, controller.view)
    }

    func testSmallPinnedButtonStillHasA44PointHitArea() {
        let button = HeadunitButton(style: .overlay, systemImageName: "gearshape.fill")
        button.frame = CGRect(x: 100, y: 100, width: 30, height: 30)
        let (window, container) = host(button)
        defer { window.isHidden = true }

        // 7 pt of slop on every side (44 - 30) / 2.
        XCTAssertTrue(button.point(inside: CGPoint(x: -6, y: 15), with: nil))
        XCTAssertTrue(button.point(inside: CGPoint(x: 36, y: 36), with: nil))
        XCTAssertFalse(button.point(inside: CGPoint(x: -8, y: 15), with: nil))
        XCTAssertFalse(button.point(inside: CGPoint(x: 15, y: 38), with: nil))
        XCTAssertTrue(container.hitTest(CGPoint(x: 95, y: 115), with: nil) === button)
        XCTAssertNil(container.hitTest(CGPoint(x: 90, y: 115), with: nil) as? HeadunitButton)
    }

    func testLargeButtonHitAreaIsNotExpanded() {
        let button = HeadunitButton(style: .filled, size: .large, title: "Big")
        button.frame = CGRect(x: 0, y: 0, width: 100, height: 60)

        XCTAssertTrue(button.point(inside: CGPoint(x: 0, y: 0), with: nil))
        XCTAssertFalse(button.point(inside: CGPoint(x: -1, y: 10), with: nil))
        XCTAssertFalse(button.point(inside: CGPoint(x: 50, y: 61), with: nil))
    }

    // MARK: - Layout in a window

    func testLongTitleInAPinnedWidthShrinksInsteadOfOverflowing() {
        let title = "Wireless: Scan for Devices"
        let button = HeadunitButton(style: .filled, size: .large, title: title, systemImageName: "wifi")
        button.translatesAutoresizingMaskIntoConstraints = false
        let (window, container) = host(button)
        defer { window.isHidden = true }
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 50),
            button.widthAnchor.constraint(equalToConstant: 260),
        ])

        container.layoutIfNeeded()

        let label = button.titleLabel!
        XCTAssertTrue(label.adjustsFontSizeToFitWidth)
        XCTAssertGreaterThanOrEqual(label.minimumScaleFactor, 0.5)
        XCTAssertEqual(button.bounds.width, 260, accuracy: 0.5)
        XCTAssertGreaterThan(titleWidth(title, of: button), label.frame.width, "title is wider than its slot, so it must scale")
        XCTAssertGreaterThanOrEqual(label.frame.minX, button.imageView!.frame.maxX - 0.5)
        XCTAssertLessThanOrEqual(label.frame.maxX, button.bounds.width + 0.5)
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
    }

    func testUnpinnedButtonSizesToItsFullTitle() {
        let title = "Wireless: Scan for Devices"
        let button = HeadunitButton(style: .filled, size: .large, title: title, systemImageName: "wifi")
        button.translatesAutoresizingMaskIntoConstraints = false
        let (window, container) = host(button)
        defer { window.isHidden = true }
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 50),
        ])

        container.layoutIfNeeded()

        XCTAssertEqual(button.bounds.width, button.intrinsicContentSize.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(button.titleLabel!.frame.width + 0.5, titleWidth(title, of: button))
    }

    // MARK: - Dark mode

    /// Average brightness (0...255) of the visible pixels of `image`, as drawn.
    private func brightness(of image: UIImage?) -> CGFloat? {
        guard let image else { return nil }
        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return nil }
        var color = 0.0, alpha = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            color += Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])
            alpha += Double(pixels[i + 3])
        }
        return alpha > 0 ? CGFloat(color / (3 * alpha) * 255) : nil
    }

    func testSymbolTintFollowsTheDarkModeSwitch() {
        // A disabled button draws its symbol in a dynamic color (tertiaryLabel).
        let button = HeadunitButton(style: .tinted, title: "Mode", systemImageName: "wifi")
        button.isEnabled = false
        let (window, _) = host(button)
        defer { window.isHidden = true }

        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        let light = brightness(of: button.image(for: .disabled))

        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        let dark = brightness(of: button.image(for: .disabled))

        guard let light, let dark else { return XCTFail("could not sample the symbol image") }
        XCTAssertGreaterThan(dark, light + 50, "symbol must be re-tinted when the interface style changes")
    }
}
