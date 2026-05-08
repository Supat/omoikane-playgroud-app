import Foundation
import Observation

/// App-wide state. Owns the database connection and the stores. Views observe
/// `dataVersion` to refresh; mutating writes bump it.
@Observable
final class AppState {
    let db: Database
    let transactions: TransactionStore
    let categories: CategoryStore
    let accounts: AccountStore
    let summaries: SummaryStore

    /// Bumped on every mutation; views key their lookups on this value so SwiftUI
    /// re-evaluates @Observable reads without us having to publish each table.
    private(set) var dataVersion: Int = 0

    /// Current user-selected currency for amount entry. App stores per-account
    /// currency at the schema level; this is just the default for new entries.
    var defaultCurrency: String = "JPY"

    init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        let db = try Database(url: url)
        try Schema.migrate(db)
        self.db = db
        self.transactions = TransactionStore(db: db)
        self.categories = CategoryStore(db: db)
        self.accounts = AccountStore(db: db)
        self.summaries = SummaryStore(db: db)
        try SeedData.seedIfNeeded(db: db, addSampleTransactions: true)
    }

    static func defaultDatabaseURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Omoikane", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("omoikane.sqlite", isDirectory: false)
    }

    func bump() { dataVersion &+= 1 }

    // MARK: - Mutation helpers (bump dataVersion + serialize)

    func addTransaction(_ tx: Transaction) throws -> Int64 {
        let id = try db.sync { try transactions.insert(tx) }
        bump()
        return id
    }

    func updateTransaction(_ tx: Transaction) throws {
        try db.sync { try transactions.update(tx) }
        bump()
    }

    func deleteTransaction(id: Int64) throws {
        try db.sync { try transactions.delete(id: id) }
        bump()
    }

    func addCategory(name: String, kind: CategoryKind, icon: String? = nil) throws -> Int64 {
        let id = try db.sync { try categories.insert(name: name, kind: kind, icon: icon) }
        bump()
        return id
    }

    func updateCategory(_ c: LedgerCategory) throws {
        try db.sync { try categories.update(c) }
        bump()
    }

    func archiveCategory(id: Int64) throws {
        try db.sync { try categories.archive(id: id) }
        bump()
    }

    func addAccount(name: String, kind: AccountKind, currency: String, initialBalanceMinor: Int64) throws -> Int64 {
        let id = try db.sync {
            try accounts.insert(name: name, kind: kind, currency: currency, initialBalanceMinor: initialBalanceMinor)
        }
        bump()
        return id
    }

    func updateAccount(_ a: Account) throws {
        try db.sync { try accounts.update(a) }
        bump()
    }
}
