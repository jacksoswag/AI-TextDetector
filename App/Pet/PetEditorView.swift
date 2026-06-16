import SwiftUI
import AppKit
import FilterCore
import UniformTypeIdentifiers

/// The pet creator/editor. Holds a fully mutable in-memory draft (a pet under
/// construction is allowed to be invalid — `PetDefinition.validate()` only
/// gates the save), exposes every authored field SwiftUI-side, and on Save
/// assembles a `PetDefinition`, validates it, and routes it to the registry.
///
/// Validation failures stay inline (a red footnote) and keep the window open,
/// because losing a half-built pet to a modal dismissal would be infuriating.
/// Built-ins never reach this view editable: the library hands us a duplicated
/// copy with a fresh custom id, so "editing a built-in" is impossible by
/// construction.
struct PetEditorView: View {
    @ObservedObject var registry: PetRegistry
    /// Called after a successful save (or Cancel) so the coordinator can close
    /// the window — the view doesn't own its window.
    let dismiss: () -> Void

    /// The draft. Seeded from the pet being edited, or a blank template.
    @State private var draft: Draft
    /// Whether we're updating an existing user pet (keep its id) vs. creating
    /// (mint a fresh custom id on save).
    private let isEditingExisting: Bool

    /// Inline validation message; nil when the draft last validated clean.
    @State private var errorText: String?

    init(registry: PetRegistry, editing pet: PetDefinition?, dismiss: @escaping () -> Void) {
        self.registry = registry
        self.dismiss = dismiss
        if let pet {
            _draft = State(initialValue: Draft(pet))
            isEditingExisting = true
        } else {
            _draft = State(initialValue: Draft.blank())
            isEditingExisting = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    speechSection
                    assetsSection
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Identity")
            HStack(spacing: 16) {
                HStack {
                    Text("Name")
                    TextField("Sprout", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)
                }
                HStack {
                    Text("Personality")
                    Picker("", selection: $draft.personality) {
                        ForEach(PetPersonality.allCases, id: \.self) { p in
                            Text(p.rawValue.capitalized).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
            }
        }
    }

    // MARK: - Speech

    private var speechSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Speech")

            // One tab per required state key — the keys ARE the contract with
            // the detection layer, so we drive directly off requiredStateKeys.
            Picker("", selection: $draft.selectedStateKey) {
                ForEach(PetDefinition.requiredStateKeys, id: \.self) { key in
                    Text(stateLabel(key)).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            SpeechLineEditor(
                lines: bindingForLines(draft.selectedStateKey),
                stateLabel: stateLabel(draft.selectedStateKey)
            )
        }
    }

    /// Binding into the draft's per-state line array for the selected key,
    /// creating an empty array on first edit of a state.
    private func bindingForLines(_ key: String) -> Binding<[String]> {
        Binding(
            get: { draft.speech[key] ?? [] },
            set: { draft.speech[key] = $0 }
        )
    }

    // MARK: - Assets

    private var assetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Assets")
            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                AssetWell(title: "Base Image", required: true, isGIF: false,
                          base64: $draft.basePNG)
                ForEach(GIFSlot.allCases, id: \.self) { slot in
                    AssetWell(title: slot.title, required: false, isGIF: true,
                              base64: bindingForGIF(slot.key))
                }
            }
        }
    }

