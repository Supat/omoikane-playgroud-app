import Foundation

/// Imports a Money Pro (iBear) `.back` file, replacing the whole ledger.
///
/// The `.back` file is a flat container of `name\n<byteCount>\n<bytes>\n`
/// entries; one of them is Money Pro's SQLite database. We write that blob
/// to a temp file, ATTACH it, and translate with plain SQL inside one
/// transaction. Money Pro keeps money as REAL and category lines in a
/// `splitTransaction` child table; we round to minor units and emit one
/// row per split line, linked through `split_group`.
///
/// Opening balances: Money Pro's `balance.sum` is the figure the app
/// displays, so each account's `initial_balance_minor` is set to
/// `displayed − net flow of the imported rows`. Credit cards are flipped
/// because Omoikane stores debt as negative.
/// ponytail: Money Pro's own opening-balance rows (type 7) are dropped in
/// favour of this; if a balance looks off after import, edit it in Accounts.
enum MoneyProImport {
    struct Summary {
        var accounts = 0
        var categories = 0
        var transactions = 0
        var homeCurrency: String?
    }

    enum ImportError: LocalizedError {
        case notABackup
        var errorDescription: String? { "This file is not a Money Pro backup." }
    }

    static func run(db: Database, backupURL: URL) throws -> Summary {
        let scoped = backupURL.startAccessingSecurityScopedResource()
        defer { if scoped { backupURL.stopAccessingSecurityScopedResource() } }
        let sqlite = try extractDatabase(from: Data(contentsOf: backupURL))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moneypro-\(UUID().uuidString).sqlite")
        try sqlite.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try run(db: db, moneyProDatabasePath: tmp.path)
    }

    /// Pull the embedded SQLite database out of the `.back` container.
    static func extractDatabase(from data: Data) throws -> Data {
        var i = data.startIndex
        func line() -> String? {
            guard let nl = data[i...].firstIndex(of: 0x0A) else { return nil }
            defer { i = nl + 1 }
            return String(decoding: data[i..<nl], as: UTF8.self)
        }
        while i < data.endIndex,
              let name = line(),
              let size = line().flatMap(Int.init),
              i + size <= data.endIndex {
            let blob = data[i..<(i + size)]
            i += size
            if i < data.endIndex, data[i] == 0x0A { i += 1 }
            if name.hasSuffix("database.sql"), blob.starts(with: "SQLite format 3".utf8) {
                return Data(blob)
            }
        }
        throw ImportError.notABackup
    }

