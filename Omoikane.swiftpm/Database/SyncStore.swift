import Foundation
import SQLite3

/// One row of a synced table as it travels between devices: column → value,
/// with foreign keys carried as the referenced row's `uuid`, never a local id.
struct SyncRecord: Equatable {
    var table: String
    var uuid: String
    var fields: [String: SyncValue]

    var updatedAt: Int64 {
        if case .int(let v)? = fields["updated_at"] { return v }
        return 0
    }
}

enum SyncValue: Equatable {
    case int(Int64), real(Double), text(String), null
}

struct SyncTable {
    let name: String
    /// Column that identifies a row locally: `id`, or `currency` for rates.
    let key: String
    /// Foreign-key columns → referenced table.
    let refs: [String: String]
}

/// The SQLite half of iCloud sync. Triggers (Schema V13) fill `sync_outbox`
/// with every row the app inserts or updates and `sync_tombstones` with every
/// row it deletes; this class turns the outbox into records, applies records
/// from other devices with last-writer-wins on `updated_at`, and keeps the
/// change token. It knows nothing about CloudKit; `CloudSync` does the wire.
///
/// While `apply` runs, `sync_flags.applying = 1` silences the triggers so
/// remote rows are not re-queued as local changes.
final class SyncStore {
    /// Dependency order: a table only references tables before it (and
    /// categories reference themselves; `apply` puts parents first).
    static let tables: [SyncTable] = [
        SyncTable(name: "accounts", key: "id", refs: [:]),
        SyncTable(name: "categories", key: "id", refs: ["parent_id": "categories"]),
        SyncTable(name: "payees", key: "id", refs: [:]),
        SyncTable(name: "currency_rates", key: "currency", refs: [:]),
        SyncTable(name: "statements", key: "id", refs: ["account_id": "accounts"]),
        SyncTable(name: "transactions", key: "id", refs: [
            "category_id": "categories", "account_id": "accounts", "counterparty_account_id": "accounts",
            "payee_id": "payees", "statement_id": "statements", "counterparty_statement_id": "statements"]),
        SyncTable(name: "schedules", key: "id", refs: [
            "category_id": "categories", "account_id": "accounts", "counterparty_account_id": "accounts",
            "payee_id": "payees", "interest_category_id": "categories"]),
    ]
    static func table(named name: String) -> SyncTable? { tables.first { $0.name == name } }

    /// Tombstones older than this are swept once pushed. A stale edit from a
    /// device that was offline longer than this could resurrect a row.
    static let tombstoneRetention: Int64 = 30 * 86_400

    struct Column { let name: String; let type: String; let notNull: Bool }

    private let db: Database
    private var columnCache: [String: [Column]] = [:]
    init(db: Database) { self.db = db }

    // MARK: - Metadata

    func columns(of table: String) throws -> [Column] {
        if let c = columnCache[table] { return c }
        let s = try db.prepare("PRAGMA table_info(\(table));")
        var out: [Column] = []
        while try s.step() { out.append(Column(name: s.string(1), type: s.string(2).uppercased(), notNull: s.int(3) != 0)) }
        columnCache[table] = out
        return out
    }

    // MARK: - Outbound

    /// Rows waiting to go up, and the outbox sequence they were read at.
    func pendingUpserts() throws -> (records: [SyncRecord], seq: Int64) {
        var out: [SyncRecord] = []
        for t in Self.tables {
            let cols = try columns(of: t.name).filter { $0.name != "id" }
            let select = cols.map { c -> String in
                if let ref = t.refs[c.name] { return "(SELECT uuid FROM \(ref) WHERE id = t.\(c.name)) AS \(c.name)" }
                return "t.\(c.name)"
            }.joined(separator: ", ")
            let s = try db.prepare("SELECT \(select) FROM \(t.name) AS t JOIN sync_outbox o ON o.tbl = '\(t.name)' AND o.uuid = t.uuid;")
            while try s.step() {
                var fields: [String: SyncValue] = [:]
                var uuid = ""
                for i in 0..<s.columnCount {
                    let name = s.columnName(i)
                    let v = Self.value(s, i)
                    if name == "uuid" { if case .text(let u) = v { uuid = u }; continue }
                    fields[name] = v
                }
                out.append(SyncRecord(table: t.name, uuid: uuid, fields: fields))
            }
        }
        return (out, try scalar("SELECT COALESCE(MAX(seq), 0) FROM sync_outbox;"))
    }

