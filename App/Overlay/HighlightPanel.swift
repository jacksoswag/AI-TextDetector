import AppKit
import FilterCore

/// One highlight annotation over a native app's suspect text block: a
/// borderless, non-activating panel that *marks* the block (dim wash + glowing
/// outline) without ever obscuring it. The spec is explicit — highlights are
/// pure annotation, never censorship: the content stays fully readable through
/// the overlay, layout is never touched, and the panel passes every click and
/// scroll straight through to the app beneath it (`ignoresMouseEvents`). The
/// text is never hidden, so there are no tracking areas, no hover mask, no pill,
/// and no per-frame work — the styling is static once applied.
final class HighlightPanel: NSPanel {

    private(set) var highlightView: HighlightView!
    private(set) var state: DetectionState
    private(set) var words: Int

    // MARK: - Bar geometry (single source of truth)
    //
    // The bracket panel extends `bracketExpand` points to the LEFT of the text
    // so the vertical bar clears the first glyph, and the stroke is drawn
    // `bracketStrokeInset` points in from that expanded edge. Both the bar's
    // own path (HighlightView) and everything that anchors to the bar (the
    // mascot, its commentary box) derive their x from these two constants, so
    // the bar can be retuned in one place without anything drifting off it.

    /// Points the bracket panel extends to the left of the text block.
    static let bracketExpand: CGFloat = 12
    /// X of the vertical stroke inside the expanded panel (HighlightView.lx).
    static let bracketStrokeInset: CGFloat = 2
    /// Screen-x of the bracket's vertical bar for text beginning at `textMinX`.
    static func barX(textMinX: CGFloat) -> CGFloat { textMinX - bracketExpand + bracketStrokeInset }
    /// Gap from the vertical bar to the first glyph of the text it brackets.
    /// Reused as the symmetric gap on the bar's left side (bar → commentary box).
    static var barToTextGap: CGFloat { bracketExpand - bracketStrokeInset }

    /// The vertical extent the bracket line is actually DRAWN at — the single
    /// source of truth shared by the stroke (HighlightView) and everything that
    /// must sit inside the line (the mascot, which may never fall below the
    /// line's bottom). Trust the measured rect for normal paragraphs, and clamp
    /// only absurdly tall container rects to a word-count estimate so a
    /// screen-tall AXTextArea (VS Code / Google Docs) doesn't produce a
    /// full-screen bracket. The estimate assumes ~10 words per line, 22px/line.
    static func drawnLineHeight(rectHeight: CGFloat, words: Int) -> CGFloat {
        let estimatedLines = max(1, ceil(CGFloat(words) / 10.0))
        let estimatedHeight = estimatedLines * 22.0 + 8.0
        return rectHeight > estimatedHeight * 3.0 ? estimatedHeight : rectHeight
    }

