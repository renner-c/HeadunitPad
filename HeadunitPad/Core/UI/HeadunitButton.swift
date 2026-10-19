import UIKit

/// Button styled with the classic UIButton API so it works on iOS 14.
/// `UIButton.Configuration` (the filled / tinted / plain styles) needs iOS 15.
///
/// Change the title or image later with `setTitle(_:for:)` using `.normal`;
/// the disabled and highlighted looks are handled here.
///
/// The symbol is given as an ordered list of SF Symbol names: the first one that
/// resolves on the running OS wins, so a newer symbol can be preferred with an older
/// one as the iOS 14 fallback. `scripts/check_sf_symbols.py` enforces this in CI.
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
    private var alphaBeforeHighlight: CGFloat?

    private var accent: UIColor { accentOverride ?? tintColor }

    /// The first candidate for which `lookup` returns an image, with the name that resolved.
    /// `lookup` is injectable so tests can simulate an OS that lacks a symbol.
    static func resolveSymbol(
        from candidates: [String],
        lookup: (String) -> UIImage? = { UIImage(systemName: $0) }
    ) -> (name: String, image: UIImage)? {
        for name in candidates {
            if let image = lookup(name) { return (name, image) }
        }
        return nil
    }

    /// Name of the symbol that resolved, or nil when there is none.
    let resolvedSymbolName: String?

    /// - Parameter systemImageNames: SF Symbol names in order of preference; the first
    ///   that exists on the running OS is used. Empty means no image.
    init(
        style: Style,
        size: Size = .medium,
        title: String? = nil,
        systemImageNames: [String] = [],
        symbolLookup: (String) -> UIImage? = { UIImage(systemName: $0) },
        accent: UIColor? = nil,
        imagePadding: CGFloat = 8
    ) {
        self.style = style
        self.size = size
        self.accentOverride = accent
        let resolved = Self.resolveSymbol(from: systemImageNames, lookup: symbolLookup)
        self.symbol = resolved?.image
        self.resolvedSymbolName = resolved?.name
        super.init(frame: .zero)

        titleLabel?.font = UIFont.preferredFont(forTextStyle: size == .large ? .title3 : .body)
        titleLabel?.adjustsFontForContentSizeCategory = true
        // Fixed-width buttons (pinned by callers) shrink a long title instead of truncating it.
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        titleLabel?.lineBreakMode = .byTruncatingTail
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

    convenience init(
        style: Style,
        size: Size = .medium,
        title: String? = nil,
        systemImageName: String?,
        accent: UIColor? = nil,
        imagePadding: CGFloat = 8
    ) {
        self.init(
            style: style,
            size: size,
            title: title,
            systemImageNames: systemImageName.map { [$0] } ?? [],
            accent: accent,
            imagePadding: imagePadding
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { applyAppearance() }
    }

    /// Dims relative to whatever alpha the caller set, and restores that alpha afterwards.
    override var isHighlighted: Bool {
        didSet {
            if isHighlighted, alphaBeforeHighlight == nil {
                alphaBeforeHighlight = alpha
                alpha *= 0.7
            } else if !isHighlighted, let restored = alphaBeforeHighlight {
                alpha = restored
                alphaBeforeHighlight = nil
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // The symbol is pre-tinted with `.alwaysOriginal`, so it does not follow dark mode by itself.
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyAppearance()
        }
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

    /// Keeps a 44x44 pt hit area even when a caller pins the button smaller.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (Self.minimumTouchTarget - bounds.width) / 2)
        let dy = max(0, (Self.minimumTouchTarget - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
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
        // Resolve dynamic colors against this button's traits so dark mode gets the right shade.
        let image = symbol?.withTintColor(foreground.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        setImage(image, for: .normal)
        setImage(image, for: .disabled)
    }
}
