import SwiftUI

/// "Accounts" tab. Lists accounts with their balances; tapping navigates to
/// the per-account detail (balances + reconciliation history). The "+" in the
/// toolbar opens AddAccountSheet.
struct AccountsView: View {
    @Environment(AppState.self) private var app

    @State private var accounts: [Account] = []
    @State private var balanceByAccount: [Int64: Int64] = [:]
    @State private var addingAccount = false
    /// When non-nil, drives the delete-confirmation alert. Same pattern
    /// as `CategoriesView` — fresh reference count so the message can
    /// refuse hard delete and offer Archive when the account is in use.
    @State private var deletePrompt: AccountDeletePrompt? = nil
    @State private var actionError: String? = nil

    var body: some View {
        List {
            if accounts.isEmpty {
                Text("No accounts yet. Tap + to create one.")
                    .foregroundStyle(.secondary)
            } else {
                let groups = accounts.splitForDisplay()
                if !groups.payment.isEmpty {
                    Section("Payment Accounts") {
                        ForEach(groups.payment) { a in
                            row(for: a)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    rowActions(for: a)
                                }
                        }
                    }
                }
                if !groups.credit.isEmpty {
                    Section("Credit Cards") {
                        ForEach(groups.credit) { a in
                            row(for: a)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    rowActions(for: a)
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addingAccount = true } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("New account")
            }
        }
        .sheet(isPresented: $addingAccount) { AddAccountSheet() }
        .task(id: app.dataVersion) { reload() }
        .alert(
            "Delete '\(deletePrompt?.account.name ?? "")'?",
            isPresented: Binding(
                get: { deletePrompt != nil },
                set: { if !$0 { deletePrompt = nil } }
            ),
            presenting: deletePrompt
        ) { prompt in
            if prompt.isBlocked {
                // FK enforcement (transactions, statements) would refuse
                // the delete. Offer Archive instead so the user has a
                // useful next step without a dead-end alert.
                Button("Archive instead") {
                    do { try app.archiveAccount(id: prompt.account.id) }
                    catch { actionError = "\(error)" }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("Delete", role: .destructive) {
                    do { try app.deleteAccount(id: prompt.account.id) }
                    catch { actionError = "\(error)" }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    /// Trailing-swipe actions shared by both account groups. Delete is
    /// destructive and routes through the alert so the user is told
    /// (a) what's still referencing this account and (b) whether the
    /// operation will succeed at all.
    @ViewBuilder
    private func rowActions(for a: Account) -> some View {
        Button(role: .destructive) {
            startDelete(a)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        Button {
            do { try app.archiveAccount(id: a.id) }
            catch { actionError = "\(error)" }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .tint(.orange)
    }

    private func startDelete(_ a: Account) {
        do {
            let refs = try app.accounts.referenceCount(for: a.id)
            deletePrompt = AccountDeletePrompt(account: a, refs: refs)
        } catch {
            actionError = "Couldn't check references: \(error)"
        }
    }

    @ViewBuilder
    private func row(for a: Account) -> some View {
        NavigationLink {
            AccountDetailView(accountId: a.id)
        } label: {
            HStack {
                Image(systemName: a.kind.sfSymbol).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(a.name)
                    Text("\(a.kind.displayName) · \(a.currency)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.money(balanceByAccount[a.id] ?? 0, currency: a.currency))
                    .monospacedDigit()
                    .foregroundStyle((balanceByAccount[a.id] ?? 0) >= 0 ? Color.primary : .red)
            }
        }
    }

    private func reload() {
        do {
            accounts = try app.accounts.list(includeArchived: false)
            var balances: [Int64: Int64] = [:]
            for a in accounts {
                balances[a.id] = try app.accounts.balanceMinor(accountId: a.id)
            }
            balanceByAccount = balances
        } catch {
            print("AccountsView reload error: \(error)")
        }
    }
}

/// Bundled state for the account-delete confirmation alert. Holds the
/// account and a snapshot of how many transactions / statements still
/// reference it so the alert text can adapt to the situation.
private struct AccountDeletePrompt: Identifiable {
    let account: Account
    let refs: (fromLeg: Int, toLeg: Int, statements: Int)
    var id: Int64 { account.id }

    var totalTxRefs: Int { refs.fromLeg + refs.toLeg }
    var isBlocked: Bool { totalTxRefs > 0 || refs.statements > 0 }

    var message: String {
        if isBlocked {
            let tx = "\(totalTxRefs) transaction\(totalTxRefs == 1 ? "" : "s")"
            let st = "\(refs.statements) reconciliation statement\(refs.statements == 1 ? "" : "s")"
            return "Still referenced by \(tx) and \(st). Hard delete would break referential integrity, so archive instead — it hides the account from pickers without touching history."
        } else {
            return "No transactions or statements reference this account, so it's safe to delete. This cannot be undone."
        }
    }
}

/// Sheet for creating a new account. Shared between the "+" button on
/// AccountsView and any other entry point that wants to add an account.
struct AddAccountSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var currency: String = "JPY"
    @State private var initialBalanceText: String = "0"
    @State private var clearsByDefault: Bool = false
    @State private var closingDay: Int = 0      // 0 == None

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(AccountKind.allCases, id: \.self) { k in
                        Label(k.displayName, systemImage: k.sfSymbol).tag(k)
                    }
                }
                CurrencyPicker(title: "Currency", selection: $currency)
                LabeledContent("Initial balance") {
                    NumberPadField(
                        text: $initialBalanceText,
                        placeholder: "0",
                        alignment: .right
                    )
                }

                Section {
                    Toggle("Auto-clear new entries", isOn: $clearsByDefault)
                    Picker("Statement closing day", selection: $closingDay) {
                        Text("None").tag(0)
                        ForEach(1...28, id: \.self) { d in
                            Text("\(d)").tag(d)
                        }
                    }
                } header: {
                    Text("Reconciliation")
                } footer: {
                    Text("Auto-clear is recommended for accounts that don't need reconciliation (e.g. cash). Closing day pre-fills the date when you start a reconciliation.")
                }
            }
            .navigationTitle("New Account")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if currency == "JPY" { currency = app.homeCurrency }
                clearsByDefault = (kind == .cash)
            }
            .onChange(of: kind) { _, newKind in
                clearsByDefault = (newKind == .cash)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let minor = parseMinor(initialBalanceText, currency: currency) ?? 0
                        do {
                            _ = try app.addAccount(
                                name: name, kind: kind,
                                currency: currency, initialBalanceMinor: minor,
                                clearsEntriesByDefault: clearsByDefault,
                                statementClosingDay: closingDay == 0 ? nil : closingDay
                            )
                            dismiss()
                        } catch {
                            // Picker restricts inputs to valid currencies.
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private func parseMinor(_ text: String, currency: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let digits = Money.fractionDigits(for: currency)
        if digits == 0 { return Int64(cleaned) }
        guard let d = Double(cleaned) else { return nil }
        return Int64((d * pow(10.0, Double(digits))).rounded())
    }
}
