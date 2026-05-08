import SwiftUI

/// "Transactions" tab. Top level lists accounts; tapping one drills into
/// `AccountTransactionsView`, which holds the actual transaction list,
/// search, kind filter, keyboard navigation, and landscape split-view
/// quick-entry pane.
struct TransactionsView: View {
    @Environment(AppState.self) private var app

    @State private var accounts: [Account] = []
    @State private var balanceByAccount: [Int64: Int64] = [:]

    var body: some View {
        List {
            if accounts.isEmpty {
                Section {
                    Text("No accounts yet. Add one from the Accounts tab.")
                        .foregroundStyle(.secondary)
                }
            } else {
                let groups = accounts.splitForDisplay()
                if !groups.payment.isEmpty {
                    Section("Payment Accounts") {
                        ForEach(groups.payment) { a in row(for: a) }
                    }
                }
                if !groups.credit.isEmpty {
                    Section {
                        ForEach(groups.credit) { a in row(for: a) }
                    } header: {
                        Text("Credit Cards")
                    } footer: {
                        Text("Tap an account to view its transactions.")
                    }
                }
            }
        }
        .navigationTitle("Transactions")
        .task(id: app.dataVersion) { reload() }
    }

    @ViewBuilder
    private func row(for a: Account) -> some View {
        NavigationLink {
            AccountTransactionsView(account: a)
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
            print("TransactionsView reload error: \(error)")
        }
    }
}

/// Period selector for the per-account transaction list. Each case maps to
/// an inclusive (`fromYearMonth`, `toYearMonth`) range applied via
/// `TransactionFilter`. Stored as an enum (not raw dates) so the menu UI
/// stays terse and the range is computed against "now" at reload time —
/// which keeps "This month" honest if the device clock crosses midnight
/// while the view is open.
enum PeriodFilter: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, last3Months, thisYear

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .thisMonth:   return "This month"
        case .lastMonth:   return "Last month"
        case .last3Months: return "Last 3 months"
        case .thisYear:    return "This year"
        }
    }

    /// Inclusive `(from, to)` year-month bounds in YYYYMM form.
    func yearMonthRange(now: Date = Date()) -> (Int, Int) {
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let curYM = y * 100 + m
        switch self {
        case .thisMonth:
            return (curYM, curYM)
        case .lastMonth:
            let prev = subtractMonths(year: y, month: m, by: 1)
            return (prev, prev)
        case .last3Months:
            // Current month plus the two preceding ones.
            return (subtractMonths(year: y, month: m, by: 2), curYM)
        case .thisYear:
            return (y * 100 + 1, y * 100 + 12)
        }
    }

    private func subtractMonths(year: Int, month: Int, by n: Int) -> Int {
        var y = year
        var m = month - n
        while m <= 0 {
            m += 12
            y -= 1
        }
        return y * 100 + m
    }
}

/// Transaction list scoped to a single account. Shows entries whose primary
/// account matches *or* whose counterparty leg points at this account (so
/// transfers appear in both ends' views).
///
/// Layout adapts to orientation — landscape splits into a list + inline
/// `TransactionEntryView`; portrait keeps the modal sheet flow.
struct AccountTransactionsView: View {
    @Environment(AppState.self) private var app

    let account: Account

    @State private var rows: [Transaction] = []
    @State private var search: String = ""
    @State private var kindFilter: TransactionKind? = nil
    @State private var periodFilter: PeriodFilter = .thisMonth
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
                TransactionEditor(transaction: nil, initialAccountId: account.id)
            }
            .sheet(item: $editing) { tx in
                TransactionEditor(transaction: tx)
            }
    }

    /// Two-column layout (landscape). Left: list. Right: an inline
    /// `TransactionEntryView` that mirrors the current selection, or the
    /// **Quick Entry View** (a special case of `TransactionEntryView` —
    /// see that type's doc comment for the operating-modes table) when
    /// nothing is selected.
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
    }

    /// Detail column for the landscape split view. Re-mounts via `.id` when
    /// the selected row changes so `@State` inside the entry view re-primes
    /// from the new transaction. The no-selection branch is the **Quick
    /// Entry View**.
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
                initialAccountId: account.id,
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
            // Period header doubles as a status line — the user can see
            // which window is active without opening the toolbar menu.
            Section(periodFilter.displayName) {
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
        }
        .listStyle(.insetGrouped)
        .focused($listFocused)
        .background(searchShortcut)
        .overlay {
            if rows.isEmpty {
                EmptyStateView(
                    title: "No transactions",
                    message: "Tap + to add an entry to \(account.name).",
                    sfSymbol: "list.bullet.rectangle"
                )
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
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
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(PeriodFilter.allCases) { p in
                        Button(p.displayName) { periodFilter = p }
                    }
                } label: {
                    Label(periodFilter.displayName, systemImage: "calendar")
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
                // The landscape split view's detail column already exposes
                // a quick-entry form whenever nothing is selected, so the
                // modal "+" entry point would be redundant — disable it.
                .disabled(isLandscape)
            }
        }
        .task(id: app.dataVersion) { reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: kindFilter) { _, _ in reload() }
        .onChange(of: periodFilter) { _, _ in reload() }
        .onAppear {
            // Claim keyboard focus for the list so arrow keys move through
            // rows instead of falling into the search field. .searchable
            // tends to be the first focusable thing otherwise.
            listFocused = true
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
            // any-leg so transfers show up on both endpoints' lists.
            f.accountIdAnyLeg = account.id
            let (fromYM, toYM) = periodFilter.yearMonthRange()
            f.fromYearMonth = fromYM
            f.toYearMonth = toYM
            f.limit = 500
            rows = try app.transactions.list(f)
            categoriesById = Dictionary(uniqueKeysWithValues: try app.categories.list(includeArchived: true).map { ($0.id, $0) })
            accountsById = Dictionary(uniqueKeysWithValues: try app.accounts.list(includeArchived: true).map { ($0.id, $0) })
        } catch {
            print("AccountTransactionsView reload error: \(error)")
        }
    }
}
