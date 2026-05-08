import Foundation

/// Reads from the materialized `monthly_summaries` table for O(small index range)
/// queries regardless of how large `transactions` becomes.
///
/// All grouped results carry their currency. Callers either format per-currency
/// or roll up to the user's home currency via `AppState.convertedToHome(_:)`.
final class SummaryStore {
    private let db: Database
    init(db: Database) { self.db = db }

    // MARK: Totals

    /// Per-currency totals: kind → currency → minor.
    /// Caller decides whether to display per-currency or roll up to home.
    struct CurrencyTotals {
        /// kind → currency → minor units.
        var byKind: [TransactionKind: [String: Int64]] = [:]

        func total(for kind: TransactionKind) -> [String: Int64] { byKind[kind] ?? [:] }
        func total(for kind: TransactionKind, currency: String) -> Int64 {
            byKind[kind]?[currency] ?? 0
        }
        var currencies: [String] {
            Array(Set(byKind.values.flatMap { $0.keys })).sorted()
        }
    }

    /// Sum of amounts by (kind, currency) in [from, to] year_month range.
    func totals(fromYM: Int, toYM: Int, accountIds: [Int64]? = nil) throws -> CurrencyTotals {
        var sql = """
            SELECT kind, currency, COALESCE(SUM(total_amount_minor), 0)
              FROM monthly_summaries
             WHERE year_month BETWEEN ? AND ?
        """
        if let accountIds, !accountIds.isEmpty {
            let qs = accountIds.map { _ in "?" }.joined(separator: ",")
            sql += " AND account_id IN (\(qs))"
        }
        sql += " GROUP BY kind, currency;"
        let s = try db.prepare(sql)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        if let accountIds {
            var i: Int32 = 3
            for a in accountIds { s.bind(a, at: i); i += 1 }
        }
        var t = CurrencyTotals()
        while try s.step() {
            let kind = TransactionKind(rawValue: s.string(0)) ?? .expense
            let currency = s.string(1)
            let total = s.int64(2)
            t.byKind[kind, default: [:]][currency] = total
        }
        return t
    }

    // MARK: Grouped breakdowns

    /// Spending/income by category over a range, optionally filtered to a single
    /// currency or to specific accounts. The result row carries its currency.
    func byCategory(fromYM: Int, toYM: Int, kind: TransactionKind, currency: String? = nil, accountIds: [Int64]? = nil) throws -> [GroupedSummary] {
        var sql = """
            SELECT c.id, c.name, ms.currency,
                   COALESCE(SUM(ms.total_amount_minor), 0) AS total,
                   COALESCE(SUM(ms.transaction_count), 0)  AS cnt
              FROM monthly_summaries ms
              JOIN categories c ON c.id = ms.category_id
             WHERE ms.year_month BETWEEN ? AND ?
               AND ms.kind = ?
        """
        var binds: [(Statement, Int32) -> Void] = []
        if let currency {
            sql += " AND ms.currency = ?"
            binds.append { s, i in s.bind(currency, at: i) }
        }
        if let accountIds, !accountIds.isEmpty {
            let qs = accountIds.map { _ in "?" }.joined(separator: ",")
            sql += " AND ms.account_id IN (\(qs))"
            for a in accountIds { binds.append { s, i in s.bind(a, at: i) } }
        }
        sql += " GROUP BY c.id, c.name, ms.currency ORDER BY total DESC;"
        let s = try db.prepare(sql)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        s.bind(kind.rawValue, at: 3)
        var i: Int32 = 4
        for b in binds { b(s, i); i += 1 }

        var out: [GroupedSummary] = []
        while try s.step() {
            out.append(GroupedSummary(
                key: s.string(1),
                keyId: s.int64(0),
                currency: s.string(2),
                totalMinor: s.int64(3),
                count: s.int(4)
            ))
        }
        return out
    }

