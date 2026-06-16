import Foundation
import CryptoKit

public struct ExplainabilitySnapshot: Codable, Sendable {
    public let calibrationApplied: Double
    public let uncertaintyBreakdown: Double
    public let confidenceDistribution: Double
    public let stageDecisionReason: String
}

public struct ReplayEvent: Codable, Sendable {
    public let timestamp: Date
    public let blockHash: String
    public let stageUsed: String
    public let pAiFinal: Float
    public let confidence: Float
    public let uncertainty: Float
    public let domain: String
    public let latencyMs: Int
    public let uiAction: String // highlight | ignored | dismissed
    public let explainability: ExplainabilitySnapshot
}

public final class SemanticEventLog: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let key = "diagnostics.semantic_events"
    private static let retentionDays: TimeInterval = 14 * 24 * 60 * 60

    public init(defaults: UserDefaults = .appGroup) {
        self.defaults = defaults
    }

    public func record(_ event: ReplayEvent) {
        lock.lock(); defer { lock.unlock() }
        var events = load()
        events.append(event)
        
        let cutoff = Date().addingTimeInterval(-Self.retentionDays)
        events.removeAll { $0.timestamp < cutoff }
        
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Self.key)
        }
    }

    public func load() -> [ReplayEvent] {
        guard let data = defaults.data(forKey: Self.key),
              let events = try? JSONDecoder().decode([ReplayEvent].self, from: data) else {
            return []
        }
        return events
    }
    
    public static func hashBlock(_ text: String) -> String {
        let inputData = Data(text.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
