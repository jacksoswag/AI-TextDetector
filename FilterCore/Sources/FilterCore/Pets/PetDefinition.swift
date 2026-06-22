import Foundation

// Every Codable type in this file declares EXPLICIT CodingKeys, even where the
// key matches the property name. Pet JSON is a user-facing file format — it
// ships in the bundle, lives in Application Support, and gets traded between
// people — so a Swift property rename must never silently change the wire
// format. Same policy as DetectionState's frozen raw values.

/// Why a pet definition was rejected. Typed (not stringly) so the pet editor
/// can map each case onto the offending field; the strings below exist for
/// log lines and `PetRegistry.lastLoadIssues`.
public enum PetValidationError: Error, Equatable, Sendable, LocalizedError {
    case emptyID
    case emptyName
    /// The state key is absent from `speech_templates`, or none of its lines
    /// survive whitespace trimming — both leave the pet mute for that state.
    case missingTemplates(stateKey: String)
    /// `base_png` is not decodable base64, or decodes to zero bytes.
    case undecodableBaseImage

    public var errorDescription: String? {
        switch self {
        case .emptyID:
            return "Pet id must not be empty."
        case .emptyName:
            return "Pet name must not be empty."
        case .missingTemplates(let stateKey):
            return "No usable speech template for state \"\(stateKey)\"."
        case .undecodableBaseImage:
            return "base_png is not valid base64 image data."
        }
    }
}


/// Names of the animation styles the UI should play per behavior. Free-form
/// strings rather than an enum so a pet file can reference styles added in a
/// later app version without invalidating itself on the current one.
public struct PetAnimationProfile: Codable, Equatable, Sendable {
    public let idle: String
    public let track: String
    public let alert: String

    private enum CodingKeys: String, CodingKey {
        case idle, track, alert
    }

    public init(idle: String, track: String, alert: String) {
        self.idle = idle
        self.track = track
        self.alert = alert
    }
}

/// Artwork travels inside the JSON as base64 so a custom pet is exactly one
/// shareable file — no sidecar images to lose in transit. Bytes are decoded
/// on demand because the registry round-trips definitions far more often than
/// the UI rasterizes one.
public struct PetAssets: Codable, Equatable, Sendable {
    public let basePNG: String
    /// Animation loops keyed "idle" / "track" / "alert" / "fly_in" / "fly_out".
    /// Progressive enhancement: a pet with only `base_png` still works (the UI
    /// falls back to the static image), so `validate()` does not require gifs.
    public let gifs: [String: String]

    private enum CodingKeys: String, CodingKey {
        case basePNG = "base_png"
        case gifs
    }

    public init(basePNG: String, gifs: [String: String]) {
        self.basePNG = basePNG
        self.gifs = gifs
    }

    public func basePNGData() -> Data? {
        Data(base64Encoded: basePNG)
    }

    public func gifData(_ key: String) -> Data? {
        gifs[key].flatMap { Data(base64Encoded: $0) }
    }
}

/// One pet, as authored. The struct mirrors the bundled-JSON contract; the
/// behavioral pieces that interpret it live elsewhere (`PetSpeechEngine`
/// picks lines, `PetStateMachine` picks behaviors) so a definition stays a
/// dumb, fully serializable value.
public struct PetDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Lines keyed by `DetectionState` raw value. A dictionary rather than a
    /// struct of five arrays because the keys ARE the contract with the
    /// detection layer — see `requiredStateKeys`.
    public let speechTemplates: [String: [String]]
    public let animationProfile: PetAnimationProfile
    public let assets: PetAssets

    private enum CodingKeys: String, CodingKey {
        case id, name, assets
        case speechTemplates = "speech_templates"
        case animationProfile = "animation_profile"
    }

    /// `DetectionState.allCases` raw values, restated literally. Restated —
    /// not derived — so the file-format contract is legible in one place, and
    /// so adding a `DetectionState` case (which would instantly invalidate
    /// every pet file in the wild) is a decision someone has to make here on
    /// purpose. PetCoreTests pins the two lists together.
    public static let requiredStateKeys = ["safe", "uncertain", "suspicious", "high", "very_high"]

    public init(id: String, name: String,
                speechTemplates: [String: [String]], animationProfile: PetAnimationProfile,
                assets: PetAssets) {
        self.id = id
        self.name = name
        self.speechTemplates = speechTemplates
        self.animationProfile = animationProfile
        self.assets = assets
    }

    /// Same pet under a new identity — the import-collision path needs to
    /// re-key a definition without hand-copying the other fields.
    public func withID(_ newID: String) -> PetDefinition {
        PetDefinition(id: newID, name: name,
                      speechTemplates: speechTemplates, animationProfile: animationProfile,
                      assets: assets)
    }

    /// Validation lives at the boundary, not in `init` or `decode`: the editor
    /// needs to hold half-finished pets in memory, but nothing reaches the
    /// registry, the speech engine, or disk without passing here first.
    public func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PetValidationError.emptyID
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PetValidationError.emptyName
        }
        // Data(base64Encoded:) returns empty (non-nil) Data for "", so the
        // emptiness check is load-bearing, not paranoia.
        guard let png = assets.basePNGData(), !png.isEmpty else {
            throw PetValidationError.undecodableBaseImage
        }
    }
}