    static func run(db: Database, moneyProDatabasePath path: String) throws -> Summary {
        // ATTACH is not allowed inside a transaction, so it brackets one.
        try db.exec("ATTACH DATABASE '\(path.replacingOccurrences(of: "'", with: "''"))' AS mp;")
        defer { try? db.exec("DETACH DATABASE mp;") }
        var summary = Summary()
        try db.transaction {
            try db.exec(sql)
            summary.accounts     = try scalar(db, "SELECT COUNT(*) FROM accounts;")
            summary.categories   = try scalar(db, "SELECT COUNT(*) FROM categories;")
            summary.transactions = try scalar(db, "SELECT COUNT(*) FROM transactions;")
            let home = try db.prepare("SELECT key FROM mp.currency WHERE isDefault = 1 LIMIT 1;")
            if try home.step() { summary.homeCurrency = home.string(0) }
        }
        return summary
    }

    private static func scalar(_ db: Database, _ query: String) throws -> Int {
        let s = try db.prepare(query)
        return try s.step() ? s.int(0) : 0
    }

    /// Money Pro transactionType → kind. 0 expense, 1 income, 2 transfer,
    /// 3 lend, 4/5 borrow, 6 repay, 7 opening balance (dropped), 8 misc.
    static let sql = """
        DELETE FROM transactions;
        DELETE FROM statements;
        DELETE FROM monthly_summaries;
        DELETE FROM categories;
        DELETE FROM accounts;
        DELETE FROM currency_rates;

        CREATE TEMP TABLE cur_scale AS
        SELECT key AS cur, CASE WHEN key IN ('JPY','KRW','VND','IDR') THEN 1 ELSE 100 END AS scale
          FROM mp.currency;

        -- Live accounts, plus deleted ones that still own a live transaction leg (imported archived).
        CREATE TEMP TABLE acct_src AS
        SELECT b.primaryKey, b.name, b.currencyKey, b.sum, b.isDeleted, b.indexNumber, b.defaultCleared,
               CASE b.balanceType
                 WHEN 1 THEN 'credit' WHEN 2 THEN 'investment' WHEN 3 THEN 'other'
                 ELSE CASE WHEN b.name LIKE '%Bank%' OR b.name LIKE '%SMBC%' OR b.name LIKE '%Saving%' OR b.name LIKE '%Wise%'
                           THEN 'bank' ELSE 'cash' END
               END AS kind,
               ROW_NUMBER() OVER (ORDER BY b.isDeleted, b.indexNumber, b.primaryKey) AS new_id
          FROM mp.balance b
         WHERE b.isDeleted = 0
            OR EXISTS (SELECT 1 FROM mp.transactions t WHERE t.isDeleted = 0
                          AND (t.cashFlowPrimaryKey = b.primaryKey OR t.secondCashFlowPrimaryKey = b.primaryKey));

        INSERT INTO accounts (id, name, kind, currency, initial_balance_minor, is_archived, sort_order, clears_entries_by_default)
        SELECT a.new_id, a.name, a.kind, a.currencyKey, 0, a.isDeleted, a.indexNumber, a.defaultCleared
          FROM acct_src a ORDER BY a.new_id;

        CREATE TEMP TABLE cat_src AS
        SELECT c.primaryKey, c.name, c.flowType, c.parentPrimaryKey, c.hidden, c.indexNumber,
               ROW_NUMBER() OVER (ORDER BY (c.parentPrimaryKey IS NOT NULL AND c.parentPrimaryKey <> ''),
                                           c.flowType, c.indexNumber, c.primaryKey) AS new_id
          FROM mp.category c WHERE c.isDeleted = 0;

        INSERT INTO categories (id, name, kind, parent_id, sort_order, is_archived)
        SELECT c.new_id, c.name, CASE c.flowType WHEN 1 THEN 'income' ELSE 'expense' END,
               (SELECT p.new_id FROM cat_src p WHERE p.primaryKey = c.parentPrimaryKey),
               c.indexNumber, c.hidden
          FROM cat_src c ORDER BY c.new_id;

        -- Transfers need a NOT NULL category; a handful of rows have none.
        INSERT INTO categories (name, kind, sort_order, is_archived) VALUES ('Transfer', 'expense', 9000, 1);
        INSERT INTO categories (name, kind, sort_order, is_archived) VALUES ('Uncategorized', 'expense', 9001, 0);
        CREATE TEMP TABLE fallback AS
        SELECT (SELECT id FROM categories WHERE name = 'Transfer' AND sort_order = 9000) AS transfer_cat,
               (SELECT id FROM categories WHERE name = 'Uncategorized' AND sort_order = 9001) AS uncat;

        CREATE TEMP TABLE split_groups AS
        SELECT transactionsPrimaryKey AS pk, ROW_NUMBER() OVER (ORDER BY transactionsPrimaryKey) AS grp
          FROM mp.splitTransaction GROUP BY transactionsPrimaryKey HAVING COUNT(*) > 1;

        -- One row per split line; rows with no split (transfers, strays) import whole.
        CREATE TEMP TABLE tx_src AS
        SELECT t.primaryKey AS pk, t.sum AS tsum, t.secondSum AS tsum2, t.date AS date, t.transactionType AS ty,
               t.description AS description, t.payeePrimaryKey AS payee, t.isCleared AS isCleared,
               fa.new_id AS from_id, fa.currencyKey AS from_cur, ta.new_id AS to_id, ta.currencyKey AS to_cur,
               s.sum AS ssum, s.categoryPrimaryKey AS scat
          FROM mp.transactions t
          JOIN acct_src fa ON fa.primaryKey = t.cashFlowPrimaryKey
          LEFT JOIN acct_src ta ON ta.primaryKey = t.secondCashFlowPrimaryKey
          LEFT JOIN mp.splitTransaction s ON s.transactionsPrimaryKey = t.primaryKey
         WHERE t.isDeleted = 0 AND t.transactionType <> 7;

        INSERT INTO transactions (occurred_on, year_month, occurred_at, amount_minor, currency, kind,
                                  category_id, account_id, counterparty_account_id, counterparty_amount_minor,
                                  note, tags, created_at, updated_at, cleared_at, counterparty_cleared_at, split_group)
        SELECT CAST(julianday(x.date, 'unixepoch', 'localtime') - julianday('1970-01-01') AS INTEGER),
               CAST(strftime('%Y%m', x.date, 'unixepoch', 'localtime') AS INTEGER),
               CAST(x.date AS INTEGER),
               CAST(ROUND(COALESCE(x.ssum, x.tsum) * COALESCE(fs.scale, 100)) AS INTEGER),
               x.from_cur,
               CASE WHEN x.ty = 2 THEN 'transfer' WHEN x.ty IN (1,4,5) THEN 'income' ELSE 'expense' END,
               CASE WHEN x.ty = 2 THEN f.transfer_cat
                    ELSE COALESCE((SELECT c.new_id FROM cat_src c WHERE c.primaryKey = x.scat), f.uncat) END,
               x.from_id,
               CASE WHEN x.ty = 2 THEN x.to_id END,
               CASE WHEN x.ty = 2 AND x.from_cur <> x.to_cur THEN CAST(ROUND(x.tsum2 * COALESCE(ts.scale, 100)) AS INTEGER) END,
               COALESCE(NULLIF(x.description, ''),
                        (SELECT p.name FROM mp.payee p WHERE x.payee <> '' AND p.primaryKey = x.payee)),
               '[]',
               CAST(x.date AS INTEGER), CAST(x.date AS INTEGER),
               CASE WHEN x.isCleared = 1 THEN CAST(x.date AS INTEGER) END,
               CASE WHEN x.isCleared = 1 AND x.ty = 2 THEN CAST(x.date AS INTEGER) END,
               (SELECT g.grp FROM split_groups g WHERE g.pk = x.pk)
          FROM tx_src x
          LEFT JOIN cur_scale fs ON fs.cur = x.from_cur
          LEFT JOIN cur_scale ts ON ts.cur = x.to_cur
          CROSS JOIN fallback f
         ORDER BY x.date, x.pk;

        -- Money Pro stores "home units per 1 unit" inverted relative to currency_rates.
        INSERT INTO currency_rates (currency, rate_to_home, updated_at)
        SELECT key, 1.0 / rate, CAST(strftime('%s', 'now') AS INTEGER)
          FROM mp.currency
         WHERE rate > 0
           AND key <> (SELECT key FROM mp.currency WHERE isDefault = 1 LIMIT 1)
           AND key IN (SELECT DISTINCT currency FROM accounts);

        -- Opening balance = Money Pro's displayed balance − what the imported rows net to,
        -- so every account lands on the figure the user last saw. Credit cards flip sign.
        UPDATE accounts SET initial_balance_minor =
            CAST(ROUND((SELECT CASE WHEN a.kind = 'credit' THEN -a.sum ELSE a.sum END * COALESCE(cs.scale, 100)
                          FROM acct_src a LEFT JOIN cur_scale cs ON cs.cur = a.currencyKey
                         WHERE a.new_id = accounts.id)) AS INTEGER)
            - COALESCE((SELECT SUM(CASE kind WHEN 'income' THEN amount_minor ELSE -amount_minor END)
                          FROM transactions WHERE account_id = accounts.id), 0)
            - COALESCE((SELECT SUM(COALESCE(counterparty_amount_minor, amount_minor))
                          FROM transactions WHERE kind = 'transfer' AND counterparty_account_id = accounts.id), 0);

        DROP TABLE cur_scale;
        DROP TABLE acct_src;
        DROP TABLE cat_src;
        DROP TABLE fallback;
        DROP TABLE split_groups;
        DROP TABLE tx_src;
        """
}
