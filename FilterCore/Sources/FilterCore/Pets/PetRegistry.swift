import Foundation
import Combine

/// Why a registry operation was refused. Distinct from `PetValidationError`:
/// that one means "this pet is malformed", this one means "the pet is fine
/// but the operation doesn't apply" — the UI routes them differently (editor
/// field hints vs. an alert).
public enum PetRegistryError: Error, Equatable, Sendable, LocalizedError {
    case duplicateID(String)
    case builtinIsReadOnly(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateID(let id):
            return "A pet with id \"\(id)\" already exists."
        case .builtinIsReadOnly(let id):
            return "\"\(id)\" is a built-in pet and cannot be modified or deleted."
        case .notFound(let id):
            return "No pet with id \"\(id)\"."
        }
    }
}

/// Source of truth for which pets exist and which one is active.
///
/// Two tiers with different ownership: built-ins ship read-only inside the app
/// bundle, user pets live as one JSON file each under Application Support and
/// are the only tier CRUD touches. `@unchecked Sendable` on the same terms as
/// `DomainTrustManager`: an NSLock serializes mutation so an off-main import
/// or export can't corrupt state, while `@Published` values are written on
/// whatever thread called the mutator — the app drives this object from the
/// main thread (a SwiftUI requirement, not enforced here).
public final class PetRegistry: ObservableObject, @unchecked Sendable {

    /// Also erased by `PrivacyManager.eraseAllLocalData` — keep the literal in
    /// sync there.
    public static let activeIDKey = "pets.activeID"

    private let builtinDirectory: URL?
    public let userDirectory: URL
    private let defaults: UserDefaults
    private let lock = NSLock()

    private var builtinIDs: Set<String> = []
    /// Which file actually served each user pet. Saves write canonically to
    /// `<id>.json`, but a hand-dropped "mypet.json" holding id "zippy" is
    /// legal — update and delete must hit the file that exists, or the stale
    /// copy resurrects the pet on the next load.
    private var userFileURLs: [String: URL] = [:]

    /// Built-ins first (sorted by id), then user pets (sorted by id) — one
    /// canonical order so a live registry and a freshly reloaded one can never
    /// disagree, regardless of FileManager enumeration order.
    @Published public private(set) var pets: [PetDefinition] = []

    /// Files skipped on the last `loadAll()`, as "file: reason" strings.
    /// Published so settings UI can say "2 pets could not be loaded" instead
    /// of letting them silently vanish.
    @Published public private(set) var lastLoadIssues: [String] = []

