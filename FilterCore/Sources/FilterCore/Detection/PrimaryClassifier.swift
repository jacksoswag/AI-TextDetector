import Foundation

/// LAYER 2 abstraction — the swappable primary model.
///
/// The engine, UI, and persistence know nothing about Core ML, tokenizers, or
/// model files; they see "a thing that turns a batch of texts into AI
/// probabilities". Upgrading the model means shipping a new implementation of
/// this protocol (or just new weights) and changing nothing else.
public struct ClassifierOutput: Codable, Sendable {
    /// 0...1, probability the text is AI-generated.
    public let aiProbability: Double
    /// 0...1, how unsure the model is (1 at p=0.5, 0 at p∈{0,1}).
    public let uncertainty: Double
    /// Optional embedding vector for Stage 2 or analysis.
    public let embedding: [Float]?

    public init(aiProbability: Double, uncertainty: Double? = nil, embedding: [Float]? = nil) {
        self.aiProbability = clamp(aiProbability, 0, 1)
        self.uncertainty = uncertainty ?? (1.0 - abs(2.0 * self.aiProbability - 1.0))
        self.embedding = embedding
    }
}

public protocol PrimaryClassifier: Sendable {
    /// Stable identifier; keys the score cache, so new weights need a new id.
    var id: String { get }
    var displayName: String { get }

    /// Score a batch. Implementations should process the whole batch in one
    /// underlying call where the runtime supports it.
    func score(texts: [String]) async throws -> [ClassifierOutput]
}

/// Test double: fixed or text-keyed probability, records call/batch counts.
public final class MockClassifier: PrimaryClassifier, @unchecked Sendable {
    public let id: String
    public let displayName = "Mock"
    private let scorer: @Sendable (String) -> Double
    private let lock = NSLock()
    public private(set) var callCount = 0
    public private(set) var batchSizes: [Int] = []
    public private(set) var scoredTexts: [String] = []

    public init(probability: Double, id: String = "mock.v1") {
        self.scorer = { _ in probability }
        self.id = id
    }

    public init(id: String = "mock.v1", scorer: @escaping @Sendable (String) -> Double) {
        self.scorer = scorer
        self.id = id
    }

    public func score(texts: [String]) async throws -> [ClassifierOutput] {
        record(texts)
        return texts.map { ClassifierOutput(aiProbability: scorer($0)) }
    }

    /// Synchronous so the NSLock never straddles a suspension point (NSLock
    /// is illegal across `await`; Swift 6 makes direct use in async bodies an
    /// error).
    private func record(_ texts: [String]) {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        batchSizes.append(texts.count)
        scoredTexts.append(contentsOf: texts)
    }
}
