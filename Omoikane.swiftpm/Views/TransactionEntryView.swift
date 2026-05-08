import SwiftUI

/// Form body for adding or editing a single transaction. Decoupled from any
/// particular presentation container: it is embedded inside a `NavigationStack`
/// when used as a modal sheet (`TransactionEditor`) and inside the detail
/// column when used in the landscape split view (`TransactionsView`).
///
/// Behavior is parameter-driven:
/// - `onSaveCompletion`: called after a successful save. When set (modal
///   usage), the caller typically dismisses the sheet. When nil and editing
///   an existing row, the form quietly stays put. When nil and creating a
///   new row (no `transaction`), the form acts as a *quick entry*: amount,
///   note, and tags clear, account/category/kind/date remain sticky, and
///   focus jumps back to the amount field for the next entry.
/// - `onEscape`: optional Esc-key handler. Wired to `.onKeyPress(.escape)`
///   on the form. The split-view caller uses this to drop the row selection
///   when the user is mid-edit.
struct TransactionEntryView: View {
    @Environment(AppState.self) private var app

    let transaction: Transaction?
    var onSaveCompletion: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    @State private var kind: TransactionKind = .expense
    @State private var amountText: String = ""
    @State private var counterpartyAmountText: String = ""
    @State private var occurredOn: Date = Date()
    @State private var categoryId: Int64? = nil
    @State private var accountId: Int64? = nil
    @State private var counterpartyAccountId: Int64? = nil
    @State private var note: String = ""
    @State private var tagsText: String = ""
    @State private var clearedNow: Bool = false
    @State private var counterpartyClearedNow: Bool = false

    @State private var categories: [LedgerCategory] = []
    @State private var accounts: [Account] = []
    @State private var loadError: String?

    /// Focusable text fields. Drives Tab / Return / next-button traversal:
    /// amount → (counterpartyAmount if cross-currency transfer) → note → tags.
    @FocusState private var focusedField: FormField?
    enum FormField: Hashable { case amount, counterpartyAmount, note, tags }

    private var isEditing: Bool { transaction != nil }

