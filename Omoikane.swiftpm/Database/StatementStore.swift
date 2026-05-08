import Foundation

enum StatementError: Error, CustomStringConvertible {
    case currencyMismatch(expected: String, got: String)
    case statementClosed
    case unknown(String)

    var description: String {
        switch self {
        case .currencyMismatch(let exp, let got):
            return "Statement currency \(got) doesn't match account currency \(exp)."
        case .statementClosed:
            return "Statement is reconciled and locked. Reopen it first."
        case .unknown(let m): return m
        }
    }
}

/// CRUD plus the atomic finalize/reopen workflow for reconciliation
/// statements. The finalize path is what actually clears transactions —
/// it stamps the per-leg `cleared_at` / `statement_id` columns and writes
/// an audit snapshot (`cleared_total_minor`, `cleared_count`) onto the
/// statement so the reconciled value survives later edits to the
/// underlying transactions.
final class StatementStore {
    private let db: Database
    private let transactions: TransactionStore
    init(db: Database, transactions: TransactionStore) {
        self.db = db
        self.transactions = transactions
    }

    // MARK: - Read

    func list(accountId: Int64) throws -> [LedgerStatement] {
        let s = try db.prepare("""
            SELECT id, account_id, statement_date, statement_balance_minor, currency,
                   status, cleared_total_minor, cleared_count, note, opened_at, reconciled_at
              FROM statements
             WHERE account_id = ?
             ORDER BY statement_date DESC, id DESC;
        """)
        s.bind(accountId, at: 1)
        var out: [LedgerStatement] = []
        while try s.step() { out.append(Self.read(s)) }
        return out
    }

    func get(id: Int64) throws -> LedgerStatement? {
        let s = try db.prepare("""
            SELECT id, account_id, statement_date, statement_balance_minor, currency,
                   status, cleared_total_minor, cleared_count, note, opened_at, reconciled_at
              FROM statements WHERE id = ?;
        """)
        s.bind(id, at: 1)
        if try s.step() { return Self.read(s) }
        return nil
    }

    // MARK: - Write

    /// Open a new statement. Currency is enforced equal to the account's
    /// currency (we don't support reconciling a USD card against a JPY
    /// statement; that's nonsense).
    @discardableResult
    func open(
        accountId: Int64,
        statementDate: Date,
        balanceMinor: Int64,
        currency: String,
        note: String?
    ) throws -> Int64 {
        // Currency-match guard.
        let curStmt = try db.prepare("SELECT currency FROM accounts WHERE id = ?;")
        curStmt.bind(accountId, at: 1)
        var accountCurrency = ""
        if try curStmt.step() { accountCurrency = curStmt.string(0) }
        curStmt.reset()
        if accountCurrency != currency {
            throw StatementError.currencyMismatch(expected: accountCurrency, got: currency)
        }

        let now = Int64(Date().timeIntervalSince1970)
        let s = try db.prepare("""
            INSERT INTO statements
                (account_id, statement_date, statement_balance_minor, currency,
                 status, cleared_total_minor, cleared_count, note, opened_at, reconciled_at)
            VALUES (?, ?, ?, ?, 'open', NULL, NULL, ?, ?, NULL);
        """)
        s.bind(accountId,                    at: 1)
        s.bind(Int64(statementDate.dayKey),  at: 2)
        s.bind(balanceMinor,                 at: 3)
        s.bind(currency,                     at: 4)
        s.bind(note,                         at: 5)
        s.bind(now,                          at: 6)
        try s.step()
        return db.lastInsertId
    }

    /// Patch an open statement's balance/date/note. No-op (and would corrupt
    /// the audit snapshot) on a reconciled one — call `reopen` first.
    func update(_ st: LedgerStatement) throws {
        guard st.status == .open else { throw StatementError.statementClosed }
        let s = try db.prepare("""
            UPDATE statements
               SET statement_date = ?, statement_balance_minor = ?, note = ?
             WHERE id = ?;
        """)
        s.bind(Int64(st.statementDate.dayKey), at: 1)
        s.bind(st.statementBalanceMinor,       at: 2)
        s.bind(st.note,                        at: 3)
        s.bind(st.id,                          at: 4)
        try s.step()
    }

