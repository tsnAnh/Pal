import Foundation

public enum ISODate {
    public static func parse(_ text: String, defaultZone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == "T" || $0 == " " })
        guard let datePart = parts.first, let day = parseDay(String(datePart)) else { return nil }
        var zone = defaultZone
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        if parts.count == 2 {
            var time = String(parts[1])
            if time.hasSuffix("Z") || time.hasSuffix("z") {
                zone = TimeZone(secondsFromGMT: 0) ?? defaultZone
                time.removeLast()
            } else if let split = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                guard let offset = parseOffset(String(time[split...])) else { return nil }
                zone = TimeZone(secondsFromGMT: offset) ?? defaultZone
                time = String(time[..<split])
            }
            let fields = time.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(fields.count), let parsedHour = Int(fields[0]), let parsedMinute = Int(fields[1]) else { return nil }
            hour = parsedHour
            minute = parsedMinute
            if fields.count == 3 {
                let secondText = fields[2].split(separator: ".", omittingEmptySubsequences: false)
                guard let parsedSecond = Int(secondText[0]) else { return nil }
                second = parsedSecond
                if secondText.count == 2 {
                    guard let digits = Double("0." + secondText[1]) else { return nil }
                    fraction = digits
                }
            }
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute, second: second)
        components.timeZone = zone
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: day.year, month: day.month, day: day.day) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    public static func format(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            sign, magnitude / 3600, (magnitude % 3600) / 60
        )
    }

    private static func parseDay(_ text: String) -> (year: Int, month: Int, day: Int)? {
        let fields = text.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4, let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return (year, month, day)
    }

    private static func parseOffset(_ text: String) -> Int? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 4 || digits.count == 2, let value = Int(digits) else { return nil }
        let hours = digits.count == 4 ? value / 100 : value
        let minutes = digits.count == 4 ? value % 100 : 0
        guard hours <= 14, minutes < 60 else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
}
