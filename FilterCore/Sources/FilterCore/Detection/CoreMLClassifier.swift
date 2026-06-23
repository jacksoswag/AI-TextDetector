import Foundation
import CoreML

/// Tokenizers the classifier can drive. Both turn text into content ids;
/// the classifier owns windowing and special-token assembly, which are
/// id-level and family-agnostic.
///   WordPiece — BERT/e5 family (the general detector)
///   BPE       — ModernBERT family (Stage-2)
protocol PieceTokenizing: Sendable {
    func contentIDs(_ text: String, limit: Int) -> [Int32]
}
extension WordPieceTokenizer: PieceTokenizing {}
// BPETokenizer conformance declared in BPETokenizer.swift

/// LAYER 2 — a Core ML text classifier. The general detector is a small
/// transformer encoder (e5-small / MiniLM class, ~33M params) scoring fixed
/// 256-token windows; the optional Stage-2 model is a ModernBERT-large at
/// 512 tokens, FP16 on the Neural Engine. Each model's compute units come from
/// its model-info.json (`compute_units`): the general detector uses `.all`;
/// Stage-2 declares `cpu_and_ne` and is pinned to the Neural Engine.
///
/// Model artifacts live beside the app, produced by scripts/convert-model.py
/// (or convert-stage2-modernbert.py):
///   AITextClassifier.mlmodelc   compiled model
///   vocab.txt | bpe-vocab.json  tokenizer vocabulary (model-info names it)
///   model-info.json             label orientation + tokenizer parameters
public final class CoreMLClassifier: PrimaryClassifier, @unchecked Sendable {

    public struct ModelInfo: Codable {
        public struct TokenRef: Codable {
            public let token: String
            public let id: Int32
        }
        public struct SpecialTokenIDs: Codable {
            public let cls: TokenRef
            public let sep: TokenRef
            public let pad: TokenRef
            public let unk: TokenRef
        }
        /// Optional Platt scaling fitted on the user's own labeled data
        /// (scripts/calibrate.py prints these). Identity when absent.
        public struct Calibration: Codable {
            public let temperature: Double
            public let bias: Double
        }
        /// Which tokenizer family the artifacts use. Absent = WordPiece with
        /// vocab.txt (every pre-Stage-2 model-info in the wild).
        public struct TokenizerSpec: Codable {
            public let type: String
            public let vocab_file: String?
        }
        /// Which compute units the model was compiled/tested for. Absent = .all.
        /// Some models (e.g. fp32 Stage-2) only work on CPU; using .all risks
        /// NaN on the GPU path and SIGABRT in the CoreML compiler subprocess.
        public let compute_units: String?
        public let source_repo: String
        public let seq_len: Int
        public let ai_label_index: Int
        public let do_lower_case: Bool
        public let special_token_ids: SpecialTokenIDs
        public let calibration: Calibration?
        public let tokenizer: TokenizerSpec?

        var specialTokens: WordPieceTokenizer.SpecialTokens {
            .init(cls: special_token_ids.cls.id, sep: special_token_ids.sep.id,
                  pad: special_token_ids.pad.id, unk: special_token_ids.unk.id)
        }

        var tokenizerVocabFileName: String {
            tokenizer?.vocab_file ?? "vocab.txt"
        }
    }

    public let id: String
    public let displayName: String

    private let model: MLModel
    private let tokenizer: PieceTokenizing
    private let info: ModelInfo
    private let inputIDsName: String
    private let maskName: String
    private let outputName: String
    /// Per-text window cap for this instance. Stage-2 (a ~144ms/window ANE
    /// model) loads with a tight cap so a long block can't queue many windows;
    /// the default mirrors the family-agnostic static limit.
    private let maxWindows: Int

    public init(
        modelURL: URL, infoURL: URL, vocabURL: URL,
        maxWindows: Int? = nil
    ) throws {
        self.maxWindows = maxWindows ?? Self.maxWindowsPerText
        // Info first: it decides compute units (and the tokenizer family)
        // before the model is instantiated.
        let info = try JSONDecoder().decode(ModelInfo.self, from: Data(contentsOf: infoURL))
        self.info = info

        let configuration = MLModelConfiguration()
        switch info.compute_units {
        case "cpu_only":            configuration.computeUnits = .cpuOnly
        case "cpu_and_gpu":         configuration.computeUnits = .cpuAndGPU
        case "cpu_and_ne":          configuration.computeUnits = .cpuAndNeuralEngine
        default:                    configuration.computeUnits = .all
        }
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
        switch info.tokenizer?.type {
        case "bpe":
            self.tokenizer = try BPETokenizer(vocabFile: vocabURL, special: info.specialTokens)
        case nil, "wordpiece":
            self.tokenizer = try WordPieceTokenizer(
                vocabFile: vocabURL,
                special: info.specialTokens,
                doLowerCase: info.do_lower_case
            )
        default:
            // Unknown tokenizer — refuse to load rather than silently producing
            // garbage scores. loadStage2() catches this as nil and the pipeline
            // degrades to the fast model only (correct, safe fallback).
            throw CocoaError(.coderInvalidValue)
        }
        self.id = "coreml:\(info.source_repo)"
        self.displayName = info.source_repo

        // Resolve I/O names from the model itself so renames in conversion
        // never silently break scoring.
        let inputs = model.modelDescription.inputDescriptionsByName.keys
        guard let mask = inputs.first(where: { $0.localizedCaseInsensitiveContains("mask") }),
              let ids = inputs.first(where: { $0 != mask }),
              let output = model.modelDescription.outputDescriptionsByName.keys.first else {
            throw CocoaError(.coderInvalidValue)
        }
        self.inputIDsName = ids
        self.maskName = mask
        self.outputName = output
    }

