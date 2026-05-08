import Foundation

enum TransactionKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case income, expense, transfer
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .income:   return "Income"
        case .expense:  return "Expense"
        case .transfer: return "Transfer"
        }
    }

    var sfSymbol: String {
        switch self {
        case .income:   return "arrow.down.circle.fill"
        case .expense:  return "arrow.up.circle.fill"
        case .transfer: return "arrow.left.arrow.right.circle.fill"
        }
    }
}

enum CategoryKind: String, CaseIterable, Codable, Hashable {
    case income, expense
}

enum AccountKind: String, CaseIterable, Codable, Hashable {
    case cash, bank, credit, investment, other

    var displayName: String {
        switch self {
        case .cash:       return "Cash"
        case .bank:       return "Bank"
        case .credit:     return "Credit"
        case .investment: return "Investment"
        case .other:      return "Other"
        }
    }

    var sfSymbol: String {
        switch self {
        case .cash:       return "banknote"
        case .bank:       return "building.columns"
        case .credit:     return "creditcard"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .other:      return "tray.full"
        }
    }
}

/// Renamed from `Category` to avoid clash with the ObjC-runtime `Category`
/// typealias for `OpaquePointer` exposed via `import Foundation`.
struct LedgerCategory: Identifiable, Hashable {
    var id: Int64
    var name: String
    var kind: CategoryKind
    var parentId: Int64?
    var icon: String?
    var color: String?
    var sortOrder: Int
    var isArchived: Bool
}

struct Account: Identifiable, Hashable {
    var id: Int64
    var name: String
    var kind: AccountKind
    var currency: String
    var initialBalanceMinor: Int64
    var isArchived: Bool
    var sortOrder: Int
    /// New entries posted to this account are auto-marked cleared on insert.
    /// Used so cash accounts (which you don't reconcile) skip the ceremony.
    var clearsEntriesByDefault: Bool = false
    /// Day-of-month (1...28) when the account's statement closes. Drives the
    /// default statement date in `ReconciliationSheet`. nil = no preference.
    var statementClosingDay: Int? = nil
}

/// Which leg of a transaction is being cleared. For non-transfers there is
/// only the `.account` leg. Transfers are a single row that touches two
/// accounts; each side gets its own clearing slot.
enum TransactionLeg: String, Hashable, Codable { case account, counterparty }

struct Transaction: Identifiable, Hashable {
    var id: Int64
    var occurredOn: Date
    var amountMinor: Int64
    /// ISO 4217 currency code of the from-account. Denormalized so
    /// `monthly_summaries` can group by currency without a join.
    var currency: String
    var kind: TransactionKind
    var categoryId: Int64
    var accountId: Int64
    var counterpartyAccountId: Int64?
    /// Receiving leg of a cross-currency transfer (in the counterparty
    /// account's currency). nil for non-transfers and same-currency transfers.
    var counterpartyAmountMinor: Int64?
    var note: String?
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    /// When the from-account leg was marked cleared (against a statement, or
    /// auto-cleared at insert time for accounts with `clearsEntriesByDefault`).
    var clearedAt: Date? = nil
    /// Statement that cleared the from-account leg, if any.
    var statementId: Int64? = nil
    /// Cleared timestamp for the to-account leg (transfers only).
    var counterpartyClearedAt: Date? = nil
    /// Statement that cleared the to-account leg (transfers only).
    var counterpartyStatementId: Int64? = nil

    /// Amount with sign — useful for net-flow math (income positive, expense negative).
    var signedAmountMinor: Int64 {
        switch kind {
        case .income:   return amountMinor
        case .expense:  return -amountMinor
        case .transfer: return 0
        }
    }

    /// Did either leg clear? Cheap UI check.
    var isClearedAny: Bool { clearedAt != nil || counterpartyClearedAt != nil }
}

/// Filter object used by TransactionStore.list and SummaryStore queries.
struct TransactionFilter {
    var fromYearMonth: Int?
    var toYearMonth: Int?
    var kinds: [TransactionKind]?
    var categoryIds: [Int64]?
    var accountIds: [Int64]?
    var currencies: [String]?
    var searchText: String?
    var limit: Int?
    var offset: Int?
    /// Match `account_id = X OR (kind = 'transfer' AND counterparty_account_id = X)`.
    /// Used by ReconciliationSheet which needs to see both legs of transfers.
    var accountIdAnyLeg: Int64?
    /// Cap rows by occurred_on (day key). Inclusive. Used by ReconciliationSheet
    /// so future-dated transactions don't clutter a statement-period view.
    var occurredOnAtMost: Int?
    /// Filter by clearing state (on the leg referenced by `accountIdAnyLeg`,
    /// if set; otherwise on the from-account leg).
    var clearedOnly: Bool?

    static let allTime = TransactionFilter()
    static func month(_ ym: Int) -> TransactionFilter {
        var f = TransactionFilter()
        f.fromYearMonth = ym
        f.toYearMonth = ym
        return f
    }
}

enum StatementStatus: String, Codable, Hashable { case open, reconciled }

/// One reconciliation cycle for one account. Renamed from `Statement` to
/// avoid clash with the SQLite-prepared-statement wrapper class in
/// `Database.swift`. `statementBalanceMinor` follows the same signed
/// convention as `AccountStore.balanceMinor` (debt is negative). The UI
/// flips the sign for `.credit` accounts on display.
struct LedgerStatement: Identifiable, Hashable {
    var id: Int64
    var accountId: Int64
    var statementDate: Date
    var statementBalanceMinor: Int64
    var currency: String
    var status: StatementStatus
    /// Snapshot at finalize, for audit. Stays accurate even if a cleared
    /// transaction is later edited. nil while the statement is still open.
    var clearedTotalMinor: Int64?
    var clearedCount: Int?
    var note: String?
    var openedAt: Date
    var reconciledAt: Date?
}

/// A row in the materialized aggregate. Returned by SummaryStore.
struct MonthlySummary: Hashable {
    var yearMonth: Int
    var categoryId: Int64
    var accountId: Int64
    var currency: String
    var kind: TransactionKind
    var totalMinor: Int64
    var count: Int
}

/// A grouped summary keyed by either category, account, or year-month.
/// Carries currency so callers can format correctly (or convert to home).
struct GroupedSummary: Identifiable, Hashable {
    var key: String
    var keyId: Int64
    var currency: String
    var totalMinor: Int64
    var count: Int
    var id: String { "\(key)|\(currency)" }
}

/// One row in `currency_rates`. Home currency is not stored here (it's a UI
/// preference owned by AppState). `rateToHome` is "1 unit of this currency
/// equals N units of the home currency".
struct CurrencyRate: Identifiable, Hashable {
    var currency: String
    var rateToHome: Double
    var updatedAt: Date
    var id: String { currency }
}
