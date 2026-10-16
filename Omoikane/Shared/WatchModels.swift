import Foundation

/// What the Watch needs to capture an expense, published by the iOS app as
/// one CloudKit record (`watch_snapshot` / "snapshot", JSON in `payload`)
/// whenever the ledger changes. Flat on purpose: the Watch never sees the
/// ledger, only enough names and ids to label a new entry.
struct WatchSnapshot: Codable, Equatable {
    struct AccountRef: Codable, Equatable, Identifiable, Hashable {
        var id: String          // sync uuid
        var name: String
        var kind: String        // AccountKind raw value
        var currency: String
    }
    struct CategoryRef: Codable, Equatable, Identifiable, Hashable {
        var id: String          // sync uuid
        var name: String
        var parentId: String?
        var icon: String?
        var color: String?
    }
    var homeCurrency: String
    /// Active accounts in display order, payment accounts and credit cards only.
    var accounts: [AccountRef]
    /// Active expense categories, parents before their children.
    var categories: [CategoryRef]
    var yearMonth: Int
    /// This month's spend and the spending limit, home-currency minor units.
    var monthSpentMinor: Int64
    var monthLimitMinor: Int64?
    var generatedAt: Int64

    static let recordType = "watch_snapshot"
    static let recordName = "snapshot"
    static let payloadKey = "payload"

    /// Content identity: the same ledger state yields the same hash
    /// whenever it is generated, so an unchanged snapshot is not re-sent.
    var contentHash: Int {
        var copy = self
        copy.generatedAt = 0
        return (try? JSONEncoder.sorted.encode(copy).hashValue) ?? 0
    }
}

/// One expense captured on the Watch, written as a CloudKit record
/// (`watch_inbox`, record name = `id`, JSON in `payload`). The iOS app turns
/// it into a transaction with the same uuid, so two devices ingesting the
/// same entry produce one row.
struct WatchInboxEntry: Codable, Equatable, Identifiable {
    var id: String
    var amountMinor: Int64
    var currency: String
    var accountId: String
    var categoryId: String
    /// Capture time, Unix seconds. Also the row's created/updated clock.
    var occurredAt: Int64
    var note: String?
    var isEssential: Bool
    var isReimbursable: Bool

    static let recordType = "watch_inbox"
    static let payloadKey = "payload"

    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

extension JSONEncoder {
    /// Deterministic key order, for hashing and for stable payloads.
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