    /// One artifact directory = compiled model + model-info + whichever
    /// tokenizer file the info names (vocab.txt default for WordPiece;
    /// bpe-vocab.json for ModernBERT). Reading the info first is what lets
    /// a single loader serve both tokenizer families.
    public static func load(from dir: URL) -> CoreMLClassifier? {
        load(from: dir, maxWindows: maxWindowsPerText)
    }

    /// `load(from:)` with an explicit per-text window cap. Stage-2 uses a tight
    /// cap (see `loadStage2`); the no-arg overload preserves the default for
    /// `loadDefault` and existing callers.
    static func load(from dir: URL, maxWindows: Int) -> CoreMLClassifier? {
        let model = dir.appendingPathComponent("AITextClassifier.mlmodelc")
        let infoFile = dir.appendingPathComponent("model-info.json")
        guard FileManager.default.fileExists(atPath: model.path),
              let data = try? Data(contentsOf: infoFile),
              let info = try? JSONDecoder().decode(ModelInfo.self, from: data) else { return nil }
        let vocab = dir.appendingPathComponent(info.tokenizerVocabFileName)
        guard FileManager.default.fileExists(atPath: vocab.path) else { return nil }
        return try? CoreMLClassifier(
            modelURL: model, infoURL: infoFile, vocabURL: vocab, maxWindows: maxWindows)
    }

