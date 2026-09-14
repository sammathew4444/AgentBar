import AppKit
import QuartzCore

/// Bar.qml's `openPanelIndicator`: an accent pill on the bar's inner edge under the module whose
/// panel is open. On a top bar that is an underline, centred under the icon.
final class OpenPanelIndicator: NSView {
    /// `max(Style.space(10), round(iconSlot * 0.55))` with the 27-unit icon slot.
    static let length: CGFloat = 15
    /// `Style.space(2)`.
    static let thickness: CGFloat = 2
    /// `Style.space(2)` in from the bar's inner edge.
    static let inset: CGFloat = 2
    /// `opacity: 0.9` while open.
    static let openOpacity: CGFloat = 0.9

    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = Self.thickness / 2
        alphaValue = 0
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Clicks belong to the status item button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func attach(to button: NSStatusBarButton) {
        button.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: button.centerXAnchor),
            bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -Self.inset),
            widthAnchor.constraint(equalToConstant: Self.length),
            heightAnchor.constraint(equalToConstant: Self.thickness),
        ])
    }

    /// `Color.accent` of the current theme.
    func setColor(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    /// 120 ms, `Easing.OutCubic`.
    func setOpen(_ open: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            animator().alphaValue = open ? Self.openOpacity : 0
        }
    }
}