    func pendingDeletes() throws -> (deletes: [(table: String, uuid: String)], seq: Int64) {
        let s = try db.prepare("SELECT tbl, uuid FROM sync_tombstones WHERE pushed = 0;")
        var out: [(String, String)] = []
        while try s.step() { out.append((s.string(0), s.string(1))) }
        return (out, try scalar("SELECT COALESCE(MAX(seq), 0) FROM sync_tombstones WHERE pushed = 0;"))
    }

    /// Drop outbox rows and mark tombstones up to the sequences a push read
    /// at; anything changed since keeps a higher sequence and stays queued.
    func markPushed(upsertSeq: Int64, deleteSeq: Int64) throws {
        try db.transaction {
            let a = try db.prepare("DELETE FROM sync_outbox WHERE seq <= ?;"); a.bind(upsertSeq, at: 1); try a.step()
            let b = try db.prepare("UPDATE sync_tombstones SET pushed = 1 WHERE pushed = 0 AND seq <= ?;"); b.bind(deleteSeq, at: 1); try b.step()
        }
    }

    func pendingCount() throws -> Int {
        Int(try scalar("SELECT (SELECT COUNT(*) FROM sync_outbox) + (SELECT COUNT(*) FROM sync_tombstones WHERE pushed = 0);"))
    }

    func sweepTombstones(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        let s = try db.prepare("DELETE FROM sync_tombstones WHERE pushed = 1 AND deleted_at < ?;")
        s.bind(now - Self.tombstoneRetention, at: 1); try s.step()
    }

    // MARK: - Inbound

    /// Apply records from other devices in one transaction. Upserts win when
    /// strictly newer than the local row; deletes run in reverse dependency
    /// order and are skipped (not failed) when a local row still references
    /// the target. Returns how many rows changed.
    @discardableResult
    func apply(upserts: [SyncRecord], deletes: [(table: String, uuid: String)]) throws -> Int {
        var changed = 0
        try db.transaction {
            try db.exec("UPDATE sync_flags SET applying = 1 WHERE id = 1;")
            defer { try? db.exec("UPDATE sync_flags SET applying = 0 WHERE id = 1;") }
            for t in Self.tables {
                var recs = upserts.filter { $0.table == t.name }
                if t.name == "categories" {
                    // Parents before children: nesting is one level deep.
                    recs.sort { ($0.fields["parent_id"] ?? .null) == .null && ($1.fields["parent_id"] ?? .null) != .null }
                }
                for r in recs where try upsert(r, in: t) { changed += 1 }
            }
            for t in Self.tables.reversed() {
                for d in deletes where d.table == t.name {
                    if try delete(uuid: d.uuid, in: t) { changed += 1 }
                }
            }
        }
        return changed
    }

