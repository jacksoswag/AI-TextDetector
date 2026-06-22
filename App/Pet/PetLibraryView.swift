import SwiftUI
import AppKit
import FilterCore

/// SwiftUI bridge to `AnimatedImageView` so the library and editor can show a
/// live, looping preview of a pet's animations inside SwiftUI. Reuses the exact
/// view the overlay uses, so what you preview is what you'll see on screen.
struct AnimatedGIFView: NSViewRepresentable {
    /// GIF bytes to animate, or nil to show the static fallback.
    let gifData: Data?
    /// Static PNG fallback when `gifData` is nil or undecodable.
    let pngData: Data?
    /// A stable identifier for the current art so we only re-mount on change.
    let key: String

    func makeNSView(context: Context) -> AnimatedImageView {
        let view = AnimatedImageView()
        mount(view)
        return view
    }

    func updateNSView(_ nsView: AnimatedImageView, context: Context) {
        // Only re-mount when the resolved art key changed — otherwise the loop
        // would restart on every SwiftUI re-render.
        guard nsView.currentGIFKey != key else { return }
        mount(nsView)
    }

    private func mount(_ view: AnimatedImageView) {
        if let gifData {
            view.play(gifData: gifData, key: key)
        } else if let pngData {
            view.showStatic(pngData: pngData, key: key)
        }
    }
}

/// The Pet Library window: every installed pet in a list, a live preview of the
/// selected one, and the management actions (new / edit / duplicate / delete /
/// import / export). Selecting a row sets the active pet — the radio bound to
/// `registry.activePetID` is the selection model, so "selected" and "active"
/// are the same thing, which is what the user expects.
struct PetLibraryView: View {
    @ObservedObject var registry: PetRegistry
    let coordinator: PetWindowsCoordinator

    /// Which behavior the preview pane is cycling. Local UI state; defaults to
    /// idle so opening the window shows the resting pose.
    @State private var previewBehavior: PreviewBehavior = .idle
    /// Row the user is hovering, used to drive the preview without changing the
    /// active selection on mere hover.
    @State private var hoveredID: String?

    /// Pet shown in the preview: hovered row if any, else the active pet.
    private var previewPet: PetDefinition? {
        if let hoveredID, let pet = registry.pets.first(where: { $0.id == hoveredID }) {
            return pet
        }
        return registry.pets.first { $0.id == registry.activePetID } ?? registry.pets.first
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 300)
            preview
                .frame(minWidth: 220)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - List + toolbar

    private var list: some View {
        VStack(spacing: 0) {
            List {
                ForEach(registry.pets) { pet in
                    PetRow(
                        pet: pet,
                        isActive: pet.id == registry.activePetID,
                        isBuiltin: registry.isBuiltin(id: pet.id),
                        select: { registry.activePetID = pet.id }
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hoveredID = inside ? pet.id : (hoveredID == pet.id ? nil : hoveredID)
                    }
                }
                
                HStack {
                    Button("New Pet") { coordinator.openEditor(editing: nil) }
                    Spacer()
                    Button("Open Folder") {
                        NSWorkspace.shared.open(registry.userDirectory)
                    }
                }
                .padding(.vertical, 8)
                .controlSize(.small)
                .buttonStyle(.plain)
            }
            .listStyle(.inset)

            // Surface load problems quietly: a corrupt dropped file shouldn't
            // be invisible, but it also shouldn't shout.
            if !registry.lastLoadIssues.isEmpty {
                Divider()
                LoadIssuesFootnote(issues: registry.lastLoadIssues)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    // Removed toolbar as it's now inline

    // MARK: - Preview pane

    private var preview: some View {
        VStack(spacing: 12) {
            if let pet = previewPet {
                AnimatedGIFView(
                    gifData: pet.assets.gifData(previewBehavior.gifKey),
                    pngData: pet.assets.basePNGData(),
                    // Key on pet + behavior so switching either re-mounts the
                    // correct loop.
                    key: "\(pet.id)-\(previewBehavior.gifKey)"
                )
                .frame(width: 140, height: 140)
                .background(checkerboard)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(pet.name).font(.headline)

                Picker("", selection: $previewBehavior) {
                    ForEach(PreviewBehavior.allCases, id: \.self) { b in
                        Text(b.label).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                
                HStack(spacing: 8) {
                    let isBuiltin = registry.isBuiltin(id: pet.id)
                    Button("Edit") {
                        coordinator.openEditor(editing: isBuiltin ? duplicate(pet) : pet)
                    }
                    Button("Duplicate") {
                        do {
                            let dupe = duplicate(pet)
                            try registry.add(dupe)
                            registry.activePetID = dupe.id
                        } catch {
                            coordinator.presentError(error)
                        }
                    }
                    Button("Delete") {
                        confirmDelete(pet)
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            } else {
                Text("No pets installed.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A subtle checker so transparent pixel art reads against the pane.
    private var checkerboard: some View {
        Color(nsColor: .controlBackgroundColor)
    }

    // MARK: - Actions

    /// Clone a (usually built-in) pet into an editable custom one: new id, a
    /// "Copy" name so the original stays put, same art and templates.
    private func duplicate(_ pet: PetDefinition) -> PetDefinition {
        PetDefinition(
            id: "custom-\(Self.shortHex())",
            name: "\(pet.name) Copy",
            speechTemplates: pet.speechTemplates,
            animationProfile: pet.animationProfile,
            assets: pet.assets
        )
    }

    private func confirmDelete(_ pet: PetDefinition?) {
        guard let pet else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(pet.name)\"?"
        alert.informativeText = "This moves the pet file to the Trash. It will be permanently deleted after 30 days."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try registry.delete(id: pet.id) }
            catch { coordinator.presentError(error) }
        }
    }

    /// 8 hex chars of a UUID — matches the registry's own import-suffix style so
    /// custom ids look consistent regardless of where they were minted.
    static func shortHex() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

// MARK: - Row

private struct PetRow: View {
    let pet: PetDefinition
    let isActive: Bool
    let isBuiltin: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Radio: tapping the row OR the dot selects (= activates) the pet.
            Button(action: select) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            thumbnail
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(pet.name).font(.body)
            }

            Spacer()

            if isBuiltin {
                Text("Built-in")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    /// Static base PNG as the row thumbnail (cheap; no animation in the list).
    @ViewBuilder private var thumbnail: some View {
        if let data = pet.assets.basePNGData(), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)   // keep pixel art crisp
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2))
        }
    }
}

// MARK: - Load issues footnote

private struct LoadIssuesFootnote: View {
    let issues: [String]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(issues, id: \.self) { issue in
                    Text(issue).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("\(issues.count) pet\(issues.count == 1 ? "" : "s") couldn't be loaded",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Preview behavior selector

/// The behaviors the preview pane can cycle. Distinct from `PetBehavior` because
/// the preview also shows the entrance/exit animations the runtime never picks
/// as a steady state — the editor and library want to vet every gif slot.
enum PreviewBehavior: CaseIterable {
    case idle, track, alert, flyIn, flyOut

    var gifKey: String {
        switch self {
        case .idle:   return "idle"
        case .track:  return "track"
        case .alert:  return "alert"
        case .flyIn:  return "fly_in"
        case .flyOut: return "fly_out"
        }
    }

    var label: String {
        switch self {
        case .idle:   return "Idle"
        case .track:  return "Track"
        case .alert:  return "Alert"
        case .flyIn:  return "In"
        case .flyOut: return "Out"
        }
    }
}
