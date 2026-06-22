import AppKit

/// The floating window a pet instance lives in. Every window trait here is
/// in service of one promise from the spec: the pet NEVER obstructs the
/// user. It cannot be clicked, cannot steal focus, cannot become key, and
/// rides above normal windows without ever joining the Cmd-Tab /
/// window-cycling world.
///
/// 43×43 (the art's scaled pixel size — 67% of the former 64pt footprint, so
/// one pet per flagged block stays a small, unobtrusive marker), borderless,
/// transparent, shadowless: the pixel art is the only thing the user sees —
/// no chrome, no card, nothing to imply a clickable surface.
final class PetPanel: NSPanel {

    /// Fallback edge length when no user size is supplied. The live size is the
    /// user's pet-size setting, passed in by PetCoordinator.
    static let defaultSize = NSSize(width: 43, height: 43)

    let imageView = AnimatedImageView(frame: .zero)

    init(size: NSSize = PetPanel.defaultSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            // .nonactivatingPanel: clicking near it (it can't actually be
            // clicked — see ignoresMouseEvents) never activates the app.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Float above ordinary windows but stay out of every interaction path.
        level = .floating
        // The single most important line: the pet is decoration, so every
        // click and scroll passes straight through to whatever is underneath.
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // .transient + .ignoresCycle: never in Cmd-Tab, never in the window
        // cycle. .fullScreenAuxiliary: still visible when another app is
        // full-screen, which is exactly where the user reads long AI text.
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        // Keep it visible across Spaces; the user shouldn't lose their pet by
        // switching desktops.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        // A clipping container welds the art to the bracket line. The panel's
        // right edge sits exactly on the line (see PetCoordinator.anchorOrigin),
        // so `masksToBounds` turns that edge into a hard wall: the art can be
        // shoved a full panel-width to the right — fully behind the line — and is
        // CLIPPED there, so it can never sweep over the text to the right of the
        // line, and the pet reads as ducking behind / peeking out from the line.
        // This explicit clip is REQUIRED: a bare NSWindow does not clip
        // out-of-frame layer content, so without it the rightward hide would
        // render the art on top of the text instead of hiding it.
        let clip = NSView(frame: NSRect(origin: .zero, size: size))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        imageView.frame = clip.bounds
        // Fills the clip, so resizing the panel (live size changes) rescales the art.
        imageView.autoresizingMask = [.width, .height]
        clip.addSubview(imageView)
        contentView = clip
    }

    // Decorative panels must refuse keyboard/main status outright — even
    // nonactivating panels will otherwise accept becoming key on some events.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
