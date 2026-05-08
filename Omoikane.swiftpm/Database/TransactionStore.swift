import Foundation

final class TransactionStore {
    private let db: Database
    init(db: Database) { self.db = db }

    @discardableResult
    func insert(_ tx: Transaction) throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let s = try db.prepare("""
            INSERT INTO transactions
                (occurred_on, year_month, occurred_at, amount_minor, currency, kind,
                 category_id, account_id, counterparty_account_id,
                 counterparty_amount_minor, note, tags, created_at, updated_at,
                 cleared_at, statement_id,
                 counterparty_cleared_at, counterparty_statement_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
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
                    (occurred_on, year_month, amount_minor, currency, kind,
                     category_id, account_id, counterparty_account_id,
                     counterparty_amount_minor, note, tags, created_at, updated_at,
                     cleared_at, statement_id,
                     counterparty_cleared_at, counterparty_statement_id)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
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
               SET occurred_on = ?, year_month = ?, occurred_at = ?,
                   amount_minor = ?, currency = ?,
                   kind = ?, category_id = ?, account_id = ?,
                   counterparty_account_id = ?, counterparty_amount_minor = ?,
                   note = ?, tags = ?, updated_at = ?,
                   cleared_at = ?, statement_id = ?,
                   counterparty_cleared_at = ?, counterparty_statement_id = ?
             WHERE id = ?;
        """)
        s.bind(Int64(tx.occurredOn.dayKey),                   at: 1)
        s.bind(Int64(tx.occurredOn.yearMonthKey),             at: 2)
        s.bind(Int64(tx.occurredOn.timeIntervalSince1970),    at: 3)
        s.bind(tx.amountMinor,                                at: 4)
        s.bind(tx.currency,                                   at: 5)
        s.bind(tx.kind.rawValue,                              at: 6)
        s.bind(tx.categoryId,                                 at: 7)
        s.bind(tx.accountId,                                  at: 8)
        s.bind(tx.counterpartyAccountId,                      at: 9)
        s.bind(tx.counterpartyAmountMinor,                    at: 10)
        s.bind(tx.note,                                       at: 11)
        s.bind(Self.encodeTags(tx.tags),                      at: 12)
        s.bind(now,                                           at: 13)
        s.bind(tx.clearedAt.map { Int64($0.timeIntervalSince1970) }, at: 14)
        s.bind(tx.statementId,                                at: 15)
        s.bind(tx.counterpartyClearedAt.map { Int64($0.timeIntervalSince1970) }, at: 16)
        s.bind(tx.counterpartyStatementId,                    at: 17)
        s.bind(tx.id,                                         at: 18)
        try s.step()
    }

    /// Mark one leg of a transaction cleared against a statement.
    /// Used by `StatementStore.finalize`. Idempotent — re-clearing with the
    /// same statement is a no-op.
    func markCleared(id: Int64, leg: TransactionLeg, statementId: Int64, clearedAt: Date) throws {
        let ts = Int64(clearedAt.timeIntervalSince1970)
        let sql: String
        switch leg {
        case .account:
            sql = "UPDATE transactions SET cleared_at = ?, statement_id = ? WHERE id = ?;"
        case .counterparty:
            sql = "UPDATE transactions SET counterparty_cleared_at = ?, counterparty_statement_id = ? WHERE id = ?;"
        }
        let s = try db.prepare(sql)
        s.bind(ts,          at: 1)
        s.bind(statementId, at: 2)
        s.bind(id,          at: 3)
        try s.step()
    }

    /// Reverse `markCleared` for a leg. Used by `StatementStore.delete` so
    /// deleting an open statement doesn't leave orphan clearings pointing at it.
    func unmarkClearings(forStatementId stmtId: Int64) throws {
        let s1 = try db.prepare("""
            UPDATE transactions SET cleared_at = NULL, statement_id = NULL
             WHERE statement_id = ?;
        """)
        s1.bind(stmtId, at: 1)
        try s1.step()
        let s2 = try db.prepare("""
            UPDATE transactions
               SET counterparty_cleared_at = NULL, counterparty_statement_id = NULL
             WHERE counterparty_statement_id = ?;
        """)
        s2.bind(stmtId, at: 1)
        try s2.step()
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
        if let curs = filter.currencies, !curs.isEmpty {
            let placeholders = curs.map { _ in "?" }.joined(separator: ",")
            conds.append("currency IN (\(placeholders))")
            for c in curs {
                binds.append { s, i in s.bind(c, at: i) }
            }
        }
        if let anyLeg = filter.accountIdAnyLeg {
            conds.append("(account_id = ? OR (kind = 'transfer' AND counterparty_account_id = ?))")
            binds.append { s, i in s.bind(anyLeg, at: i) }
            binds.append { s, i in s.bind(anyLeg, at: i) }
        }
        if let cap = filter.occurredOnAtMost {
            conds.append("occurred_on <= ?")
            binds.append { s, i in s.bind(Int64(cap), at: i) }
        }
        if let cleared = filter.clearedOnly {
            // If anyLeg is set, the cleared check follows the same leg.
            // Otherwise it's about the from-account leg.
            if let anyLeg = filter.accountIdAnyLeg {
                if cleared {
                    conds.append("((account_id = ? AND cleared_at IS NOT NULL) OR (counterparty_account_id = ? AND counterparty_cleared_at IS NOT NULL))")
                } else {
                    conds.append("((account_id = ? AND cleared_at IS NULL) OR (counterparty_account_id = ? AND counterparty_cleared_at IS NULL))")
                }
                binds.append { s, i in s.bind(anyLeg, at: i) }
                binds.append { s, i in s.bind(anyLeg, at: i) }
            } else {
                conds.append(cleared ? "cleared_at IS NOT NULL" : "cleared_at IS NULL")
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
        // occurred_at is the precise timestamp; occurred_on remains in the
        // tiebreaker for rows written before v4 (where occurred_at = 0).
        sql += " ORDER BY occurred_at DESC, occurred_on DESC, id DESC"
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
        SELECT id, occurred_on, occurred_at, amount_minor, currency, kind,
               category_id, account_id,
               counterparty_account_id, counterparty_amount_minor,
               note, tags, created_at, updated_at,
               cleared_at, statement_id,
               counterparty_cleared_at, counterparty_statement_id
    """

    private func bindInsert(_ s: Statement, _ tx: Transaction, now: Int64) {
        s.bind(Int64(tx.occurredOn.dayKey),                   at: 1)
        s.bind(Int64(tx.occurredOn.yearMonthKey),             at: 2)
        s.bind(Int64(tx.occurredOn.timeIntervalSince1970),    at: 3)
        s.bind(tx.amountMinor,                                at: 4)
        s.bind(tx.currency,                                   at: 5)
        s.bind(tx.kind.rawValue,                              at: 6)
        s.bind(tx.categoryId,                                 at: 7)
        s.bind(tx.accountId,                                  at: 8)
        s.bind(tx.counterpartyAccountId,                      at: 9)
        s.bind(tx.counterpartyAmountMinor,                    at: 10)
        s.bind(tx.note,                                       at: 11)
        s.bind(Self.encodeTags(tx.tags),                      at: 12)
        s.bind(now,                                           at: 13)
        s.bind(now,                                           at: 14)
        s.bind(tx.clearedAt.map { Int64($0.timeIntervalSince1970) }, at: 15)
        s.bind(tx.statementId,                                at: 16)
        s.bind(tx.counterpartyClearedAt.map { Int64($0.timeIntervalSince1970) }, at: 17)
        s.bind(tx.counterpartyStatementId,                    at: 18)
    }

    private static func read(_ s: Statement) -> Transaction {
        // Prefer the full Unix timestamp; fall back to the day-key midnight
        // for rows written before the v4 backfill (occurred_at = 0 means
        // never set). The fallback stays consistent with the migration's
        // backfill formula (`occurred_on * 86400`).
        let occurredAtSeconds = s.int64(2)
        let occurredOn: Date = occurredAtSeconds > 0
            ? Date(timeIntervalSince1970: TimeInterval(occurredAtSeconds))
            : Date.from(dayKey: s.int(1))

        return Transaction(
            id: s.int64(0),
            occurredOn: occurredOn,
            amountMinor: s.int64(3),
            currency: s.string(4),
            kind: TransactionKind(rawValue: s.string(5)) ?? .expense,
            categoryId: s.int64(6),
            accountId: s.int64(7),
            counterpartyAccountId: s.optionalInt64(8),
            counterpartyAmountMinor: s.optionalInt64(9),
            note: s.optionalString(10),
            tags: decodeTags(s.optionalString(11)),
            createdAt: Date(timeIntervalSince1970: TimeInterval(s.int64(12))),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(s.int64(13))),
            clearedAt: s.optionalInt64(14).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            statementId: s.optionalInt64(15),
            counterpartyClearedAt: s.optionalInt64(16).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            counterpartyStatementId: s.optionalInt64(17)
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
