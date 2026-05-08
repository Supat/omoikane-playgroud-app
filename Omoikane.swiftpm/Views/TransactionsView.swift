import SwiftUI

struct TransactionsView: View {
    @Environment(AppState.self) private var app

    @State private var rows: [Transaction] = []
    @State private var search: String = ""
    @State private var kindFilter: TransactionKind? = nil
    @State private var editing: Transaction? = nil
    @State private var showingNew = false
    @State private var categoriesById: [Int64: LedgerCategory] = [:]
    @State private var accountsById: [Int64: Account] = [:]

    var body: some View {
        List {
            ForEach(rows) { tx in
                Button {
                    editing = tx
                } label: {
                    rowView(tx)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        try? app.deleteTransaction(id: tx.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if rows.isEmpty {
                EmptyStateView(
                    title: "No transactions",
                    message: "Tap + to add your first entry.",
                    sfSymbol: "list.bullet.rectangle"
                )
            }
        }
        .navigationTitle("Transactions")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("All")    { kindFilter = nil }
                    Button("Income") { kindFilter = .income }
                    Button("Expense") { kindFilter = .expense }
                    Button("Transfer") { kindFilter = .transfer }
                } label: {
                    Label(kindFilter?.displayName ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            TransactionEditor(transaction: nil)
        }
        .sheet(item: $editing) { tx in
            TransactionEditor(transaction: tx)
        }
        .task(id: app.dataVersion) { reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: kindFilter) { _, _ in reload() }
    }

    @ViewBuilder
    private func rowView(_ tx: Transaction) -> some View {
        let cat = categoriesById[tx.categoryId]
        let acc = accountsById[tx.accountId]
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint(for: tx.kind).opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: cat?.icon ?? tx.kind.sfSymbol)
                    .foregroundStyle(tint(for: tx.kind))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cat?.name ?? "—").font(.body)
                HStack(spacing: 6) {
                    if let acc {
                        Text(acc.name)
                    }
                    if let note = tx.note, !note.isEmpty {
                        Text("·")
                        Text(note).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatAmount(tx))
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint(for: tx.kind))
                    .monospacedDigit()
                Text(Formatters.mediumDate.string(from: tx.occurredOn))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tint(for kind: TransactionKind) -> Color {
        switch kind {
        case .income:   return .green
        case .expense:  return .red
        case .transfer: return .blue
        }
    }

    private func formatAmount(_ tx: Transaction) -> String {
        let prefix: String
        switch tx.kind {
        case .income:   prefix = "+"
        case .expense:  prefix = "−"
        case .transfer: prefix = ""
        }
        let acc = accountsById[tx.accountId]
        return prefix + Formatters.money(tx.amountMinor, currency: acc?.currency ?? "JPY")
    }

    private func reload() {
        do {
            var f = TransactionFilter()
            f.searchText = search.isEmpty ? nil : search
            if let kindFilter { f.kinds = [kindFilter] }
            f.limit = 500
            rows = try app.transactions.list(f)
            categoriesById = Dictionary(uniqueKeysWithValues: try app.categories.list(includeArchived: true).map { ($0.id, $0) })
            accountsById = Dictionary(uniqueKeysWithValues: try app.accounts.list(includeArchived: true).map { ($0.id, $0) })
        } catch {
            print("Transactions reload error: \(error)")
        }
    }
}