    var body: some View {
        Form {
            if let tx = transaction, tx.isClearedAny {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This entry is on a reconciled statement.")
                                .font(.subheadline.weight(.medium))
                            Text("Editing or deleting will leave the statement's snapshot total unchanged but the underlying total will drift. Reopen the statement first if you want a clean re-reconciliation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.orange.opacity(0.1))
            }

            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(TransactionKind.allCases) { k in
                        Label(k.displayName, systemImage: k.sfSymbol).tag(k)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(kind == .transfer ? "From amount" : "Amount") {
                HStack {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .amount)
                        .submitLabel(.next)
                        .onSubmit { advanceFocus(from: .amount) }
                    Text(fromCurrency)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                DatePicker("Date", selection: $occurredOn, displayedComponents: .date)

                Picker("Account", selection: Binding(
                    get: { accountId ?? accounts.first?.id ?? 0 },
                    set: { accountId = $0 }
                )) {
                    ForEach(accounts) { a in
                        Label("\(a.name) (\(a.currency))", systemImage: a.kind.sfSymbol).tag(a.id)
                    }
                }

                if kind == .transfer {
                    Picker("To account", selection: Binding(
                        get: { counterpartyAccountId ?? accounts.first(where: { $0.id != accountId })?.id ?? 0 },
                        set: { counterpartyAccountId = $0 }
                    )) {
                        ForEach(accounts.filter { $0.id != accountId }) { a in
                            Label("\(a.name) (\(a.currency))", systemImage: a.kind.sfSymbol).tag(a.id)
                        }
                    }

                    if isCrossCurrencyTransfer {
                        HStack {
                            Text("To amount")
                            Spacer()
                            TextField("0", text: $counterpartyAmountText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .counterpartyAmount)
                                .submitLabel(.next)
                                .onSubmit { advanceFocus(from: .counterpartyAmount) }
                                .font(.body.monospacedDigit())
                                .multilineTextAlignment(.trailing)
                            Text(toCurrency)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Picker("Category", selection: Binding(
                        get: { categoryId ?? availableCategories.first?.id ?? 0 },
                        set: { categoryId = $0 }
                    )) {
                        ForEach(availableCategories) { c in
                            if let icon = c.icon {
                                Label(c.name, systemImage: icon).tag(c.id)
                            } else {
                                Text(c.name).tag(c.id)
                            }
                        }
                    }
                }
            }

            Section("Note") {
                TextField("Optional note", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focusedField, equals: .note)
                    .submitLabel(.next)
                    .onSubmit { advanceFocus(from: .note) }
                TextField("Tags (comma separated)", text: $tagsText)
                    .focused($focusedField, equals: .tags)
                    .submitLabel(.done)
                    .onSubmit {
                        focusedField = nil
                        if canSave { save() }
                    }
            }

            Section {
                Toggle(kind == .transfer ? "From-side cleared" : "Cleared",
                       isOn: $clearedNow)
                if kind == .transfer {
                    Toggle("To-side cleared", isOn: $counterpartyClearedNow)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Cleared entries are marked with a check in the list and count toward an account's cleared balance. Toggling off here detaches this entry from any reconciled statement it was on.")
                    .font(.footnote)
            }

            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isEditing ? "Edit" : "New Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .onAppear {
            primeFromExisting()
            // For new entries, drop focus straight into the amount field
            // so the user can start typing immediately.
            if transaction == nil { focusedField = .amount }
        }
        .task { loadReferences() }
        .onChange(of: kind) { _, _ in
            if kind != .transfer {
                if let id = categoryId,
                   let c = categories.first(where: { $0.id == id }),
                   (kind == .income ? c.kind == .income : c.kind == .expense) {
                    return
                }
                categoryId = availableCategories.first?.id
            }
        }
        .onKeyPress(.escape) {
            if let onEscape {
                focusedField = nil
                onEscape()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Currency helpers

    private var fromAccount: Account? {
        accounts.first { $0.id == accountId }
    }
    private var toAccount: Account? {
        accounts.first { $0.id == counterpartyAccountId }
    }
    private var fromCurrency: String {
        fromAccount?.currency ?? app.homeCurrency
    }
    private var toCurrency: String {
        toAccount?.currency ?? fromCurrency
    }
    private var isCrossCurrencyTransfer: Bool {
        kind == .transfer && fromCurrency != toCurrency
    }

    private var availableCategories: [LedgerCategory] {
        let target: CategoryKind = (kind == .income) ? .income : .expense
        return categories.filter { $0.kind == target && !$0.isArchived }
    }

    private var canSave: Bool {
        guard let parsed = parseMinor(amountText, currency: fromCurrency), parsed > 0 else { return false }
        if accountId == nil && accounts.first == nil { return false }
        if kind == .transfer {
            guard counterpartyAccountId != nil, counterpartyAccountId != accountId else { return false }
            if isCrossCurrencyTransfer {
                guard let cp = parseMinor(counterpartyAmountText, currency: toCurrency), cp > 0 else { return false }
            }
            return true
        }
        return categoryId != nil || availableCategories.first != nil
    }

    private func loadReferences() {
        do {
            categories = try app.categories.list()
            accounts = try app.accounts.list()
            if accountId == nil { accountId = accounts.first?.id }
            if categoryId == nil { categoryId = availableCategories.first?.id }
            // For a brand-new entry, prime the Cleared toggle to the
            // from-account's `clearsEntriesByDefault` flag. Visible in the
            // editor; user can flip it off if needed.
            if transaction == nil, let acct = fromAccount {
                clearedNow = acct.clearsEntriesByDefault
            }
        } catch {
            loadError = "Failed to load: \(error)"
        }
    }

    private func primeFromExisting() {
        guard let tx = transaction else { return }
        kind = tx.kind
        amountText = formatMinorToText(tx.amountMinor, currency: tx.currency)
        if let cp = tx.counterpartyAmountMinor {
            // We need toCurrency to format; defer formatting until accounts load.
            counterpartyAmountText = String(cp)
        }
        occurredOn = tx.occurredOn
        categoryId = tx.categoryId
        accountId = tx.accountId
        counterpartyAccountId = tx.counterpartyAccountId
        note = tx.note ?? ""
        tagsText = tx.tags.joined(separator: ", ")
        clearedNow = (tx.clearedAt != nil)
        counterpartyClearedNow = (tx.counterpartyClearedAt != nil)
    }

    private func save() {
        guard let amt = parseMinor(amountText, currency: fromCurrency), amt > 0 else { return }
        let acct = accountId ?? accounts.first?.id ?? 0
        let cat: Int64
        if kind == .transfer {
            cat = categoryId ?? availableCategories.first?.id ?? categories.first?.id ?? 0
        } else {
            cat = categoryId ?? availableCategories.first?.id ?? 0
        }
        let now = Date()
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let cpAmount: Int64? = isCrossCurrencyTransfer
            ? parseMinor(counterpartyAmountText, currency: toCurrency)
            : nil

        do {
            if let existing = transaction {
                var updated = existing
                updated.kind = kind
                updated.amountMinor = amt
                updated.currency = fromCurrency
                updated.occurredOn = occurredOn
                updated.categoryId = cat
                updated.accountId = acct
                updated.counterpartyAccountId = (kind == .transfer) ? counterpartyAccountId : nil
                updated.counterpartyAmountMinor = cpAmount
                updated.note = note.isEmpty ? nil : note
                updated.tags = tags
                updated.updatedAt = now
                applyClearingToggles(to: &updated, now: now)
                try app.updateTransaction(updated)
            } else {
                var tx = Transaction(
                    id: 0,
                    occurredOn: occurredOn,
                    amountMinor: amt,
                    currency: fromCurrency,
                    kind: kind,
                    categoryId: cat,
                    accountId: acct,
                    counterpartyAccountId: (kind == .transfer) ? counterpartyAccountId : nil,
                    counterpartyAmountMinor: cpAmount,
                    note: note.isEmpty ? nil : note,
                    tags: tags,
                    createdAt: now,
                    updatedAt: now
                )
                applyClearingToggles(to: &tx, now: now)
                try app.addTransaction(tx)
            }
            if let onSaveCompletion {
                onSaveCompletion()
            } else if transaction == nil {
                // Quick-entry mode: clear the variable fields, keep the
                // sticky ones (account/category/kind/date) so the user can
                // crank through a stack of receipts without re-picking.
                amountText = ""
                counterpartyAmountText = ""
                note = ""
                tagsText = ""
                clearedNow = fromAccount?.clearsEntriesByDefault ?? false
                counterpartyClearedNow = false
                focusedField = .amount
            }
        } catch {
            loadError = "Save failed: \(error)"
        }
    }

    /// Push the toggle state into the Transaction's clearing columns. Toggling
    /// off detaches from any reconciled statement (sets statement_id to nil).
    /// Toggling on leaves an existing statement_id alone if already set —
    /// otherwise stamps `clearedAt = now` as an ad-hoc clearing.
    private func applyClearingToggles(to tx: inout Transaction, now: Date) {
        if clearedNow {
            if tx.clearedAt == nil { tx.clearedAt = now }
        } else {
            tx.clearedAt = nil
            tx.statementId = nil
        }

        if kind == .transfer {
            if counterpartyClearedNow {
                if tx.counterpartyClearedAt == nil { tx.counterpartyClearedAt = now }
            } else {
                tx.counterpartyClearedAt = nil
                tx.counterpartyStatementId = nil
            }
        } else {
            tx.counterpartyClearedAt = nil
            tx.counterpartyStatementId = nil
        }
    }

    /// Move keyboard focus to the next logical field. Skips
    /// `.counterpartyAmount` for non-cross-currency rows.
    private func advanceFocus(from field: FormField) {
        switch field {
        case .amount:
            focusedField = isCrossCurrencyTransfer ? .counterpartyAmount : .note
        case .counterpartyAmount:
            focusedField = .note
        case .note:
            focusedField = .tags
        case .tags:
            focusedField = nil
        }
    }

    private func parseMinor(_ text: String, currency: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let digits = Money.fractionDigits(for: currency)
        if digits == 0 { return Int64(cleaned) }
        guard let d = Double(cleaned) else { return nil }
        return Int64((d * pow(10.0, Double(digits))).rounded())
    }

    private func formatMinorToText(_ minor: Int64, currency: String) -> String {
        let digits = Money.fractionDigits(for: currency)
        if digits == 0 { return String(minor) }
        let scale = pow(10.0, Double(digits))
        return String(format: "%.\(digits)f", Double(minor) / scale)
    }
}
