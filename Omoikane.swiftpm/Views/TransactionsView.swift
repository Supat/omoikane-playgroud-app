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

    /// Currently keyboard-selected row. The List shows it highlighted; arrow
    /// keys move it; Return opens the editor for the selected row. In
    /// landscape mode this also drives the split-view detail column.
    @State private var selectedId: Int64?

    /// Drives whether arrow keys land on the row list or on the search field.
    /// We claim list focus on appear so search doesn't auto-grab the keyboard;
    /// users invoke search deliberately via ⌘F.
    @FocusState private var listFocused: Bool
    /// Bound to the search field via `.searchFocused`. Setting it to `true`
    /// programmatically focuses the search field; setting it to `false`
    /// resigns focus back to wherever it was.
    @FocusState private var searchFocused: Bool

    var body: some View {
        // GeometryReader gives us width/height to detect landscape on iPad.
        // Both orientations are `.regular` size class on iPad, so we can't use
        // `horizontalSizeClass` to discriminate. Width > height is the
        // canonical landscape check.
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            Group {
                if isLandscape {
                    landscapeBody
                } else {
                    portraitBody
                }
            }
        }
    }

    /// Single-column layout (portrait). Tapping a row opens the editor sheet,
    /// matching the original behavior.
    @ViewBuilder
    private var portraitBody: some View {
        listSurface(isLandscape: false)
            .sheet(isPresented: $showingNew) {
                TransactionEditor(transaction: nil)
            }
            .sheet(item: $editing) { tx in
                TransactionEditor(transaction: tx)
            }
    }

    /// Two-column layout (landscape). Left: list. Right: an inline
    /// `TransactionEntryView` that mirrors the current selection, or a
    /// quick-entry form when nothing is selected.
    @ViewBuilder
    private var landscapeBody: some View {
        HStack(spacing: 0) {
            listSurface(isLandscape: true)
                .frame(maxWidth: .infinity)
            Divider()
            NavigationStack {
                detailColumn
            }
            .frame(maxWidth: .infinity)
        }
        // The "+" toolbar button still presents a sheet in landscape; that
        // matches the existing keyboard shortcut (⌘N) and gives the user an
        // explicit way to start a new entry without losing the currently
        // selected row in the detail pane.
        .sheet(isPresented: $showingNew) {
            TransactionEditor(transaction: nil)
        }
    }

    /// Detail column for the landscape split view. Re-mounts via `.id` when
    /// the selected row changes so `@State` inside the entry view re-primes
    /// from the new transaction.
    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedId, let tx = rows.first(where: { $0.id == id }) {
            TransactionEntryView(
                transaction: tx,
                onSaveCompletion: nil,
                onEscape: { selectedId = nil; listFocused = true }
            )
            .id(id)
        } else {
            TransactionEntryView(
                transaction: nil,
                onSaveCompletion: nil,
                onEscape: { listFocused = true }
            )
            .id("new-quick-entry")
        }
    }

    /// The list, search, and toolbar — shared between portrait and landscape.
    @ViewBuilder
    private func listSurface(isLandscape: Bool) -> some View {
        // The hidden ⌘F button has to live somewhere in the hierarchy so its
        // .keyboardShortcut is registered, but we don't want it visible. A
        // .background(EmptyView() …) or 0×0 frame keeps layout untouched.
        List(selection: $selectedId) {
            ForEach(rows) { tx in
                rowView(tx)
                    .tag(tx.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isLandscape {
                            selectedId = tx.id
                        } else {
                            editing = tx
                        }
                    }
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
        .focused($listFocused)
        .background(searchShortcut)
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
        .searchable(text: $search,
                    placement: .navigationBarDrawer(displayMode: .always))
        .searchFocused($searchFocused)
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
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("New transaction")
            }
        }
        .task(id: app.dataVersion) { reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: kindFilter) { _, _ in reload() }
        .onAppear {
            // Claim keyboard focus for the list so arrow keys move through
            // rows instead of falling into the search field. .searchable
            // tends to be the first focusable thing otherwise.
            listFocused = true
            // In portrait we leave selectedId nil by default to avoid an
            // accidental highlight; in landscape we'd rather show *something*
            // in the detail column, but the quick-entry form covers that
            // case fine, so we still leave selection nil.
            if selectedId == nil { selectedId = nil }
        }
        .onChange(of: rows) { _, newRows in
            // Keep selectedId pointing at a real row after reloads.
            if let id = selectedId, !newRows.contains(where: { $0.id == id }) {
                selectedId = nil
            }
        }
        .onKeyPress(.return) {
            // If a row is selected via keyboard, Return opens the editor
            // (portrait) or just confirms selection (landscape — the detail
            // is already showing the same row).
            if let id = selectedId, let tx = rows.first(where: { $0.id == id }) {
                if !isLandscape {
                    editing = tx
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            // Esc clears the row selection. In landscape this swaps the
            // detail column back to the quick-entry form.
            if selectedId != nil {
                selectedId = nil
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.tab) {
            // iPadOS's default Tab-to-cycle-controls drifts focus into the
            // search field, which is jarring while keyboard-navigating the
            // row list. Swallow it here. Users move tabs with ⌃Tab and
            // focus search deliberately with ⌘F.
            return .handled
        }
    }

    /// Hidden ⌘F binding. Lives in `.background(...)` so it's mounted but
    /// occupies no layout space. SwiftUI's `.searchable` does not surface
    /// a built-in keyboard shortcut on iPad, so we add one explicitly.
    private var searchShortcut: some View {
        // Real, hit-testable Button — `.allowsHitTesting(false)` removes the
        // view from the responder chain, which is exactly where SwiftUI
        // registers `.keyboardShortcut`, so it must NOT be applied here.
        // Opacity 0 keeps it invisible; 1×1 keeps it out of the way.
        Button {
            listFocused = false
            searchFocused = true
        } label: {
            EmptyView()
        }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 1, height: 1)
        .opacity(0)
        .accessibilityHidden(true)
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
                HStack(spacing: 6) {
                    if tx.isClearedAny {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .accessibilityLabel("Cleared")
                    }
                    Text(cat?.name ?? "—").font(.body)
                }
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
