import Foundation
import CryptoKit

/// Cheap, allocation-light text statistics shared by the gate logic and the
/// heuristic detector. All functions are pure.
public enum TextMetrics {

    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            // Direct checks: CharacterSet.contains bridges to Foundation and
            // dominates profile time when called per scalar.
            let v = scalar.value
            let isSpace = v == 32 || (9...13).contains(v) || v == 0xA0
                || (v > 0x1FFF && scalar.properties.isWhitespace)
            if isSpace {
                if inWord { count += 1; inWord = false }
            } else {
                inWord = true
            }
        }
        if inWord { count += 1 }
        return count
    }

    /// Naive sentence splitter. Good enough for statistical features; not for NLP.
    public static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 1 }
    }

    /// Stable cache key for a block of text. Whitespace-insensitive so that
    /// minor layout differences don't defeat the cache.
    public static func cacheKey(_ text: String, detectorID: String) -> String {
        let normalized = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(detectorID):\(hex):\(normalized.count)"
    }

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func stdDev(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
        return variance.squareRoot()
    }
}

public func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    min(max(value, low), high)
}
