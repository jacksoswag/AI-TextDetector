import Foundation

/// App-wide constants. The product is a single process (the menu bar app), so
/// plain `UserDefaults.standard` is the persistence layer.
public enum AppInfo {
    public static let version = "0.2.0"
    public static let supportDirectoryName = "AIContentFilter"

    /// ~/Library/Application Support/AIContentFilter — optional location for
    /// model artifacts installed after the fact (see CoreMLClassifier search
    /// order). Also where the disabled debug-LLM weights would live.
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportDirectoryName)
    }
}

public extension UserDefaults {
    /// Single store for settings, statistics, trust list, and learned biases.
    /// Named `appGroup` historically; it is just the app's standard defaults.
    static let appGroup: UserDefaults = .standard
}
