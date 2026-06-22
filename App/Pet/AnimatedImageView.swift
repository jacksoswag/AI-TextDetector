import AppKit

/// The pet's actual pixels. A thin NSImageView subclass that exists for one
/// reason: AppKit animates multi-frame GIFs entirely on its own once you hand
/// `.image` an `NSImage` built from animated GIF data — playback runs on the
/// AppKit/CoreAnimation side with zero app-side frame work. That is the whole
/// point of the spec's "no per-frame compute" rule, so we lean on it instead
/// of decoding frames ourselves.
///
/// `currentGIFKey` lets callers ask "am I already playing this?" so a looping
/// GIF is never restarted on every detection event — restarting would visibly
/// stutter the loop back to frame 0.
final class AnimatedImageView: NSImageView {

    /// Identifier of whatever animation is currently mounted (e.g. the resolved
    /// gif dictionary key, or nil for a static PNG). The coordinator swaps
    /// images only when this changes — see `PetCoordinator.mountGIF`.
    private(set) var currentGIFKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // `animates = true` is what tells AppKit to drive the GIF's frame
        // timeline; without it an animated NSImage shows only its first frame.
        animates = true
        imageScaling = .scaleProportionallyUpOrDown
        // Pixel art: keep the look crisp rather than smeared when the panel is
        // larger than the source art.
        wantsLayer = true
        layer?.magnificationFilter = .nearest
    }

    /// Mount an animated GIF. `key` is the caller's name for it so repeat calls
    /// with the same key can be skipped by the caller. Building the NSImage from
    /// the GIF's bytes and assigning `.image` is all it takes — AppKit starts
    /// the loop.
    func play(gifData: Data, key: String) {
        guard let image = NSImage(data: gifData) else { return }
        image.cacheMode = .never   // animated reps must re-render per frame
        self.image = image
        currentGIFKey = key
    }

    /// Mount a single still frame (the base PNG fallback when a behavior's GIF
    /// is absent). Clears `currentGIFKey` so the next GIF for any key mounts.
    func showStatic(pngData: Data, key: String? = nil) {
        guard let image = NSImage(data: pngData) else { return }
        self.image = image
        currentGIFKey = key
    }

    func stop() {
        self.image = nil
        self.currentGIFKey = nil
    }
}
