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

    public init(aiProbability: Double, uncertainty: Double? = nil) {
        self.aiProbability = clamp(aiProbability, 0, 1)
        self.uncertainty = uncertainty ?? (1.0 - abs(2.0 * self.aiProbability - 1.0))
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
