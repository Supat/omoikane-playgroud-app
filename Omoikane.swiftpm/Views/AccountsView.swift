import SwiftUI

/// "Accounts" tab. Lists accounts with their balances; tapping navigates to
/// the per-account detail (balances + reconciliation history). The "+" in the
/// toolbar opens AddAccountSheet.
struct AccountsView: View {
    @Environment(AppState.self) private var app

    @State private var accounts: [Account] = []
    @State private var balanceByAccount: [Int64: Int64] = [:]
    @State private var addingAccount = false

    var body: some View {
        List {
            if accounts.isEmpty {
                Text("No accounts yet. Tap + to create one.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { a in
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
                    TextField("0", text: $initialBalanceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
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
