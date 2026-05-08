import Foundation

final class TransactionStore {
    private let db: Database
    init(db: Database) { self.db = db }

    @discardableResult
    func insert(_ tx: Transaction) throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let s = try db.prepare("""
            INSERT INTO transactions
                (occurred_on, year_month, amount_minor, kind, category_id, account_id,
                 counterparty_account_id, note, tags, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """)
        bindInsert(s, tx, now: now)
        try s.step()
        return db.lastInsertId
    }

    /// Bulk insert with a single transaction wrapper. Used by SeedData and imports.
    func bulkInsert(_ items: [Transaction]) throws {
        try db.transaction {
            let now = Int64(Date().timeIntervalSince1970)
            let s = try db.prepare("""
                INSERT INTO transactions
                    (occurred_on, year_month, amount_minor, kind, category_id, account_id,
                     counterparty_account_id, note, tags, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """)
            for tx in items {
                s.reset()
                bindInsert(s, tx, now: now)
                try s.step()
            }
        }
    }

    func update(_ tx: Transaction) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let s = try db.prepare("""
            UPDATE transactions
               SET occurred_on = ?, year_month = ?, amount_minor = ?, kind = ?,
                   category_id = ?, account_id = ?, counterparty_account_id = ?,
                   note = ?, tags = ?, updated_at = ?
             WHERE id = ?;
        """)
        s.bind(Int64(tx.occurredOn.dayKey),    at: 1)
        s.bind(Int64(tx.occurredOn.yearMonthKey), at: 2)
        s.bind(tx.amountMinor,                  at: 3)
        s.bind(tx.kind.rawValue,                at: 4)
        s.bind(tx.categoryId,                   at: 5)
        s.bind(tx.accountId,                    at: 6)
        s.bind(tx.counterpartyAccountId,        at: 7)
        s.bind(tx.note,                         at: 8)
        s.bind(Self.encodeTags(tx.tags),        at: 9)
        s.bind(now,                             at: 10)
        s.bind(tx.id,                           at: 11)
        try s.step()
    }

    func delete(id: Int64) throws {
        let s = try db.prepare("DELETE FROM transactions WHERE id = ?;")
        s.bind(id, at: 1)
        try s.step()
    }

    func get(id: Int64) throws -> Transaction? {
        let s = try db.prepare(Self.selectColumns + " FROM transactions WHERE id = ?;")
        s.bind(id, at: 1)
        if try s.step() { return Self.read(s) }
        return nil
    }

    func list(_ filter: TransactionFilter) throws -> [Transaction] {
        var conds: [String] = []
        var binds: [(Statement, Int32) -> Void] = []

        if let from = filter.fromYearMonth {
            conds.append("year_month >= ?")
            binds.append { s, i in s.bind(Int64(from), at: i) }
        }
        if let to = filter.toYearMonth {
            conds.append("year_month <= ?")
            binds.append { s, i in s.bind(Int64(to), at: i) }
        }
        if let kinds = filter.kinds, !kinds.isEmpty {
            let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
            conds.append("kind IN (\(placeholders))")
            for k in kinds {
                binds.append { s, i in s.bind(k.rawValue, at: i) }
            }
        }
        if let cats = filter.categoryIds, !cats.isEmpty {
            let placeholders = cats.map { _ in "?" }.joined(separator: ",")
            conds.append("category_id IN (\(placeholders))")
            for c in cats {
                binds.append { s, i in s.bind(c, at: i) }
            }
        }
        if let accs = filter.accountIds, !accs.isEmpty {
            let placeholders = accs.map { _ in "?" }.joined(separator: ",")
            conds.append("account_id IN (\(placeholders))")
            for a in accs {
                binds.append { s, i in s.bind(a, at: i) }
            }
        }
        if let q = filter.searchText, !q.isEmpty {
            conds.append("(note LIKE ? OR tags LIKE ?)")
            let like = "%\(q)%"
            binds.append { s, i in s.bind(like, at: i) }
            binds.append { s, i in s.bind(like, at: i) }
        }

        var sql = Self.selectColumns + " FROM transactions"
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }
        sql += " ORDER BY occurred_on DESC, id DESC"
        if let lim = filter.limit { sql += " LIMIT \(lim)" }
        if let off = filter.offset { sql += " OFFSET \(off)" }

        let s = try db.prepare(sql)
        var i: Int32 = 1
        for b in binds { b(s, i); i += 1 }

        var out: [Transaction] = []
        while try s.step() { out.append(Self.read(s)) }
        return out
    }

    func count() throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM transactions;")
        if try s.step() { return s.int(0) }
        return 0
    }

    // MARK: - Internals

    private static let selectColumns = """
        SELECT id, occurred_on, amount_minor, kind, category_id, account_id,
               counterparty_account_id, note, tags, created_at, updated_at
    """

    private func bindInsert(_ s: Statement, _ tx: Transaction, now: Int64) {
        s.bind(Int64(tx.occurredOn.dayKey),       at: 1)
        s.bind(Int64(tx.occurredOn.yearMonthKey), at: 2)
        s.bind(tx.amountMinor,                    at: 3)
        s.bind(tx.kind.rawValue,                  at: 4)
        s.bind(tx.categoryId,                     at: 5)
        s.bind(tx.accountId,                      at: 6)
        s.bind(tx.counterpartyAccountId,          at: 7)
        s.bind(tx.note,                           at: 8)
        s.bind(Self.encodeTags(tx.tags),          at: 9)
        s.bind(now,                               at: 10)
        s.bind(now,                               at: 11)
    }

    private static func read(_ s: Statement) -> Transaction {
        Transaction(
            id: s.int64(0),
            occurredOn: Date.from(dayKey: s.int(1)),
            amountMinor: s.int64(2),
            kind: TransactionKind(rawValue: s.string(3)) ?? .expense,
            categoryId: s.int64(4),
            accountId: s.int64(5),
            counterpartyAccountId: s.optionalInt64(6),
            note: s.optionalString(7),
            tags: decodeTags(s.optionalString(8)),
            createdAt: Date(timeIntervalSince1970: TimeInterval(s.int64(9))),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(s.int64(10)))
        )
    }

    private static func encodeTags(_ tags: [String]) -> String {
        guard !tags.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: tags),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }

    private static func decodeTags(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}