    /// Existence check without paying a Core ML model load.
    public static func artifactsPresent(in dir: URL) -> Bool {
        let model = dir.appendingPathComponent("AITextClassifier.mlmodelc")
        let infoFile = dir.appendingPathComponent("model-info.json")
        guard FileManager.default.fileExists(atPath: model.path),
              let data = try? Data(contentsOf: infoFile),
              let info = try? JSONDecoder().decode(ModelInfo.self, from: data) else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(info.tokenizerVocabFileName).path)
    }

    /// Locate model artifacts: app bundle resources first, then the repo's
    /// Models/ directory (development), then Application Support.
    public static func loadDefault() -> CoreMLClassifier? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Models"))
            candidates.append(resources)
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Models"))
        candidates.append(AppInfo.supportDirectory.appendingPathComponent("Models"))

        for dir in candidates {
            if let classifier = load(from: dir) { return classifier }
        }
        return nil
    }

    /// Locate the optional Stage-2 escalation model (ModernBERT-large, BPE),
    /// which runs FP16 on the Neural Engine at ~144ms per 512-token window.
    /// Searches the bundle's `Stage2` resources, then the repo's `Models/Stage2`
    /// (development), then Application Support. Caps at `maxWindows: 2` so even a
    /// long borderline block stays well under the 250ms end-to-end budget.
    /// Returns nil gracefully when artifacts are absent or fail to load —
    /// callers degrade to Stage-1.
    public static func loadStage2() -> CoreMLClassifier? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Stage2"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Models").appendingPathComponent("Stage2"))
        candidates.append(AppInfo.supportDirectory
            .appendingPathComponent("Models").appendingPathComponent("Stage2"))

        for dir in candidates {
            if let classifier = load(from: dir, maxWindows: 2) { return classifier }
        }
        return nil
    }

    // MARK: - Scoring (windowed)

    /// A 256-token export sees ~190 words. Longer blocks are scored as
    /// overlapping windows (stride keeps ~25% overlap) so AI text buried past
    /// the first paragraphs still registers. Aggregation leans toward the
    /// hottest window but damps lone spikes: 0.65·max + 0.35·mean.
    static let windowOverlap = 64
    static let maxWindowsPerText = 6
    static let maxContentTokens = 4096

    public func score(texts: [String]) async throws -> [ClassifierOutput] {
        guard !texts.isEmpty else { return [] }

        var providers: [MLFeatureProvider] = []
        var owner: [Int] = []   // provider index → text index
        for (textIndex, text) in texts.enumerated() {
            let content = tokenizer.contentIDs(text, limit: Self.maxContentTokens)
            for window in Self.windows(
                for: content, sequenceLength: info.seq_len, maxWindows: maxWindows) {
                providers.append(try featureProvider(window: window))
                owner.append(textIndex)
            }
        }

        // MLModel prediction is synchronous; hop off the caller's executor.
        let windowProbs: [Double] = try await Task.detached(priority: .userInitiated) { [self] in
            let batch = MLArrayBatchProvider(array: providers)
            let results = try model.predictions(fromBatch: batch)
            return try (0..<results.count).map { try probability(from: results.features(at: $0)) }
        }.value

        var grouped = [[Double]](repeating: [], count: texts.count)
        for (index, p) in windowProbs.enumerated() {
            grouped[owner[index]].append(p)
        }
        return grouped.map { probs in
            // Real uncertainty from cross-window dispersion: a text whose
            // windows disagree is genuinely uncertain. Single-window texts have
            // zero dispersion → low uncertainty. This replaces the synthetic
            // tent-function-of-p default and makes the field meaningful for
            // logs/UI/cache (the escalation gate keys on threshold proximity).
            let dispersion = clamp(2.0 * TextMetrics.stdDev(probs), 0, 1)
            return ClassifierOutput(aiProbability: Self.aggregate(probs), uncertainty: dispersion)
        }
    }

    static func windows(
        for content: [Int32], sequenceLength: Int,
        maxWindows: Int = maxWindowsPerText
    ) -> [ArraySlice<Int32>] {
        let body = sequenceLength - 2
        guard content.count > body else { return [content[...]] }

        let stride = body - windowOverlap
        // A seq_len <= windowOverlap + 2 makes stride <= 0, which would never
        // advance `start` (infinite loop). Both shipped models are 256/512, so
        // this only guards a hypothetical tiny future model: score one window.
        guard stride > 0 else { return [content[..<body]] }
        var slices: [ArraySlice<Int32>] = []
        var start = 0
        while start < content.count {
            slices.append(content[start..<min(start + body, content.count)])
            if start + body >= content.count { break }
            start += stride
        }
        guard slices.count > maxWindows else { return slices }
        guard maxWindows > 1 else { return [slices[0]] }
        // Very long text: sample windows evenly so the whole document is seen.
        let last = slices.count - 1
        let picks = (0..<maxWindows).map { Int((Double($0) * Double(last) / Double(maxWindows - 1)).rounded()) }
        return Array(Set(picks)).sorted().map { slices[$0] }
    }

    static func aggregate(_ probs: [Double]) -> Double {
        guard probs.count > 1 else { return probs.first ?? 0.5 }
        let maxP = probs.max() ?? 0.5
        let mean = probs.reduce(0, +) / Double(probs.count)
        return 0.65 * maxP + 0.35 * mean
    }

    private func featureProvider(window: ArraySlice<Int32>) throws -> MLFeatureProvider {
        let encoded = WordPieceTokenizer.assemble(
            window: window, sequenceLength: info.seq_len, special: info.specialTokens)
        let shape = [1, NSNumber(value: info.seq_len)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        // Bulk-copy into each array's contiguous int32 buffer. A fresh
        // [1, seqLen] MLMultiArray is contiguous (the closure's stride arg is
        // unused for that reason) and `assemble` pads ids/mask to exactly seqLen,
        // so a raw byte copy avoids the per-element NSNumber boxing the subscript
        // path pays on every window. The assert pins the length invariant the
        // copy relies on — a future model with a mismatched seq_len would
        // otherwise corrupt inputs silently.
        assert(encoded.ids.count == info.seq_len && encoded.mask.count == info.seq_len)
        encoded.ids.withUnsafeBytes { src in
            ids.withUnsafeMutableBytes { dst, _ in dst.copyMemory(from: src) }
        }
        encoded.mask.withUnsafeBytes { src in
            mask.withUnsafeMutableBytes { dst, _ in dst.copyMemory(from: src) }
        }
        return try MLDictionaryFeatureProvider(dictionary: [
            inputIDsName: MLFeatureValue(multiArray: ids),
            maskName: MLFeatureValue(multiArray: mask),
        ])
    }

    private func probability(from features: MLFeatureProvider) throws -> Double {
        guard let array = features.featureValue(for: outputName)?.multiArrayValue else {
            throw CocoaError(.coderValueNotFound)
        }
        return calibrated(array[info.ai_label_index].doubleValue)
    }

    /// Platt scaling in logit space; identity unless model-info.json carries
    /// fitted values from scripts/calibrate.py.
    private func calibrated(_ p: Double) -> Double {
        guard let c = info.calibration else { return p }
        let q = clamp(p, 1e-6, 1 - 1e-6)
        let logit = log(q / (1 - q))
        return 1 / (1 + exp(-((logit + c.bias) / max(0.05, c.temperature))))
    }
}