    /// Atomically: clear each (txId, leg), then snapshot the totals onto
    /// the statement and flip status to 'reconciled'. Re-callable: if some
    /// legs are already cleared with this statement_id they're left alone;
    /// if they're cleared with a *different* statement_id they're overwritten
    /// (last-finalize-wins, matching the user's intent in this session).
    func finalize(statementId: Int64, clearings: [(txId: Int64, leg: TransactionLeg)]) throws {
        try db.transaction {
            let now = Date()
            for c in clearings {
                try transactions.markCleared(id: c.txId, leg: c.leg, statementId: statementId, clearedAt: now)
            }
            // Snapshot — sum the signed amount of each cleared leg from this
            // statement's perspective. For the from-leg we use the row's
            // signed amount (income +, expense -, transfer -). For the
            // to-leg of a transfer it's the inbound amount in the account's
            // own currency (counterparty_amount_minor falling back to amount_minor).
            let snapStmt = try db.prepare("""
                SELECT COALESCE(SUM(CASE
                            WHEN statement_id = ? THEN
                                CASE kind
                                    WHEN 'income'   THEN amount_minor
                                    WHEN 'expense'  THEN -amount_minor
                                    WHEN 'transfer' THEN -amount_minor
                                    ELSE 0 END
                            WHEN counterparty_statement_id = ? THEN
                                COALESCE(counterparty_amount_minor, amount_minor)
                            ELSE 0 END), 0),
                       COALESCE(SUM(CASE WHEN statement_id = ? OR counterparty_statement_id = ?
                                          THEN 1 ELSE 0 END), 0)
                  FROM transactions
                 WHERE statement_id = ? OR counterparty_statement_id = ?;
            """)
            snapStmt.bind(statementId, at: 1)
            snapStmt.bind(statementId, at: 2)
            snapStmt.bind(statementId, at: 3)
            snapStmt.bind(statementId, at: 4)
            snapStmt.bind(statementId, at: 5)
            snapStmt.bind(statementId, at: 6)
            var total: Int64 = 0
            var count: Int = 0
            if try snapStmt.step() { total = snapStmt.int64(0); count = snapStmt.int(1) }
            snapStmt.reset()

            let ts = Int64(now.timeIntervalSince1970)
            let fin = try db.prepare("""
                UPDATE statements
                   SET status = 'reconciled',
                       cleared_total_minor = ?,
                       cleared_count = ?,
                       reconciled_at = ?
                 WHERE id = ?;
            """)
            fin.bind(total,       at: 1)
            fin.bind(count,       at: 2)
            fin.bind(ts,          at: 3)
            fin.bind(statementId, at: 4)
            try fin.step()
        }
    }

    /// Flip a reconciled statement back to open. The per-tx clearings stay
    /// pointing at this statement — the user can untick rows in the sheet
    /// to remove them. Snapshot is cleared so a stale total doesn't claim
    /// the statement is "balanced at $X" while actively being edited.
    func reopen(statementId: Int64) throws {
        let s = try db.prepare("""
            UPDATE statements
               SET status = 'open',
                   cleared_total_minor = NULL,
                   cleared_count = NULL,
                   reconciled_at = NULL
             WHERE id = ?;
        """)
        s.bind(statementId, at: 1)
        try s.step()
    }

    /// Delete an *open* statement. Refuses to delete a reconciled one (the
    /// user must reopen first). Detaches any clearings that were pointing
    /// here so transactions don't reference a phantom statement_id.
    func delete(statementId: Int64) throws {
        try db.transaction {
            // Status check.
            let chk = try db.prepare("SELECT status FROM statements WHERE id = ?;")
            chk.bind(statementId, at: 1)
            var status = ""
            if try chk.step() { status = chk.string(0) }
            chk.reset()
            guard status == "open" else { throw StatementError.statementClosed }

            try transactions.unmarkClearings(forStatementId: statementId)
            let del = try db.prepare("DELETE FROM statements WHERE id = ?;")
            del.bind(statementId, at: 1)
            try del.step()
        }
    }

    // MARK: - Internals

    private static func read(_ s: Statement) -> LedgerStatement {
        LedgerStatement(
            id: s.int64(0),
            accountId: s.int64(1),
            statementDate: Date.from(dayKey: s.int(2)),
            statementBalanceMinor: s.int64(3),
            currency: s.string(4),
            status: StatementStatus(rawValue: s.string(5)) ?? .open,
            clearedTotalMinor: s.optionalInt64(6),
            clearedCount: s.optionalInt64(7).map(Int.init),
            note: s.optionalString(8),
            openedAt: Date(timeIntervalSince1970: TimeInterval(s.int64(9))),
            reconciledAt: s.optionalInt64(10).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
