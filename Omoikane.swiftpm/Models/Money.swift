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
}
