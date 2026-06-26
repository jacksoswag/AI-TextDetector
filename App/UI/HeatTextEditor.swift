import SwiftUI
import AppKit
import FilterCore

/// The check window's editable text box. The AI heat is a single layer now: a
/// dark, subtle green→red gradient painted as the text view's background, one
/// band per scored paragraph block (same blocks and same model cascade as the
/// on-screen scan). Hovering a block shows its probability. See
/// `HeatBackgroundTextView`. Any edit clears it.
struct HeatTextEditor: NSViewRepresentable {
    @Binding var text: String
    var blocks: [AIBlockScore]?
    var analyzedText: String
    /// Called with the probability of the block under the cursor, or nil when the
    /// cursor leaves the blocks. Drives the "Block: __% AI" label by the button.
    var onHoverBlock: (Double?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = HeatBackgroundTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.typingAttributes = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
        ]
        // Analyze text verbatim — never let macOS rewrite quotes/dashes, which
        // would desync the analyzed snapshot from what's on screen.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.onHoverBlock = onHoverBlock

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? HeatBackgroundTextView else { return }
        context.coordinator.parent = self
        if textView.string != text { textView.string = text }
        textView.onHoverBlock = onHoverBlock
        textView.analyzedSnapshot = analyzedText
        textView.blockScores = (analyzedText == textView.string) ? (blocks ?? []) : []
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HeatTextEditor
        init(_ parent: HeatTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// NSTextView that paints the per-block AI heat as a vertical gradient behind the
/// text: each scored block is a near-uniform green→red band (dark and subtle),
/// feathered into its neighbours. Hovering a block shows its probability. Block
/// positions come from the live layout, so the field tracks the text and scrolls.
final class HeatBackgroundTextView: NSTextView {
    var blockScores: [AIBlockScore] = [] {
        didSet { gradientCache = nil; blockRects = nil; hasReportedHover = false; needsDisplay = true; needsLayout = true }
    }
    var analyzedSnapshot = ""
    var onHoverBlock: ((Double?) -> Void)?

    private var gradientCache: (size: CGSize, gradient: CGGradient)?

    // MARK: - Gradient

    override func draw(_ dirtyRect: NSRect) {
        if let gradient = backgroundGradient(), let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.clip(to: dirtyRect)
            // Flipped view: minY is the top → gradient location 0 is the top.
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: bounds.midX, y: bounds.minY),
                end: CGPoint(x: bounds.midX, y: bounds.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        super.draw(dirtyRect)
    }

    private func backgroundGradient() -> CGGradient? {
        guard !blockScores.isEmpty, string == analyzedSnapshot,
              let layoutManager, let textContainer, bounds.height > 1 else { return nil }
        if let gradientCache, gradientCache.size == bounds.size { return gradientCache.gradient }

        let height = bounds.height
        let inset = textContainerInset.height

        // One near-uniform band per block (top/bottom stops at the block color),
        // plus a midpoint stop in each gap colored at the averaged score so a
        // green→red transition passes through yellow rather than muddy brown.
        // A wide feather widens the gaps, making those transitions gentle.
        var bands: [(top: CGFloat, bottom: CGFloat, probability: Double)] = []
        for block in blockScores {
            let glyphs = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let feather = min(14, rect.height * 0.4)
            let top = clamp((rect.minY + feather + inset) / height, 0, 1)
            let bottom = clamp((rect.maxY - feather + inset) / height, 0, 1)
            bands.append((min(top, bottom), max(top, bottom), block.probability))
        }
        guard !bands.isEmpty else { return nil }
        bands.sort { $0.top < $1.top }

        var stops: [(loc: CGFloat, color: CGColor)] = [(0, blockColor(probability: bands[0].probability))]
        for (i, band) in bands.enumerated() {
            stops.append((band.top, blockColor(probability: band.probability)))
            stops.append((band.bottom, blockColor(probability: band.probability)))
            if i + 1 < bands.count {
                let next = bands[i + 1]
                stops.append(((band.bottom + next.top) / 2,
                              blockColor(probability: (band.probability + next.probability) / 2)))
            }
        }
        stops.append((1, blockColor(probability: bands[bands.count - 1].probability)))

        // CGGradient needs strictly increasing locations.
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        var previous: CGFloat = -1
        for stop in stops {
            let loc = min(max(stop.loc, previous + 1e-4), 1)
            colors.append(stop.color)
            locations.append(loc)
            previous = loc
        }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                        locations: locations) else { return nil }
        gradientCache = (bounds.size, gradient)
        return gradient
    }

    /// Subtle green → yellow → red by probability, continuous hue. Constant
    /// saturation/brightness/alpha so the whole ramp reads as one clean heatmap
    /// rather than fading out in the middle.
    private func blockColor(probability: Double) -> CGColor {
        let p = min(max(probability, 0), 1)
        let hue = CGFloat(0.33 * (1 - p))                // 0.33 green · 0.165 yellow · 0.0 red
        let ns = NSColor(hue: hue, saturation: 0.72, brightness: 0.62, alpha: 0.22)
        return (ns.usingColorSpace(.sRGB) ?? ns).cgColor
    }

    private func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(x, lo), hi)
    }

    // MARK: - Per-block hover

    /// Cached on-screen rects per block (nil until next layout), hit-tested on
    /// mouse-move to report the hovered block's probability.
    private var blockRects: [(rects: [NSRect], probability: Double)]?
    private var hoverTrackingArea: NSTrackingArea?
    private var lastHoverProbability: Double?
    private var hasReportedHover = false

    override func layout() {
        super.layout()
        blockRects = nil          // recomputed lazily on the next hover
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let probability = currentBlockRects().first { entry in
            entry.rects.contains { $0.contains(point) }
        }?.probability
        reportHover(probability)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        reportHover(nil)
    }

    private func currentBlockRects() -> [(rects: [NSRect], probability: Double)] {
        if let blockRects { return blockRects }
        var computed: [(rects: [NSRect], probability: Double)] = []
        if !blockScores.isEmpty, string == analyzedSnapshot,
           let layoutManager, let textContainer {
            let inset = textContainerInset
            for block in blockScores {
                var rects: [NSRect] = []
                let glyphs = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { rect, _ in rects.append(rect.offsetBy(dx: inset.width, dy: inset.height)) }
                computed.append((rects, block.probability))
            }
        }
        blockRects = computed
        return computed
    }

    private func reportHover(_ probability: Double?) {
        guard !hasReportedHover || probability != lastHoverProbability else { return }
        hasReportedHover = true
        lastHoverProbability = probability
        onHoverBlock?(probability)
    }

    // MARK: - Rich paste (formatting kept, colours/sizes normalized for the dark UI)

    /// Paste keeps bold/italic/underline/strikethrough and list structure, but
    /// normalizes the font to the body size (preserving bold/italic) and forces a
    /// readable foreground with no background — so a source's black-on-white text
    /// can't render invisible against the dark window, and pasted highlights don't
    /// fight the heat gradient. The detector still reads `string` (plain), so this
    /// is purely cosmetic.
    override func paste(_ sender: Any?) {
        guard let objects = NSPasteboard.general.readObjects(
                forClasses: [NSAttributedString.self], options: nil) as? [NSAttributedString],
              let pasted = objects.first, pasted.length > 0 else {
            super.paste(sender)
            return
        }
        let sanitized = Self.sanitized(pasted)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: sanitized.string) else { return }
        textStorage?.replaceCharacters(in: range, with: sanitized)
        didChangeText()
    }

    private static func sanitized(_ input: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: input)
        let full = NSRange(location: 0, length: output.length)
        let body = NSFont.preferredFont(forTextStyle: .body)
        let manager = NSFontManager.shared
        output.beginEditing()
        // Rebuild each font as body size + the run's bold/italic traits; underline,
        // strikethrough, and paragraph styles (lists, indents) pass through.
        output.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let traits = (value as? NSFont).map { manager.traits(of: $0) } ?? []
            var font = body
            if traits.contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            output.addAttribute(.font, value: font, range: range)
        }
        output.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        output.removeAttribute(.backgroundColor, range: full)
        output.endEditing()
        return output
    }
}
