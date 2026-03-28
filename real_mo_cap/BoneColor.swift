import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Provides a single, deterministic color-for-bone-name mapping used throughout the app:
/// skeleton node materials, LFO ring overlays, and MIDI menu tracker colors.
enum BoneColor {

    // MARK: - Deterministic hash (stable across launches)

    /// Returns a deterministic hash for a string, unlike Swift's `hashValue` which is randomised per process.
    private static func stableHash(_ string: String) -> UInt64 {
        // djb2 hash
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return hash
    }

    /// Hue (0–1) for a given bone name, deterministic across launches.
    static func hue(for boneName: String) -> Double {
        let h = stableHash(boneName)
        return Double(h % 360) / 360.0
    }

    // MARK: - SwiftUI Color

    /// SwiftUI `Color` for a bone / tracker name.
    /// If `name` is a tracker like `"head.x"`, pass the **bone** portion (`"head"`).
    static func color(for boneName: String) -> Color {
        Color(hue: hue(for: boneName), saturation: 0.7, brightness: 0.9)
    }

    /// Extracts the bone name from a tracker string (e.g. `"head.x"` → `"head"`).
    /// Returns the full string if there is no dot component, e.g. `"frame.index"` stays as-is.
    static func boneName(fromTracker tracker: String) -> String {
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return tracker }
        let comp = parts[1]
        // Only strip known axis suffixes; keep compound names like "frame.index" intact
        if comp == "x" || comp == "y" || comp == "z" {
            return parts[0]
        }
        return tracker
    }

    /// Convenience: color for a tracker string, using the bone name portion.
    static func colorForTracker(_ tracker: String) -> Color {
        color(for: boneName(fromTracker: tracker))
    }

    // MARK: - UIKit UIColor (for SceneKit materials)

    #if canImport(UIKit)
    static func uiColor(for boneName: String) -> UIColor {
        UIColor(hue: CGFloat(hue(for: boneName)), saturation: 0.7, brightness: 0.9, alpha: 1)
    }
    #endif
}
