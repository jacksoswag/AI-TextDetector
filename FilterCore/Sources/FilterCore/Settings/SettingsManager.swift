import Foundation
import Combine

public enum SettingsKey {
    public static let enabled = "settings.enabled"
    /// Legacy pre-§3.1 key, when the slider was a model-probability bar.
    /// Kept only so PrivacyManager can erase it from older installs; never
    /// read or written anymore.
    public static let threshold = "settings.threshold"
    /// Minimum FINAL SCORE (§3.1) that triggers highlighting. Double
    /// 0.30...0.95. A fresh key because the unit changed: a stored 0.85
    /// model-probability bar would silently become a near-unreachable
    /// final-score bar if reused.
    public static let thresholdV2 = "settings.threshold.v2"
    public static let minWords = "settings.minWords"            // Int
    public static let nativeScanning = "settings.nativeScanning"
    public static let launchAtLoginDone = "settings.launchAtLoginRegistered"
    /// On-screen pet edge length in points. Double, clamped to petSizeRange.
    public static let petSize = "settings.petSize"
}

/// Slider band labels, named for the lowest `DetectionState` that still gets
/// highlighted at that threshold (state bands sit at 0.30/0.60/0.80/0.95).
public enum ThresholdBand {
    public static func label(for threshold: Double) -> String {
        switch threshold {
        case 0.95...:       return "Very High"
        case 0.80..<0.95:   return "High"
        case 0.60..<0.80:   return "Suspicious"
        case 0.45..<0.60:   return "Uncertain"
        default:            return "Max Sensitivity"
        }
    }
}

/// Immutable read of the current settings. Non-UI consumers (the engine, the
/// acquisition layer) read a fresh snapshot per evaluation instead of holding
/// observable state, so every pass sees the latest slider values.
public struct SettingsSnapshot: Sendable {
    public let isEnabled: Bool
    public let threshold: Double
    public let minWords: Int
    public let nativeScanningEnabled: Bool

    public static func current(_ defaults: UserDefaults = .appGroup) -> SettingsSnapshot {
        SettingsManager.registerDefaults(defaults)
        return SettingsSnapshot(
            isEnabled: defaults.bool(forKey: SettingsKey.enabled),
            threshold: clamp(defaults.double(forKey: SettingsKey.thresholdV2), 0.30, 0.95),
            minWords: max(30, defaults.integer(forKey: SettingsKey.minWords)),
            nativeScanningEnabled: defaults.bool(forKey: SettingsKey.nativeScanning)
        )
    }
}

/// Observable settings store for the menu bar app (the single writer).
/// Values persist to the app defaults; everything else reads snapshots.
public final class SettingsManager: ObservableObject {

    /// 0.60 catches "Suspicious and above" out of the box — the default has to
    /// demonstrate the product on first launch without flooding the page.
    public static let defaultThreshold = 0.60
    /// 30 still scores short AI artifacts (search summaries, brief chat replies).
    /// Short blocks are never escalated to the length-sensitive Stage-2 model and
    /// are painted only when Stage-1 is decisively AI (see DetectionEngine's
    /// confidence gate), so a short formal-human block abstains instead of flagging.
    public static let defaultMinWords = 30
    /// Pet edge length in points. The default (43) sits at ~1/3 of the
    /// slider's range, so the slider reads as "a bit small by default, room to grow".
    public static let defaultPetSize = 43.0
    public static let petSizeRange: ClosedRange<Double> = 20...90

    private let defaults: UserDefaults

    @Published public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: SettingsKey.enabled) }
    }

    /// Minimum final score (§3.1) that triggers highlighting.
    /// 0.30 ... 0.95, continuous.
    @Published public var threshold: Double {
        didSet { defaults.set(clamp(threshold, 0.30, 0.95), forKey: SettingsKey.thresholdV2) }
    }

    @Published public var minWords: Int {
        didSet { defaults.set(minWords, forKey: SettingsKey.minWords) }
    }

    /// Tier 2/3 (Accessibility + OCR) scanning of native apps. It needs the
    /// Accessibility permission and costs battery, so it is a user-facing toggle.
    @Published public var nativeScanningEnabled: Bool {
        didSet { defaults.set(nativeScanningEnabled, forKey: SettingsKey.nativeScanning) }
    }

    /// On-screen pet edge length in points (square). Adjusted by the slider in
    /// the menu bar's Pet tab; read by the pet layer to size/resize panels.
    @Published public var petSize: Double {
        didSet {
            defaults.set(clamp(petSize, Self.petSizeRange.lowerBound, Self.petSizeRange.upperBound),
                         forKey: SettingsKey.petSize)
        }
    }

    public var thresholdLabel: String { ThresholdBand.label(for: threshold) }
    public var thresholdPercent: Int { Int((threshold * 100).rounded()) }

    public init(defaults: UserDefaults = .appGroup) {
        self.defaults = defaults
        Self.registerDefaults(defaults)
        self.isEnabled = defaults.bool(forKey: SettingsKey.enabled)
        self.threshold = clamp(defaults.double(forKey: SettingsKey.thresholdV2), 0.30, 0.95)
        self.minWords = max(30, defaults.integer(forKey: SettingsKey.minWords))
        self.nativeScanningEnabled = defaults.bool(forKey: SettingsKey.nativeScanning)
        self.petSize = clamp(defaults.double(forKey: SettingsKey.petSize),
                                Self.petSizeRange.lowerBound, Self.petSizeRange.upperBound)
    }

    static func registerDefaults(_ defaults: UserDefaults) {
        defaults.register(defaults: [
            SettingsKey.enabled: true,
            SettingsKey.thresholdV2: defaultThreshold,
            SettingsKey.minWords: defaultMinWords,
            SettingsKey.nativeScanning: true,   // everything is automatic by default
            SettingsKey.petSize: defaultPetSize,
        ])
    }
}
