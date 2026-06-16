import Foundation

/// The text registers the detector understands. Routing picks a register so the
/// score can be calibrated per domain; `general` means no specific register
/// applies and the general detector stands alone.
///
/// Raw values are frozen: they key the per-domain calibration profiles
/// (`CalibrationEngine`) and diagnostics.
public enum TextDomain: String, Codable, Sendable, CaseIterable {
    case conversation
    case academic
    case news
    case social
    case marketing
    case technical
    case creative
    case general
}

/// The router's verdict for one block: which expert (if any) should score it,
/// and how separated that choice was from the runner-up. Pure data — carrying
/// it in `DetectionResult` lets diagnostics explain "why this expert".
public struct RoutingDecision: Codable, Sendable, Equatable {
    public let domain: TextDomain
    /// 0...1. For routed blocks: how clearly the winning register beat the
    /// runner-up. For `general`: how far every register was from mattering.
    public let confidence: Double

    public init(domain: TextDomain, confidence: Double) {
        self.domain = domain
        self.confidence = clamp(confidence, 0, 1)
    }

    public static let general = RoutingDecision(domain: .general, confidence: 1.0)
}
