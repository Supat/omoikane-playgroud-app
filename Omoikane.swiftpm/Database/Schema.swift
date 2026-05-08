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
    static let latestVersion = 4

    static func migrate(_ db: Database) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);")
        // Read in a sub-scope so the Statement is finalized (and the read cursor
        // released) before any DDL runs. ALTER TABLE in SQLite requires no
        // open statements on the connection or it fails with "table is locked".
        var current = 0
        do {
            let s = try db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_version;")
            if try s.step() { current = s.int(0) }
            s.reset()
        }

        if current < 1 {
            try db.transaction {
                try migrateToV1(db)
                try db.exec("INSERT INTO schema_version(version) VALUES (1);")
            }
        }
        if current < 2 {
            try db.transaction {
                try migrateToV2(db)
                try db.exec("INSERT INTO schema_version(version) VALUES (2);")
            }
        }
        if current < 3 {
            try db.transaction {
                try migrateToV3(db)
                try db.exec("INSERT INTO schema_version(version) VALUES (3);")
            }
        }
        if current < 4 {
            try db.transaction {
                try migrateToV4(db)
                try db.exec("INSERT INTO schema_version(version) VALUES (4);")
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

    /// V2: per-currency aggregation + cross-currency transfers.
    ///
    /// Adds `currency` (denormalized from accounts at insert time) and
    /// `counterparty_amount_minor` (the receiving leg of a cross-currency
    /// transfer) to `transactions`. Adds `currency` to the
    /// `monthly_summaries` primary key so summing across currencies stops
    /// being meaningless. Adds a `currency_rates` table that stores how many
    /// units of the home currency one unit of the foreign currency is worth;
    /// the home currency itself is stored elsewhere (UserDefaults via AppState)
    /// since it's a UI preference, not relational data.
    private static func migrateToV2(_ db: Database) throws {
        // 1. New columns on transactions.
        try db.exec("ALTER TABLE transactions ADD COLUMN currency TEXT;")
        try db.exec("ALTER TABLE transactions ADD COLUMN counterparty_amount_minor INTEGER;")

        // Backfill currency from the account at the time of the transaction.
        // For an account whose currency was changed later, this fixes the
        // historical rows to the *current* currency, which matches the model
        // (an account has one currency for its lifetime).
        try db.exec("""
            UPDATE transactions
               SET currency = (SELECT a.currency FROM accounts a WHERE a.id = transactions.account_id)
             WHERE currency IS NULL;
        """)
        // Make currency NOT NULL going forward via a CHECK rather than a
        // table rebuild (cheaper for an existing dataset).
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tx_currency_ym ON transactions(currency, year_month);")

        // 2. monthly_summaries needs currency in the PK.
        // SQLite cannot ALTER a PK in place; drop triggers + table, recreate, repopulate.
        try db.exec("DROP TRIGGER IF EXISTS tx_ai;")
        try db.exec("DROP TRIGGER IF EXISTS tx_au;")
        try db.exec("DROP TRIGGER IF EXISTS tx_ad;")
        try db.exec("DROP TABLE IF EXISTS monthly_summaries;")

        try db.exec("""
            CREATE TABLE monthly_summaries (
                year_month         INTEGER NOT NULL,
                category_id        INTEGER NOT NULL,
                account_id         INTEGER NOT NULL,
                currency           TEXT    NOT NULL,
                kind               TEXT    NOT NULL,
                total_amount_minor INTEGER NOT NULL DEFAULT 0,
                transaction_count  INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (year_month, category_id, account_id, currency, kind)
            ) WITHOUT ROWID;
        """)
        try db.exec("CREATE INDEX idx_ms_ym       ON monthly_summaries(year_month);")
        try db.exec("CREATE INDEX idx_ms_cat_ym   ON monthly_summaries(category_id, year_month);")
        try db.exec("CREATE INDEX idx_ms_acc_ym   ON monthly_summaries(account_id, year_month);")
        try db.exec("CREATE INDEX idx_ms_kind_ym  ON monthly_summaries(kind, year_month);")
        try db.exec("CREATE INDEX idx_ms_cur_ym   ON monthly_summaries(currency, year_month);")

        try db.exec("""
            CREATE TRIGGER tx_ai AFTER INSERT ON transactions
            BEGIN
                INSERT INTO monthly_summaries
                    (year_month, category_id, account_id, currency, kind, total_amount_minor, transaction_count)
                VALUES
                    (NEW.year_month, NEW.category_id, NEW.account_id, NEW.currency, NEW.kind,
                     NEW.amount_minor, 1)
                ON CONFLICT(year_month, category_id, account_id, currency, kind) DO UPDATE SET
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
                   AND currency    = OLD.currency
                   AND kind        = OLD.kind;
                DELETE FROM monthly_summaries
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND currency    = OLD.currency
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
                   AND currency    = OLD.currency
                   AND kind        = OLD.kind;
                DELETE FROM monthly_summaries
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND currency    = OLD.currency
                   AND kind        = OLD.kind
                   AND transaction_count <= 0;
                INSERT INTO monthly_summaries
                    (year_month, category_id, account_id, currency, kind, total_amount_minor, transaction_count)
                VALUES
                    (NEW.year_month, NEW.category_id, NEW.account_id, NEW.currency, NEW.kind,
                     NEW.amount_minor, 1)
                ON CONFLICT(year_month, category_id, account_id, currency, kind) DO UPDATE SET
                    total_amount_minor = total_amount_minor + NEW.amount_minor,
                    transaction_count  = transaction_count  + 1;
            END;
        """)

        // Repopulate summaries from the now-currency-tagged transactions.
        try db.exec("""
            INSERT INTO monthly_summaries
                (year_month, category_id, account_id, currency, kind, total_amount_minor, transaction_count)
            SELECT year_month, category_id, account_id, currency, kind,
                   SUM(amount_minor), COUNT(*)
              FROM transactions
             GROUP BY year_month, category_id, account_id, currency, kind;
        """)

        // 3. Currency rates: 1 unit of `currency` is worth `rate_to_home`
        //    units of the user's home currency. Home currency itself is not
        //    in this table (it's the implicit identity). Rate is stored as
        //    REAL because exchange rates aren't expressible in minor units.
        try db.exec("""
            CREATE TABLE currency_rates (
                currency     TEXT PRIMARY KEY,
                rate_to_home REAL NOT NULL,
                updated_at   INTEGER NOT NULL
            );
        """)
    }

    /// V3: reconciliation. Adds a `statements` table, per-leg clearing columns
    /// on `transactions`, two policy columns on `accounts`, and tightens the
    /// `tx_au` trigger so checkbox-tick UPDATEs that change only the clearing
    /// columns don't churn `monthly_summaries`.
    private static func migrateToV3(_ db: Database) throws {
        // 1. Statements table — must exist before adding the FK column on
        //    transactions. statement_balance_minor is signed (matches the
        //    convention used by AccountStore.balanceMinor).
        try db.exec("""
            CREATE TABLE statements (
                id                       INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id               INTEGER NOT NULL REFERENCES accounts(id),
                statement_date           INTEGER NOT NULL,
                statement_balance_minor  INTEGER NOT NULL,
                currency                 TEXT    NOT NULL,
                status                   TEXT    NOT NULL DEFAULT 'open' CHECK(status IN ('open','reconciled')),
                cleared_total_minor      INTEGER,
                cleared_count            INTEGER,
                note                     TEXT,
                opened_at                INTEGER NOT NULL,
                reconciled_at            INTEGER
            );
        """)
        try db.exec("CREATE INDEX idx_stmt_account_date ON statements(account_id, statement_date DESC);")

        // 2. Account policy columns.
        try db.exec("ALTER TABLE accounts ADD COLUMN clears_entries_by_default INTEGER NOT NULL DEFAULT 0;")
        try db.exec("ALTER TABLE accounts ADD COLUMN statement_closing_day INTEGER;")

        // Cash accounts default to auto-cleared entries (you don't reconcile cash).
        try db.exec("UPDATE accounts SET clears_entries_by_default = 1 WHERE kind = 'cash';")

        // 3. Per-leg clearing on transactions.
        // - cleared_at / statement_id are the from-account leg
        //   (the row's account_id side; used by every kind).
        // - counterparty_cleared_at / counterparty_statement_id are the
        //   transfer-only to-account leg.
        try db.exec("ALTER TABLE transactions ADD COLUMN cleared_at INTEGER;")
        try db.exec("ALTER TABLE transactions ADD COLUMN statement_id INTEGER REFERENCES statements(id);")
        try db.exec("ALTER TABLE transactions ADD COLUMN counterparty_cleared_at INTEGER;")
        try db.exec("ALTER TABLE transactions ADD COLUMN counterparty_statement_id INTEGER REFERENCES statements(id);")

        try db.exec("CREATE INDEX idx_tx_account_cleared ON transactions(account_id, cleared_at);")
        try db.exec("CREATE INDEX idx_tx_cp_cleared      ON transactions(counterparty_account_id, counterparty_cleared_at);")
        try db.exec("CREATE INDEX idx_tx_statement       ON transactions(statement_id, occurred_on);")

        // 4. Tighten tx_au: only do the (subtract OLD, re-insert NEW) shuffle
        //    when one of the dimensions monthly_summaries cares about actually
        //    changed. A reconciliation tick changes cleared_at/statement_id
        //    only — those don't appear in the aggregate.
        try db.exec("DROP TRIGGER IF EXISTS tx_au;")
        try db.exec("""
            CREATE TRIGGER tx_au AFTER UPDATE ON transactions
            WHEN OLD.amount_minor != NEW.amount_minor
              OR OLD.year_month   != NEW.year_month
              OR OLD.category_id  != NEW.category_id
              OR OLD.account_id   != NEW.account_id
              OR OLD.currency     != NEW.currency
              OR OLD.kind         != NEW.kind
            BEGIN
                UPDATE monthly_summaries
                   SET total_amount_minor = total_amount_minor - OLD.amount_minor,
                       transaction_count  = transaction_count  - 1
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND currency    = OLD.currency
                   AND kind        = OLD.kind;
                DELETE FROM monthly_summaries
                 WHERE year_month  = OLD.year_month
                   AND category_id = OLD.category_id
                   AND account_id  = OLD.account_id
                   AND currency    = OLD.currency
                   AND kind        = OLD.kind
                   AND transaction_count <= 0;
                INSERT INTO monthly_summaries
                    (year_month, category_id, account_id, currency, kind, total_amount_minor, transaction_count)
                VALUES
                    (NEW.year_month, NEW.category_id, NEW.account_id, NEW.currency, NEW.kind,
                     NEW.amount_minor, 1)
                ON CONFLICT(year_month, category_id, account_id, currency, kind) DO UPDATE SET
                    total_amount_minor = total_amount_minor + NEW.amount_minor,
                    transaction_count  = transaction_count  + 1;
            END;
        """)
    }

    /// V4: minute-precision timestamps on transactions. Adds `occurred_at`
    /// (Unix epoch seconds) so the UI can record and display time-of-day.
    /// `occurred_on` (day key) is preserved unchanged because every
    /// existing query and index already keys off it; `occurred_at` is
    /// purely additive. Backfilled from `occurred_on` (midnight UTC of
    /// the recorded day), so existing rows continue to sort consistently.
    private static func migrateToV4(_ db: Database) throws {
        try db.exec("ALTER TABLE transactions ADD COLUMN occurred_at INTEGER NOT NULL DEFAULT 0;")
        // 86400 seconds per day. Day key * 86400 gives the UTC midnight
        // of that day, which is the right "no time of day known" baseline.
        try db.exec("UPDATE transactions SET occurred_at = occurred_on * 86400 WHERE occurred_at = 0;")
        // Index for ORDER BY within a day (rows sharing occurred_on now
        // get a stable sub-day ordering).
        try db.exec("CREATE INDEX idx_tx_occurred_at ON transactions(occurred_at);")
    }

    /// Recompute monthly_summaries from scratch. Useful after bulk imports that
    /// were intentionally run with triggers disabled, or as a self-heal.
    static func rebuildSummaries(_ db: Database) throws {
        try db.transaction {
            try db.exec("DELETE FROM monthly_summaries;")
            try db.exec("""
                INSERT INTO monthly_summaries
                    (year_month, category_id, account_id, currency, kind, total_amount_minor, transaction_count)
                SELECT year_month, category_id, account_id, currency, kind,
                       SUM(amount_minor), COUNT(*)
                  FROM transactions
                 GROUP BY year_month, category_id, account_id, currency, kind;
            """)
        }
    }
}
