import SwiftUI

/// Form body for adding or editing a single transaction. Decoupled from any
/// particular presentation container: it is embedded inside a `NavigationStack`
/// when used as a modal sheet (`TransactionEditor`) and inside the detail
/// column when used in the landscape split view (`TransactionsView`).
///
/// Three operating modes, all rendered by the same body:
/// 1. **Edit**            — `transaction != nil`. Title: "Edit".
/// 2. **New Entry**       — `transaction == nil`, `onSaveCompletion != nil`.
///                          Modal flow; Save dismisses. Title: "New Entry".
/// 3. **Quick Entry View** — `transaction == nil`, `onSaveCompletion == nil`.
///                          The split-view detail column when nothing is
///                          selected. Confirmation button reads "Add". On
///                          tap the row is inserted, then the form is
///                          fully reset and focus is dropped — the user
///                          chooses deliberately whether to start another
///                          entry. Title: "Quick Entry".
///
/// Behavior is parameter-driven:
/// - `onSaveCompletion`: called after a successful save. When set (modal
///   usage), the caller typically dismisses the sheet. When nil and editing
///   an existing row, the form quietly stays put. When nil and creating a
///   new row, the form acts as the **Quick Entry View** described above.
/// - `onEscape`: optional Esc-key handler. Wired to `.onKeyPress(.escape)`
///   on the form. The split-view caller uses this to drop the row selection
///   when the user is mid-edit.
struct TransactionEntryView: View {
    @Environment(AppState.self) private var app

    let transaction: Transaction?
    /// When creating a new transaction (`transaction == nil`), pre-select
    /// this account in the picker. Ignored when editing.
    var initialAccountId: Int64? = nil
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
    @State private var payeeId: Int64? = nil
    @State private var addingPayee = false
    @State private var newPayeeName = ""
    @State private var loanRole: LoanRole? = nil
    @State private var isEssential: Bool = false
    /// New entries only: also create a schedule that repeats this entry.
    @State private var repeatFrequency: ScheduleFrequency? = nil
    /// Two or more lines = a split; the main Category picker and Amount
    /// field give way to the per-line ones. Empty = ordinary single row.
    @State private var splitLines: [SplitLine] = []

    @State private var categories: [LedgerCategory] = []
    @State private var accounts: [Account] = []
    @State private var payees: [Payee] = []
    @State private var loadError: String?

    struct SplitLine: Identifiable, Hashable {
        let id = UUID()
        var categoryId: Int64?
        var amountText: String
    }
    private var isSplit: Bool { splitLines.count >= 2 }

    /// Focusable text fields. Drives Tab / Return / next-button traversal:
    /// amount → (counterpartyAmount if cross-currency transfer) → note → tags.
    @FocusState private var focusedField: FormField?
    enum FormField: Hashable { case amount, counterpartyAmount, note, tags }

    private var isEditing: Bool { transaction != nil }

    /// "Edit" / "New Entry" / "Quick Entry" — see the operating-modes
    /// table in the type's doc comment.
    private var navigationTitle: String {
        if isEditing { return "Edit" }
        return onSaveCompletion == nil ? "Quick Entry" : "New Entry"
    }

    /// Confirmation-button label. Quick Entry uses "Add" to signal the
    /// non-modal insert-and-clear semantics.
    private var confirmActionLabel: String {
        if isEditing { return "Save" }
        return onSaveCompletion == nil ? "Add" : "Save"
    }

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
                    if isSplit {
                        Spacer()
                        Text(formatMinorToText(splitTotalMinor, currency: fromCurrency))
                            .moneyStyle()
                            .font(.system(size: 28))
                            .accessibilityLabel("Total of split lines")
                    } else {
                        NumberPadField(
                            text: $amountText,
                            placeholder: "0",
                            font: .monospacedDigitSystemFont(ofSize: 28, weight: .regular),
                            alignment: .right,
                            onSubmit: { advanceFocus(from: .amount) }
                        )
                    }
                    Text(fromCurrency)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                DatePicker("Date", selection: $occurredOn, displayedComponents: [.date, .hourAndMinute])

