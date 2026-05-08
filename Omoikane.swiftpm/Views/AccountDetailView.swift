import SwiftUI

/// Account-detail screen, reachable by tapping an account row in ManageView.
/// Shows balances, lets the user start a reconciliation, and lists past
/// statements.
struct AccountDetailView: View {
    @Environment(AppState.self) private var app

    let accountId: Int64

    @State private var account: Account?
    @State private var totalBalance: Int64 = 0
    @State private var clearedBalance: Int64 = 0
    @State private var statementsList: [LedgerStatement] = []
    @State private var startingReconciliation = false
    @State private var editingClosingDay = false

    var body: some View {
        Form {
            if let account {
                accountHeader(account)
                balanceSection(account)
                policySection(account)
                statementsSection(account)
            } else {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(account?.name ?? "Account")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.dataVersion) { reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startingReconciliation = true
                } label: {
                    Label("Reconcile", systemImage: "checkmark.seal")
                }
                .disabled(account == nil)
            }
        }
        .sheet(isPresented: $startingReconciliation) {
            if let account {
                ReconciliationSheet(account: account, existingStatementId: nil)
            }
        }
    }

    @ViewBuilder
    private func accountHeader(_ a: Account) -> some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: a.kind.sfSymbol).foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.headline)
                    Text("\(a.kind.displayName) · \(a.currency)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func balanceSection(_ a: Account) -> some View {
        Section("Balance") {
            LabeledContent("Total") {
                Text(Formatters.money(totalBalance, currency: a.currency))
                    .monospacedDigit()
                    .foregroundStyle(totalBalance >= 0 ? Color.primary : .red)
            }
            LabeledContent("Cleared") {
                Text(Formatters.money(clearedBalance, currency: a.currency))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Uncleared") {
                Text(Formatters.money(totalBalance - clearedBalance, currency: a.currency))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func policySection(_ a: Account) -> some View {
        Section("Reconciliation policy") {
            Toggle(isOn: Binding(
                get: { a.clearsEntriesByDefault },
                set: { newValue in
                    var copy = a
                    copy.clearsEntriesByDefault = newValue
                    try? app.updateAccount(copy)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-clear new entries")
                    Text("New entries on this account are marked cleared on insert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Statement closing day", selection: Binding(
                get: { a.statementClosingDay ?? 0 },
                set: { newValue in
                    var copy = a
                    copy.statementClosingDay = (newValue == 0) ? nil : newValue
                    try? app.updateAccount(copy)
                }
            )) {
                Text("None").tag(0)
                ForEach(1...28, id: \.self) { d in
                    Text("\(d)").tag(d)
                }
            }
        }
    }

    @ViewBuilder
    private func statementsSection(_ a: Account) -> some View {
        Section("Statements") {
            if statementsList.isEmpty {
                Text("No statements yet. Tap Reconcile to start one.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(statementsList) { st in
                    StatementRow(statement: st, account: a)
                }
            }
        }
    }

    private func reload() {
        do {
            account = try app.accounts.get(id: accountId)
            totalBalance = try app.accounts.balanceMinor(accountId: accountId)
            clearedBalance = try ClearedBalance.compute(db: app.db, accountId: accountId)
            statementsList = try app.statements.list(accountId: accountId)
        } catch {
            print("AccountDetailView reload error: \(error)")
        }
    }
}

private struct StatementRow: View {
    @Environment(AppState.self) private var app
    let statement: LedgerStatement
    let account: Account
    @State private var reopenSheet = false

    var body: some View {
        NavigationLink {
            ReconciliationSheet(account: account, existingStatementId: statement.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.mediumDate.string(from: statement.statementDate))
                    Text("\(statement.status.rawValue.capitalized)\(reconciledCountLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.money(statement.statementBalanceMinor, currency: statement.currency))
                    .monospacedDigit()
                Image(systemName: statement.status == .reconciled ? "checkmark.seal.fill" : "clock")
                    .foregroundStyle(statement.status == .reconciled ? .green : .orange)
            }
        }
    }

    private var reconciledCountLabel: String {
        if let count = statement.clearedCount, count > 0 {
            return " · \(count) entries"
        }
        return ""
    }
}

/// Cleared balance for an account. Mirrors `AccountStore.balanceMinor`'s
/// math, but counts only legs whose clearing column is non-nil.
enum ClearedBalance {
    static func compute(db: Database, accountId: Int64) throws -> Int64 {
        let s = try db.prepare("""
            SELECT
                COALESCE(initial_balance_minor, 0)
                + COALESCE((SELECT SUM(CASE kind
                                          WHEN 'income'   THEN amount_minor
                                          WHEN 'expense'  THEN -amount_minor
                                          WHEN 'transfer' THEN -amount_minor
                                          ELSE 0 END)
                             FROM transactions
                            WHERE account_id = ? AND cleared_at IS NOT NULL), 0)
                + COALESCE((SELECT SUM(COALESCE(counterparty_amount_minor, amount_minor))
                             FROM transactions
                            WHERE kind = 'transfer'
                              AND counterparty_account_id = ?
                              AND counterparty_cleared_at IS NOT NULL), 0)
              FROM accounts WHERE id = ?;
        """)
        s.bind(accountId, at: 1).bind(accountId, at: 2).bind(accountId, at: 3)
        if try s.step() { return s.int64(0) }
        return 0
    }
}
