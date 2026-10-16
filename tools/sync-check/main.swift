// Exercises the SQLite half of iCloud sync (Schema V13 triggers + SyncStore)
// on macOS with two databases and an in-memory stand-in for the CloudKit
// zone. No iCloud account needed. Run from the repo root:
//
//   swiftc -O -o /tmp/sync-check Omoikane/Database/Database.swift \
//       Omoikane/Database/Schema.swift Omoikane/Database/SyncStore.swift \
//       Omoikane/Database/TransactionStore.swift Omoikane/Database/CategoryAccountStore.swift \
//       Omoikane/Database/PayeeStore.swift Omoikane/Database/CurrencyStore.swift \
//       Omoikane/Database/SeedData.swift Omoikane/Models/Models.swift \
//       Omoikane/Models/Money.swift tools/sync-check/main.swift \
//   && /tmp/sync-check /tmp/sync-check-dir
import Foundation

/// What CloudKit does for us, minus the network: last save wins per record,
/// and a cursor hands back everything that changed since.
final class FakeZone {
    struct Entry { var record: SyncRecord?; var seq: Int }
    var entries: [String: Entry] = [:]
    var seq = 0
    func push(_ upserts: [SyncRecord], _ deletes: [(table: String, uuid: String)]) {
        for r in upserts { seq += 1; entries["\(r.table)/\(r.uuid)"] = Entry(record: r, seq: seq) }
        for d in deletes { seq += 1; entries["\(d.table)/\(d.uuid)"] = Entry(record: nil, seq: seq) }
    }
    func changes(since: Int) -> (upserts: [SyncRecord], deletes: [(table: String, uuid: String)]) {
        var ups: [SyncRecord] = [], dels: [(String, String)] = []
        for (key, e) in entries where e.seq > since {
            if let r = e.record { ups.append(r) } else { let p = key.split(separator: "/", maxSplits: 1); dels.append((String(p[0]), String(p[1]))) }
        }
        return (ups, dels)
    }
}

struct Device {
    let name: String
    let db: Database
    let sync: SyncStore
    let tx: TransactionStore
    let accounts: AccountStore
    let categories: CategoryStore
    let payees: PayeeStore
    let rates: CurrencyStore
    var cursor = 0

    init(name: String, dir: URL) throws {
        self.name = name
        db = try Database(url: dir.appendingPathComponent("\(name).sqlite"))
        try Schema.migrate(db)
        sync = SyncStore(db: db)
        tx = TransactionStore(db: db)
        accounts = AccountStore(db: db)
        categories = CategoryStore(db: db)
        payees = PayeeStore(db: db)
        rates = CurrencyStore(db: db)
    }

    /// Pull then push, as CloudSync does. Our own pushes are pulled back on
    /// the next cycle on purpose: applying them must be a no-op.
    mutating func sync(_ zone: FakeZone) throws {
        let ch = zone.changes(since: cursor)
        cursor = zone.seq
        try sync.apply(upserts: ch.upserts, deletes: ch.deletes)
        let ups = try sync.pendingUpserts(), dels = try sync.pendingDeletes()
        zone.push(ups.records, dels.deletes)
        try sync.markPushed(upsertSeq: ups.seq, deleteSeq: dels.seq)
    }

    func scalar(_ sql: String) -> Int64 { let s = try! db.prepare(sql); return (try! s.step()) ? s.int64(0) : 0 }
    func text(_ sql: String) -> String { let s = try! db.prepare(sql); return (try! s.step()) ? s.string(0) : "" }
    func pending() -> Int { try! sync.pendingCount() }
    func summariesConsistent() -> Bool {
        scalar("""
            SELECT COUNT(*) FROM (
              SELECT year_month, category_id, account_id, currency, kind, SUM(amount_minor), COUNT(*) FROM transactions GROUP BY 1,2,3,4,5
              EXCEPT SELECT year_month, category_id, account_id, currency, kind, total_amount_minor, transaction_count FROM monthly_summaries)
            """) == 0
    }
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: dir)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let zone = FakeZone()
var a = try Device(name: "a", dir: dir)
var b = try Device(name: "b", dir: dir)
let now = Date()

