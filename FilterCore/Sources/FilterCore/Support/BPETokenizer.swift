import Foundation

/// Minimal byte-level BPE tokenizer for the ModernBERT family. Dependency-free,
/// like `WordPieceTokenizer`. Implements the GPT-2 byte-to-unicode scheme with
/// the standard BPE merge algorithm, suitable for any model trained with
/// HuggingFace's ByteLevel pre-tokenizer.
///
/// File formats (produced by scripts/convert-stage2-modernbert.py):
///   bpe-vocab.json    {"token": id, ...}     full token → id vocabulary
///   bpe-merges.json   [[a, b], ...]          merge pairs, index 0 = highest priority
///
/// The vocab file path is specified in model-info.json as
/// `tokenizer.vocab_file = "bpe-vocab.json"`; the merges file is resolved from
/// the same directory by replacing "vocab" with "merges".
public struct BPETokenizer: Sendable {

    // Re-use WordPieceTokenizer's SpecialTokens — same {cls, sep, pad, unk: Int32}
    // shape. No dependency on the WordPiece algorithm itself.
    public typealias SpecialTokens = WordPieceTokenizer.SpecialTokens

    private let vocab: [String: Int32]
    private let merges: [MergeKey: Int]
    private let special: SpecialTokens
    /// Whitespace "added tokens": vocab entries that are a run of 2+ raw spaces
    /// (e.g. "    " → the 4-space id). The HF tokenizer matches these literal
    /// runs BEFORE byte-level encoding, and the word after a run is then bare
    /// (no "Ġ" prefix). Byte-level encoding alone would mis-tokenize multi-space
    /// and indented (code) text, so we split runs out first. Sorted longest-first
    /// for greedy leftmost-longest matching, mirroring HF added-token behavior.
    private let spaceTokens: [(count: Int, id: Int32)]

    private struct MergeKey: Hashable, Sendable {
        let first: String
        let second: String
    }

    public init(vocabFile: URL, special: SpecialTokens) throws {
        // Vocab: {"token": id, ...}
        let vocabData = try Data(contentsOf: vocabFile)
        let rawVocab = try JSONDecoder().decode([String: Int32].self, from: vocabData)
        self.vocab = rawVocab

        // Merges: [[a, b], ...] in priority order. Adjacent to the vocab file.
        let mergesURL = vocabFile.deletingLastPathComponent()
            .appendingPathComponent(
                vocabFile.lastPathComponent.replacingOccurrences(of: "vocab", with: "merges"))
        let mergesData = try Data(contentsOf: mergesURL)
        let rawMerges = try JSONDecoder().decode([[String]].self, from: mergesData)
        var m = [MergeKey: Int](minimumCapacity: rawMerges.count)
        for (i, pair) in rawMerges.enumerated() where pair.count == 2 {
            m[MergeKey(first: pair[0], second: pair[1])] = i
        }
        self.merges = m
        self.special = special

        // Pure-space vocab entries of length >= 2 are the whitespace added tokens.
        self.spaceTokens = rawVocab.compactMap { (key: String, id: Int32) -> (count: Int, id: Int32)? in
            guard key.count >= 2, key.allSatisfy({ $0 == " " }) else { return nil }
            return (key.count, id)
        }.sorted { $0.count > $1.count }
    }

    // MARK: - PieceTokenizing (contentIDs + assemble; assemble is shared via WordPieceTokenizer)