    private func bindingForGIF(_ key: String) -> Binding<String> {
        Binding(
            get: { draft.gifs[key] ?? "" },
            set: { newValue in
                if newValue.isEmpty { draft.gifs.removeValue(forKey: key) }
                else { draft.gifs[key] = newValue }
            }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    // MARK: - Save

    /// Assemble → validate → persist. On a validation error we stash the
    /// human-readable message and keep the window open so the user can fix the
    /// offending field; a registry error (e.g. a duplicate id) shows the same
    /// way.
    private func save() {
        let pet = draft.build(
            id: isEditingExisting ? draft.existingID : "custom-\(PetLibraryView.shortHex())"
        )
        do {
            try pet.validate()
            if isEditingExisting {
                try registry.update(pet)
            } else {
                try registry.add(pet)
            }
            errorText = nil
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    /// Human label for a frozen state raw value.
    private func stateLabel(_ key: String) -> String {
        switch key {
        case "very_high": return "Very High"
        default:          return key.capitalized
        }
    }
}

// MARK: - Speech line editor

/// Editable list of lines for one state: a text field per line plus add/remove.
/// Trimming happens at save (on the assembled draft), so the user can type
/// freely here including trailing spaces mid-edit.
private struct SpeechLineEditor: View {
    @Binding var lines: [String]
    let stateLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lines.isEmpty {
                Text("Using default line: \"\(stateLabel)\"")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lines.indices, id: \.self) { index in
                HStack {
                    TextField("What the mascot says…", text: $lines[index])
                        .textFieldStyle(.roundedBorder)
                    Button {
                        lines.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                lines.append("")
            } label: {
                Label("Add line", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .controlSize(.small)
        }
    }
}

// MARK: - Asset well

/// One asset slot: a preview (animated for gif, static for png) and a Choose…
/// button that base64-encodes the picked file into the draft. Clears via a
/// small remove button when populated.
private struct AssetWell: View {
    let title: String
    let required: Bool
    let isGIF: Bool
    @Binding var base64: String

    private var data: Data? { Data(base64Encoded: base64) }

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 48, height: 48)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.callout)
                    if required {
                        Text("(required)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(base64.isEmpty ? "Not set" : "\(byteCount) bytes")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            if !base64.isEmpty {
                Button {
                    base64 = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Button("Choose…") { choose() }
                .controlSize(.small)
        }
    }

    private var byteCount: Int { data?.count ?? 0 }

    @ViewBuilder private var preview: some View {
        if isGIF, !base64.isEmpty, let data {
            AnimatedGIFView(gifData: data, pngData: nil, key: "\(title)-\(data.count)")
        } else if let data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: isGIF ? "play.rectangle" : "photo")
                .foregroundStyle(.tertiary)
        }
    }

    /// Pick a file of the right type and fold its raw bytes into the draft as
    /// base64. We store bytes, not a path, so the pet stays a single shareable
    /// file (matching `PetAssets`' base64 contract).
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = isGIF ? [.gif] : [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let fileData = try? Data(contentsOf: url) else { return }
        base64 = fileData.base64EncodedString()
    }
}

// MARK: - GIF slots

/// The five optional animation slots, in the order they appear in the editor.
private enum GIFSlot: CaseIterable {
    case idle, track, alert, flyIn, flyOut

    var key: String {
        switch self {
        case .idle:   return "idle"
        case .track:  return "track"
        case .alert:  return "alert"
        case .flyIn:  return "fly_in"
        case .flyOut: return "fly_out"
        }
    }

    var title: String {
        switch self {
        case .idle:   return "Idle GIF"
        case .track:  return "Track GIF"
        case .alert:  return "Alert GIF"
        case .flyIn:  return "Fly-in GIF"
        case .flyOut: return "Fly-out GIF"
        }
    }
}

// MARK: - Draft model

/// Mutable working copy of a pet. Separate from `PetDefinition` precisely
/// because a definition is immutable and validated; a draft is neither while
/// the user is mid-edit. `build(id:)` collapses it back into a definition.
private struct Draft {
    var existingID: String = ""
    var name: String = ""
    var personality: PetPersonality = .companion
    var speech: [String: [String]] = [:]
    var gifs: [String: String] = [:]
    var basePNG: String = ""
    /// The speech tab currently in front. Defaults to the first state key.
    var selectedStateKey: String = PetDefinition.requiredStateKeys[0]

    init(_ pet: PetDefinition) {
        existingID = pet.id
        name = pet.name
        personality = pet.personalityBase
        speech = pet.speechTemplates
        gifs = pet.assets.gifs
        basePNG = pet.assets.basePNG
    }

    private init() {}

    /// A blank draft pre-seeded with empty arrays for every required state, so
    /// the speech tabs all render their "add a line" affordance immediately.
    static func blank() -> Draft {
        var d = Draft()
        for key in PetDefinition.requiredStateKeys { d.speech[key] = [] }
        return d
    }

    /// Collapse the draft into a definition. Trims every speech line and drops
    /// the empties (validate() then catches a state left with nothing usable);
    /// the animation profile keys are fixed names the runtime resolves against
    /// the gif dictionary.
    func build(id: String) -> PetDefinition {
        var trimmedSpeech: [String: [String]] = [:]
        for key in PetDefinition.requiredStateKeys {
            let lines = speech[key] ?? []
            let kept = lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let category = key == "very_high" ? "Very High" : key.capitalized
            trimmedSpeech[key] = kept.isEmpty ? [category] : kept
        }
        return PetDefinition(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            personalityBase: personality,
            speechTemplates: trimmedSpeech,
            animationProfile: PetAnimationProfile(idle: "idle", track: "track", alert: "alert"),
            assets: PetAssets(basePNG: basePNG, gifs: gifs)
        )
    }
}
