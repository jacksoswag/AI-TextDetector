import Foundation

/// A minimal calibration baseline utilizing strict temperature scaling.
/// Applies calibration AFTER inference and does NOT mutate raw logs.
/// Removed adaptive user bias and complex drift logic for deterministic M3-optimized training prep.
public final class CalibrationEngine: @unchecked Sendable {
    
    // Neutral (identity). The principled, data-fitted calibration now lives in
    // the model's Platt scaling (`calibration` in Models/model-info.json, fit by
    // scripts/calibrate.py — a global temperature+bias applied in CoreMLClassifier
    // BEFORE this engine), so the recommended threshold is defined on the
    // post-Platt score and must not be perturbed by a second per-register shift.
    // These per-register temperatures are kept as a hook for a future PER-REGISTER
    // calibration fit; until that data exists they stay 1.0 (no-op). A value > 1
    // would SOFTEN (toward 0.5, fewer false positives), < 1 would SHARPEN.
    private let domainTemperatures: [String: Double] = [
        "general": 1.0,
        "academic": 1.0,
        "social": 1.0,
        "technical": 1.0,
        "conversation": 1.0
    ]

    public init() {}

    private func logit(_ p: Double) -> Double {
        // Assuming global clamp exists as it did in the original file
        let clamped = clamp(p, 1e-6, 1 - 1e-6)
        return log(clamped / (1 - clamped))
    }

    private func sigmoid(_ l: Double) -> Double {
        return 1.0 / (1.0 + exp(-l))
    }

    /// Applies simple per-domain temperature scaling to raw baseline probabilities.
    public func calibrate(pBase: Double, domain: String) -> Double {
        // STEP 1 - CANONICAL CONVERSION TO LOGITS
        let l = logit(pBase)
        
        // STEP 2 - TEMPERATURE SCALING
        let t = domainTemperatures[domain] ?? 1.0
        let scaledLogit = l / t
        
        // STEP 3 - FINAL PROBABILITY RETURN
        return sigmoid(scaledLogit)
    }
}
