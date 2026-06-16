import Foundation

/// Minimal BERT-style WordPiece tokenizer (basic tokenization + greedy
/// longest-match subwords). Dependency-free; covers the uncased e5/MiniLM
/// family used by the bundled classifier. Not a general-purpose HF tokenizer.
public struct WordPieceTokenizer: Sendable {

    public struct SpecialTokens: Codable, Sendable {
        public let cls: Int32
        public let sep: Int32
        public let pad: Int32
        public let unk: Int32
        public init(cls: Int32, sep: Int32, pad: Int32, unk: Int32) {
            self.cls = cls; self.sep = sep; self.pad = pad; self.unk = unk
        }
    }

    private let vocab: [String: Int32]
    private let special: SpecialTokens
    private let doLowerCase: Bool
    private let maxWordChars = 100

    public init(vocab: [String: Int32], special: SpecialTokens, doLowerCase: Bool) {
        self.vocab = vocab
        self.special = special
        self.doLowerCase = doLowerCase
    }

    /// Load from a standard one-token-per-line vocab.txt.
    public init(vocabFile: URL, special: SpecialTokens, doLowerCase: Bool) throws {
        let raw = try String(contentsOf: vocabFile, encoding: .utf8)
        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(32_000)
        var index: Int32 = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let token = line.trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { vocab[token] = index }
            index += 1
        }
        self.init(vocab: vocab, special: special, doLowerCase: doLowerCase)
    }

    /// Encode to fixed-length ids + attention mask: [CLS] tokens… [SEP] [PAD]…
    /// Truncates at sequenceLength; use `contentIDs` + `assemble` for windowed
    /// scoring of longer text.
    public func encode(_ text: String, sequenceLength: Int) -> (ids: [Int32], mask: [Int32]) {
        let content = contentIDs(text, limit: sequenceLength - 2)
        return Self.assemble(window: content[...], sequenceLength: sequenceLength, special: special)
    }

    /// Subword ids for the whole text, no specials, no padding.
    public func contentIDs(_ text: String, limit: Int = .max) -> [Int32] {
        var ids: [Int32] = []
        outer: for word in basicTokens(text) {
            for piece in wordPieces(word) {
                if ids.count >= limit { break outer }
                ids.append(piece)
            }
        }
        return ids
    }

    /// Wrap a content window in [CLS]…[SEP] and pad to sequenceLength.
    public static func assemble(
        window: ArraySlice<Int32>,
        sequenceLength: Int,
        special: SpecialTokens
    ) -> (ids: [Int32], mask: [Int32]) {
        var ids: [Int32] = [special.cls]
        ids.append(contentsOf: window.prefix(sequenceLength - 2))
        ids.append(special.sep)

        var mask = [Int32](repeating: 1, count: ids.count)
        while ids.count < sequenceLength {
            ids.append(special.pad)
            mask.append(0)
        }
        return (ids, mask)
    }

    // MARK: - Basic tokenization (lowercase, strip accents, split punctuation)

    private func basicTokens(_ text: String) -> [String] {
        var prepared = text
        if doLowerCase {
            prepared = prepared.lowercased()
                .folding(options: .diacriticInsensitive, locale: .init(identifier: "en_US"))
        }
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for ch in prepared {
            if ch.isWhitespace || ch.isNewline {
                flush()
            } else if ch.isPunctuation || ch.isSymbol || Self.isCJK(ch) {
                flush()
                tokens.append(String(ch))
            } else {
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    // MARK: - WordPiece (greedy longest-match-first)

    private func wordPieces(_ word: String) -> [Int32] {
        guard word.count <= maxWordChars else { return [special.unk] }
        if let whole = vocab[word] { return [whole] }

        var pieces: [Int32] = []
        let chars = Array(word)
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int32?
            while start < end {
                var candidate = String(chars[start..<end])
                if start > 0 { candidate = "##" + candidate }
                if let id = vocab[candidate] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [special.unk] }
            pieces.append(id)
            start = end
        }
        return pieces
    }
}
