// Dry-run the Money Pro importer on macOS against a real .back file, using the
// app's own Database / Schema / MoneyProImport sources. Fails loudly if the
// import breaks. Run from the repo root:
//
//   swiftc -O -o /tmp/mp-dryrun Omoikane.swiftpm/Database/Database.swift \
//       Omoikane.swiftpm/Database/Schema.swift \
//       Omoikane.swiftpm/Database/MoneyProImport.swift tools/moneypro-import/main.swift \
//   && /tmp/mp-dryrun "<backup>.back" /tmp/omoikane-dryrun.sqlite
import Foundation

let backup = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: out)
let db = try Database(url: out)
try Schema.migrate(db)
let summary = try MoneyProImport.run(db: db, backupURL: backup)
print("imported accounts=\(summary.accounts) categories=\(summary.categories) transactions=\(summary.transactions) home=\(summary.homeCurrency ?? "-")")

func check(_ sql: String, _ label: String) throws {
    let s = try db.prepare(sql)
    guard try s.step() else { fatalError("\(label): no row") }
    let n = s.int(0)
    print("\(label): \(n)")
    precondition(n == 0, "\(label) must be 0")
}
try check("""
    SELECT COUNT(*) FROM (
      SELECT year_month, category_id, account_id, currency, kind, SUM(amount_minor), COUNT(*) FROM transactions GROUP BY 1,2,3,4,5
      EXCEPT
      SELECT year_month, category_id, account_id, currency, kind, total_amount_minor, transaction_count FROM monthly_summaries)
    """, "summary mismatches")
try check("SELECT COUNT(*) FROM transactions WHERE category_id NOT IN (SELECT id FROM categories)", "dangling categories")
try check("SELECT COUNT(*) FROM transactions WHERE account_id NOT IN (SELECT id FROM accounts) OR (counterparty_account_id IS NOT NULL AND counterparty_account_id NOT IN (SELECT id FROM accounts))", "dangling accounts")
try check("SELECT COUNT(*) FROM transactions WHERE kind = 'transfer' AND counterparty_account_id IS NULL", "transfers without counterparty")
try check("SELECT COUNT(*) FROM transactions WHERE occurred_at = 0", "rows without timestamp")

let rows = try db.prepare("""
    SELECT a.name, a.kind, a.currency, a.is_archived,
      COALESCE(a.initial_balance_minor,0)
      + COALESCE((SELECT SUM(CASE kind WHEN 'income' THEN amount_minor WHEN 'expense' THEN -amount_minor WHEN 'transfer' THEN -amount_minor END) FROM transactions WHERE account_id=a.id),0)
      + COALESCE((SELECT SUM(COALESCE(counterparty_amount_minor, amount_minor)) FROM transactions WHERE kind='transfer' AND counterparty_account_id=a.id),0)
    FROM accounts a WHERE a.is_archived = 0 ORDER BY a.sort_order
    """)
print("live account balances (minor units):")
while try rows.step() {
    print("  \(rows.string(0)) [\(rows.string(1)), \(rows.string(2))]: \(rows.int64(4))")
}
