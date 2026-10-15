import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(AppState.self) private var app

    @State private var totals: SummaryStore.CurrencyTotals = .init()
    @State private var byCategory: [GroupedSummary] = []
    @State private var trend: [GroupedSummary] = []
    @State private var topAccounts: [GroupedSummary] = []
    @State private var ymKey: Int = YearMonth.current()
    @State private var budgets: [BudgetRow] = []
    @State private var essentialByCurrency: [String: Int64] = [:]
    @State private var dailyTotals: [Int: Int64] = [:]
    @State private var selectedDay: Int? = nil
    @State private var dayRows: [Transaction] = []
    @State private var dayBudgets: [DayBudgetRow] = []

    /// A budgeted category the selected day touched: that day's spend and
    /// the month-to-date position through that day.
    struct DayBudgetRow: Identifiable {
        var category: LedgerCategory
        var todayHome: Int64
        var toDateHome: Int64
        var budgetMinor: Int64
        var id: Int64 { category.id }
    }
    @State private var categoryNames: [Int64: String] = [:]
    @State private var accountsById: [Int64: Account] = [:]

    struct BudgetRow: Identifiable {
        var category: LedgerCategory
        var spentHome: Int64
        var id: Int64 { category.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !missing.isEmpty { missingRatesBanner }
                summaryCards
                essentialSection
                calendarSection
                budgetSection
                trendChart
                categoryBreakdown
                accountBreakdown
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        .task(id: app.dataVersion) { reload() }
        .task(id: app.rateVersion) { reload() }
        .onChange(of: ymKey) { _, _ in reload() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Month").font(.subheadline).foregroundStyle(.secondary)
                Text(monthLabel(ymKey)).font(.title.weight(.semibold))
            }
            Spacer()
            Stepper(value: $ymKey, in: 200001 ... 209912, step: 1) {
                EmptyView()
            }
            .labelsHidden()
            .onChange(of: ymKey) { _, newValue in
                let (y, m) = YearMonth.components(newValue)
                if m < 1  { ymKey = YearMonth.key(year: y - 1, month: 12) }
                if m > 12 { ymKey = YearMonth.key(year: y + 1, month: 1) }
            }
        }
    }

    /// Month grid with each day's spending; tapping a day lists its entries.
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calendar (\(app.homeCurrency))").font(.headline)
            MonthCalendar(yearMonth: $ymKey, selectedDay: $selectedDay,
                          dailyTotals: dailyTotals, currency: app.homeCurrency)
                .frame(maxWidth: .infinity)
            if let day = selectedDay {
                Divider()
                HStack {
                    Text(Formatters.mediumDate.string(from: Date.from(dayKey: day)))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if dayRows.isEmpty {
                        Text("No entries").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ForEach(dayRows) { tx in
                    HStack(spacing: 8) {
                        Image(systemName: tx.kind.sfSymbol)
                            .foregroundStyle(tx.kind == .income ? .green : (tx.kind == .expense ? .red : .blue))
                            .font(.caption)
                        Text(categoryNames[tx.categoryId] ?? tx.kind.displayName)
                        Text(accountsById[tx.accountId]?.name ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Formatters.moneyText(tx.amountMinor, currency: tx.currency)
                            .foregroundStyle(tx.kind == .expense ? .red : .primary)
                    }
                    .font(.subheadline)
                }
                if !dayBudgets.isEmpty {
                    Divider()
                    Text("Budgets through this day (\(app.homeCurrency))")
                        .font(.subheadline.weight(.medium))
                    ForEach(dayBudgets) { row in
                        let over = row.toDateHome > row.budgetMinor
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.category.name)
                                Text("\(Formatters.money(row.todayHome, currency: app.homeCurrency)) today")
                                    .moneyStyle()
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Formatters.money(row.toDateHome, currency: app.homeCurrency)) / \(Formatters.money(row.budgetMinor, currency: app.homeCurrency))")
                                    .moneyStyle()
                                    .font(.subheadline)
                                    .foregroundStyle(over ? .red : .primary)
                            }
                            ProgressView(value: Double(min(row.toDateHome, row.budgetMinor)), total: Double(max(row.budgetMinor, 1)))
                                .tint(over ? .red : .accentColor)
                                .accessibilityLabel("\(row.category.name) budget through this day")
                                .accessibilityValue(over ? "Over budget" : "\(Int(Double(row.toDateHome) / Double(max(row.budgetMinor, 1)) * 100)) percent used")
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: selectedDay) { _, _ in loadDayRows() }
    }

    private func loadDayRows() {
        guard let day = selectedDay else { dayRows = []; dayBudgets = []; return }
        let all = (try? app.transactions.list(.month(Date.from(dayKey: day).yearMonthKey))) ?? []
        dayRows = all.filter { $0.occurredOn.dayKey == day }

        // Budget position through the selected day, for categories spent on that day.
        let cats = (try? app.categories.list()) ?? []
        let expenses = all.filter { $0.kind == .expense && $0.occurredOn.dayKey <= day }
        dayBudgets = cats.compactMap { c -> DayBudgetRow? in
            guard let budget = c.budgetMinor else { return nil }
            let ids = Set([c.id] + cats.filter { $0.parentId == c.id }.map(\.id))
            let mine = expenses.filter { ids.contains($0.categoryId) }
            let today = mine.filter { $0.occurredOn.dayKey == day }
                .reduce(Int64(0)) { $0 + (app.convertedToHome($1.amountMinor, from: $1.currency) ?? 0) }
            guard today > 0 else { return nil }
            let toDate = mine.reduce(Int64(0)) { $0 + (app.convertedToHome($1.amountMinor, from: $1.currency) ?? 0) }
            return DayBudgetRow(category: c, todayHome: today, toDateHome: toDate, budgetMinor: budget)
        }
    }

    /// Essential vs discretionary share of the month's spending, in the
    /// home currency. Hidden until at least one expense is flagged.
    @ViewBuilder
    private var essentialSection: some View {
        let essential = sumToHome(essentialByCurrency)
        if essential > 0 {
            let discretionary = max(homeExpense - essential, 0)
            let share = homeExpense > 0 ? Double(essential) / Double(homeExpense) : 0
            VStack(alignment: .leading, spacing: 10) {
                Text("Essential vs discretionary (\(app.homeCurrency))").font(.headline)
                HStack {
                    Label("Essential", systemImage: "lifepreserver").foregroundStyle(.orange)
                    Spacer()
                    Formatters.moneyText(essential, currency: app.homeCurrency)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Label("Discretionary", systemImage: "cart").foregroundStyle(.secondary)
                    Spacer()
                    Formatters.moneyText(discretionary, currency: app.homeCurrency)
                    Text("\(Int(((1 - share) * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                ProgressView(value: share)
                    .tint(.orange)
                    .accessibilityLabel("Essential share of spending")
                    .accessibilityValue("\(Int((share * 100).rounded())) percent")
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Monthly budgets from Categories, spent this month in the home
    /// currency. A parent's budget covers its sub-categories.
    @ViewBuilder
    private var budgetSection: some View {
        if !budgets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Budgets (\(app.homeCurrency))").font(.headline)
                ForEach(budgets) { row in
                    let limit = row.category.budgetMinor ?? 0
                    let over = row.spentHome > limit
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.category.name)
                            Spacer()
                            Text("\(Formatters.money(row.spentHome, currency: app.homeCurrency)) / \(Formatters.money(limit, currency: app.homeCurrency))")
                                .moneyStyle()
                                .font(.subheadline)
                                .foregroundStyle(over ? .red : .secondary)
                        }
                        ProgressView(value: Double(min(row.spentHome, limit)), total: Double(max(limit, 1)))
                            .tint(over ? .red : .accentColor)
                            .accessibilityLabel("\(row.category.name) budget")
                            .accessibilityValue(over ? "Over budget" : "\(Int(Double(row.spentHome) / Double(max(limit, 1)) * 100)) percent")
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var missingRatesBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rate missing for \(missing.joined(separator: ", "))")
                    .font(.subheadline.weight(.medium))
                Text("Open Settings → Exchange rates to include them in the home-currency rollup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var summaryCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(app.homeCurrency) rollup").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                StatCard(
                    title: "Income",
                    value: Formatters.money(homeIncome, currency: app.homeCurrency),
                    tint: .green,
                    sfSymbol: "arrow.down.circle.fill"
                )
                StatCard(
                    title: "Expense",
                    value: Formatters.money(homeExpense, currency: app.homeCurrency),
                    tint: .red,
                    sfSymbol: "arrow.up.circle.fill"
                )
                StatCard(
                    title: "Net",
                    value: Formatters.money(homeIncome - homeExpense, currency: app.homeCurrency),
                    tint: (homeIncome - homeExpense) >= 0 ? .green : .red,
                    sfSymbol: "equal.circle.fill"
                )
                StatCard(
                    title: "Transactions",
                    value: "\(byCategory.reduce(0) { $0 + $1.count })",
                    tint: .blue,
                    sfSymbol: "list.number"
                )
            }

            if perCurrencyRows.count > 1 {
                Text("By currency").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(perCurrencyRows, id: \.currency) { row in
                        HStack {
                            Text(row.currency).font(.body.weight(.medium))
                            Spacer()
                            Formatters.moneyText(row.income, currency: row.currency)
                                .foregroundStyle(.green)
                                .monospacedDigit()
                            Text("·").foregroundStyle(.secondary)
                            Formatters.moneyText(row.expense, currency: row.currency)
                                .foregroundStyle(.red)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 6 months — expense (\(app.homeCurrency))").font(.headline)
            if monthlyHomeExpense.isEmpty {
                EmptyStateView(title: "No data", message: "Add a few entries to see trends.", sfSymbol: "chart.bar")
                    .frame(height: 180)
            } else {
                Chart(monthlyHomeExpense, id: \.label) { row in
                    BarMark(
                        x: .value("Month", YearMonth.date(fromLabel: row.label), unit: .month),
                        y: .value("Total", Double(row.minor))
                    )
                    .foregroundStyle(.red.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year())
                    }
                }
                .frame(height: 220)
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by category (\(app.homeCurrency))").font(.headline)
            if categoryRows.isEmpty {
                EmptyStateView(title: "No expenses", message: "Add an expense to see a breakdown.", sfSymbol: "chart.pie")
            } else {
                ForEach(categoryRows.prefix(8), id: \.name) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Formatters.moneyText(row.minor, currency: app.homeCurrency)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var accountBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By account").font(.headline)
            if topAccounts.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                ForEach(topAccounts) { row in
                    HStack {
                        Text(row.key)
                        Text(row.currency).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Formatters.moneyText(row.totalMinor, currency: row.currency)
                            .foregroundStyle(row.totalMinor >= 0 ? Color.primary : .red)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Derived data

    private var missing: [String] {
        let active = Set(
            totals.byKind.values.flatMap(\.keys)
            + byCategory.map(\.currency)
            + topAccounts.map(\.currency)
        )
        return app.missingRates(among: Array(active))
    }

    private var homeIncome: Int64 {
        sumToHome(totals.total(for: .income))
    }
    private var homeExpense: Int64 {
        sumToHome(totals.total(for: .expense))
    }

    private func sumToHome(_ map: [String: Int64]) -> Int64 {
        var sum: Int64 = 0
        for (cur, minor) in map {
            if let h = app.convertedToHome(minor, from: cur) {
                sum += h
            }
        }
        return sum
    }

    private struct PerCurrencyRow: Hashable {
        let currency: String
        let income: Int64
        let expense: Int64
    }

    private var perCurrencyRows: [PerCurrencyRow] {
        totals.currencies.map { c in
            PerCurrencyRow(
                currency: c,
                income: totals.total(for: .income, currency: c),
                expense: totals.total(for: .expense, currency: c)
            )
        }
    }

    private struct LabeledMinor: Hashable { let label: String; let minor: Int64 }

    private var monthlyHomeExpense: [LabeledMinor] {
        var bucket: [String: Int64] = [:]
        for row in trend {
            if let h = app.convertedToHome(row.totalMinor, from: row.currency) {
                bucket[row.key, default: 0] += h
            }
        }
        return bucket
            .sorted { $0.key < $1.key }
            .map { LabeledMinor(label: $0.key, minor: $0.value) }
    }

    private struct CategoryRow: Hashable { let name: String; let minor: Int64 }

    private var categoryRows: [CategoryRow] {
        var bucket: [String: Int64] = [:]
        for row in byCategory {
            if let h = app.convertedToHome(row.totalMinor, from: row.currency) {
                bucket[row.key, default: 0] += h
            }
        }
        return bucket
            .map { CategoryRow(name: $0.key, minor: $0.value) }
            .sorted { $0.minor > $1.minor }
    }

    // MARK: - Logic

    private func reload() {
        do {
            totals = try app.summaries.totals(fromYM: ymKey, toYM: ymKey)
            byCategory = try app.summaries.byCategory(fromYM: ymKey, toYM: ymKey, kind: .expense)
            let win = YearMonth.window(endingAt: ymKey, monthsBack: 6)
            trend = try app.summaries.byMonth(fromYM: win.start, toYM: win.end, kind: .expense)
            topAccounts = try app.summaries.netByAccount(fromYM: ymKey, toYM: ymKey)
            essentialByCurrency = try app.summaries.essentialExpense(fromYM: ymKey, toYM: ymKey)
            dailyTotals = try app.summaries.dailyExpense(yearMonth: ymKey).mapValues { sumToHome($0) }
            categoryNames = Dictionary(uniqueKeysWithValues: try app.categories.list(includeArchived: true).map { ($0.id, $0.name) })
            accountsById = Dictionary(uniqueKeysWithValues: try app.accounts.list(includeArchived: true).map { ($0.id, $0) })
            if let day = selectedDay, Date.from(dayKey: day).yearMonthKey != ymKey { selectedDay = nil }
            loadDayRows()
            let cats = try app.categories.list()
            budgets = cats.filter { $0.budgetMinor != nil }.map { c in
                let ids = Set([c.id] + cats.filter { $0.parentId == c.id }.map(\.id))
                let spent = byCategory
                    .filter { ids.contains($0.keyId) }
                    .reduce(Int64(0)) { $0 + (app.convertedToHome($1.totalMinor, from: $1.currency) ?? 0) }
                return BudgetRow(category: c, spentHome: spent)
            }
        } catch {
            print("Dashboard reload error: \(error)")
        }
    }

    private func monthLabel(_ key: Int) -> String {
        let (y, m) = YearMonth.components(key)
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = 1
        if let d = Calendar.current.date(from: comps) {
            return Formatters.monthLabel.string(from: d)
        }
        return String(format: "%04d-%02d", y, m)
    }
}
