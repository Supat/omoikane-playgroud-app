import Foundation

/// Schema and migrations.
///
/// Performance design notes
/// ------------------------
/// `transactions` is the append-heavy fact table. It stores money in **minor units**
/// (e.g. yen as Int64; for currencies with sub-units, the smallest unit). It also
/// denormalizes two derived columns to avoid recomputing them at query time:
///   - `occurred_on`: days-since-1970-01-01 in the user's calendar (Int)
///   - `year_month`: YYYYMM as Int (e.g. 202605)
///
/// Both have indexes so range scans (last 30 days, this month, etc.) are O(log N).
///
/// `monthly_summaries` is a *materialized* aggregate keyed by
/// (year_month, category_id, account_id, kind). It is maintained by triggers on
/// every insert/update/delete to `transactions`, so summary queries don't scan the
/// fact table at all. With a few million rows in `transactions`, asking
/// "spending by category in May 2026 for the credit card account" is a small index
/// range scan over the summary table.
enum Schema {
    static let latestVersion = 1

    static func migrate(_ db: Database) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);")
        var current = 0
        let s = try db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_version;")
        if try s.step() { current = s.int(0) }

        if current < 1 {
            try db.transaction {
                try migrateToV1(db)
                try db.exec("INSERT INTO schema_version(version) VALUES (1);")
            }
        }
    }

    private static func migrateToV1(_ db: Database) throws {
        try db.exec("""
            CREATE TABLE categories (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT    NOT NULL,
                kind        TEXT    NOT NULL CHECK(kind IN ('income','expense')),
                parent_id   INTEGER REFERENCES categories(id),
                icon        TEXT,
                color       TEXT,
                sort_order  INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0
            );
        """)
        try db.exec("CREATE INDEX idx_cat_kind ON categories(kind, is_archived, sort_order);")

        try db.exec("""
            CREATE TABLE accounts (
                id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                name                  TEXT    NOT NULL,
                kind                  TEXT    NOT NULL CHECK(kind IN ('cash','bank','credit','investment','other')),
                currency              TEXT    NOT NULL DEFAULT 'JPY',
                initial_balance_minor INTEGER NOT NULL DEFAULT 0,
                is_archived           INTEGER NOT NULL DEFAULT 0,
                sort_order            INTEGER NOT NULL DEFAULT 0
            );
        """)
        try db.exec("CREATE INDEX idx_acc_archived ON accounts(is_archived, sort_order);")

        try db.exec("""
            CREATE TABLE transactions (
                id                       INTEGER PRIMARY KEY AUTOINCREMENT,
                occurred_on              INTEGER NOT NULL,
                year_month               INTEGER NOT NULL,
                amount_minor             INTEGER NOT NULL,
                kind                     TEXT    NOT NULL CHECK(kind IN ('income','expense','transfer')),
                category_id              INTEGER NOT NULL REFERENCES categories(id),
                account_id               INTEGER NOT NULL REFERENCES accounts(id),
                counterparty_account_id  INTEGER REFERENCES accounts(id),
                note                     TEXT,
                tags                     TEXT,
                created_at               INTEGER NOT NULL,
                updated_at               INTEGER NOT NULL
            );
        """)
        try db.exec("CREATE INDEX idx_tx_occurred_on ON transactions(occurred_on);")
        try db.exec("CREATE INDEX idx_tx_year_month  ON transactions(year_month);")
        try db.exec("CREATE INDEX idx_tx_cat_ym      ON transactions(category_id, year_month);")
        try db.exec("CREATE INDEX idx_tx_acc_ym      ON transactions(account_id,  year_month);")
        try db.exec("CREATE INDEX idx_tx_kind_ym     ON transactions(kind,        year_month);")

        // Materialized aggregate. Composite primary key + WITHOUT ROWID for compact
        // index-only scans.
        try db.exec("""
            CREATE TABLE monthly_summaries (
                year_month         INTEGER NOT NULL,
                category_id        INTEGER NOT NULL,
                account_id         INTEGER NOT NULL,
                kind               TEXT    NOT NULL,
                total_amount_minor INTEGER NOT NULL DEFAULT 0,
                transaction_count  INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (year_month, category_id, account_id, kind)
            ) WITHOUT ROWID;
        """)
        try db.exec("CREATE INDEX idx_ms_ym       ON monthly_summaries(year_month);")
        try db.exec("CREATE INDEX idx_ms_cat_ym   ON monthly_summaries(category_id, year_month);")
        try db.exec("CREATE INDEX idx_ms_acc_ym   ON monthly_summaries(account_id, year_month);")
        try db.exec("CREATE INDEX idx_ms_kind_ym  ON monthly_summaries(kind, year_month);")

        // Triggers keep monthly_summaries in lock-step with transactions.
        try db.exec("""
            CREATE TRIGGER tx_ai AFTER INSERT ON transactions
            BEGIN
                INSERT INTO monthly_summaries
                    (year_month, category_id, account_id, kind, total_amount_minor, transaction_count)
                VALUES
                    (NEW.year_month, NEW.category_id, NEW.account_id, NEW.kind,
                     NEW.amount_minor, 1)
                ON CONFLICT(year_month, category_id, account_id, kind) DO UPDATE SET
                    total_amount_minor = total_amount_minor + NEW.amount_minor,
                    transaction_count  = transaction_count  + 1;
            END;
        """)
        try db.exec("""
            CREATE TRIGGER tx_ad AFTER DELETE ON transactions
            BEGIN
                UPDATE monthly_summaries
                   SET total_amount_minor = total_amount_minor - OLD.amount_minor,
                       transaction_count  = transaction_count  - 1
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND kind        = OLD.kind;
                DELETE FROM monthly_summaries
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND kind        = OLD.kind
                   AND transaction_count <= 0;
            END;
        """)
        try db.exec("""
            CREATE TRIGGER tx_au AFTER UPDATE ON transactions
            BEGIN
                UPDATE monthly_summaries
                   SET total_amount_minor = total_amount_minor - OLD.amount_minor,
                       transaction_count  = transaction_count  - 1
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND kind        = OLD.kind;
                DELETE FROM monthly_summaries
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND kind        = OLD.kind
                   AND transaction_count <= 0;
                INSERT INTO monthly_summaries
                    (year_month, category_id, account_id, kind, total_amount_minor, transaction_count)
                VALUES
                    (NEW.year_month, NEW.category_id, NEW.account_id, NEW.kind,
                     NEW.amount_minor, 1)
                ON CONFLICT(year_month, category_id, account_id, kind) DO UPDATE SET
                    total_amount_minor = total_amount_minor + NEW.amount_minor,
                    transaction_count  = transaction_count  + 1;
            END;
        """)
    }

    /// Recompute monthly_summaries from scratch. Useful after bulk imports that
    /// were intentionally run with triggers disabled, or as a self-heal.
    static func rebuildSummaries(_ db: Database) throws {
        try db.transaction {
            try db.exec("DELETE FROM monthly_summaries;")
            try db.exec("""
                INSERT INTO monthly_summaries
                    (year_month, category_id, account_id, kind, total_amount_minor, transaction_count)
                SELECT year_month, category_id, account_id, kind,
                       SUM(amount_minor), COUNT(*)
                  FROM transactions
                 GROUP BY year_month, category_id, account_id, kind;
            """)
        }
    }
}