    /// Totals per (month, currency) over a range. Charts pick a currency.
    func byMonth(fromYM: Int, toYM: Int, kind: TransactionKind? = nil, currency: String? = nil, accountIds: [Int64]? = nil, categoryIds: [Int64]? = nil) throws -> [GroupedSummary] {
        var sql = """
            SELECT year_month, currency,
                   COALESCE(SUM(total_amount_minor), 0) AS total,
                   COALESCE(SUM(transaction_count), 0)  AS cnt
              FROM monthly_summaries
             WHERE year_month BETWEEN ? AND ?
        """
        var binds: [(Statement, Int32) -> Void] = []
        if let kind {
            sql += " AND kind = ?"
            binds.append { s, i in s.bind(kind.rawValue, at: i) }
        }
        if let currency {
            sql += " AND currency = ?"
            binds.append { s, i in s.bind(currency, at: i) }
        }
        if let accountIds, !accountIds.isEmpty {
            let qs = accountIds.map { _ in "?" }.joined(separator: ",")
            sql += " AND account_id IN (\(qs))"
            for a in accountIds { binds.append { s, i in s.bind(a, at: i) } }
        }
        if let categoryIds, !categoryIds.isEmpty {
            let qs = categoryIds.map { _ in "?" }.joined(separator: ",")
            sql += " AND category_id IN (\(qs))"
            for c in categoryIds { binds.append { s, i in s.bind(c, at: i) } }
        }
        sql += " GROUP BY year_month, currency ORDER BY year_month;"

        let s = try db.prepare(sql)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        var i: Int32 = 3
        for b in binds { b(s, i); i += 1 }

        var out: [GroupedSummary] = []
        while try s.step() {
            let ym = s.int(0)
            let label = String(format: "%04d-%02d", ym / 100, ym % 100)
            out.append(GroupedSummary(
                key: label,
                keyId: Int64(ym),
                currency: s.string(1),
                totalMinor: s.int64(2),
                count: s.int(3)
            ))
        }
        return out
    }

    /// Spending/income by account (×currency, since an account has one currency
    /// but the join still preserves it on the row).
    func byAccount(fromYM: Int, toYM: Int, kind: TransactionKind) throws -> [GroupedSummary] {
        let s = try db.prepare("""
            SELECT a.id, a.name, ms.currency,
                   COALESCE(SUM(ms.total_amount_minor), 0),
                   COALESCE(SUM(ms.transaction_count),  0)
              FROM monthly_summaries ms
              JOIN accounts a ON a.id = ms.account_id
             WHERE ms.year_month BETWEEN ? AND ?
               AND ms.kind = ?
             GROUP BY a.id, a.name, ms.currency
             ORDER BY 4 DESC;
        """)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        s.bind(kind.rawValue, at: 3)
        var out: [GroupedSummary] = []
        while try s.step() {
            out.append(GroupedSummary(
                key: s.string(1),
                keyId: s.int64(0),
                currency: s.string(2),
                totalMinor: s.int64(3),
                count: s.int(4)
            ))
        }
        return out
    }

    /// Net flow per account in a window: income − expense (transfers ignored).
    /// Currency comes from the account itself (single currency per account).
    func netByAccount(fromYM: Int, toYM: Int) throws -> [GroupedSummary] {
        let s = try db.prepare("""
            SELECT a.id, a.name, a.currency,
                   COALESCE(SUM(CASE ms.kind WHEN 'income' THEN ms.total_amount_minor
                                              WHEN 'expense' THEN -ms.total_amount_minor
                                              ELSE 0 END), 0),
                   COALESCE(SUM(ms.transaction_count), 0)
              FROM accounts a
              LEFT JOIN monthly_summaries ms
                   ON ms.account_id = a.id
                  AND ms.year_month BETWEEN ? AND ?
             WHERE a.is_archived = 0
             GROUP BY a.id, a.name, a.currency
             ORDER BY a.sort_order;
        """)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        var out: [GroupedSummary] = []
        while try s.step() {
            out.append(GroupedSummary(
                key: s.string(1),
                keyId: s.int64(0),
                currency: s.string(2),
                totalMinor: s.int64(3),
                count: s.int(4)
            ))
        }
        return out
    }

    /// Distinct currencies that have any monthly_summaries activity in the
    /// window — used to populate the rates editor and currency filters.
    func distinctCurrencies(fromYM: Int? = nil, toYM: Int? = nil) throws -> [String] {
        var sql = "SELECT DISTINCT currency FROM monthly_summaries"
        var binds: [(Statement, Int32) -> Void] = []
        if let fromYM, let toYM {
            sql += " WHERE year_month BETWEEN ? AND ?"
            binds.append { s, i in s.bind(Int64(fromYM), at: i) }
            binds.append { s, i in s.bind(Int64(toYM), at: i) }
        }
        sql += " ORDER BY currency;"
        let s = try db.prepare(sql)
        var i: Int32 = 1
        for b in binds { b(s, i); i += 1 }
        var out: [String] = []
        while try s.step() { out.append(s.string(0)) }
        return out
    }
}
