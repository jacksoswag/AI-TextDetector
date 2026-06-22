import Foundation

/// Central place for the privacy story — both the user-facing copy and the
/// "reset everything" action. The guarantees are structural, not promises:
/// a single local process, no networking client, no analytics SDK, and all
/// model inference (Core ML) running on-device.
public enum PrivacyManager {

    public static let summary = """
    All detection runs locally. No content, analytics, browsing activity, or data leaves your device. No generative AI is used in this program.
    """

    public static let thresholdExplainer = """
    AI detection is probabilistic.

    A higher threshold only highlights text with stronger AI-indicators.

    A lower threshold highlights more content but may mark human text.

    Highlights only annotate your screen. They do not edit, filter, or remove any content.
    """

    /// What we store, so the privacy screen can be concrete about it.
    public static let storedDataDescription = """
    Stored on your device only: settings, trusted site list, usage counters, \
    and any pets you create. Erasing leaves your license and trial status \
    untouched, so it never removes a key you entered or restarts a trial.
    """

    /// Wipe every preference, statistic, trusted-site list, and user-created
    /// pet.
    public static func eraseAllLocalData(defaults: UserDefaults = .appGroup) {
        let keys = [
            SettingsKey.enabled, SettingsKey.threshold, SettingsKey.thresholdV2,
            SettingsKey.minWords, SettingsKey.nativeScanning,
            SettingsKey.launchAtLoginDone, SettingsKey.petSize,
            "trust.domains", "pets.activeID", "deletedBuiltinIDs", "accessibility.promptShown",
            StatisticsManager.Key.words, StatisticsManager.Key.blocks,
            StatisticsManager.Key.reveals,
        ]
        // License key and trial anchor are deliberately NOT erased: wiping them
        // would either drop a key the user paid for or hand out a fresh trial.
        keys.forEach(defaults.removeObject(forKey:))
        // Custom pets are user-created local data and must go with the
        // rest; built-in pets live in the app bundle and are untouched.
        // Missing directory is the common case and not an error.
        try? FileManager.default.removeItem(
            at: AppInfo.supportDirectory.appendingPathComponent("Pets"))
    }
}