                Picker("Account", selection: Binding(
                    get: { accountId ?? accounts.first?.id ?? 0 },
                    set: { accountId = $0 }
                )) {
                    accountPickerOptions(from: accounts)
                }

                if kind == .transfer {
                    Picker("To account", selection: Binding(
                        get: { counterpartyAccountId ?? accounts.first(where: { $0.id != accountId })?.id ?? 0 },
                        set: { counterpartyAccountId = $0 }
                    )) {
                        accountPickerOptions(from: accounts.filter { $0.id != accountId })
                    }

                    if isCrossCurrencyTransfer {
                        HStack {
                            Text("To amount")
                            Spacer()
                            NumberPadField(
                                text: $counterpartyAmountText,
                                placeholder: "0",
                                font: .monospacedDigitSystemFont(ofSize: 17, weight: .regular),
                                alignment: .right,
                                onSubmit: { advanceFocus(from: .counterpartyAmount) }
                            )
                            Text(toCurrency)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    if !isSplit {
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
                    Picker("Payee", selection: $payeeId) {
                        Text("None").tag(Int64?.none)
                        ForEach(payees) { p in Text(p.name).tag(Int64?.some(p.id)) }
                    }
                    Button("New payee…") { addingPayee = true }
                    Picker("Loan", selection: $loanRole) {
                        Text("None").tag(LoanRole?.none)
                        ForEach(allowedLoanRoles, id: \.self) { r in
                            Text(r.displayName).tag(LoanRole?.some(r))
                        }
                    }
                }
            }

            if kind != .transfer {
                Section {
                    if isSplit {
                        ForEach($splitLines) { $line in
                            HStack {
                                Picker("Category", selection: Binding(
                                    get: { line.categoryId ?? availableCategories.first?.id ?? 0 },
                                    set: { line.categoryId = $0 }
                                )) {
                                    ForEach(availableCategories) { c in Text(c.name).tag(c.id) }
                                }
                                .labelsHidden()
                                Spacer()
                                NumberPadField(
                                    text: $line.amountText,
                                    placeholder: "0",
                                    font: .monospacedDigitSystemFont(ofSize: 17, weight: .regular),
                                    alignment: .right
                                )
                                .frame(maxWidth: 140)
                                Button {
                                    splitLines.removeAll { $0.id == line.id }
                                    collapseSplitIfSingle()
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove line")
                            }
                        }
                        Button {
                            splitLines.append(SplitLine(categoryId: availableCategories.first?.id, amountText: ""))
                        } label: {
                            Label("Add line", systemImage: "plus.circle")
                        }
                    } else {
                        Button {
                            splitLines = [
                                SplitLine(categoryId: categoryId ?? availableCategories.first?.id, amountText: amountText),
                                SplitLine(categoryId: availableCategories.first?.id, amountText: "")
                            ]
                        } label: {
                            Label("Split into categories", systemImage: "square.split.2x1")
                        }
                    }
                } header: {
                    Text("Split")
                } footer: {
                    if isSplit {
                        Text("The amount is the sum of the lines. Remove lines down to one to un-split.")
                            .font(.footnote)
                    }
                }
            }

            if transaction == nil {
                Section {
                    Picker("Repeat", selection: $repeatFrequency) {
                        Text("Never").tag(ScheduleFrequency?.none)
                        ForEach(ScheduleFrequency.allCases, id: \.self) { f in
                            Text(f.displayName).tag(ScheduleFrequency?.some(f))
                        }
                    }
                } footer: {
                    if repeatFrequency != nil {
                        Text("Also creates a schedule that posts this entry again every period, starting with the next one. Manage schedules in Settings.")
                            .font(.footnote)
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
                if kind == .expense {
                    Toggle(isOn: $isEssential) {
                        Label("Essential", systemImage: "lifepreserver")
                    }
                }
                Toggle(kind == .transfer ? "From-side cleared" : "Cleared",
                       isOn: $clearedNow)
                if kind == .transfer {
                    Toggle("To-side cleared", isOn: $counterpartyClearedNow)
                }
            } header: {
                Text("Status")
            } footer: {
                Text((kind == .expense ? "Essential marks spending you could not avoid in order to get by. " : "")
                     + "Cleared entries are marked with a check in the list and count toward an account's cleared balance. Toggling off here detaches this entry from any reconciled statement it was on.")
                    .font(.footnote)
            }

            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // Quick Entry View labels the action "Add" because pressing
                // it inserts a new row and immediately resets the form for
                // the next entry — no modal dismiss involved. Edit / New
                // Entry keep "Save" since they're confirming a single change.
                Button(confirmActionLabel) { save() }
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
        .alert("New payee", isPresented: $addingPayee) {
            TextField("Name", text: $newPayeeName)
            Button("Add") {
                if let id = try? app.findOrCreatePayee(name: newPayeeName) {
                    payeeId = id
                    payees = (try? app.payees.list()) ?? []
                }
                newPayeeName = ""
            }
            Button("Cancel", role: .cancel) { newPayeeName = "" }
        }
        .onChange(of: kind) { _, _ in
            if let r = loanRole, !allowedLoanRoles.contains(r) { loanRole = nil }
            if kind == .transfer { splitLines = [] }
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

    /// Picker content split into "Payment Accounts" / "Credit Cards"
    /// sections, mirroring the grouping used elsewhere in the app.
    @ViewBuilder
    private func accountPickerOptions(from list: [Account]) -> some View {
        let groups = list.splitForDisplay()
        if !groups.payment.isEmpty {
            Section("Payment Accounts") {
                ForEach(groups.payment) { a in
                    Label("\(a.name) (\(a.currency))", systemImage: a.kind.sfSymbol).tag(a.id)
                }
            }
        }
        if !groups.credit.isEmpty {
            Section("Credit Cards") {
                ForEach(groups.credit) { a in
                    Label("\(a.name) (\(a.currency))", systemImage: a.kind.sfSymbol).tag(a.id)
                }
            }
        }
    }

    /// Lend is money going out, borrow is money coming in; repayment goes
    /// either way, so the kind decides which roles make sense.
    private var allowedLoanRoles: [LoanRole] {
        switch kind {
        case .expense:  return [.lend, .repay]
        case .income:   return [.borrow, .repay]
        case .transfer: return []
        }
    }

    private var splitTotalMinor: Int64 {
        splitLines.compactMap { parseMinor($0.amountText, currency: fromCurrency) }.reduce(0, +)
    }

    /// One line left is no longer a split: fold it back into the main fields.
    private func collapseSplitIfSingle() {
        guard splitLines.count == 1, let only = splitLines.first else { return }
        categoryId = only.categoryId
        amountText = only.amountText
        splitLines = []
    }

    private var availableCategories: [LedgerCategory] {
        let target: CategoryKind = (kind == .income) ? .income : .expense
        return categories.filter { $0.kind == target && !$0.isArchived }
    }

    private var canSave: Bool {
        if isSplit {
            guard splitLines.allSatisfy({ ($0.categoryId ?? availableCategories.first?.id) != nil
                                          && (parseMinor($0.amountText, currency: fromCurrency) ?? 0) > 0 })
            else { return false }
        } else {
            guard let parsed = parseMinor(amountText, currency: fromCurrency), parsed > 0 else { return false }
        }
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
            payees = try app.payees.list()
            if accountId == nil {
                if let pre = initialAccountId,
                   accounts.contains(where: { $0.id == pre }) {
                    accountId = pre
                } else {
                    accountId = accounts.first?.id
                }
            }
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
        payeeId = tx.payeeId
        loanRole = tx.loanRole
        isEssential = tx.isEssential
        if let g = tx.splitGroup, let rows = try? app.transactions.listGroup(g), rows.count > 1 {
            splitLines = rows.map { SplitLine(categoryId: $0.categoryId, amountText: formatMinorToText($0.amountMinor, currency: $0.currency)) }
        }
    }

    private func save() {
        let amt: Int64
        if isSplit {
            amt = splitTotalMinor
            guard amt > 0 else { return }
        } else {
            guard let parsed = parseMinor(amountText, currency: fromCurrency), parsed > 0 else { return }
            amt = parsed
        }
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
            if isSplit || transaction?.splitGroup != nil {
                // Split path: one row per line, replacing whatever rows
                // this logical transaction had before.
                var template = transaction ?? Transaction(
                    id: 0, occurredOn: occurredOn, amountMinor: amt, currency: fromCurrency,
                    kind: kind, categoryId: cat, accountId: acct,
                    counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                    note: nil, tags: [], createdAt: now, updatedAt: now
                )
                template.id = 0
                template.kind = kind
                template.currency = fromCurrency
                template.occurredOn = occurredOn
                template.accountId = acct
                template.counterpartyAccountId = nil
                template.counterpartyAmountMinor = nil
                template.note = note.isEmpty ? nil : note
                template.tags = tags
                template.updatedAt = now
                template.payeeId = payeeId
                template.loanRole = loanRole
                template.isEssential = kind == .expense && isEssential
                applyClearingToggles(to: &template, now: now)
                let lines: [Transaction] = isSplit
                    ? splitLines.map { line in
                        var t = template
                        t.categoryId = line.categoryId ?? availableCategories.first?.id ?? cat
                        t.amountMinor = parseMinor(line.amountText, currency: fromCurrency) ?? 0
                        return t
                    }
                    : [{ var t = template; t.categoryId = cat; t.amountMinor = amt; return t }()]
                try app.saveLines(lines,
                                  replacingGroup: transaction?.splitGroup,
                                  replacingSingle: transaction?.splitGroup == nil ? transaction?.id : nil)
            } else if let existing = transaction {
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
                updated.payeeId = payeeId
                updated.loanRole = loanRole
                updated.isEssential = kind == .expense && isEssential
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
                tx.payeeId = payeeId
                tx.loanRole = loanRole
                tx.isEssential = kind == .expense && isEssential
                applyClearingToggles(to: &tx, now: now)
                try app.addTransaction(tx)
            }
            if transaction == nil, let freq = repeatFrequency {
                let sc = Schedule(
                    id: 0, kind: kind, amountMinor: amt, categoryId: cat, accountId: acct,
                    counterpartyAccountId: kind == .transfer ? counterpartyAccountId : nil,
                    counterpartyAmountMinor: cpAmount, payeeId: payeeId,
                    note: note.isEmpty ? nil : note, frequency: freq, interval: 1,
                    nextDue: ScheduleStore.advance(occurredOn, frequency: freq, interval: 1),
                    endOn: nil,
                    isEssential: kind == .expense && isEssential
                )
                try app.addSchedule(sc)
            }
            if let onSaveCompletion {
                onSaveCompletion()
            } else if transaction == nil {
                // Quick Entry View: the new row is in the list — empty the
                // form fully and stand down focus. The user can see what
                // landed and decide deliberately whether to start another
                // entry.
                kind = .expense
                amountText = ""
                counterpartyAmountText = ""
                occurredOn = Date()
                accountId = initialAccountId
                counterpartyAccountId = nil
                categoryId = nil
                note = ""
                tagsText = ""
                counterpartyClearedNow = false
                clearedNow = fromAccount?.clearsEntriesByDefault ?? false
                payeeId = nil
                loanRole = nil
                isEssential = false
                repeatFrequency = nil
                splitLines = []
                focusedField = nil
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