    private func upsert(_ r: SyncRecord, in t: SyncTable) throws -> Bool {
        // A row we deleted after this version was written stays deleted,
        // and the delete goes up again so the server copy dies too.
        let tomb = try db.prepare("SELECT deleted_at FROM sync_tombstones WHERE tbl = ? AND uuid = ?;")
        tomb.bind(t.name, at: 1).bind(r.uuid, at: 2)
        if try tomb.step() {
            if tomb.int64(0) >= r.updatedAt {
                let re = try db.prepare("UPDATE sync_tombstones SET pushed = 0 WHERE tbl = ? AND uuid = ?;")
                re.bind(t.name, at: 1).bind(r.uuid, at: 2); try re.step()
                return false
            }
            tomb.reset()
            let drop = try db.prepare("DELETE FROM sync_tombstones WHERE tbl = ? AND uuid = ?;")
            drop.bind(t.name, at: 1).bind(r.uuid, at: 2); try drop.step()
        }
        tomb.reset()

        let cols = try columns(of: t.name).filter { $0.name != "id" && $0.name != "uuid" && r.fields[$0.name] != nil }
        var values: [SyncValue] = []
        for c in cols {
            var v = r.fields[c.name] ?? .null
            if let ref = t.refs[c.name] {
                if case .text(let u) = v, let id = try localId(table: ref, uuid: u) { v = .int(id) } else { v = .null }
                if v == .null && c.notNull { return false }   // referenced row never arrived; skip
            }
            values.append(v)
        }
        let names = cols.map(\.name) + ["uuid"]
        let conflict = t.key == "id" ? "uuid" : t.key
        let sql = """
            INSERT INTO \(t.name) (\(names.joined(separator: ", ")))
            VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))
            ON CONFLICT(\(conflict)) DO UPDATE SET \(cols.map { "\($0.name) = excluded.\($0.name)" }.joined(separator: ", "))
            WHERE excluded.updated_at > \(t.name).updated_at;
            """
        let s = try db.prepare(sql)
        for (i, v) in values.enumerated() { Self.bind(s, v, at: Int32(i + 1)) }
        s.bind(r.uuid, at: Int32(values.count + 1))
        try s.step()
        return sqlite3_changes(db.rawHandle) > 0
    }

    private func delete(uuid: String, in t: SyncTable) throws -> Bool {
        let ob = try db.prepare("DELETE FROM sync_outbox WHERE tbl = ? AND uuid = ?;")
        ob.bind(t.name, at: 1).bind(uuid, at: 2); try ob.step()
        let s = try db.prepare("DELETE FROM \(t.name) WHERE uuid = ?;")
        s.bind(uuid, at: 1)
        do { try s.step() } catch { return false }   // ponytail: FK still held locally; the row stays
        // Remember the deletion so a stale edit arriving later cannot bring it back.
        let tomb = try db.prepare("INSERT OR REPLACE INTO sync_tombstones (tbl, uuid, deleted_at, seq, pushed) VALUES (?, ?, ?, 0, 1);")
        tomb.bind(t.name, at: 1).bind(uuid, at: 2).bind(Int64(Date().timeIntervalSince1970), at: 3); try tomb.step()
        return sqlite3_changes(db.rawHandle) > 0
    }

    func localId(table: String, uuid: String) throws -> Int64? {
        let s = try db.prepare("SELECT id FROM \(table) WHERE uuid = ?;")
        s.bind(uuid, at: 1)
        return try s.step() ? s.int64(0) : nil
    }

    // MARK: - State

    func state(_ key: String) throws -> Data? {
        let s = try db.prepare("SELECT value FROM sync_state WHERE key = ?;")
        s.bind(key, at: 1)
        guard try s.step() else { return nil }
        return s.blob(0)
    }

    func setState(_ key: String, _ value: Data?) throws {
        if let value {
            let s = try db.prepare("INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?);")
            s.bind(key, at: 1).bind(value, at: 2); try s.step()
        } else {
            let s = try db.prepare("DELETE FROM sync_state WHERE key = ?;")
            s.bind(key, at: 1); try s.step()
        }
    }

    /// Forget the change token and zone bookkeeping, e.g. after a backup
    /// restore: the next pull re-reads the whole zone and the upserts sort
    /// out what is newer.
    func resetRemoteState() throws { try db.exec("DELETE FROM sync_state;") }

    // MARK: - Helpers

    private func scalar(_ sql: String) throws -> Int64 {
        let s = try db.prepare(sql)
        return try s.step() ? s.int64(0) : 0
    }

    static func value(_ s: Statement, _ i: Int32) -> SyncValue {
        switch s.columnType(i) {
        case SQLITE_INTEGER: return .int(s.int64(i))
        case SQLITE_FLOAT:   return .real(s.double(i))
        case SQLITE_TEXT:    return .text(s.string(i))
        default:             return .null
        }
    }

    static func bind(_ s: Statement, _ v: SyncValue, at i: Int32) {
        switch v {
        case .int(let x):  s.bind(x, at: i)
        case .real(let x): s.bind(x, at: i)
        case .text(let x): s.bind(x, at: i)
        case .null:        s.bindNull(at: i)
        }
    }
}
