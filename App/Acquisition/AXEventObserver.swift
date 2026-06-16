import ApplicationServices
import Foundation

/// A live Accessibility notification subscription for one process. Wraps a
/// single `AXObserver` (one per pid) and drives the event-driven update loop
/// (spec §5): instead of polling an app for changes, we ask it to *tell* us
/// when its focused window moves, its title changes, a tracked text element's
/// value changes, and so on.
///
/// Lifetime rules (the AX API is unforgiving here):
///   • The observer must outlive every registration made against it. Drop the
///     last strong reference and the C run-loop source dies with it, silently
///     stopping all callbacks — so the owner keeps this object alive for as
///     long as it wants events (we hold an LRU of these per frontmost app).
///   • The C callback receives a `refcon`; we pass an unretained pointer to
///     `self` through it and trampoline back. Because it is *unretained*, the
///     callback must never fire after deinit — `invalidate()` removes the
///     run-loop source and all registrations first, and deinit calls it.
///   • Registrations are tracked so `invalidate()` (and therefore deinit) can
///     remove each one. Some apps reject some notifications on some elements;
///     those failures are tolerated and simply not tracked.
///
/// MainActor-bound: AX observers deliver on the run loop they were added to
/// (the main run loop), and every consumer here is main-actor state.
@MainActor
final class AXEventObserver {

    /// Called on the main run loop for every delivered notification, with the
    /// notification name and the element it fired on.
    private let handler: (String, AXUIElement) -> Void

    private let pid: pid_t
    private var observer: AXObserver?
    /// Every (element, notification) pair we successfully registered, so
    /// `invalidate()` can tear them all down. Elements are boxed by identity
    /// via `AXUIElement` (a CFType) paired with the notification string.
    private var registrations: [(element: AXUIElement, notification: String)] = []
    private var isValid = true

    /// Create the observer and wire its run-loop source into the main run loop.
    /// Fails (returns nil) only if `AXObserverCreate` itself fails — e.g. the
    /// pid is gone — in which case there is nothing to observe.
    init?(pid: pid_t, handler: @escaping (String, AXUIElement) -> Void) {
        self.pid = pid
        self.handler = handler

        var created: AXObserver?
        let result = AXObserverCreate(pid, Self.callback, &created)
        guard result == .success, let created else { return nil }
        observer = created

        // Add the source once, here; individual notifications attach later via
        // `observe(_:on:)`. `.defaultMode` matches the main run loop's normal
        // mode (AX delivery does not need the tracking/common modes).
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )
    }

    deinit {
        // deinit may run off the main actor; the teardown only touches CF
        // objects that are safe to release here, and `isValid`/`registrations`
        // are not read concurrently because the last reference is dropping.
        guard isValid, let observer else { return }
        for registration in registrations {
            AXObserverRemoveNotification(observer, registration.element, registration.notification as CFString)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    /// Subscribe to `notification` on `element`. Idempotent — re-registering an
    /// existing pair is a no-op — and tolerant: apps legitimately reject some
    /// notifications (an element that can't be destroyed won't accept
    /// `AXUIElementDestroyed`), and those are skipped rather than fatal.
    func observe(_ notification: String, on element: AXUIElement) {
        guard isValid, let observer else { return }
        if registrations.contains(where: { $0.notification == notification && CFEqual($0.element, element) }) {
            return
        }
        // refcon is an unretained pointer back to self; safe because we remove
        // the source in invalidate()/deinit before self is gone.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        // .success registers; .notificationAlreadyRegistered means the app
        // already had it (still ours to remove). Anything else = app declined.
        if status == .success || status == .notificationAlreadyRegistered {
            registrations.append((element, notification))
        }
    }

    /// Remove every registration for one notification name (across all
    /// elements), keeping the rest. Used to swap the per-scan
    /// `AXValueChanged` set — the structural window/app subscriptions must
    /// survive, only the previous scan's text-element subscriptions are
    /// replaced. No-op for names that were never registered.
    func cancelAll(notification: String) {
        guard isValid, let observer else { return }
        registrations.removeAll { registration in
            guard registration.notification == notification else { return false }
            AXObserverRemoveNotification(observer, registration.element, notification as CFString)
            return true
        }
    }

    /// Remove every registration and detach the run-loop source. After this the
    /// observer delivers nothing and is safe to release. Called on app switch /
    /// termination (and by deinit). Idempotent.
    func invalidate() {
        guard isValid else { return }
        isValid = false
        guard let observer else { return }
        for registration in registrations {
            AXObserverRemoveNotification(observer, registration.element, registration.notification as CFString)
        }
        registrations.removeAll()
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        self.observer = nil
    }

    /// C trampoline. AX hands back the `refcon` we stored; reconstitute `self`
    /// (unretained) and forward on the main actor. The callback is always
    /// invoked on the run loop the source was added to (main), so hopping to
    /// the main actor is a formality that satisfies the isolation checker
    /// without changing delivery timing.
    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<AXEventObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        MainActor.assumeIsolated {
            observer.handler(name, element)
        }
    }
}
