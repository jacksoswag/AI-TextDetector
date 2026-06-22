import AppKit
import SwiftUI
import FilterCore
import UniformTypeIdentifiers   // UTType.json for the import/export file panels

/// Owns the two auxiliary windows — Pet Library and Pet Editor — and the
/// import/export file panels. One controller each, reused across opens, because
/// a menu-bar app that spawns a fresh window per click leaks windows and loses
/// the user's place. The menu panel and the library both route here, so all
/// window lifecycle and all NSAlert/NSOpenPanel plumbing live in one spot.
///
/// Every entry point activates the app first: a menu-bar (LSUIElement) app is
/// not normally frontmost, so without `NSApp.activate` its windows would open
/// behind whatever the user was reading.
@MainActor
final class PetWindowsCoordinator: NSObject {

    private let registry: PetRegistry

    private var libraryController: NSWindowController?
    private var editorController: NSWindowController?
    private var textCheckController: NSWindowController?

    init(registry: PetRegistry) {
        self.registry = registry
        super.init()
    }

    // MARK: - Library

    func openLibrary() {
        NSApp.activate(ignoringOtherApps: true)

        if let controller = libraryController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        // The library view calls back here for every action (edit, duplicate,
        // import, export) so the coordinator stays the single owner of windows
        // and dialogs — the SwiftUI view never touches AppKit window state.
        let view = PetLibraryView(registry: registry, coordinator: self)
        let controller = makeWindow(title: "Mascot Library",
                                    size: NSSize(width: 560, height: 460),
                                    content: view)
        libraryController = controller
        controller.showWindow(nil)
    }

    // MARK: - Editor

    /// Open the editor on a working copy. `editing == nil` starts a blank pet;
    /// otherwise it edits the given definition (the library hands us a
    /// already-duplicated copy for built-ins, so by the time we're here the pet
    /// is always user-editable).
    func openEditor(editing pet: PetDefinition?) {
        NSApp.activate(ignoringOtherApps: true)

        let view = PetEditorView(registry: registry, editing: pet) { [weak self] in
            self?.editorController?.close()
        }

        // Reuse the single editor window: replace its content so reopening for
        // a different pet doesn't stack windows.
        if let controller = editorController, let window = controller.window {
            window.title = pet == nil ? "New Mascot" : "Edit Mascot"
            window.contentViewController = NSHostingController(rootView: view)
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = makeWindow(title: pet == nil ? "New Mascot" : "Edit Mascot",
                                    size: NSSize(width: 540, height: 620),
                                    content: view)
        editorController = controller
        controller.showWindow(nil)
    }

    // MARK: - Check Text

    /// The manual check window: paste text, get a human-vs-AI verdict. Reuses the
    /// single controller across opens like the other aux windows, and is resizable
    /// so a long passage gets a taller editor.
    func openTextCheck(engine: DetectionEngine) {
        NSApp.activate(ignoringOtherApps: true)

        if let controller = textCheckController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = TextCheckView(engine: engine, registry: registry)
        let controller = makeWindow(title: "Check Text",
                                    size: NSSize(width: 420, height: 460),
                                    content: view, resizable: true)
        textCheckController = controller
        controller.showWindow(nil)
    }

    // MARK: - Import / Export

    /// Pick a .json and import it. Collisions auto-rename inside the registry;
    /// thrown errors surface as an alert. On success, offer to make it active —
    /// importing a pet you can't see is a dead end.
    func runImportPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a mascot (.json) to import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pet = try registry.importPet(from: url)
            confirmImport(pet)
        } catch {
            presentError(error)
        }
    }

    /// Export one pet to a .json the user names. Default file name is the pet's
    /// display name so the saved file is recognizable, not "<id>.json".
    func runExportPanel(petID: String) {
        NSApp.activate(ignoringOtherApps: true)
        let name = registry.pets.first { $0.id == petID }?.name ?? petID
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(name).json"
        panel.prompt = "Export"
        panel.message = "Save this mascot as a shareable file"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try registry.exportPet(id: petID, to: url)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Alerts

    /// Surface a thrown registry/validation error verbatim — these conform to
    /// LocalizedError with copy written for humans, so we show it as-is.
    func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't complete that"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        runAlert(alert)
    }

    /// Confirm a successful import and offer to switch to the new pet. The
    /// auto-rename means the imported name may differ from the file; show what
    /// actually landed.
    private func confirmImport(_ pet: PetDefinition) {
        let alert = NSAlert()
        alert.messageText = "Imported \"\(pet.name)\""
        alert.informativeText = "The mascot was added to your library."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set Active")
        alert.addButton(withTitle: "Not Now")
        if runAlert(alert) == .alertFirstButtonReturn {
            registry.activePetID = pet.id
        }
    }

    /// Run an alert sheeted on whichever pet window is up, else app-modal.
    /// Sheeting keeps the alert tied to the relevant window instead of floating
    /// detached from a menu-bar app with no main window.
    @discardableResult
    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.runModal()
    }

    // MARK: - Window factory

    private func makeWindow(title: String, size: NSSize, content: some View,
                            resizable: Bool = false) -> NSWindowController {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        if resizable { window.styleMask.insert(.resizable) }
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false   // we keep the controller alive
        return NSWindowController(window: window)
    }
}
