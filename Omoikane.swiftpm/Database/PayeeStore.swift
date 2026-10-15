import Foundation

final class PayeeStore {
    private let db: Database
    init(db: Database) { self.db = db }

    func list(includeArchived: Bool = false) throws -> [Payee] {
        let s = try db.prepare("""
            SELECT id, name, is_archived FROM payees
             \(includeArchived ? "" : "WHERE is_archived = 0")
             ORDER BY name COLLATE NOCASE;
        """)
        var out: [Payee] = []
        while try s.step() {
            out.append(Payee(id: s.int64(0), name: s.string(1), isArchived: s.int(2) != 0))
        }
        return out
    }

    /// Returns the existing payee with this name (case-insensitive) or
    /// creates one. Names are trimmed; an empty name yields nil.
    func findOrCreate(name raw: String) throws -> Int64? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let find = try db.prepare("SELECT id FROM payees WHERE name = ? COLLATE NOCASE;")
        find.bind(name, at: 1)
        if try find.step() { return find.int64(0) }
        let ins = try db.prepare("INSERT INTO payees (name) VALUES (?);")
        ins.bind(name, at: 1)
        try ins.step()
        return db.lastInsertId
    }

    func update(_ p: Payee) throws {
        let s = try db.prepare("UPDATE payees SET name = ?, is_archived = ? WHERE id = ?;")
        s.bind(p.name, at: 1).bind(p.isArchived ? 1 : 0, at: 2).bind(p.id, at: 3)
        try s.step()
    }

    func referenceCount(for id: Int64) throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM transactions WHERE payee_id = ?;")
        s.bind(id, at: 1)
        return try s.step() ? s.int(0) : 0
    }

    /// Hard delete; FK enforcement rejects it while transactions reference
    /// the payee, so callers check `referenceCount(for:)` first.
    func delete(id: Int64) throws {
        let s = try db.prepare("DELETE FROM payees WHERE id = ?;")
        s.bind(id, at: 1)
        try s.step()
    }
}
