import Foundation

/// Human-readable byte strings, using the same decimal (1 GB = 1,000,000,000 bytes) convention
/// that Finder and "About This Mac" use, so numbers line up with what the user sees elsewhere.
public enum ByteFormatter {
    public static func string(_ bytes: Int64, decimals: Int? = nil) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) \(units[0])" }
        let places = decimals ?? (value < 10 ? 2 : (value < 100 ? 1 : 0))
        return String(format: "%.\(places)f %@", value, units[unit])
    }

    /// Short form for badges, e.g. "1.2 GB", "540 MB", "0 bytes".
    public static func short(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        return string(bytes)
    }

    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }
}

public enum AgeFormatter {
    /// "today", "3 days ago", "2 months ago", "over a year ago", or "unknown".
    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<0: return "in the future"
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<30: return "\(days) days ago"
        case 30..<60: return "1 month ago"
        case 60..<365: return "\(days / 30) months ago"
        case 365..<730: return "1 year ago"
        default: return "\(days / 365) years ago"
        }
    }
}