// --- 1. A builds a ledger; B receives it with every reference intact.
let bank = try a.accounts.insert(name: "Bank", kind: .bank)
let card = try a.accounts.insert(name: "Card", kind: .credit, creditLimitMinor: 100_000)
let food = try a.categories.insert(name: "Food", kind: .expense, color: "#FF0000")
let grocer = try a.categories.insert(name: "Groceries", kind: .expense, parentId: food)
let salary = try a.categories.insert(name: "Salary", kind: .income)
let amazon = try a.payees.findOrCreate(name: "Amazon")!
try a.rates.upsert(currency: "USD", rateToHome: 150)
func mk(_ amount: Int64, _ kind: TransactionKind, _ cat: Int64, _ acct: Int64, cp: Int64? = nil, payee: Int64? = nil, note: String? = nil) -> Transaction {
    var t = Transaction(id: 0, occurredOn: now, amountMinor: amount, currency: "JPY", kind: kind, categoryId: cat, accountId: acct,
                        counterpartyAccountId: cp, counterpartyAmountMinor: nil, note: note, tags: [], createdAt: now, updatedAt: now)
    t.payeeId = payee; return t
}
let t1 = try a.tx.insert(mk(1200, .expense, grocer, bank, payee: amazon, note: "bread"))
let t2 = try a.tx.insert(mk(320_000, .income, salary, bank))
_ = try a.tx.insert(mk(5000, .transfer, food, bank, cp: card))
try a.tx.replace(groupId: nil, singleId: nil, with: [mk(700, .expense, grocer, card), mk(300, .expense, food, card)])
precondition(a.pending() > 0, "outbox empty after inserts")
try a.sync(zone)
precondition(a.pending() == 0, "outbox not cleared after push")
try b.sync(zone)
for table in ["accounts", "categories", "payees", "currency_rates", "transactions"] {
    let ca = a.scalar("SELECT COUNT(*) FROM \(table)"), cb = b.scalar("SELECT COUNT(*) FROM \(table)")
    precondition(ca == cb, "\(table): a=\(ca) b=\(cb)")
}
precondition(b.text("SELECT p.name FROM categories c JOIN categories p ON p.id = c.parent_id WHERE c.name = 'Groceries'") == "Food", "parent link lost")
precondition(b.text("SELECT a.name || '/' || c.name || '/' || p.name FROM transactions t JOIN accounts a ON a.id = t.account_id JOIN categories c ON c.id = t.category_id JOIN payees p ON p.id = t.payee_id WHERE t.note = 'bread'") == "Bank/Groceries/Amazon", "transaction refs lost")
precondition(b.text("SELECT a.name FROM transactions t JOIN accounts a ON a.id = t.counterparty_account_id WHERE t.kind = 'transfer'") == "Card", "transfer counterparty lost")
precondition(b.scalar("SELECT COUNT(DISTINCT split_group) FROM transactions WHERE split_group IS NOT NULL") == 1, "split group lost")
precondition(b.scalar("SELECT credit_limit_minor FROM accounts WHERE name = 'Card'") == 100_000, "credit limit lost")
precondition(b.summariesConsistent() && a.summariesConsistent(), "summaries drifted")
precondition(b.pending() == 0, "applying remote rows re-queued them")
// Pulling our own pushes back changes nothing.
try a.sync(zone)
precondition(a.pending() == 0 && a.scalar("SELECT COUNT(*) FROM transactions") == 5, "echo changed local state")
print("1 bootstrap ok")

// --- 2. Independent edits on both sides converge.
var e1 = try b.tx.get(id: try b.sync.localId(table: "transactions", uuid: a.text("SELECT uuid FROM transactions WHERE id = \(t1)"))!)!
e1.amountMinor = 1300; try b.tx.update(e1)
var e2 = try a.tx.get(id: t2)!; e2.amountMinor = 330_000; try a.tx.update(e2)
// The whole run fits in one second; move the edits' clocks forward as real time would.
try b.db.exec("UPDATE transactions SET updated_at = updated_at + 5 WHERE note = 'bread';")
try a.db.exec("UPDATE transactions SET updated_at = updated_at + 5 WHERE amount_minor = 330000;")
try b.sync(zone); try a.sync(zone); try b.sync(zone)
precondition(a.scalar("SELECT amount_minor FROM transactions WHERE note = 'bread'") == 1300, "B's edit not on A")
precondition(b.scalar("SELECT amount_minor FROM transactions WHERE amount_minor = 330000") == 330_000, "A's edit not on B")
print("2 converge ok")

// --- 3. Same row edited on both: the later clock wins everywhere.
let breadUUID = a.text("SELECT uuid FROM transactions WHERE note = 'bread'")
try a.db.exec("UPDATE transactions SET amount_minor = 1111 WHERE uuid = '\(breadUUID)'; UPDATE transactions SET updated_at = 1000 WHERE uuid = '\(breadUUID)';")
try b.db.exec("UPDATE transactions SET amount_minor = 2222 WHERE uuid = '\(breadUUID)'; UPDATE transactions SET updated_at = 2000 WHERE uuid = '\(breadUUID)';")
try a.sync(zone); try b.sync(zone); try a.sync(zone)
precondition(a.scalar("SELECT amount_minor FROM transactions WHERE uuid = '\(breadUUID)'") == 2222, "later edit lost on A")
precondition(b.scalar("SELECT amount_minor FROM transactions WHERE uuid = '\(breadUUID)'") == 2222, "later edit overwritten on B")
print("3 conflict ok")

