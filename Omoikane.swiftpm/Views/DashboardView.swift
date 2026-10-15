import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(AppState.self) private var app

    @State private var totals: SummaryStore.CurrencyTotals = .init()
    @State private var byCategory: [GroupedSummary] = []
    @State private var trend: [GroupedSummary] = []
    @State private var topAccounts: [GroupedSummary] = []
    @State private var ymKey: Int = YearMonth.current()
    /// Trend range in months; the bucket (daily/weekly/monthly) follows it.
    @State private var trendMonths: Int = 6
    @State private var trendDaily: [SummaryStore.DayTotal] = []
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
    @State private var categoryParents: [Int64: Int64] = [:]
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
                limitSection
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
        .glassCard(cornerRadius: 12)
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

    /// The month's spending against the overall monthly limit from
    /// Categories and Budget. Hidden until a limit is set.
    @ViewBuilder
    private var limitSection: some View {
        if let limit = app.monthlySpendingLimitMinor, limit > 0 {
            let spent = homeExpense
            let over = spent > limit
            let share = Double(spent) / Double(limit)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Spending limit (\(app.homeCurrency))").font(.headline)
                    Spacer()
                    Text("\(Formatters.money(spent, currency: app.homeCurrency)) / \(Formatters.money(limit, currency: app.homeCurrency))")
                        .moneyStyle()
                        .font(.subheadline)
                        .foregroundStyle(over ? .red : .secondary)
                }
                ProgressView(value: min(share, 1))
                    .tint(over ? .red : (share > 0.85 ? .orange : .accentColor))
                    .accessibilityLabel("Spending against the monthly limit")
                    .accessibilityValue(over ? "Over the limit" : "\(Int((share * 100).rounded())) percent used")
                Text(over
                     ? "Over the limit by \(Formatters.money(spent - limit, currency: app.homeCurrency))."
                     : "\(Formatters.money(limit - spent, currency: app.homeCurrency)) left this month.")
                    .moneyStyle()
                    .font(.caption)
                    .foregroundStyle(over ? .red : .secondary)
            }
            .padding(12)
            .glassCard(cornerRadius: 12)
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
            .glassCard(cornerRadius: 12)
        }
    }

    /// Monthly budgets from Categories, spent this month in the home
    /// currency. A parent's budget covers its sub-categories.
    @ViewBuilder
    private var budgetSection: some View {
        if !budgets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Budgets and income targets (\(app.homeCurrency))").font(.headline)
                ForEach(budgets) { row in
                    let limit = row.category.budgetMinor ?? 0
                    let isIncome = row.category.kind == .income
                    // Expense: past the budget is bad (red). Income: reaching the target is good (green).
                    let over = row.spentHome > limit
                    let tone: Color = isIncome ? (row.spentHome >= limit ? .green : .accentColor) : (over ? .red : .accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(row.category.name, systemImage: isIncome ? "arrow.down.circle" : "arrow.up.circle")
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            Text("\(Formatters.money(row.spentHome, currency: app.homeCurrency)) / \(Formatters.money(limit, currency: app.homeCurrency))")
                                .moneyStyle()
                                .font(.subheadline)
                                .foregroundStyle(!isIncome && over ? .red : .secondary)
                        }
                        ProgressView(value: Double(min(row.spentHome, limit)), total: Double(max(limit, 1)))
                            .tint(tone)
                            .accessibilityLabel(isIncome ? "\(row.category.name) income target" : "\(row.category.name) budget")
                            .accessibilityValue(isIncome
                                ? (row.spentHome >= limit ? "Target reached" : "\(Int(Double(row.spentHome) / Double(max(limit, 1)) * 100)) percent of target")
                                : (over ? "Over budget" : "\(Int(Double(row.spentHome) / Double(max(limit, 1)) * 100)) percent"))
                    }
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 12)
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
        .glassEffect(.regular.tint(.orange.opacity(0.3)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    value: "\(monthTransactionCount)",
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
                .glassCard()
            }
        }
    }

    private var trendUnit: Calendar.Component { TrendSeries.unit(forMonths: trendMonths) }

    private var trendPoints: [TrendSeries.Point] {
        TrendSeries.points(
            unit: trendUnit, endingAt: ymKey, monthsBack: trendMonths,
            monthly: trend.compactMap { r in app.convertedToHome(r.totalMinor, from: r.currency).map { (r.key, $0) } },
            daily: trendDaily.compactMap { r in app.convertedToHome(r.minor, from: r.currency).map { (r.dayKey, $0) } }
        )
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Expense trend (\(app.homeCurrency)) · \(TrendSeries.unitName(trendUnit))").font(.headline)
                Spacer()
                Picker("Range", selection: $trendMonths) {
                    Text("1M").tag(1)
                    Text("3M").tag(3)
                    Text("6M").tag(6)
                    Text("12M").tag(12)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            if trendPoints.allSatisfy({ $0.minor == 0 }) {
                EmptyStateView(title: "No data", message: "Add a few entries to see trends.", sfSymbol: "chart.bar")
                    .frame(height: 180)
            } else {
                Chart(trendPoints, id: \.date) { p in
                    BarMark(
                        x: .value("Date", p.date, unit: trendUnit),
                        y: .value("Total", Double(p.minor))
                    )
                    .foregroundStyle(.red.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: trendUnit, count: max(1, trendPoints.count / 8))) { _ in
                        AxisGridLine()
                        AxisTick()
                        if trendUnit == .month {
                            AxisValueLabel(format: .dateTime.month(.abbreviated).year())
                        } else {
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                }
                .frame(height: 220)
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .glassCard()
        .onChange(of: trendMonths) { _, _ in reload() }
    }

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by category (\(app.homeCurrency))").font(.headline)
            if categoryRows.isEmpty {
                EmptyStateView(title: "No expenses", message: "Add an expense to see a breakdown.", sfSymbol: "chart.pie")
            } else {
                ForEach(categoryRows.prefix(8)) { row in
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
        .glassCard()
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
        .glassCard()
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

    private struct CategoryRow: Hashable, Identifiable { let id: Int64; let name: String; let minor: Int64 }
    @State private var monthTransactionCount: Int = 0

    private var categoryRows: [CategoryRow] {
        // Keyed by category id: same-named categories under different parents stay apart.
        var bucket: [Int64: Int64] = [:]
        for row in byCategory {
            if let h = app.convertedToHome(row.totalMinor, from: row.currency) {
                bucket[row.keyId, default: 0] += h
            }
        }
        return bucket
            .map { id, minor in
                let name = categoryNames[id] ?? "—"
                let parent = categoryParents[id].flatMap { categoryNames[$0] }
                return CategoryRow(id: id, name: parent.map { "\($0) › \(name)" } ?? name, minor: minor)
            }
            .sorted { $0.minor > $1.minor }
    }

    // MARK: - Logic

    private func reload() {
        do {
            totals = try app.summaries.totals(fromYM: ymKey, toYM: ymKey)
            byCategory = try app.summaries.byCategory(fromYM: ymKey, toYM: ymKey, kind: .expense)
            let win = YearMonth.window(endingAt: ymKey, monthsBack: trendMonths)
            trend = try app.summaries.byMonth(fromYM: win.start, toYM: win.end, kind: .expense)
            trendDaily = trendUnit == .month ? [] : try app.summaries.dailyTotals(fromYM: win.start, toYM: win.end, kind: .expense)
            topAccounts = try app.summaries.netByAccount(fromYM: ymKey, toYM: ymKey)
            essentialByCurrency = try app.summaries.essentialExpense(fromYM: ymKey, toYM: ymKey)
            dailyTotals = try app.summaries.dailyExpense(yearMonth: ymKey).mapValues { sumToHome($0) }
            let allCats = try app.categories.list(includeArchived: true)
            categoryNames = Dictionary(uniqueKeysWithValues: allCats.map { ($0.id, $0.name) })
            categoryParents = Dictionary(uniqueKeysWithValues: allCats.compactMap { c in c.parentId.map { (c.id, $0) } })
            monthTransactionCount = try app.summaries.transactionCount(fromYM: ymKey, toYM: ymKey)
            accountsById = Dictionary(uniqueKeysWithValues: try app.accounts.list(includeArchived: true).map { ($0.id, $0) })
            if let day = selectedDay, Date.from(dayKey: day).yearMonthKey != ymKey { selectedDay = nil }
            loadDayRows()
            let cats = try app.categories.list()
            let incomeByCategory = try app.summaries.byCategory(fromYM: ymKey, toYM: ymKey, kind: .income)
            budgets = cats.filter { $0.budgetMinor != nil }.map { c in
                let ids = Set([c.id] + cats.filter { $0.parentId == c.id }.map(\.id))
                let source = c.kind == .income ? incomeByCategory : byCategory
                let spent = source
                    .filter { ids.contains($0.keyId) }
                    .reduce(Int64(0)) { $0 + (app.convertedToHome($1.totalMinor, from: $1.currency) ?? 0) }
                return BudgetRow(category: c, spentHome: spent)
            }
            .sorted { ($0.category.kind == .expense ? 0 : 1, $0.category.name) < ($1.category.kind == .expense ? 0 : 1, $1.category.name) }
        } catch {
            print("Dashboard reload error: \(error)")
        }
    }

    private func monthLabel(_ key: Int) -> String { YearMonth.label(key) }
}
