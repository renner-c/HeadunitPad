import UIKit

/// Button styled with the classic UIButton API so it works on iOS 14.
/// `UIButton.Configuration` (the filled / tinted / plain styles) needs iOS 15.
///
/// Change the title or image later with `setTitle(_:for:)` using `.normal`;
/// the disabled and highlighted looks are handled here.
final class HeadunitButton: UIButton {
    enum Style {
        /// Solid accent background, white content.
        case filled
        /// Translucent accent background, accent content.
        case tinted
        /// Icon-only capsule: white content on translucent black, for floating over video.
        case overlay
    }

    enum Size {
        case medium
        case large
    }

    private static let minimumTouchTarget: CGFloat = 44

    private let style: Style
    private let size: Size
    private let accentOverride: UIColor?
    private let symbol: UIImage?

    private var accent: UIColor { accentOverride ?? tintColor }

    init(
        style: Style,
        size: Size = .medium,
        title: String? = nil,
        systemImageName: String? = nil,
        accent: UIColor? = nil,
        imagePadding: CGFloat = 8
    ) {
        self.style = style
        self.size = size
        self.accentOverride = accent
        self.symbol = systemImageName.flatMap { UIImage(systemName: $0) }
        super.init(frame: .zero)

        titleLabel?.font = UIFont.preferredFont(forTextStyle: size == .large ? .title3 : .body)
        titleLabel?.adjustsFontForContentSizeCategory = true
        setTitle(title, for: .normal)

        let inset: UIEdgeInsets
        switch (style, size) {
        case (.overlay, _):
            inset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        case (_, .medium):
            inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        case (_, .large):
            inset = UIEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        }
        if title != nil && symbol != nil {
            // Space between image and title: split it around the pair so the content stays
            // centered, and widen the content rect so nothing is clipped.
            let half = imagePadding / 2
            imageEdgeInsets = UIEdgeInsets(top: 0, left: -half, bottom: 0, right: half)
            titleEdgeInsets = UIEdgeInsets(top: 0, left: half, bottom: 0, right: -half)
            contentEdgeInsets = UIEdgeInsets(top: inset.top, left: inset.left + half, bottom: inset.bottom, right: inset.right + half)
        } else {
            contentEdgeInsets = inset
        }

        layer.cornerCurve = .continuous
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { applyAppearance() }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = cornerRadius
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(
            width: max(base.width, Self.minimumTouchTarget),
            height: max(base.height, Self.minimumTouchTarget)
        )
    }

    private var cornerRadius: CGFloat {
        switch (style, size) {
        case (.overlay, _): return bounds.height / 2
        case (_, .medium): return 10
        case (_, .large): return 14
        }
    }

    private func applyAppearance() {
        let background: UIColor
        let foreground: UIColor
        if !isEnabled {
            background = .tertiarySystemFill
            foreground = .tertiaryLabel
        } else {
            switch style {
            case .filled:
                background = accent
                foreground = .white
            case .tinted:
                background = accent.withAlphaComponent(0.15)
                foreground = accent
            case .overlay:
                background = UIColor.black.withAlphaComponent(0.35)
                foreground = .white
            }
        }
        backgroundColor = background
        setTitleColor(foreground, for: .normal)
        setTitleColor(foreground, for: .disabled)
        // Draw the symbol in the foreground color directly so the button's tintColor is not involved.
        let image = symbol?.withTintColor(foreground, renderingMode: .alwaysOriginal)
        setImage(image, for: .normal)
        setImage(image, for: .disabled)
    }
}