    private var deletedBuiltinIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "deletedBuiltinIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "deletedBuiltinIDs") }
    }

    /// Persisted selection. It may reference a pet that no longer resolves
    /// (deleted file, retired built-in); `activePet` falls back at read time
    /// while the stored value is left alone, so a selection pointing at a
    /// temporarily missing pet heals itself when the file returns.
    @Published public var activePetID: String {
        didSet { defaults.set(activePetID, forKey: Self.activeIDKey) }
    }

    public static let nonePet = PetDefinition(
        id: "none",
        name: "None",
        speechTemplates: [
            "safe": [
                "Rhythm and word choice vary naturally. This reads human.",
                "Burstiness is healthy. No machine fingerprints found.",
                "Sentence lengths swing like a person wrote them. Clear.",
                "Vocabulary is irregular in the good way. Human signal.",
                "No template structures detected. Looks organic.",
                "Typos, tangents, texture. People write like this."
            ],
            "uncertain": [
                "Mixed signals. I would not call this either way.",
                "Some even pacing, but plenty of human noise. Inconclusive.",
                "The data is ambiguous. Withholding judgment.",
                "Short sample, weak signal. Treat any score as a guess.",
                "Could be edited prose, could be a model. Not enough evidence.",
                "I see overlap with both styles. No verdict from me."
            ],
            "suspicious": [
                "Sentence rhythm is unusually even here.",
                "Low burstiness and tidy transitions. Worth a closer look.",
                "Hedged claims, balanced clauses. A familiar pattern.",
                "Word variety is flatter than typical human prose.",
                "Every paragraph lands at the same length. Notable.",
                "Connective phrasing looks templated. Keep that in mind."
            ],
            "high": [
                "Multiple stylometric markers align with AI generation.",
                "Uniform cadence, stock phrasing, zero typos. Strong signal.",
                "This matches model output on most of my checks.",
                "Statistically, humans rarely write this evenly.",
                "High confidence: the structure here is machine-typical.",
                "The fingerprint is consistent across the whole passage."
            ],
            "very_high": [
                "Provenance markers indicate machine generation. Near certain.",
                "Every check I ran agrees: this is model output.",
                "Confidence is at the top of my scale. AI-written.",
                "This is as close to certain as my analysis gets.",
                "Signal saturation. I would file this as AI text.",
                "Generated text, with metadata to match. Case closed."
            ]
        ],
        animationProfile: PetAnimationProfile(idle: "idle", track: "track", alert: "alert"),
        assets: PetAssets(basePNG: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", gifs: [:])
    )

    public init(builtinDirectory: URL?,
                userDirectory: URL = AppInfo.supportDirectory.appendingPathComponent("Pets"),
                defaults: UserDefaults = .appGroup) {
        self.builtinDirectory = builtinDirectory
        self.userDirectory = userDirectory
        self.defaults = defaults
        self.activePetID = defaults.string(forKey: Self.activeIDKey) ?? ""
        loadAll()
    }

    /// The app's wiring: built-ins ride in the bundle's Pets/ resource folder.
    /// (Bundle integration lands with the app target; FilterCore itself stays
    /// bundle-agnostic and testable through the designated initializer.)
    public convenience init() {
        self.init(builtinDirectory: Bundle.main.resourceURL?.appendingPathComponent("Pets"))
    }

    // MARK: - Loading

    /// Re-scan both directories. Invalid files are skipped and reported, never
    /// fatal: one corrupt download must not take down the whole pet system.
    /// On id collisions the earlier tier wins (built-ins shadow user files),
    /// so `isBuiltin(id:)` stays unambiguous.
    public func loadAll() {
        var issues: [String] = []

        var builtinLoaded: [(url: URL, pet: PetDefinition)] = []
        if let builtinDirectory {
            builtinLoaded = Self.decode(in: builtinDirectory, issues: &issues)
        }
        let userLoaded = Self.decode(in: userDirectory, issues: &issues)

        var seen = Set<String>()
        func unique(_ entries: [(url: URL, pet: PetDefinition)]) -> [(url: URL, pet: PetDefinition)] {
            entries.filter { entry in
                if seen.insert(entry.pet.id).inserted { return true }
                issues.append("\(entry.url.lastPathComponent): duplicate pet id \"\(entry.pet.id)\" — skipped")
                return false
            }
        }
        let builtin = unique(builtinLoaded).filter { !deletedBuiltinIDs.contains($0.pet.id) }
        let user = unique(userLoaded)

        lock.lock(); defer { lock.unlock() }
        builtinIDs = Set(builtin.map(\.pet.id))
        userFileURLs = Dictionary(uniqueKeysWithValues: user.map { ($0.pet.id, $0.url) })
        pets = builtin.map(\.pet) + user.map(\.pet)
        lastLoadIssues = issues
    }

    /// Decode + validate every *.json in `directory`. Files are visited in
    /// filename order so duplicate-id resolution is stable across filesystems;
    /// the result is re-sorted by pet id because filenames are not guaranteed
    /// to match ids.
    private static func decode(in directory: URL,
                               issues: inout [String]) -> [(url: URL, pet: PetDefinition)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else {
            return []   // missing directory is the empty tier, not an error
        }
        let files = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [(url: URL, pet: PetDefinition)] = []
        for file in files {
            do {
                let pet = try JSONDecoder().decode(PetDefinition.self, from: Data(contentsOf: file))
                try pet.validate()
                loaded.append((file, pet))
            } catch {
                issues.append("\(file.lastPathComponent): \(describe(error))")
            }
        }
        return loaded.sorted { $0.pet.id < $1.pet.id }
    }

    /// Validation errors read well via LocalizedError; DecodingError's
    /// localizedDescription hides the useful part, so fall back to the full
    /// debug description for anything else.
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: - Reading

    /// The pet the UI should show: the stored selection, else the first
    /// built-in (the one tier guaranteed present in a shipping app), else
    /// whatever exists.
    public var activePet: PetDefinition? {
        lock.lock(); defer { lock.unlock() }
        if activePetID == "" { return PetRegistry.nonePet }
        return pets.first { $0.id == activePetID }
            ?? pets.first { builtinIDs.contains($0.id) }
            ?? pets.first
    }

    public func isBuiltin(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return builtinIDs.contains(id)
    }

    // MARK: - CRUD (user tier only)

    /// Persist a brand-new user pet. Collisions are an error, not an
    /// overwrite: "add" coming from the editor must never clobber a built-in
    /// or an existing custom pet. Imports rename instead — see `importPet`.
    public func add(_ pet: PetDefinition) throws {
        try pet.validate()
        lock.lock(); defer { lock.unlock() }
        guard !pets.contains(where: { $0.id == pet.id }) else {
            throw PetRegistryError.duplicateID(pet.id)
        }
        try persist(pet)
        pets.append(pet)
        resort()
    }

    /// Replace an existing user pet. A pet's id is its identity — "renaming"
    /// is delete + add, never an update that strands the old file.
    public func update(_ pet: PetDefinition) throws {
        try pet.validate()
        lock.lock(); defer { lock.unlock() }
        guard !builtinIDs.contains(pet.id) else {
            throw PetRegistryError.builtinIsReadOnly(pet.id)
        }
        guard let index = pets.firstIndex(where: { $0.id == pet.id }) else {
            throw PetRegistryError.notFound(pet.id)
        }
        try persist(pet)
        pets[index] = pet
    }

    /// Remove a user pet (entry and file). If it was active, selection falls
    /// back to the first built-in so the pet on screen never just vanishes.
    public func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = pets.firstIndex(where: { $0.id == id }) else {
            throw PetRegistryError.notFound(id)
        }
        if builtinIDs.contains(id) {
            var deleted = deletedBuiltinIDs
            deleted.insert(id)
            deletedBuiltinIDs = deleted
            builtinIDs.remove(id)
        } else {
            // Move to trash so the user has 30 days to recover it.
            let url = userFileURLs[id] ?? fileURL(for: id)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            userFileURLs.removeValue(forKey: id)
        }
        pets.remove(at: index)
        if activePetID == id {
            activePetID = pets.first?.id ?? ""
        }
    }

    // MARK: - Sharing

    /// Bring an external .json into the user tier. On id collision the import
    /// gets a fresh id ("<original>-<8 hex>") rather than failing or
    /// overwriting: people share pets, and a friend's "sprout" must coexist
    /// with the "sprout" already installed.
    @discardableResult
    public func importPet(from url: URL) throws -> PetDefinition {
        let data = try Data(contentsOf: url)
        var pet = try JSONDecoder().decode(PetDefinition.self, from: data)
        try pet.validate()

        lock.lock(); defer { lock.unlock() }
        let originalID = pet.id
        while pets.contains(where: { $0.id == pet.id }) {
            pet = pet.withID("\(originalID)-\(Self.importSuffix())")
        }
        try persist(pet)
        pets.append(pet)
        resort()
        return pet
    }

    /// Write one pet as a standalone shareable file. Built-ins export too —
    /// export-then-import is how a built-in becomes the starting point of a
    /// custom pet.
    public func exportPet(id: String, to url: URL) throws {
        lock.lock()
        let pet = pets.first { $0.id == id }
        lock.unlock()
        guard let pet else { throw PetRegistryError.notFound(id) }
        try Self.encode(pet).write(to: url, options: .atomic)
    }

    // MARK: - Files

    /// One file per pet. Pretty-printed with sorted keys: these files are
    /// hand-editable and shareable, so byte-stable, diffable output matters
    /// more than write speed.
    private static func encode(_ pet: PetDefinition) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(pet)
    }

    private func fileURL(for id: String) -> URL {
        userDirectory.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func persist(_ pet: PetDefinition) throws {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let url = userFileURLs[pet.id] ?? fileURL(for: pet.id)
        try Self.encode(pet).write(to: url, options: .atomic)
        userFileURLs[pet.id] = url
    }

    /// Restore the canonical order after an append — matches what `loadAll()`
    /// produces.
    private func resort() {
        pets.sort { a, b in
            let aBuiltin = builtinIDs.contains(a.id)
            let bBuiltin = builtinIDs.contains(b.id)
            if aBuiltin != bBuiltin { return aBuiltin }
            return a.id < b.id
        }
    }

    /// 8 hex chars of a UUID — short enough to read aloud, random enough that
    /// the collision loop above is theater.
    private static func importSuffix() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
