import AppKit
import ApplicationServices

/// Thin Swift helpers over the C Accessibility API.
enum AX {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    /// Reads an integer-valued attribute (e.g. kAXNumberOfCharacters) — a cheap
    /// way to detect text-length changes without copying the whole value string.
    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        copy(element, attribute) as? Int
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = copy(element, attribute), let array = value as? [AnyObject] else { return [] }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Frame in Accessibility coordinates (origin = top-left of the main screen).
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute),
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = appElement(pid: pid)
        return element(app, kAXFocusedWindowAttribute)
            ?? elements(app, kAXWindowsAttribute).first
    }

    /// The top-level application AX element for a pid. The anchor for app-level
    /// notification subscriptions (focused-window / title / activation changes).
    static func appElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// The deepest UI element of `pid`'s app at a global Accessibility point
    /// (top-left origin). Scoped to the target app, so it returns that app's own
    /// content and never our overlay panels (a different process's windows are
    /// invisible to this hit-test). Used by the overlay content-presence probe to
    /// confirm the text a highlight brackets is still rendered at its rect.
    static func elementAt(pid: pid_t, axPoint: CGPoint) -> AXUIElement? {
        var out: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement(pid: pid),
                                               Float(axPoint.x), Float(axPoint.y),
                                               &out) == .success else { return nil }
        return out
    }

    /// Best-effort readable text of an element: its value, else its title, else
    /// its description. nil when the element exposes none of them.
    static func valueText(_ element: AXUIElement) -> String? {
        string(element, kAXValueAttribute as String)
            ?? string(element, kAXTitleAttribute as String)
            ?? string(element, kAXDescriptionAttribute as String)
    }
}

extension NSScreen {
    /// The (0,0)-origin primary display whose height defines the AX/Cocoa
    /// Y-flip. `screens.first` is not guaranteed to be this screen.
    static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }
}

extension CGRect {
    /// Convert a top-left-origin (AX / CoreGraphics display) rect to Cocoa's
    /// bottom-left-origin screen space used by NSWindow.
    var axToCocoa: CGRect {
        let primaryHeight = NSScreen.primaryHeight
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}
