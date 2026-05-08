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
}

struct Transaction: Identifiable, Hashable {
    var id: Int64
    var occurredOn: Date
    var amountMinor: Int64
    var kind: TransactionKind
    var categoryId: Int64
    var accountId: Int64
    var counterpartyAccountId: Int64?
    var note: String?
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    /// Amount with sign — useful for net-flow math (income positive, expense negative).
    var signedAmountMinor: Int64 {
        switch kind {
        case .income:   return amountMinor
        case .expense:  return -amountMinor
        case .transfer: return 0
        }
    }
}

/// Filter object used by TransactionStore.list and SummaryStore queries.
struct TransactionFilter {
    var fromYearMonth: Int?
    var toYearMonth: Int?
    var kinds: [TransactionKind]?
    var categoryIds: [Int64]?
    var accountIds: [Int64]?
    var searchText: String?
    var limit: Int?
    var offset: Int?

    static let allTime = TransactionFilter()
    static func month(_ ym: Int) -> TransactionFilter {
        var f = TransactionFilter()
        f.fromYearMonth = ym
        f.toYearMonth = ym
        return f
    }
}

/// A row in the materialized aggregate. Returned by SummaryStore.
struct MonthlySummary: Hashable {
    var yearMonth: Int
    var categoryId: Int64
    var accountId: Int64
    var kind: TransactionKind
    var totalMinor: Int64
    var count: Int
}

/// A grouped summary, e.g. "by category" or "by month".
struct GroupedSummary: Identifiable, Hashable {
    var key: String        // category name, account name, or "YYYY-MM"
    var keyId: Int64       // category id / account id / year_month
    var totalMinor: Int64
    var count: Int
    var id: String { key }
}
