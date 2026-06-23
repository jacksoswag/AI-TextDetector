import Foundation
@testable import FilterCore

/// Test double: fixed or text-keyed probability, records call/batch counts.
/// Lives in the test target so the production framework ships no mock.
final class MockClassifier: PrimaryClassifier, @unchecked Sendable {
    let id: String
    let displayName = "Mock"
    private let scorer: @Sendable (String) -> Double
    /// When set, every output reports this uncertainty instead of the default
    /// tent-of-probability; lets a test drive the uncertainty gate independently
    /// of the score.
    private let fixedUncertainty: Double?
    private let lock = NSLock()
    private(set) var callCount = 0
    private(set) var batchSizes: [Int] = []

    init(probability: Double, uncertainty: Double? = nil, id: String = "mock.v1") {
        self.scorer = { _ in probability }
        self.fixedUncertainty = uncertainty
        self.id = id
    }

    init(id: String = "mock.v1", uncertainty: Double? = nil, scorer: @escaping @Sendable (String) -> Double) {
        self.scorer = scorer
        self.fixedUncertainty = uncertainty
        self.id = id
    }

    func score(texts: [String]) async throws -> [ClassifierOutput] {
        record(texts)
        return texts.map { ClassifierOutput(aiProbability: scorer($0), uncertainty: fixedUncertainty) }
    }

    /// Synchronous so the NSLock never straddles a suspension point (NSLock is
    /// illegal across `await`; Swift 6 makes direct use in async bodies an error).
    private func record(_ texts: [String]) {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        batchSizes.append(texts.count)
    }
}