    public func contentIDs(_ text: String, limit: Int = .max) -> [Int32] {
        // No whitespace added tokens → pure byte-level BPE (the GPT-2 path).
        guard !spaceTokens.isEmpty else { return Array(byteLevelIDs(text).prefix(limit)) }

        // Split on runs of 2+ spaces, which match dedicated whitespace tokens
        // ahead of byte-level encoding; byte-level-BPE the segments between runs.
        var ids: [Int32] = []
        var segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            ids.append(contentsOf: byteLevelIDs(segment))
            segment.removeAll(keepingCapacity: true)
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == " " {
                var run = 0
                while i + run < chars.count, chars[i + run] == " " { run += 1 }
                if run >= 2 {
                    // Greedy leftmost-longest into whitespace tokens; a leftover
                    // single space (a run length no token sum reaches exactly)
                    // stays in the stream to become the next word's leading space.
                    var runIDs: [Int32] = []
                    var rem = run
                    while rem >= 2, let tok = spaceTokens.first(where: { $0.count <= rem }) {
                        runIDs.append(tok.id); rem -= tok.count
                    }
                    if !runIDs.isEmpty {
                        flush()
                        ids.append(contentsOf: runIDs)
                        i += run - rem      // leave `rem` (0 or 1) spaces behind
                        continue
                    }
                }
            }
            segment.append(chars[i])
            i += 1
        }
        flush()
        return ids.count > limit ? Array(ids.prefix(limit)) : ids
    }

    /// Byte-level GPT-2 BPE over a whitespace-run-free segment.
    private func byteLevelIDs(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        let ns = text as NSString
        let matches = Self.preTokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let chunk = ns.substring(with: m.range)
            for token in applyBPE(byteEncode(chunk)) {
                ids.append(vocab[token] ?? special.unk)
            }
        }
        return ids
    }

    // MARK: - Byte-level encoding

    /// Map a string to its GPT-2 byte-level unicode representation: each UTF-8
    /// byte becomes one unicode character via the fixed 256-entry table. The
    /// resulting [String] elements are the initial BPE units before merging.
    private func byteEncode(_ s: String) -> [String] {
        var result = [String]()
        result.reserveCapacity(s.utf8.count)
        for byte in s.utf8 {
            // byteToUnicode covers all 256 byte values — force-unwrap is safe.
            result.append(String(Self.byteToUnicode[Int(byte)]))
        }
        return result
    }

    // MARK: - BPE merge application

    private func applyBPE(_ tokens: [String]) -> [String] {
        var toks = tokens
        while toks.count >= 2 {
            // Linear scan for the highest-priority (lowest index) merge pair.
            var bestPriority = Int.max
            var bestIdx = -1
            for i in 0..<toks.count - 1 {
                let key = MergeKey(first: toks[i], second: toks[i + 1])
                if let p = merges[key], p < bestPriority {
                    bestPriority = p
                    bestIdx = i
                }
            }
            guard bestIdx >= 0 else { break }
            toks[bestIdx] = toks[bestIdx] + toks[bestIdx + 1]
            toks.remove(at: bestIdx + 1)
        }
        return toks
    }

    // MARK: - Static tables

    /// GPT-2 bytes_to_unicode() mapping baked as a 256-entry array indexed by
    /// byte value. Printable ASCII (33–126), ¡–¬ (161–172), and ®–ÿ (174–255)
    /// map to themselves; the remaining 68 control/non-printing bytes map to
    /// unicode codepoints 256–323 (Ā–ģ).
    private static let byteToUnicode: [Character] = {
        var table = [Character](repeating: "\0", count: 256)
        var overflow = 256
        for i in 0...255 {
            let b = UInt8(i)
            if (33...126).contains(b) || (161...172).contains(b) || (174...255).contains(b) {
                table[i] = Character(UnicodeScalar(UInt32(b))!)
            } else {
                table[i] = Character(UnicodeScalar(UInt32(overflow))!)
                overflow += 1
            }
        }
        return table
    }()

    /// Simplified GPT-2 pre-tokenizer: captures contractions, optional-space +
    /// letters/digits/other-non-whitespace, and trailing whitespace runs.
    /// Matches HuggingFace's ByteLevel pre-tokenizer with use_regex=true on the
    /// English and mixed-language text this product scores.
    private static let preTokenRegex: NSRegularExpression = {
        let p = #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
        return try! NSRegularExpression(pattern: p)
    }()
}

extension BPETokenizer: PieceTokenizing {}
