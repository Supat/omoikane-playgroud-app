import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case prepareFailed(String)
    case stepFailed(String)
    case execFailed(String)

    var description: String {
        switch self {
        case .openFailed(let c, let m): return "open(\(c)): \(m)"
        case .prepareFailed(let m): return "prepare: \(m)"
        case .stepFailed(let m): return "step: \(m)"
        case .execFailed(let m): return "exec: \(m)"
        }
    }
}

final class Database {
    private var handle: OpaquePointer?
    private let serial = DispatchQueue(label: "omoikane.db", qos: .userInitiated)

    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw DatabaseError.openFailed(code: rc, message: msg)
        }
        self.handle = db
        try applyPragmas()
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private func applyPragmas() throws {
        // WAL: concurrent readers + a single writer; durable enough with synchronous=NORMAL.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA temp_store = MEMORY;")
        try exec("PRAGMA mmap_size = 268435456;")   // 256MB memory map
        try exec("PRAGMA cache_size = -20000;")     // ~20MB page cache
        try exec("PRAGMA busy_timeout = 5000;")
    }

    // MARK: - Execution

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.execFailed(msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var raw: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &raw, nil)
        guard rc == SQLITE_OK, let raw else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(raw: raw)
    }

    /// Re-entrant transaction. The outermost call uses BEGIN/COMMIT; nested calls
    /// use SAVEPOINT/RELEASE so callers can compose without coordinating who opens
    /// the transaction. Single-connection-only — depth is intentionally not
    /// thread-protected; all mutating work runs through `sync { … }`.
    private var transactionDepth = 0

    @discardableResult
    func transaction<T>(_ block: () throws -> T) throws -> T {
        let isOuter = transactionDepth == 0
        let savepoint = "sp\(transactionDepth)"
        if isOuter {
            try exec("BEGIN IMMEDIATE;")
        } else {
            try exec("SAVEPOINT \(savepoint);")
        }
        transactionDepth += 1
        do {
            let value = try block()
            transactionDepth -= 1
            if isOuter {
                try exec("COMMIT;")
            } else {
                try exec("RELEASE \(savepoint);")
            }
            return value
        } catch {
            transactionDepth -= 1
            if isOuter {
                try? exec("ROLLBACK;")
            } else {
                try? exec("ROLLBACK TO \(savepoint);")
                try? exec("RELEASE \(savepoint);")
            }
            throw error
        }
    }

    /// Serializes mutating work; reads can also use this when consistency matters.
    func sync<T>(_ block: () throws -> T) rethrows -> T {
        try serial.sync { try block() }
    }

    var lastInsertId: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
}

/// Thin RAII wrapper around a sqlite3_stmt.
final class Statement {
    private let raw: OpaquePointer

    init(raw: OpaquePointer) { self.raw = raw }
    deinit { sqlite3_finalize(raw) }

    @discardableResult
    func reset() -> Statement {
        sqlite3_reset(raw)
        sqlite3_clear_bindings(raw)
        return self
    }

    // MARK: Binding (1-indexed)

    @discardableResult func bind(_ v: Int64, at i: Int32) -> Statement {
        sqlite3_bind_int64(raw, i, v); return self
    }
    @discardableResult func bind(_ v: Int, at i: Int32) -> Statement {
        sqlite3_bind_int64(raw, i, Int64(v)); return self
    }
    @discardableResult func bind(_ v: Double, at i: Int32) -> Statement {
        sqlite3_bind_double(raw, i, v); return self
    }
    @discardableResult func bind(_ v: String, at i: Int32) -> Statement {
        sqlite3_bind_text(raw, i, v, -1, SQLITE_TRANSIENT); return self
    }
    @discardableResult func bind(_ v: String?, at i: Int32) -> Statement {
        if let v { sqlite3_bind_text(raw, i, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(raw, i) }
        return self
    }
    @discardableResult func bind(_ v: Int64?, at i: Int32) -> Statement {
        if let v { sqlite3_bind_int64(raw, i, v) }
        else { sqlite3_bind_null(raw, i) }
        return self
    }
    @discardableResult func bindNull(at i: Int32) -> Statement {
        sqlite3_bind_null(raw, i); return self
    }

    // MARK: Stepping

    /// Returns true if a row is available, false if SQLITE_DONE, throws otherwise.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(raw)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let msg = String(cString: sqlite3_errmsg(sqlite3_db_handle(raw)))
            throw DatabaseError.stepFailed("rc=\(rc) \(msg)")
        }
    }

    // MARK: Column accessors (0-indexed)

    func int64(_ c: Int32) -> Int64 { sqlite3_column_int64(raw, c) }
    func int(_ c: Int32) -> Int { Int(sqlite3_column_int64(raw, c)) }
    func double(_ c: Int32) -> Double { sqlite3_column_double(raw, c) }
    func string(_ c: Int32) -> String {
        guard let p = sqlite3_column_text(raw, c) else { return "" }
        return String(cString: p)
    }
    func optionalString(_ c: Int32) -> String? {
        guard sqlite3_column_type(raw, c) != SQLITE_NULL,
              let p = sqlite3_column_text(raw, c) else { return nil }
        return String(cString: p)
    }
    func optionalInt64(_ c: Int32) -> Int64? {
        sqlite3_column_type(raw, c) == SQLITE_NULL ? nil : sqlite3_column_int64(raw, c)
    }
    func isNull(_ c: Int32) -> Bool { sqlite3_column_type(raw, c) == SQLITE_NULL }
}