    init(rect: CGRect, state: DetectionState, words: Int, floating: Bool = true) {
        self.state = state
        self.words = words

        // Expand the frame horizontally so we can draw the bracket spaced away
        // from the text, without clipping the path on the left edge.
        let expandedRect = CGRect(x: rect.minX - Self.bracketExpand, y: rect.minY, width: rect.width + Self.bracketExpand, height: rect.height)

        super.init(contentRect: expandedRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Annotations are pure passthrough: every click and scroll belongs to
        // the content underneath. Without this the highlight would eat events
        // the app needs (and there is no longer anything to "open" by clicking).
        ignoresMouseEvents = true
        // OCR highlights cover whatever is topmost (they ARE the visible
        // pixels) → floating. Window-anchored highlights use the normal level
        // and get z-ordered directly above their content window, so a highlight
        // on a background window stays under whatever covers that window.
        level = floating ? .floating : .normal
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow

        let view = HighlightView(frame: CGRect(origin: .zero, size: expandedRect.size), state: state, words: words)
        highlightView = view
        contentView = view
        alphaValue = 1.0 // Always fully opaque
        view.bracketLayer.strokeStart = 0.5
        view.bracketLayer.strokeEnd = 0.5
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Content window this panel sits above (AX layers); nil = floating.
    /// Kept on the panel so re-asserts (window managers reorder freely) restore
    /// the correct z-position immediately instead of waiting for a tracking tick.
    var contentWindowNumber: Int?

    /// Restyle and resize an existing panel in place.
    func update(rect: CGRect, state: DetectionState, words: Int) {
        self.state = state
        self.words = words
        let expandedRect = CGRect(x: rect.minX - Self.bracketExpand, y: rect.minY, width: rect.width + Self.bracketExpand, height: rect.height)
        setFrame(expandedRect, display: false)
        highlightView.frame = CGRect(origin: .zero, size: expandedRect.size)
        highlightView.apply(state: state, words: words)
    }

    private var isExpanded = false

    func show(isScrolling: Bool = false) {
        if let contentWindowNumber {
            order(.above, relativeTo: contentWindowNumber)
        } else {
            orderFrontRegardless()
        }

        contentView?.wantsLayer = true
        alphaValue = 1.0

        if isScrolling {
            collapseLine(animated: false)
        } else {
            expandLine(animated: true)
        }
    }

    func dismiss() {
        orderOut(nil)
    }

    func expandLine(animated: Bool = true) {
        guard !isExpanded else { return }
        isExpanded = true
        
        if animated {
            let startAnim = CABasicAnimation(keyPath: "strokeStart")
            startAnim.fromValue = highlightView.bracketLayer.presentation()?.strokeStart ?? 0.5
            startAnim.toValue = 0.0
            startAnim.duration = 0.15
            startAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            let endAnim = CABasicAnimation(keyPath: "strokeEnd")
            endAnim.fromValue = highlightView.bracketLayer.presentation()?.strokeEnd ?? 0.5
            endAnim.toValue = 1.0
            endAnim.duration = 0.15
            endAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            highlightView.bracketLayer.strokeStart = 0.0
            highlightView.bracketLayer.strokeEnd = 1.0
            highlightView.bracketLayer.add(startAnim, forKey: "strokeStart")
            highlightView.bracketLayer.add(endAnim, forKey: "strokeEnd")
        } else {
            highlightView.bracketLayer.strokeStart = 0.0
            highlightView.bracketLayer.strokeEnd = 1.0
        }
    }

    func collapseLine(animated: Bool = true) {
        guard isExpanded else { return }
        isExpanded = false
        
        if animated {
            let startAnim = CABasicAnimation(keyPath: "strokeStart")
            startAnim.fromValue = highlightView.bracketLayer.presentation()?.strokeStart ?? 0.0
            startAnim.toValue = 0.5
            startAnim.duration = 0.15
            startAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            let endAnim = CABasicAnimation(keyPath: "strokeEnd")
            endAnim.fromValue = highlightView.bracketLayer.presentation()?.strokeEnd ?? 1.0
            endAnim.toValue = 0.5
            endAnim.duration = 0.15
            endAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            highlightView.bracketLayer.strokeStart = 0.5
            highlightView.bracketLayer.strokeEnd = 0.5
            highlightView.bracketLayer.add(startAnim, forKey: "strokeStart")
            highlightView.bracketLayer.add(endAnim, forKey: "strokeEnd")
        } else {
            highlightView.bracketLayer.strokeStart = 0.5
            highlightView.bracketLayer.strokeEnd = 0.5
        }
    }

    /// Pin this panel's z-position directly above its content window.
    /// Re-asserted on window/app events; window managers reorder freely.
    func orderAbove(windowNumber: Int?) {
        contentWindowNumber = windowNumber
        if let windowNumber {
            order(.above, relativeTo: windowNumber)
        } else {
            orderFrontRegardless()
        }
    }
}

/// The highlight itself: a single Apple Glass-style bracket on the left edge of
/// the detected block. No background fill, no border, no overlay — just a thin
/// state-colored vertical line with short curved nubs at the top and bottom.
/// Everything is layer state set once in `apply(state:)`.
final class HighlightView: NSView {

    private struct Style {
        let color: NSColor
        let glowRadius: CGFloat
    }

    private static func style(for state: DetectionState) -> Style {
        switch state {
        case .suspicious: return Style(color: .systemYellow, glowRadius: 3)
        case .high:       return Style(color: .systemOrange,  glowRadius: 4)
        case .veryHigh:   return Style(color: .systemRed,     glowRadius: 5)
        case .safe, .uncertain:
            assertionFailure("HighlightView created for non-highlight state \(state)")
            return Style(color: .systemYellow, glowRadius: 3)
        }
    }

    let bracketLayer = CAShapeLayer()
    private var words: Int = 0

    init(frame: CGRect, state: DetectionState, words: Int) {
        self.words = words
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        bracketLayer.fillColor = nil
        bracketLayer.lineWidth = 1.5
        bracketLayer.lineCap = .round
        bracketLayer.lineJoin = .round
        bracketLayer.masksToBounds = false
        bracketLayer.shadowOffset = .zero
        layer?.addSublayer(bracketLayer)

        apply(state: state, words: words)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var allowsVibrancy: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bracketLayer.frame = bounds
        updateBracketPath()
        CATransaction.commit()
    }

    private func updateBracketPath() {
        guard bounds.height > 4 else { return }
        let nub: CGFloat = 6                            // length of horizontal cap at top and bottom
        let r:   CGFloat = 4                            // corner radius
        let lx:  CGFloat = HighlightPanel.bracketStrokeInset  // x of the vertical stroke

        // Shared with the mascot's anchor math so the pet sits inside the line
        // the reader actually sees (HighlightPanel.drawnLineHeight).
        let h = HighlightPanel.drawnLineHeight(rectHeight: bounds.height, words: words)

        // Cocoa coordinates: y=0 is the bottom. Text is top-aligned, so draw from the top down.
        let topY = bounds.height
        let bottomY = bounds.height - h

        let path = CGMutablePath()
        path.move(to: CGPoint(x: lx + nub, y: topY))
        path.addLine(to: CGPoint(x: lx + r, y: topY))
        path.addQuadCurve(to: CGPoint(x: lx, y: topY - r), control: CGPoint(x: lx, y: topY))
        path.addLine(to: CGPoint(x: lx, y: bottomY + r))
        path.addQuadCurve(to: CGPoint(x: lx + r, y: bottomY), control: CGPoint(x: lx, y: bottomY))
        path.addLine(to: CGPoint(x: lx + nub, y: bottomY))
        bracketLayer.path = path
    }

    func apply(state: DetectionState, words: Int) {
        self.words = words
        let style = Self.style(for: state)
        // Bracket line drawn at 0.60 (the mascot rests at 0.80, set separately).
        let cg = style.color.withAlphaComponent(0.60).cgColor
        bracketLayer.strokeColor = cg
        bracketLayer.shadowColor = NSColor.black.cgColor
        bracketLayer.shadowOpacity = 0.25
        bracketLayer.shadowRadius = 2.0
        bracketLayer.shadowOffset = .zero
        if !bounds.isEmpty { updateBracketPath() }
    }
}

