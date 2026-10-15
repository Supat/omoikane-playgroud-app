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
    let payees: PayeeStore
    let schedules: ScheduleStore

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
        self.payees = PayeeStore(db: db)
        self.schedules = ScheduleStore(db: db, transactions: txStore)

        // Home currency: persisted preference > device locale > JPY.
        let stored = UserDefaults.standard.string(forKey: Self.homeCurrencyKey)
        let localeCode = Locale.current.currency?.identifier
        self.homeCurrency = stored ?? localeCode ?? "JPY"

        try SeedData.seedIfNeeded(db: db, homeCurrency: self.homeCurrency, addSampleTransactions: true)
        try refreshRates()
        try postDueSchedules()
        BackupStore.backupIfDue(db: db)
    }

    // MARK: - Backups

    @discardableResult
    func backupNow() throws -> URL { try BackupStore.backup(db: db) }

    func autoBackupIfDue() { BackupStore.backupIfDue(db: db) }

    /// Replace the live database with a backup, then migrate it forward
    /// and refresh everything derived from it.
    func restore(from url: URL) throws {
        try db.sync {
            try db.restore(from: url)
            try Schema.migrate(db)
        }
        try refreshRates()
        bump()
    }

    /// Post every recurring transaction that has come due. Called at
    /// launch and whenever the app returns to the foreground.
    func postDueSchedules() throws {
        let n = try db.sync { try schedules.postDue() }
        if n > 0 { bump() }
    }

    private static let homeCurrencyKey = "omoikane.homeCurrency"
    private static let spendingLimitKey = "omoikane.monthlySpendingLimitMinor"

    /// Overall monthly spending limit in home-currency minor units; nil = none.
    /// A preference like the home currency, so it lives in UserDefaults.
    var monthlySpendingLimitMinor: Int64? {
        get { UserDefaults.standard.object(forKey: Self.spendingLimitKey) as? Int64 }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: Self.spendingLimitKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.spendingLimitKey) }
            bump()
        }
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

    // MARK: - Import

    /// Replaces the whole ledger with the contents of a Money Pro backup.
    func importMoneyPro(from url: URL) throws -> MoneyProImport.Summary {
        let summary = try db.sync { try MoneyProImport.run(db: db, backupURL: url) }
        if let home = summary.homeCurrency { homeCurrency = home }
        try refreshRates()
        bump()
        return summary
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

    /// Save a logical transaction as one row per line (a split when there
    /// is more than one). Replaces the previous rows of the same group or
    /// the previous single row.
    func saveLines(_ lines: [Transaction], replacingGroup: Int64?, replacingSingle: Int64?) throws {
        try db.sync { try transactions.replace(groupId: replacingGroup, singleId: replacingSingle, with: lines) }
        bump()
    }

    /// Post an income or expense that moves the account to `newBalanceMinor`.
    /// Uses (and lazily creates) a "Balance adjustment" category of the
    /// matching kind so the correction is visible and reportable.
    func adjustBalance(accountId: Int64, to newBalanceMinor: Int64) throws {
        try db.sync {
            guard let acct = try accounts.get(id: accountId) else { return }
            let delta = newBalanceMinor - (try accounts.balanceMinor(accountId: accountId))
            guard delta != 0 else { return }
            let kind: TransactionKind = delta > 0 ? .income : .expense
            let catKind: CategoryKind = delta > 0 ? .income : .expense
            let all = try categories.list(includeArchived: true)
            let catId = try all.first { $0.name == "Balance adjustment" && $0.kind == catKind }?.id
                ?? categories.insert(name: "Balance adjustment", kind: catKind, icon: "equal.circle")
            let now = Date()
            var tx = Transaction(
                id: 0, occurredOn: now, amountMinor: abs(delta), currency: acct.currency,
                kind: kind, categoryId: catId, accountId: accountId,
                counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                note: "Balance adjustment", tags: [], createdAt: now, updatedAt: now
            )
            tx.clearedAt = now
            _ = try transactions.insert(tx)
        }
        bump()
    }

    /// Delete every transaction and the summary cache; accounts, categories,
    /// payees, schedules, rates and statements stay. Balances fall back to
    /// each account's opening balance.
    func clearAllTransactions() throws {
        try db.sync {
            try db.transaction {
                try db.exec("DELETE FROM transactions;")
                try db.exec("DELETE FROM monthly_summaries;")
            }
        }
        bump()
    }

    // MARK: - Payees & schedules

    func findOrCreatePayee(name: String) throws -> Int64? {
        let id = try db.sync { try payees.findOrCreate(name: name) }
        bump()
        return id
    }

    func updatePayee(_ p: Payee) throws {
        try db.sync { try payees.update(p) }
        bump()
    }

    func deletePayee(id: Int64) throws {
        try db.sync { try payees.delete(id: id) }
        bump()
    }

    @discardableResult
    func addSchedule(_ sc: Schedule) throws -> Int64 {
        let id = try db.sync { try schedules.insert(sc) }
        bump()
        return id
    }

    func updateSchedule(_ sc: Schedule) throws {
        try db.sync { try schedules.update(sc) }
        bump()
    }

    func deleteSchedule(id: Int64) throws {
        try db.sync { try schedules.delete(id: id) }
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
        statementClosingDay: Int? = nil,
        creditLimitMinor: Int64? = nil
    ) throws -> Int64 {
        let id = try db.sync {
            try accounts.insert(
                name: name, kind: kind, currency: currency,
                initialBalanceMinor: initialBalanceMinor,
                clearsEntriesByDefault: clearsEntriesByDefault,
                statementClosingDay: statementClosingDay,
                creditLimitMinor: creditLimitMinor
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
