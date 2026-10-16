import Foundation

/// Money is stored as Int64 of minor units (e.g. yen as integer count).
/// For currencies with sub-units like USD, multiply by 100.
struct Money: Hashable, CustomStringConvertible {
    var minor: Int64
    var currency: String

    init(minor: Int64, currency: String = "JPY") {
        self.minor = minor
        self.currency = currency
    }

    var description: String { format() }

    func format() -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = Self.fractionDigits(for: currency)
        let scale = pow(10.0, Double(Self.fractionDigits(for: currency)))
        let value = Double(minor) / scale
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "1,234.5" → minor units for `currency`; nil for empty or unparsable text.
    static func parseMinor(_ text: String, currency: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        // Decimal, not Double: Double loses integer precision past 2^53,
        // which a 15-digit amount in a 2-decimal currency exceeds.
        guard cleaned.contains(where: \.isNumber),   // "." alone is not an amount
              var scaled = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        scaled *= pow(Decimal(10), fractionDigits(for: currency))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        // Int64 conversion wraps silently out of range; refuse instead.
        guard abs(rounded) < Decimal(sign: .plus, exponent: 18, significand: 9) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    /// Minor units → plain editable text ("1234" or "12.34"), no symbol.
    static func formatMinorText(_ minor: Int64, currency: String) -> String {
        let digits = fractionDigits(for: currency)
        if digits == 0 { return String(minor) }
        return String(format: "%.\(digits)f", Double(minor) / pow(10.0, Double(digits)))
    }

    static func fractionDigits(for currency: String) -> Int {
        // Most everyday currencies; "JPY", "KRW" have no fraction.
        switch currency {
        case "JPY", "KRW", "VND", "IDR": return 0
        default: return 2
        }
    }
}

extension Date {
    /// Days since 1970-01-01 in the user's local calendar.
    /// Independent of time-of-day; suitable for "what day did this transaction land on?"
    var dayKey: Int {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: self)
        guard let day = cal.date(from: comps) else { return 0 }
        let epoch = cal.date(from: DateComponents(year: 1970, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        return cal.dateComponents([.day], from: epoch, to: day).day ?? 0
    }

    /// YYYYMM as Int (e.g. 202605) for fast equality lookups.
    var yearMonthKey: Int {
        let comps = Calendar.current.dateComponents([.year, .month], from: self)
        return (comps.year ?? 0) * 100 + (comps.month ?? 0)
    }

    static func from(dayKey: Int) -> Date {
        let cal = Calendar.current
        let epoch = cal.date(from: DateComponents(year: 1970, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        return cal.date(byAdding: .day, value: dayKey, to: epoch) ?? epoch
    }
}

/// Helpers to compute year_month ranges for queries.
enum YearMonth {
    static func key(year: Int, month: Int) -> Int { year * 100 + month }

    static func components(_ key: Int) -> (year: Int, month: Int) {
        (year: key / 100, month: key % 100)
    }

    /// Inclusive [start, end] year_month keys for a window of N months ending at `endKey`.
    static func window(endingAt endKey: Int, monthsBack: Int) -> (start: Int, end: Int) {
        let (y, m) = components(endKey)
        var startYear = y
        var startMonth = m - monthsBack + 1
        while startMonth <= 0 {
            startMonth += 12
            startYear -= 1
        }
        return (key(year: startYear, month: startMonth), endKey)
    }

    static func current() -> Int {
        Date().yearMonthKey
    }

    /// Fix a key whose month stepped past 12 or below 1 (Stepper overflow).
    static func normalized(_ key: Int) -> Int {
        let (y, m) = components(key)
        if m < 1  { return self.key(year: y - 1, month: 12) }
        if m > 12 { return self.key(year: y + 1, month: 1) }
        return key
    }

    /// "Oct 2026" for a YYYYMM key.
    static func label(_ key: Int) -> String {
        let (y, m) = components(key)
        let d = Calendar.current.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
        return d.formatted(.dateTime.month(.abbreviated).year())
    }

    /// First day of the month for a "YYYY-MM" or "YYYYMM" label. Lets charts
    /// use a real date axis instead of truncated string labels.
    static func date(fromLabel label: String) -> Date {
        let digits = label.filter(\.isNumber)
        guard digits.count >= 6, let y = Int(digits.prefix(4)), let m = Int(digits.dropFirst(4).prefix(2)) else {
            return Date()
        }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
    }
}

/// Trend-chart bucketing shared by Dashboard and Reports: daily for one
/// month, weekly for a quarter, monthly beyond. Points are zero-filled
/// across the window, which stops at today when it ends in the current month.
enum TrendSeries {
    struct Point: Hashable { let date: Date; let minor: Int64 }

    static func unit(forMonths n: Int) -> Calendar.Component {
        switch n {
        case 1:  return .day
        case 3:  return .weekOfYear
        default: return .month
        }
    }

    static func unitName(_ u: Calendar.Component) -> String {
        switch u {
        case .day:        return "daily"
        case .weekOfYear: return "weekly"
        default:          return "monthly"
        }
    }

    /// `monthly` rows are ("YYYY-MM" or "YYYYMM", amount); `daily` rows are
    /// (dayKey, amount). Both already in the display currency. Only the
    /// series matching `unit` is read.
    static func points(unit: Calendar.Component, endingAt endKey: Int, monthsBack: Int,
                       monthly: [(String, Int64)], daily: [(Int, Int64)]) -> [Point] {
        let cal = Calendar.current
        let win = YearMonth.window(endingAt: endKey, monthsBack: monthsBack)
        let (sy, sm) = YearMonth.components(win.start)
        let (ey, em) = YearMonth.components(win.end)
        guard let startDate = cal.date(from: DateComponents(year: sy, month: sm, day: 1)),
              let nextMonth = cal.date(from: DateComponents(year: ey, month: em + 1, day: 1)),
              let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth)
        else { return [] }
        let endDate = min(monthEnd, Date())
        guard startDate <= endDate else { return [] }

        func bucketStart(_ d: Date) -> Date { cal.dateInterval(of: unit, for: d)?.start ?? d }
        var bucket: [Date: Int64] = [:]
        if unit == .month {
            for (label, a) in monthly { bucket[bucketStart(YearMonth.date(fromLabel: label)), default: 0] += a }
        } else {
            for (day, a) in daily { bucket[bucketStart(Date.from(dayKey: day)), default: 0] += a }
        }
        var out: [Point] = []
        var cursor = bucketStart(startDate)
        let last = bucketStart(endDate)
        var guardCount = 0
        while cursor <= last, guardCount < 1000 {
            out.append(Point(date: cursor, minor: bucket[cursor] ?? 0))
            guard let next = cal.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = bucketStart(next)
            guardCount += 1
        }
        return out
    }
}
