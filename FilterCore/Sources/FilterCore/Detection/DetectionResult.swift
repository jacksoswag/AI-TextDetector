import Foundation

/// Where a text block came from. Calibration (Layer 3) scales sensitivity by
/// source: OCR text is noisy, Accessibility text is clean, browser text is
/// authoritative.
public enum TextSource: String, Codable, Sendable {
    case browser
    case native
    case ocr
}

public enum DetectionLabel: String, Codable, Sendable {
    case human
    case ai
    /// Never flagged. Two ways here: the block never reached scoring
    /// (insufficient data), or the score cleared the bar but confidence
    /// didn't — §3.2 prefers admitting "unknown" over a false positive.
    case unknown
}

/// Severity bands over `finalScore` — the vocabulary the rest of the product
/// speaks. Highlight tinting and the pet companion's commentary key off the
/// state, not the raw number. The raw values are frozen ("very_high", not
/// "veryHigh"): they double as speech-template keys, so renaming a case must
/// never silently orphan a template.
public enum DetectionState: String, Codable, Sendable, CaseIterable {
    case safe
    case uncertain
    case suspicious
    case high
    case veryHigh = "very_high"

    public init(score: Double) {
        switch score {
        case ..<0.30: self = .safe
        case ..<0.60: self = .uncertain
        case ..<0.80: self = .suspicious
        case ..<0.95: self = .high
        default:      self = .veryHigh
        }
    }
}

public struct FinalDetectionResult: Codable, Sendable {
    public let p_ai_final: Float
    /// INVERTED by construction — highest at p=0.5 (most uncertain), lowest at
    /// the extremes. Telemetry only; the named-inverted field prevents callers
    /// from reading it as "more = surer". The gate uses an explicit test instead.
    public let invertedConfidence: Float
    public let uncertainty: Float
    public let stage_used: String
    public let calibration_source: String

    public var state: DetectionState { DetectionState(score: Double(p_ai_final)) }

    public init(p_ai_final: Float, invertedConfidence: Float, uncertainty: Float, stage_used: String, calibration_source: String) {
        self.p_ai_final = p_ai_final
        self.invertedConfidence = invertedConfidence
        self.uncertainty = uncertainty
        self.stage_used = stage_used
        self.calibration_source = calibration_source
    }

    public static let insufficientData = FinalDetectionResult(
        p_ai_final: 0.5, invertedConfidence: 0.0, uncertainty: 1.0, stage_used: "stage1", calibration_source: "none"
    )
}

public struct BlockInput: Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum SkipReason: String, Sendable, Codable {
    case disabled
    case trustedDomain
    case personalSurface   // mail/messaging — never scored, never highlighted
    case tooShort
    /// Stage-1 classifier failed to load; the block could not be scored.
    /// The pipeline fails fast here instead of escalating to Stage-2.
    case modelUnavailable
    /// No license is active, so the always-on overlay is paused. The manual
    /// Check Text window stays available.
    case unlicensed
}

public struct BlockVerdict: Sendable {
    public let id: String
    public let result: FinalDetectionResult
    public let shouldHighlight: Bool
    public let skipReason: SkipReason?
    /// True when this is a Stage-1-only verdict for a block the engine wants to
    /// re-score with Stage-2 (deferred escalation). The caller paints confident
    /// blocks now and asks `refine(...)` for the authoritative verdict on these.
    /// Always false on the synchronous path and after `refine`.
    public let needsRefinement: Bool

    /// Convenience for UI code: nil when the block never reached scoring.
    public var score: Double? { skipReason == nil ? Double(result.p_ai_final) : nil }

    public init(id: String, result: FinalDetectionResult, shouldHighlight: Bool, skipReason: SkipReason? = nil, needsRefinement: Bool = false) {
        self.id = id
        self.result = result
        self.shouldHighlight = shouldHighlight
        self.skipReason = skipReason
        self.needsRefinement = needsRefinement
    }
}
