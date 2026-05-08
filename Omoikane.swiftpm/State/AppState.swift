import Foundation
import Observation

/// App-wide state. Owns the database connection, the stores, and the
/// home-currency / exchange-rate preferences that the UI uses to roll up
/// numbers across currencies.
///
/// Views observe `dataVersion` for any data change (writes bump it); they
/// observe `homeCurrency` and `rateVersion` for currency-display changes.
@Observable
final class AppState {
    let db: Database
    let transactions: TransactionStore
    let categories: CategoryStore
    let accounts: AccountStore
    let summaries: SummaryStore
    let currencyRates: CurrencyStore
    let statements: StatementStore

    private(set) var dataVersion: Int = 0
    private(set) var rateVersion: Int = 0

    /// User's home currency. All summary cards roll up to this. Defaults to
    /// the device locale's currency, falling back to JPY.
    var homeCurrency: String {
        didSet {
            UserDefaults.standard.set(homeCurrency, forKey: Self.homeCurrencyKey)
            rateVersion &+= 1
        }
    }

    /// In-memory rate map: currency (non-home) → multiplier-to-home.
    /// Refreshed from `currency_rates` whenever a write happens.
    private(set) var rates: [String: Double] = [:]

    init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        let db = try Database(url: url)
        try Schema.migrate(db)
        self.db = db
        let txStore = TransactionStore(db: db)
        self.transactions = txStore
        self.categories = CategoryStore(db: db)
        self.accounts = AccountStore(db: db)
        self.summaries = SummaryStore(db: db)
        self.currencyRates = CurrencyStore(db: db)
        self.statements = StatementStore(db: db, transactions: txStore)

        // Home currency: persisted preference > device locale > JPY.
        let stored = UserDefaults.standard.string(forKey: Self.homeCurrencyKey)
        let localeCode = Locale.current.currency?.identifier
        self.homeCurrency = stored ?? localeCode ?? "JPY"

        try SeedData.seedIfNeeded(db: db, homeCurrency: self.homeCurrency, addSampleTransactions: true)
        try refreshRates()
    }

    private static let homeCurrencyKey = "omoikane.homeCurrency"

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

    // MARK: - Currency conversion

    /// Convert `minor` from `currency` into the home currency's minor units.
    /// Returns nil if a rate is missing — callers should *not* invent a number;
    /// instead show "rate missing" or skip the row.
    func convertedToHome(_ minor: Int64, from currency: String) -> Int64? {
        if currency == homeCurrency { return minor }
        guard let rate = rates[currency] else { return nil }
        let fromDigits = Money.fractionDigits(for: currency)
        let toDigits = Money.fractionDigits(for: homeCurrency)
        let nativeAmount = Double(minor) / pow(10.0, Double(fromDigits)) * rate
        return Int64((nativeAmount * pow(10.0, Double(toDigits))).rounded())
    }

    /// Returns true if every currency in `currencies` is either the home
    /// currency or has a rate set.
    func haveRatesFor(_ currencies: [String]) -> Bool {
        currencies.allSatisfy { $0 == homeCurrency || rates[$0] != nil }
    }

    /// Currencies that have activity but no rate set. Drives "set a rate"
    /// prompts in Settings/Dashboard.
    func missingRates(among currencies: [String]) -> [String] {
        currencies.filter { $0 != homeCurrency && rates[$0] == nil }
    }

    func refreshRates() throws {
        let rows = try currencyRates.list()
        var map: [String: Double] = [:]
        for r in rows { map[r.currency] = r.rateToHome }
        rates = map
        rateVersion &+= 1
    }

    // MARK: - Mutation helpers (bump dataVersion + serialize)

    /// Plain insert wrapper. The auto-clear *default* (per-account
    /// `clearsEntriesByDefault`) is applied at the UI layer in
    /// TransactionEditor where the user can see and override it via the
    /// Cleared toggle, rather than silently overriding their choice here.
    @discardableResult
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

    @discardableResult
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

    func unarchiveCategory(id: Int64) throws {
        try db.sync { try categories.unarchive(id: id) }
        bump()
    }

    func deleteCategory(id: Int64) throws {
        try db.sync { try categories.delete(id: id) }
        bump()
    }

    @discardableResult
    func addAccount(
        name: String,
        kind: AccountKind,
        currency: String,
        initialBalanceMinor: Int64,
        clearsEntriesByDefault: Bool = false,
        statementClosingDay: Int? = nil
    ) throws -> Int64 {
        let id = try db.sync {
            try accounts.insert(
                name: name, kind: kind, currency: currency,
                initialBalanceMinor: initialBalanceMinor,
                clearsEntriesByDefault: clearsEntriesByDefault,
                statementClosingDay: statementClosingDay
            )
        }
        bump()
        return id
    }

    func updateAccount(_ a: Account) throws {
        try db.sync { try accounts.update(a) }
        bump()
    }

    func archiveAccount(id: Int64) throws {
        try db.sync { try accounts.archive(id: id) }
        bump()
    }

    func unarchiveAccount(id: Int64) throws {
        try db.sync { try accounts.unarchive(id: id) }
        bump()
    }

    func deleteAccount(id: Int64) throws {
        try db.sync { try accounts.delete(id: id) }
        bump()
    }

    func setRate(currency: String, rateToHome: Double) throws {
        try db.sync { try currencyRates.upsert(currency: currency, rateToHome: rateToHome) }
        try refreshRates()
    }

    func clearRate(currency: String) throws {
        try db.sync { try currencyRates.delete(currency: currency) }
        try refreshRates()
    }

    // MARK: - Reconciliation

    @discardableResult
    func openReconciliation(
        accountId: Int64,
        date: Date,
        balanceMinor: Int64,
        currency: String,
        note: String? = nil
    ) throws -> Int64 {
        let id = try db.sync {
            try statements.open(
                accountId: accountId,
                statementDate: date,
                balanceMinor: balanceMinor,
                currency: currency,
                note: note
            )
        }
        bump()
        return id
    }

    func updateStatement(_ st: LedgerStatement) throws {
        try db.sync { try statements.update(st) }
        bump()
    }

    func finalizeReconciliation(
        statementId: Int64,
        clearings: [(txId: Int64, leg: TransactionLeg)]
    ) throws {
        try db.sync { try statements.finalize(statementId: statementId, clearings: clearings) }
        bump()
    }

    func reopenStatement(id: Int64) throws {
        try db.sync { try statements.reopen(statementId: id) }
        bump()
    }

    func deleteStatement(id: Int64) throws {
        try db.sync { try statements.delete(statementId: id) }
        bump()
    }
}