// --- 4. Deletes propagate, and a stale edit cannot resurrect a deleted row.
let salaryUUID = a.text("SELECT uuid FROM transactions WHERE amount_minor = 330000")
try a.tx.delete(id: t2)
try a.sync(zone); try b.sync(zone)
precondition(b.scalar("SELECT COUNT(*) FROM transactions WHERE uuid = '\(salaryUUID)'") == 0, "delete not applied on B")
precondition(a.scalar("SELECT COUNT(*) FROM sync_tombstones WHERE uuid = '\(salaryUUID)' AND pushed = 1") == 1, "tombstone not kept")
// Out-of-order: an older edit of the deleted row shows up in the zone after the delete.
var stale = SyncRecord(table: "transactions", uuid: salaryUUID, fields: [:])
stale.fields = ["occurred_on": .int(0), "year_month": .int(197001), "occurred_at": .int(0), "amount_minor": .int(1), "currency": .text("JPY"),
                "kind": .text("income"), "category_id": .text(a.text("SELECT uuid FROM categories WHERE name = 'Salary'")),
                "account_id": .text(a.text("SELECT uuid FROM accounts WHERE name = 'Bank'")), "tags": .text("[]"),
                "created_at": .int(0), "updated_at": .int(1), "is_essential": .int(0), "is_reimbursable": .int(0)]
zone.push([stale], [])
try a.sync(zone)
precondition(a.scalar("SELECT COUNT(*) FROM transactions WHERE uuid = '\(salaryUUID)'") == 0, "stale edit resurrected the row")
precondition(zone.entries["transactions/\(salaryUUID)"]?.record == nil, "delete not re-pushed over the stale edit")
try b.sync(zone)
precondition(b.scalar("SELECT COUNT(*) FROM transactions WHERE uuid = '\(salaryUUID)'") == 0, "stale edit landed on B")
// Deleting a referenced account is refused locally and stays refused remotely.
precondition((try? a.accounts.delete(id: card)) == nil, "FK should block deleting a used account")
print("4 delete ok")

// --- 5. Same payee name created on both sides: both survive, nothing crashes.
_ = try b.payees.findOrCreate(name: "Starbucks")
_ = try a.payees.findOrCreate(name: "Starbucks")
try a.sync(zone); try b.sync(zone); try a.sync(zone)
precondition(a.scalar("SELECT COUNT(*) FROM payees WHERE name = 'Starbucks'") == 2, "duplicate payee names must coexist")
// Rates: later write wins.
try b.rates.upsert(currency: "USD", rateToHome: 151)
try b.db.exec("UPDATE currency_rates SET updated_at = updated_at + 10 WHERE currency = 'USD';")
try b.sync(zone); try a.sync(zone)
precondition(a.text("SELECT CAST(rate_to_home AS INTEGER) FROM currency_rates WHERE currency = 'USD'") == "151", "rate not synced")
print("5 payees/rates ok")

// --- 6. Two fresh seeded installs merge into one set of defaults.
UserDefaults.standard.removeObject(forKey: SeedData.seededKey)
var c = try Device(name: "c", dir: dir)
try SeedData.seedIfNeeded(db: c.db, homeCurrency: "JPY", addSampleTransactions: true)
UserDefaults.standard.removeObject(forKey: SeedData.seededKey)
var d = try Device(name: "d", dir: dir)
try SeedData.seedIfNeeded(db: d.db, homeCurrency: "JPY", addSampleTransactions: true)
UserDefaults.standard.removeObject(forKey: SeedData.seededKey)
let zone2 = FakeZone()
let seedCats = c.scalar("SELECT COUNT(*) FROM categories"), seedTx = c.scalar("SELECT COUNT(*) FROM transactions")
try c.sync(zone2); try d.sync(zone2); try c.sync(zone2)
precondition(d.scalar("SELECT COUNT(*) FROM categories") == seedCats && c.scalar("SELECT COUNT(*) FROM categories") == seedCats, "seed categories duplicated")
precondition(d.scalar("SELECT COUNT(*) FROM transactions") == seedTx, "seed transactions duplicated")
precondition(d.summariesConsistent(), "summaries drifted after seed merge")
print("6 seed merge ok")

// --- 7. Tombstone sweep keeps recent ones.
try a.sync.sweepTombstones()
precondition(a.scalar("SELECT COUNT(*) FROM sync_tombstones") > 0, "sweep removed fresh tombstones")
try a.sync.sweepTombstones(now: Int64(Date().timeIntervalSince1970) + SyncStore.tombstoneRetention + 1)
precondition(a.scalar("SELECT COUNT(*) FROM sync_tombstones WHERE pushed = 1") == 0, "sweep kept old tombstones")
print("sync-check ok")
