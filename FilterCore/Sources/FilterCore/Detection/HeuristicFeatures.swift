import Foundation

/// Deterministic stylometric feature vector for a text block (length, entropy,
/// punctuation/capitalization ratios, repetition). Carried inside cache entries.
/// Equatable for tests and change-detection; Codable because it travels inside
/// persisted records.
public struct HeuristicFeatures: Codable, Sendable, Equatable {
    public var textLength = 0.0
    public var entropy = 0.0
    public var punctuationRatio = 0.0
    public var capitalizationRatio = 0.0
    public var repetitionScore = 0.0

    public init() {}
}
