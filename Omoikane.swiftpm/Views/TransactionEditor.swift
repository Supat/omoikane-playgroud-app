import SwiftUI

/// Add or edit a single transaction. Designed for quick entry.
struct TransactionEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction?

    @State private var kind: TransactionKind = .expense
    @State private var amountText: String = ""
    @State private var occurredOn: Date = Date()
    @State private var categoryId: Int64? = nil
    @State private var accountId: Int64? = nil
    @State private var counterpartyAccountId: Int64? = nil
    @State private var note: String = ""
    @State private var tagsText: String = ""

    @State private var categories: [LedgerCategory] = []
    @State private var accounts: [Account] = []
    @State private var loadError: String?

    private var isEditing: Bool { transaction != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(TransactionKind.allCases) { k in
                            Label(k.displayName, systemImage: k.sfSymbol).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Amount") {
                    HStack {
                        TextField("0", text: $amountText)
                            .keyboardType(.numberPad)
                            .font(.title.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                        Text(currentCurrency)
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
                            Label(a.name, systemImage: a.kind.sfSymbol).tag(a.id)
                        }
                    }

                    if kind == .transfer {
                        Picker("To Account", selection: Binding(
                            get: { counterpartyAccountId ?? accounts.first(where: { $0.id != accountId })?.id ?? 0 },
                            set: { counterpartyAccountId = $0 }
                        )) {
                            ForEach(accounts.filter { $0.id != accountId }) { a in
                                Label(a.name, systemImage: a.kind.sfSymbol).tag(a.id)
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
                    TextField("Tags (comma separated)", text: $tagsText)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .onAppear { primeFromExisting() }
            .task { loadReferences() }
            .onChange(of: kind) { _, _ in
                // When kind switches, default to a category that matches.
                if kind != .transfer {
                    if let id = categoryId,
                       let c = categories.first(where: { $0.id == id }),
                       (kind == .income ? c.kind == .income : c.kind == .expense) {
                        return
                    }
                    categoryId = availableCategories.first?.id
                }
            }
        }
    }

    private var currentCurrency: String {
        accounts.first { $0.id == accountId }?.currency ?? app.defaultCurrency
    }

    private var availableCategories: [LedgerCategory] {
        let target: CategoryKind = (kind == .income) ? .income : .expense
        return categories.filter { $0.kind == target && !$0.isArchived }
    }

    private var canSave: Bool {
        guard let parsed = parseAmount(amountText), parsed > 0 else { return false }
        if accountId == nil && accounts.first == nil { return false }
        if kind == .transfer {
            return counterpartyAccountId != nil && counterpartyAccountId != accountId
        }
        return categoryId != nil || availableCategories.first != nil
    }

    private func loadReferences() {
        do {
            categories = try app.categories.list()
            accounts = try app.accounts.list()
            if accountId == nil { accountId = accounts.first?.id }
            if categoryId == nil { categoryId = availableCategories.first?.id }
        } catch {
            loadError = "Failed to load: \(error)"
        }
    }

    private func primeFromExisting() {
        guard let tx = transaction else { return }
        kind = tx.kind
        amountText = formatMinorToText(tx.amountMinor)
        occurredOn = tx.occurredOn
        categoryId = tx.categoryId
        accountId = tx.accountId
        counterpartyAccountId = tx.counterpartyAccountId
        note = tx.note ?? ""
        tagsText = tx.tags.joined(separator: ", ")
    }

    private func save() {
        guard let amt = parseAmount(amountText), amt > 0 else { return }
        let acct = accountId ?? accounts.first?.id ?? 0
        let cat: Int64
        if kind == .transfer {
            // Transfers need *some* category — reuse a synthetic one if absent.
            cat = categoryId ?? availableCategories.first?.id ?? categories.first?.id ?? 0
        } else {
            cat = categoryId ?? availableCategories.first?.id ?? 0
        }
        let now = Date()
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            if let existing = transaction {
                var updated = existing
                updated.kind = kind
                updated.amountMinor = amt
                updated.occurredOn = occurredOn
                updated.categoryId = cat
                updated.accountId = acct
                updated.counterpartyAccountId = (kind == .transfer) ? counterpartyAccountId : nil
                updated.note = note.isEmpty ? nil : note
                updated.tags = tags
                updated.updatedAt = now
                try app.updateTransaction(updated)
            } else {
                let tx = Transaction(
                    id: 0, occurredOn: occurredOn, amountMinor: amt,
                    kind: kind, categoryId: cat, accountId: acct,
                    counterpartyAccountId: (kind == .transfer) ? counterpartyAccountId : nil,
                    note: note.isEmpty ? nil : note, tags: tags,
                    createdAt: now, updatedAt: now
                )
                _ = try app.addTransaction(tx)
            }
            dismiss()
        } catch {
            loadError = "Save failed: \(error)"
        }
    }

    private func parseAmount(_ text: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let digits = Money.fractionDigits(for: currentCurrency)
        if digits == 0 {
            return Int64(cleaned)
        }
        guard let d = Double(cleaned) else { return nil }
        return Int64((d * pow(10.0, Double(digits))).rounded())
    }

    private func formatMinorToText(_ minor: Int64) -> String {
        let digits = Money.fractionDigits(for: currentCurrency)
        if digits == 0 { return String(minor) }
        let scale = pow(10.0, Double(digits))
        return String(format: "%.\(digits)f", Double(minor) / scale)
    }
}
