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
        guard !cleaned.isEmpty,
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
