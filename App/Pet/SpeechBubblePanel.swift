import AppKit

/// A mascot's word balloon — a second floating panel showing the mascot's
/// one-line commentary on its block. Like the mascot and the highlight bracket,
/// it is PURE annotation and never intercepts input: the panel is fully
/// click-through (`ignoresMouseEvents = true`), so every click and scroll lands
/// on the content underneath. Nothing here is clickable — the only interaction
/// is dismissal, and even that is driven from the outside: MascotCoordinator's
/// global mouse monitor notices a pass-through click that fell on a visible
/// bubble and calls `fadeOut()` (the click still reaches the app below).
///
/// The bubble auto-dismisses on a fixed one-shot timer (spec §6.1):
/// deterministic, no per-frame work — a single `DispatchWorkItem` that a fresh
/// line cancels and replaces. While the block / mascot / bubble is hovered the
/// timer is parked (`isGloballyHovered`) so the commentary doesn't vanish out
/// from under the reader; leaving re-arms it. Dark translucent background so
/// 11.5pt white text stays readable over any desktop.
final class SpeechBubblePanel: NSPanel {

    /// Bubble copy wraps at 160pt of content width (33% wider than the prior 120pt).
    static let maxContentWidth: CGFloat = 160
    /// Spec: lines linger for a fixed 6s, then the bubble retires itself.
    static let visibleDuration: TimeInterval = 6.0

    private static let padding: CGFloat = 8
    static let blurMargin: CGFloat = 24
    private static let fadeDuration: TimeInterval = 0.22

    private let bubbleView = BubbleCardView()
    private let label = NSTextField(labelWithString: "")

    /// The pending auto-dismiss. Held so a new line (or an explicit hide/fade)
    /// can cancel it before it fires — the timer always reflects the latest line.
    private var dismissWorkItem: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxContentWidth, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        // Pure annotation: every click and scroll belongs to the content
        // underneath. The bubble carries nothing to click; the coordinator
        // fades it on a pass-through click (see MascotCoordinator.handleMouseDown).
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        bubbleView.wantsLayer = true

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .white
        label.maximumNumberOfLines = 0        // wrap freely; height grows to fit
        label.lineBreakMode = .byWordWrapping
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.preferredMaxLayoutWidth = Self.maxContentWidth - Self.padding * 2

        bubbleView.addSubview(label)
        contentView = bubbleView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Tracked by MascotCoordinator so the dismiss timer parks while the
    /// block / mascot / bubble is hovered.
    var isGloballyHovered: Bool = false {
        didSet {
            if isGloballyHovered {
                dismissWorkItem?.cancel()
                dismissWorkItem = nil
            } else if isVisible, dismissWorkItem == nil {
                armDismiss(after: 1.5)
            }
        }
    }

    /// Show `text`, resizing the panel to fit, and (re)arm the dismiss timer.
    /// A new call replaces the previous line and restarts the clock.
    func show(_ text: String) {
        label.stringValue = text
        layout()
        alphaValue = 1.0
        armDismiss(after: Self.visibleDuration)
    }

    /// Fade the bubble away. Used both by the auto-dismiss timer and when the
    /// reader clicks the commentary — the click itself passes straight through
    /// to the app below; this just makes the annotation politely retire.
    func fadeOut() {
        guard isVisible else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1.0   // reset for the next reveal
        })
    }

    /// Cancel any pending dismiss and hide IMMEDIATELY (no fade). Used when the
    /// mascot itself is being removed (fly-out) or a scroll burst starts, so a
    /// stale bubble can't outlive its mascot or linger over moving content.
    func hideNow() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        orderOut(nil)
        alphaValue = 1.0
    }

    // MARK: - Layout

    /// Visible-card size (the dark rounded card, WITHOUT the surrounding blur
    /// margin) for a given line — the exact measurement `layout()` applies, so
    /// callers can predict the rendered box size before it is ever shown (the
    /// mascot uses this to sit dynamically just below the box).
    static func cardSize(for text: String) -> NSSize {
        let probe = NSTextField(labelWithString: text)
        probe.font = .systemFont(ofSize: 11.5)
        probe.maximumNumberOfLines = 0
        probe.lineBreakMode = .byWordWrapping
        probe.preferredMaxLayoutWidth = maxContentWidth - padding * 2
        let textSize = probe.sizeThatFits(
            NSSize(width: maxContentWidth - padding * 2, height: .greatestFiniteMagnitude))
        return NSSize(width: min(maxContentWidth, textSize.width + padding * 2),
                      height: textSize.height + padding * 2)
    }

    private func layout() {
        // Frame the card around the measured (wrapped) label with even padding,
        // then add the invisible blur margin all round. Shares `cardSize` so the
        // mascot's prediction of this height stays exactly in sync.
        let card = Self.cardSize(for: label.stringValue)
        let windowWidth = card.width + Self.blurMargin * 2
        let windowHeight = card.height + Self.blurMargin * 2

        setContentSize(NSSize(width: windowWidth, height: windowHeight))
        bubbleView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        label.frame = NSRect(x: Self.padding + Self.blurMargin, y: Self.padding + Self.blurMargin,
                             width: card.width - Self.padding * 2,
                             height: card.height - Self.padding * 2)
    }

    // MARK: - Dismiss timing

    private func armDismiss(after duration: TimeInterval) {
        dismissWorkItem?.cancel()
        if isGloballyHovered { return }   // parked until the pointer leaves
        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

/// Draws the bubble's soft dark card. No tracking areas and no event handling —
/// the panel is click-through, so it never receives mouse events of its own.
private final class BubbleCardView: NSView {
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // A very smooth, subtle gradient fade with no hard edges.
        context.setShadow(offset: .zero, blur: 24, color: NSColor.black.withAlphaComponent(0.85).cgColor)
        context.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
        // Draw the inner soft rect; the massive blur radiates out into the blurMargin.
        let innerRect = bounds.insetBy(dx: 24, dy: 24)
        let path = CGPath(roundedRect: innerRect, cornerWidth: 20, cornerHeight: 20, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}
