import SwiftUI

/// Manage categories and accounts.
struct ManageView: View {
    @Environment(AppState.self) private var app

    @State private var categories: [LedgerCategory] = []
    @State private var accounts: [Account] = []
    @State private var balanceByAccount: [Int64: Int64] = [:]
    @State private var addingCategory = false
    @State private var addingAccount = false

    var body: some View {
        List {
            Section {
                ForEach(accounts) { a in
                    HStack {
                        Image(systemName: a.kind.sfSymbol).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(a.name)
                            Text(a.kind.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatters.money(balanceByAccount[a.id] ?? 0, currency: a.currency))
                            .monospacedDigit()
                            .foregroundStyle((balanceByAccount[a.id] ?? 0) >= 0 ? Color.primary : .red)
                    }
                }
                Button {
                    addingAccount = true
                } label: {
                    Label("Add account", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Accounts")
            }

            Section {
                ForEach(categories.filter { $0.kind == .expense }) { c in
                    categoryRow(c)
                }
                ForEach(categories.filter { $0.kind == .income }) { c in
                    categoryRow(c)
                }
                Button {
                    addingCategory = true
                } label: {
                    Label("Add category", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Categories")
            }
        }
        .navigationTitle("Manage")
        .sheet(isPresented: $addingCategory) {
            AddCategorySheet()
        }
        .sheet(isPresented: $addingAccount) {
            AddAccountSheet()
        }
        .task(id: app.dataVersion) { reload() }
    }

    @ViewBuilder
    private func categoryRow(_ c: LedgerCategory) -> some View {
        HStack {
            Image(systemName: c.icon ?? "tag").foregroundStyle(c.kind == .income ? .green : .red)
            Text(c.name)
            Spacer()
            Text(c.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reload() {
        do {
            categories = try app.categories.list(includeArchived: false)
            accounts = try app.accounts.list(includeArchived: false)
            var balances: [Int64: Int64] = [:]
            for a in accounts {
                balances[a.id] = try app.accounts.balanceMinor(accountId: a.id)
            }
            balanceByAccount = balances
        } catch {
            print("Manage reload error: \(error)")
        }
    }
}

private struct AddCategorySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: CategoryKind = .expense
    @State private var icon = "tag"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    Text("Expense").tag(CategoryKind.expense)
                    Text("Income").tag(CategoryKind.income)
                }
                .pickerStyle(.segmented)
                TextField("SF Symbol", text: $icon)
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        _ = try? app.addCategory(name: name, kind: kind, icon: icon)
                        dismiss()
                    }.disabled(name.isEmpty)
                }
            }
        }
    }
}

private struct AddAccountSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var currency = "JPY"
    @State private var initialBalance: String = "0"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(AccountKind.allCases, id: \.self) { k in
                        Label(k.displayName, systemImage: k.sfSymbol).tag(k)
                    }
                }
                TextField("Currency", text: $currency)
                TextField("Initial balance", text: $initialBalance)
                    .keyboardType(.numberPad)
            }
            .navigationTitle("New Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let bal = Int64(initialBalance) ?? 0
                        _ = try? app.addAccount(name: name, kind: kind, currency: currency, initialBalanceMinor: bal)
                        dismiss()
                    }.disabled(name.isEmpty)
                }
            }
        }
    }
}
