import Foundation

/// Human durations: "90s", "45m", "2h", "1h30m", "1.5h", "2 hours", "1d". A bare number means minutes.
public enum DurationText {
    public static func parse(_ text: String) -> TimeInterval? {
        let s = text.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        if let minutes = Double(s) { return minutes > 0 ? minutes * 60 : nil }

        var total: Double = 0
        var index = s.startIndex
        while index < s.endIndex {
            let numberStart = index
            while index < s.endIndex, s[index].isNumber || s[index] == "." { index = s.index(after: index) }
            guard let value = Double(s[numberStart..<index]) else { return nil }
            let unitStart = index
            while index < s.endIndex, s[index].isLetter { index = s.index(after: index) }
            guard let unit = unitSeconds[String(s[unitStart..<index])] else { return nil }
            total += value * unit
        }
        return total > 0 ? total : nil
    }

    private static let unitSeconds: [String: Double] = {
        var map: [String: Double] = [:]
        for u in ["s", "sec", "secs", "second", "seconds"] { map[u] = 1 }
        for u in ["m", "min", "mins", "minute", "minutes"] { map[u] = 60 }
        for u in ["h", "hr", "hrs", "hour", "hours"] { map[u] = 3600 }
        for u in ["d", "day", "days"] { map[u] = 86400 }
        return map
    }()

    /// Compact form for menus and status lines: "45s", "12m", "1h 5m", "2d 3h".
    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 { return restMinutes == 0 ? "\(hours)h" : "\(hours)h \(restMinutes)m" }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
    }
}
