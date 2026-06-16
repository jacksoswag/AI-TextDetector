import Foundation

/// Deterministic template selection — the pet's voice box.
///
/// Spec: `index = hash(block id + pet id + state) % template count`. The same
/// block, pet, and verdict must produce the same line on every visit, every
/// launch, every machine: stable reactions are what make the pet read as
/// having opinions rather than rolling dice. No randomness and no LLM by
/// design — speech, like scoring, stays deterministic and offline.
public enum PetSpeechEngine {

    /// FNV-1a, 64-bit, over UTF-8 bytes.
    ///
    /// Swift's `hashValue`/`Hasher` is forbidden here: it is seeded with a
    /// per-process random value (deliberate hash-flooding hardening), so the
    /// "same" hash changes on every launch — the pet would greet the same
    /// paragraph with a different line after every restart. FNV-1a is fixed
    /// forever, trivial to implement exactly, and has published test vectors
    /// the tests pin (`hash("") == 0xcbf29ce484222325`,
    /// `hash("a") == 0xaf63dc4c8601ec8c`).
    public static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV offset basis
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3               // FNV prime
        }
        return hash
    }

    /// The line a pet says about a block in a given state, or nil when the
    /// pet has nothing authored for that state (callers fall back to silence,
    /// not a default phrase — silence is a valid personality trait).
    ///
    /// The "|" separators keep distinct inputs distinct: plain concatenation
    /// would hash ("ab", "c") and ("a", "bc") identically.
    public static func line(blockID: String, petID: String, stateKey: String,
                            templates: [String: [String]]) -> String? {
        guard let lines = templates[stateKey], !lines.isEmpty else { return nil }
        let hash = stableHash(blockID + "|" + petID + "|" + stateKey)
        return lines[Int(hash % UInt64(lines.count))]
    }
}
