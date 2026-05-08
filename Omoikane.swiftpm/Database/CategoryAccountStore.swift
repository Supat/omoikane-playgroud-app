import Foundation

final class CategoryStore {
    private let db: Database
    init(db: Database) { self.db = db }

    func list(includeArchived: Bool = false) throws -> [LedgerCategory] {
        let sql = """
            SELECT id, name, kind, parent_id, icon, color, sort_order, is_archived
              FROM categories
             \(includeArchived ? "" : "WHERE is_archived = 0")
             ORDER BY sort_order, name;
        """
        let s = try db.prepare(sql)
        var out: [LedgerCategory] = []
        while try s.step() {
            out.append(LedgerCategory(
                id: s.int64(0),
                name: s.string(1),
                kind: CategoryKind(rawValue: s.string(2)) ?? .expense,
                parentId: s.optionalInt64(3),
                icon: s.optionalString(4),
                color: s.optionalString(5),
                sortOrder: s.int(6),
                isArchived: s.int(7) != 0
            ))
        }
        return out
    }

    @discardableResult
    func insert(name: String, kind: CategoryKind, icon: String? = nil, color: String? = nil, parentId: Int64? = nil) throws -> Int64 {
        let s = try db.prepare("""
            INSERT INTO categories (name, kind, parent_id, icon, color, sort_order, is_archived)
            VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(sort_order)+1 FROM categories), 0), 0);
        """)
        s.bind(name, at: 1)
            .bind(kind.rawValue, at: 2)
            .bind(parentId, at: 3)
            .bind(icon, at: 4)
            .bind(color, at: 5)
        try s.step()
        return db.lastInsertId
    }

    func update(_ c: LedgerCategory) throws {
        let s = try db.prepare("""
            UPDATE categories
               SET name = ?, kind = ?, parent_id = ?, icon = ?, color = ?, sort_order = ?, is_archived = ?
             WHERE id = ?;
        """)
        s.bind(c.name, at: 1)
            .bind(c.kind.rawValue, at: 2)
            .bind(c.parentId, at: 3)
            .bind(c.icon, at: 4)
            .bind(c.color, at: 5)
            .bind(c.sortOrder, at: 6)
            .bind(c.isArchived ? 1 : 0, at: 7)
            .bind(c.id, at: 8)
        try s.step()
    }

    func archive(id: Int64) throws {
        let s = try db.prepare("UPDATE categories SET is_archived = 1 WHERE id = ?;")
        s.bind(id, at: 1)
        try s.step()
    }
}

final class AccountStore {
    private let db: Database
    init(db: Database) { self.db = db }

    func list(includeArchived: Bool = false) throws -> [Account] {
        let sql = """
            SELECT id, name, kind, currency, initial_balance_minor, is_archived, sort_order
              FROM accounts
              \(includeArchived ? "" : "WHERE is_archived = 0")
             ORDER BY sort_order, name;
        """
        let s = try db.prepare(sql)
        var out: [Account] = []
        while try s.step() {
            out.append(Account(
                id: s.int64(0),
                name: s.string(1),
                kind: AccountKind(rawValue: s.string(2)) ?? .other,
                currency: s.string(3),
                initialBalanceMinor: s.int64(4),
                isArchived: s.int(5) != 0,
                sortOrder: s.int(6)
            ))
        }
        return out
    }

    @discardableResult
    func insert(name: String, kind: AccountKind, currency: String = "JPY", initialBalanceMinor: Int64 = 0) throws -> Int64 {
        let s = try db.prepare("""
            INSERT INTO accounts (name, kind, currency, initial_balance_minor, is_archived, sort_order)
            VALUES (?, ?, ?, ?, 0, COALESCE((SELECT MAX(sort_order)+1 FROM accounts), 0));
        """)
        s.bind(name, at: 1)
            .bind(kind.rawValue, at: 2)
            .bind(currency, at: 3)
            .bind(initialBalanceMinor, at: 4)
        try s.step()
        return db.lastInsertId
    }

    func update(_ a: Account) throws {
        let s = try db.prepare("""
            UPDATE accounts
               SET name = ?, kind = ?, currency = ?, initial_balance_minor = ?,
                   is_archived = ?, sort_order = ?
             WHERE id = ?;
        """)
        s.bind(a.name, at: 1)
            .bind(a.kind.rawValue, at: 2)
            .bind(a.currency, at: 3)
            .bind(a.initialBalanceMinor, at: 4)
            .bind(a.isArchived ? 1 : 0, at: 5)
            .bind(a.sortOrder, at: 6)
            .bind(a.id, at: 7)
        try s.step()
    }

    /// Net flow to date: initial_balance + sum(income) - sum(expense)
    /// (transfers cancel out across accounts and don't affect net per account here
    /// for simplicity — extend if you want directional transfer balances).
    func balanceMinor(accountId: Int64) throws -> Int64 {
        let s = try db.prepare("""
            SELECT COALESCE(initial_balance_minor, 0) +
                   COALESCE((SELECT SUM(CASE kind WHEN 'income' THEN amount_minor
                                                  WHEN 'expense' THEN -amount_minor
                                                  ELSE 0 END)
                              FROM transactions WHERE account_id = ?), 0)
              FROM accounts WHERE id = ?;
        """)
        s.bind(accountId, at: 1).bind(accountId, at: 2)
        if try s.step() { return s.int64(0) }
        return 0
    }
}
