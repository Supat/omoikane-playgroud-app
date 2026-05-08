import Foundation

/// Reads from the materialized `monthly_summaries` table for O(small index range)
/// queries regardless of how large `transactions` becomes.
///
/// Every method here is sub-millisecond on a modern device for typical household
/// sizes (years × dozens of categories × handful of accounts) because:
///   1. summaries are pre-aggregated by trigger, so we never sum the fact table,
///   2. the composite primary key + supporting indexes serve every grouping shape.
final class SummaryStore {
    private let db: Database
    init(db: Database) { self.db = db }

    // MARK: Totals

    struct KindTotals: Hashable {
        var income: Int64 = 0
        var expense: Int64 = 0
        var transfer: Int64 = 0
        var net: Int64 { income - expense }
    }

    /// Sum of amounts by kind in [from, to] year_month range.
    func totals(fromYM: Int, toYM: Int, accountIds: [Int64]? = nil) throws -> KindTotals {
        var sql = """
            SELECT kind, COALESCE(SUM(total_amount_minor), 0)
              FROM monthly_summaries
             WHERE year_month BETWEEN ? AND ?
        """
        if let accountIds, !accountIds.isEmpty {
            let qs = accountIds.map { _ in "?" }.joined(separator: ",")
            sql += " AND account_id IN (\(qs))"
        }
        sql += " GROUP BY kind;"
        let s = try db.prepare(sql)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        if let accountIds {
            var i: Int32 = 3
            for a in accountIds { s.bind(a, at: i); i += 1 }
        }
        var t = KindTotals()
        while try s.step() {
            let kind = TransactionKind(rawValue: s.string(0)) ?? .expense
            let total = s.int64(1)
            switch kind {
            case .income:   t.income   = total
            case .expense:  t.expense  = total
            case .transfer: t.transfer = total
            }
        }
        return t
    }

    // MARK: Grouped breakdowns

    /// Spending/income by category over a range. Ordered by total descending.
    func byCategory(fromYM: Int, toYM: Int, kind: TransactionKind, accountIds: [Int64]? = nil) throws -> [GroupedSummary] {
        var sql = """
            SELECT c.id, c.name,
                   COALESCE(SUM(ms.total_amount_minor), 0) AS total,
                   COALESCE(SUM(ms.transaction_count), 0)  AS cnt
              FROM monthly_summaries ms
              JOIN categories c ON c.id = ms.category_id
             WHERE ms.year_month BETWEEN ? AND ?
               AND ms.kind = ?
        """
        if let accountIds, !accountIds.isEmpty {
            let qs = accountIds.map { _ in "?" }.joined(separator: ",")
            sql += " AND ms.account_id IN (\(qs))"
        }
        sql += " GROUP BY c.id, c.name ORDER BY total DESC;"
        let s = try db.prepare(sql)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        s.bind(kind.rawValue, at: 3)
        if let accountIds {
            var i: Int32 = 4
            for a in accountIds { s.bind(a, at: i); i += 1 }
        }
        var out: [GroupedSummary] = []
        while try s.step() {
            out.append(GroupedSummary(
                key: s.string(1),
                keyId: s.int64(0),
                totalMinor: s.int64(2),
                count: s.int(3)
            ))
        }
        return out
    }

    /// Totals per month over a range. Ideal for trend charts.
    func byMonth(fromYM: Int, toYM: Int, kind: TransactionKind? = nil, accountIds: [Int64]? = nil, categoryIds: [Int64]? = nil) throws -> [GroupedSummary] {
        var sql = """
            SELECT year_month,
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
        sql += " GROUP BY year_month ORDER BY year_month;"

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
                totalMinor: s.int64(1),
                count: s.int(2)
            ))
        }
        return out
    }

    /// Spending/income by account over a range.
    func byAccount(fromYM: Int, toYM: Int, kind: TransactionKind) throws -> [GroupedSummary] {
        let s = try db.prepare("""
            SELECT a.id, a.name,
                   COALESCE(SUM(ms.total_amount_minor), 0),
                   COALESCE(SUM(ms.transaction_count),  0)
              FROM monthly_summaries ms
              JOIN accounts a ON a.id = ms.account_id
             WHERE ms.year_month BETWEEN ? AND ?
               AND ms.kind = ?
             GROUP BY a.id, a.name
             ORDER BY 3 DESC;
        """)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        s.bind(kind.rawValue, at: 3)
        var out: [GroupedSummary] = []
        while try s.step() {
            out.append(GroupedSummary(
                key: s.string(1),
                keyId: s.int64(0),
                totalMinor: s.int64(2),
                count: s.int(3)
            ))
        }
        return out
    }

    /// Net flow per account in a window: income − expense (transfers ignored).
    func netByAccount(fromYM: Int, toYM: Int) throws -> [GroupedSummary] {
        let s = try db.prepare("""
            SELECT a.id, a.name,
                   COALESCE(SUM(CASE ms.kind WHEN 'income' THEN ms.total_amount_minor
                                              WHEN 'expense' THEN -ms.total_amount_minor
                                              ELSE 0 END), 0),
                   COALESCE(SUM(ms.transaction_count), 0)
              FROM monthly_summaries ms
              JOIN accounts a ON a.id = ms.account_id
             WHERE ms.year_month BETWEEN ? AND ?
             GROUP BY a.id, a.name
             ORDER BY a.sort_order;
        """)
        s.bind(Int64(fromYM), at: 1)
        s.bind(Int64(toYM),   at: 2)
        var out: [GroupedSummary] = []
        while try s.step() {
            out.append(GroupedSummary(
                key: s.string(1),
                keyId: s.int64(0),
                totalMinor: s.int64(2),
                count: s.int(3)
            ))
        }
        return out
    }
}
