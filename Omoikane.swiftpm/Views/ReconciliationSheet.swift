import SwiftUI

/// Reconciliation sheet. Either creates a new statement (existingStatementId == nil)
/// or edits an open statement (passed in). On finalise, every ticked
/// transaction has its leg's `cleared_at` and `statement_id` set; the
/// statement flips to 'reconciled' with a snapshot of the cleared total.
///
/// For credit accounts, the displayed "Balance owed" is positive but the
/// stored `statement_balance_minor` is the signed account balance (debt
/// negative), matching `AccountStore.balanceMinor`.
struct ReconciliationSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let account: Account
    let existingStatementId: Int64?

    // Statement form
    @State private var statementId: Int64? = nil
    @State private var statementDate: Date = Date()
    @State private var balanceText: String = ""
    @State private var note: String = ""
    @State private var statusLoaded: StatementStatus? = nil

    // Transactions and selection
    @State private var rows: [Transaction] = []
    @State private var ticked: Set<Int64> = []
    @State private var loadError: String?
    @State private var confirmFinishLeftovers = false
    @State private var leftoversCount: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    statementSection
                    if let err = loadError {
                        Section { Text(err).foregroundStyle(.red) }
                    }
                    transactionsSection
                }
                stickyFooter
            }
            .navigationTitle(existingStatementId == nil ? "New reconciliation" : "Reconciliation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Save & keep open", action: saveOpen)
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!canSave)
                        Button("Finish reconciliation", action: tryFinish)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canFinish)
                        if isReconciled {
                            Button("Reopen statement", role: .destructive, action: reopen)
                        }
                    } label: {
                        Text("Save").bold()
                    }
                }
            }
            .task { initialLoad() }
            .onChange(of: statementDate) { _, _ in reloadRows() }
            .alert("Outstanding entries from before \(formattedStatementDate)",
                   isPresented: $confirmFinishLeftovers) {
                Button("Continue", action: finishConfirmed)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { }
                    .keyboardShortcut(.cancelAction)
            } message: {
                Text("\(leftoversCount) item\(leftoversCount == 1 ? "" : "s") dated on or before \(formattedStatementDate) will remain uncleared. Continue anyway?")
            }
        }
    }

    // MARK: - Sections

    private var statementSection: some View {
        Section("Statement") {
            DatePicker("Statement date", selection: $statementDate, displayedComponents: .date)

            HStack {
                Text(account.kind == .credit ? "Balance owed" : "Statement balance")
                Spacer()
                NumberPadField(
                    text: $balanceText,
                    placeholder: "0",
                    alignment: .right
                )
                .frame(maxWidth: 160)
                Text(account.currency).foregroundStyle(.secondary)
            }
            if account.kind == .credit {
                Text("Enter the positive amount you owe; we record it as a negative balance internally.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            TextField("Note (optional)", text: $note, axis: .vertical)
                .lineLimit(1...3)

            if isReconciled {
                Label("Reconciled — reopen to edit", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var transactionsSection: some View {
        Group {
            if !priorRows.isEmpty {
                Section {
                    ForEach(priorRows) { tx in row(tx) }
                } header: {
                    Text("Outstanding from prior periods")
                } footer: {
                    Text("These were dated on or before the statement date but never cleared. Pre-ticked.")
                        .font(.footnote)
                }
            }
            if !periodRows.isEmpty {
                Section("This period") {
                    ForEach(periodRows) { tx in row(tx) }
                }
            }
            if priorRows.isEmpty && periodRows.isEmpty {
                Section {
                    Text("No uncleared transactions for this account in this period.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ tx: Transaction) -> some View {
        let leg = legFor(tx)
        let signed = signedAmount(for: tx, leg: leg)
        Button {
            toggle(tx.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: ticked.contains(tx.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(ticked.contains(tx.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tx.note?.isEmpty == false ? tx.note! : tx.kind.displayName)
                        .lineLimit(1)
                    Text(Formatters.mediumDate.string(from: tx.occurredOn))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.money(signed, currency: account.currency))
                    .monospacedDigit()
                    .foregroundStyle(signed >= 0 ? Color.primary : .red)
            }
        }
        .buttonStyle(.plain)
    }

    private var stickyFooter: some View {
        let stmtSigned = parsedStatementBalanceMinor ?? 0
        let openingCleared = openingClearedBalance
        let target = stmtSigned - openingCleared
        let cleared = clearedTotalForTickedRows
        let diff = target - cleared

        return VStack(spacing: 8) {
            Divider()
            HStack {
                stat("Statement", Formatters.money(stmtSigned, currency: account.currency))
                Divider().frame(height: 28)
                stat("Cleared", Formatters.money(openingCleared + cleared, currency: account.currency))
                Divider().frame(height: 28)
                stat("Difference",
                     Formatters.money(diff, currency: account.currency),
                     tint: diff == 0 ? .green : .orange)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
        .background(.regularMaterial)
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - State derivation

    private var isReconciled: Bool { statusLoaded == .reconciled }

    private var canSave: Bool {
        parsedStatementBalanceMinor != nil
    }

    private var canFinish: Bool {
        guard let stmtSigned = parsedStatementBalanceMinor else { return false }
        let target = stmtSigned - openingClearedBalance
        return target == clearedTotalForTickedRows
    }

    private var parsedStatementBalanceMinor: Int64? {
        // Credit accounts: user enters a positive "owed" → store as negative.
        // Other kinds: store as-is (positive = positive balance).
        guard let unsigned = parseMinor(balanceText, currency: account.currency) else { return nil }
        return account.kind == .credit ? -unsigned : unsigned
    }

    /// Cleared balance for this account *as of when the user opened this
    /// sheet* — anything that was already cleared before this session
    /// started counts toward the statement balance check, in addition to
    /// the rows the user is ticking right now.
    @State private var openingClearedBalance: Int64 = 0

    private var clearedTotalForTickedRows: Int64 {
        var sum: Int64 = 0
        for tx in rows where ticked.contains(tx.id) {
            sum += signedAmount(for: tx, leg: legFor(tx))
        }
        return sum
    }

    private var priorRows: [Transaction] {
        rows.filter { $0.occurredOn.dayKey <= statementDate.dayKey - 1 }
    }
    private var periodRows: [Transaction] {
        rows.filter { $0.occurredOn.dayKey > statementDate.dayKey - 1 }
    }

    private var formattedStatementDate: String {
        Formatters.mediumDate.string(from: statementDate)
    }

    private func legFor(_ tx: Transaction) -> TransactionLeg {
        tx.accountId == account.id ? .account : .counterparty
    }

    /// Signed contribution of a transaction's relevant leg to the account's balance.
    private func signedAmount(for tx: Transaction, leg: TransactionLeg) -> Int64 {
        switch leg {
        case .account:
            switch tx.kind {
            case .income:   return tx.amountMinor
            case .expense:  return -tx.amountMinor
            case .transfer: return -tx.amountMinor
            }
        case .counterparty:
            // Inbound transfer leg in *this* account's currency.
            return tx.counterpartyAmountMinor ?? tx.amountMinor
        }
    }

    // MARK: - Actions

    private func initialLoad() {
        if let id = existingStatementId, let st = try? app.statements.get(id: id) {
            statementId = id
            statementDate = st.statementDate
            note = st.note ?? ""
            balanceText = formatMinorToInputText(st.statementBalanceMinor)
            statusLoaded = st.status
        } else {
            // Default the date from the account's closing day if set.
            statementDate = nextClosingDate(for: account, after: Date())
            statementId = nil
            statusLoaded = .open
        }
        recomputeOpeningCleared()
        reloadRows()
    }

    /// "Next sensible statement date" given the closing day on the account.
    /// If today ≤ this month's closing day → use this month; else next month.
    private func nextClosingDate(for a: Account, after date: Date) -> Date {
        guard let day = a.statementClosingDay else { return date }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.day = day
        if let candidate = cal.date(from: comps), candidate >= date {
            return candidate
        }
        // Roll to next month.
        if let nextMonth = cal.date(byAdding: .month, value: 1, to: cal.date(from: comps) ?? date) {
            return nextMonth
        }
        return date
    }

    private func recomputeOpeningCleared() {
        // Cleared balance for this account, *excluding* any rows we're about
        // to tick (since those will be added on top). Easiest: snapshot the
        // current cleared balance and treat it as "opening". For an existing
        // statement that's already been reopened, this is fine because its
        // previously-cleared rows still have cleared_at set.
        openingClearedBalance = (try? ClearedBalance.compute(db: app.db, accountId: account.id)) ?? 0
    }

    private func reloadRows() {
        do {
            var f = TransactionFilter()
            f.accountIdAnyLeg = account.id
            f.clearedOnly = false
            f.occurredOnAtMost = statementDate.dayKey
            f.limit = 2_000
            rows = try app.transactions.list(f)

            // For an existing statement, pre-tick rows already cleared *by* this statement.
            if let sid = statementId {
                ticked = Set(rows.filter {
                    $0.statementId == sid || $0.counterpartyStatementId == sid
                }.map(\.id))
            } else {
                // New reconciliation: pre-tick prior-period leftovers.
                ticked = Set(priorRows.map(\.id))
            }
        } catch {
            loadError = "Reload failed: \(error)"
        }
    }

    private func toggle(_ id: Int64) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    private func saveOpen() {
        guard let stmtSigned = parsedStatementBalanceMinor else { return }
        do {
            let id: Int64
            if let existing = statementId {
                let prior = try app.statements.get(id: existing)
                if let prior {
                    var copy = prior
                    copy.statementDate = statementDate
                    copy.statementBalanceMinor = stmtSigned
                    copy.note = note.isEmpty ? nil : note
                    try app.updateStatement(copy)
                }
                id = existing
            } else {
                id = try app.openReconciliation(
                    accountId: account.id,
                    date: statementDate,
                    balanceMinor: stmtSigned,
                    currency: account.currency,
                    note: note.isEmpty ? nil : note
                )
                statementId = id
            }
            // Apply ticks against the open statement (so user can resume later).
            let clearings = ticked.compactMap { txId -> (txId: Int64, leg: TransactionLeg)? in
                guard let tx = rows.first(where: { $0.id == txId }) else { return nil }
                return (txId: txId, leg: legFor(tx))
            }
            try app.db.sync {
                let now = Date()
                for c in clearings {
                    try app.transactions.markCleared(id: c.txId, leg: c.leg, statementId: id, clearedAt: now)
                }
            }
            app.bump()
            dismiss()
        } catch {
            loadError = "Save failed: \(error)"
        }
    }

    private func tryFinish() {
        leftoversCount = priorRows.filter { !ticked.contains($0.id) }.count
        if leftoversCount > 0 {
            confirmFinishLeftovers = true
        } else {
            finishConfirmed()
        }
    }

    private func finishConfirmed() {
        guard let stmtSigned = parsedStatementBalanceMinor else { return }
        do {
            let id: Int64
            if let existing = statementId {
                if let prior = try app.statements.get(id: existing) {
                    var copy = prior
                    copy.statementDate = statementDate
                    copy.statementBalanceMinor = stmtSigned
                    copy.note = note.isEmpty ? nil : note
                    try app.updateStatement(copy)
                }
                id = existing
            } else {
                id = try app.openReconciliation(
                    accountId: account.id,
                    date: statementDate,
                    balanceMinor: stmtSigned,
                    currency: account.currency,
                    note: note.isEmpty ? nil : note
                )
            }
            let clearings = ticked.compactMap { txId -> (txId: Int64, leg: TransactionLeg)? in
                guard let tx = rows.first(where: { $0.id == txId }) else { return nil }
                return (txId: txId, leg: legFor(tx))
            }
            try app.finalizeReconciliation(statementId: id, clearings: clearings)
            dismiss()
        } catch {
            loadError = "Finish failed: \(error)"
        }
    }

    private func reopen() {
        guard let id = statementId else { return }
        do {
            try app.reopenStatement(id: id)
            statusLoaded = .open
        } catch {
            loadError = "Reopen failed: \(error)"
        }
    }

    // MARK: - Number helpers (mirror TransactionEditor)

    private func parseMinor(_ text: String, currency: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let digits = Money.fractionDigits(for: currency)
        if digits == 0 {
            return Int64(cleaned)
        }
        guard let d = Double(cleaned) else { return nil }
        return Int64((d * pow(10.0, Double(digits))).rounded())
    }

    private func formatMinorToInputText(_ minor: Int64) -> String {
        // Display unsigned for credit (user reads "$843"); signed otherwise.
        let display = account.kind == .credit ? -minor : minor
        let digits = Money.fractionDigits(for: account.currency)
        if digits == 0 { return String(display) }
        let scale = pow(10.0, Double(digits))
        return String(format: "%.\(digits)f", Double(display) / scale)
    }
}
