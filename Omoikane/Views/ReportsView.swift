import SwiftUI
import Charts

struct ReportsView: View {
    @Environment(AppState.self) private var app

    @State private var monthsBack: Int = 6
    /// Last month of the reporting window. Defaults to the current month;
    /// pinning it elsewhere makes every section treat that month as "now".
    @State private var anchorYM: Int = YearMonth.current()
    private var isPinned: Bool { anchorYM != YearMonth.current() }
    /// Expense and Income read one kind; Net is income minus expense, so
    /// expense rows are negated and merged with income rows.
    enum ReportMode: Hashable { case expense, income, net }
    @State private var mode: ReportMode = .expense
    /// nil = "All currencies → home rollup". Non-nil = isolate one currency.
    @State private var currencyFilter: String? = nil
    @State private var byMonth: [GroupedSummary] = []
    @State private var byDay: [SummaryStore.DayTotal] = []
    @State private var byCategory: [GroupedSummary] = []
    @State private var byAccount: [GroupedSummary] = []
    @State private var totals: SummaryStore.CurrencyTotals = .init()
    @State private var availableCurrencies: [String] = []
    @State private var budgetRows: [BudgetLine] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                summaryRow

                section("Trend (\(displayCurrency)) · \(trendUnitName)") {
                    if trendPoints.allSatisfy({ $0.minor == 0 }) {
                        EmptyStateView(title: "No data", message: "Try a longer range.", sfSymbol: "chart.bar")
                            .frame(height: 200)
                    } else {
                        Chart(trendPoints, id: \.date) { p in
                            LineMark(
                                x: .value("Date", p.date, unit: trendUnit),
                                y: .value("Total", Double(p.minor))
                            )
                            .interpolationMethod(.monotone)
                            PointMark(
                                x: .value("Date", p.date, unit: trendUnit),
                                y: .value("Total", Double(p.minor))
                            )
                        }
                        // Marks follow the bucket unit, thinned to ~8 labels.
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
                        .frame(height: 240)
                    }
                }

                section("By category") {
                    if categoryRows.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        Chart(categoryRows.prefix(10)) { row in
                            BarMark(
                                x: .value("Total", Double(row.minor)),
                                y: .value("Category", row.name)
                            )
                        }
                        .frame(height: CGFloat(min(categoryRows.count, 10) * 36 + 60))
                    }
                }

                if let monthly = app.monthlySpendingLimitMinor, monthly > 0 {
                    let limit = monthly * Int64(monthsBack)
                    let spent = homeExpenseTotal
                    section("Spending limit (\(app.homeCurrency), \(monthsBack) month\(monthsBack == 1 ? "" : "s"))") {
                        LimitBar(label: "Spent", used: spent, capacity: limit, currency: app.homeCurrency,
                                 caption: spent > limit
                                    ? "Over the limit by \(Formatters.money(spent - limit, currency: app.homeCurrency)) across the range."
                                    : "\(Formatters.money(limit - spent, currency: app.homeCurrency)) under the limit across the range (\(Formatters.money(monthly, currency: app.homeCurrency)) per month).",
                                 accessibilityLabel: "Spending against the limit for the range")
                    }
                }

                section("Budgets and income targets (\(app.homeCurrency), \(monthsBack) month\(monthsBack == 1 ? "" : "s"))") {
                    if budgetRows.isEmpty {
                        Text("No budgets set. Give a category a monthly budget or income target in Settings › Categories and Budget.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        let (totalBudget, totalSpent) = BudgetMath.totals(budgetRows, kind: .expense)
                        let (totalTarget, totalIncome) = BudgetMath.totals(budgetRows, kind: .income)
                        ForEach(BudgetMath.grouped(budgetRows)) { group in
                            BudgetRowView(line: group.parent, currency: app.homeCurrency, showsCaption: true,
                                          color: group.parent.category.ownColor)
                                .padding(.vertical, 4)
                            ForEach(group.children) { line in
                                BudgetRowView(line: line, currency: app.homeCurrency, showsCaption: true,
                                              color: group.parent.category.ownColor)
                                    .padding(.vertical, 4)
                                    .padding(.leading, 20)
                            }
                        }
                        Divider()
                        if totalBudget > 0 {
                            HStack {
                                Text("All budgets").font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Formatters.money(totalSpent, currency: app.homeCurrency)) / \(Formatters.money(totalBudget, currency: app.homeCurrency))")
                                    .moneyStyle()
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(totalSpent > totalBudget ? .red : .primary)
                            }
                        }
                        if totalTarget > 0 {
                            HStack {
                                Text("All income targets").font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Formatters.money(totalIncome, currency: app.homeCurrency)) / \(Formatters.money(totalTarget, currency: app.homeCurrency))")
                                    .moneyStyle()
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(totalIncome >= totalTarget ? .green : .primary)
                            }
                        }
                    }
                }

                section("By account") {
                    if byAccount.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        ForEach(byAccount) { row in
                            HStack {
                                Text(row.key)
                                Text(row.currency).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Formatters.moneyText(row.totalMinor, currency: row.currency)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Reports")
        .task(id: app.dataVersion) { reload() }
        .task(id: app.rateVersion) { reload() }
        .onChange(of: monthsBack)     { _, _ in reload() }
        .onChange(of: anchorYM)       { _, _ in reload() }
        .onChange(of: mode)           { _, _ in reload() }
        .onChange(of: currencyFilter) { _, _ in reload() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: $mode) {
                Text("Expense").tag(ReportMode.expense)
                Text("Income").tag(ReportMode.income)
                Text("Net").tag(ReportMode.net)
            }
            .pickerStyle(.segmented)

            Picker("Range", selection: $monthsBack) {
                Text("1M").tag(1)
                Text("3M").tag(3)
                Text("6M").tag(6)
                Text("12M").tag(12)
                Text("24M").tag(24)
            }
            .pickerStyle(.segmented)

            Picker("Currency", selection: $currencyFilter) {
                Text("All → \(app.homeCurrency)").tag(String?.none)
                ForEach(availableCurrencies, id: \.self) { c in
                    Text(c).tag(String?.some(c))
                }
            }
            .pickerStyle(.menu)

            // Pinned month: the window ends here instead of at today.
            HStack(spacing: 12) {
                Label(isPinned ? "Pinned to \(YearMonth.label(anchorYM))" : "Ending \(YearMonth.label(anchorYM))",
                      systemImage: isPinned ? "pin.fill" : "calendar")
                    .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                Spacer()
                if isPinned {
                    Button("Current month") { anchorYM = YearMonth.current() }
                        .keyboardShortcut("0", modifiers: .command)
                }
                Stepper(value: $anchorYM, in: 200001 ... 209912, step: 1) {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityLabel("Pinned month")
                .accessibilityValue(YearMonth.label(anchorYM))
                .onChange(of: anchorYM) { _, v in anchorYM = YearMonth.normalized(v) }
            }
            .font(.subheadline)
        }
    }

    private var summaryRow: some View {
        let income = displayCurrencyTotal(.income)
        let expense = displayCurrencyTotal(.expense)
        let cur = displayCurrency
        return HStack(spacing: 12) {
            StatCard(title: "Income",
                     value: Formatters.money(income, currency: cur), tint: .green)
            StatCard(title: "Expense",
                     value: Formatters.money(expense, currency: cur), tint: .red)
            StatCard(title: "Net",
                     value: Formatters.money(income - expense, currency: cur),
                     tint: (income - expense) >= 0 ? .green : .red)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Derived

    private var displayCurrency: String { currencyFilter ?? app.homeCurrency }

    /// Range expense in the home currency, ignoring the currency filter,
    /// since the spending limit is a home-currency figure.
    private var homeExpenseTotal: Int64 {
        app.sumToHome(totals.total(for: .expense).map { ($0.value, $0.key) })
    }

    private func displayCurrencyTotal(_ k: TransactionKind) -> Int64 {
        if let c = currencyFilter {
            return totals.total(for: k, currency: c)
        } else {
            var sum: Int64 = 0
            for (cur, minor) in totals.total(for: k) {
                if let h = app.convertedToHome(minor, from: cur) { sum += h }
            }
            return sum
        }
    }

    private var trendUnit: Calendar.Component { TrendSeries.unit(forMonths: monthsBack) }
    private var trendUnitName: String { TrendSeries.unitName(trendUnit) }

    /// Amount in the display currency, or nil when it can't be shown.
    private func displayAmount(_ minor: Int64, currency: String) -> Int64? {
        if let f = currencyFilter { return currency == f ? minor : nil }
        return app.convertedToHome(minor, from: currency)
    }

    private var trendPoints: [TrendSeries.Point] {
        TrendSeries.points(
            unit: trendUnit, endingAt: anchorYM, monthsBack: monthsBack,
            monthly: byMonth.compactMap { r in displayAmount(r.totalMinor, currency: r.currency).map { (r.key, $0) } },
            daily: byDay.compactMap { r in displayAmount(r.minor, currency: r.currency).map { (r.dayKey, $0) } }
        )
    }

    private struct CategoryRow: Hashable, Identifiable { let id: Int64; let name: String; let minor: Int64 }
    @State private var categoryLabels: [Int64: String] = [:]

    private var categoryRows: [CategoryRow] {
        // Keyed by category id, not name: "Other" exists under several parents.
        var bucket: [Int64: Int64] = [:]
        var names: [Int64: String] = [:]
        for row in byCategory {
            let amount: Int64?
            if currencyFilter != nil {
                amount = (row.currency == currencyFilter) ? row.totalMinor : nil
            } else {
                amount = app.convertedToHome(row.totalMinor, from: row.currency)
            }
            if let a = amount { bucket[row.keyId, default: 0] += a; names[row.keyId] = row.key }
        }
        return bucket
            .map { CategoryRow(id: $0.key, name: categoryLabels[$0.key] ?? names[$0.key] ?? "—", minor: $0.value) }
            // Net mixes signs: rank by magnitude so the biggest movers lead.
            .sorted { mode == .net ? abs($0.minor) > abs($1.minor) : $0.minor > $1.minor }
    }

    // MARK: - Logic

    private func reload() {
        let win = YearMonth.window(endingAt: anchorYM, monthsBack: monthsBack)
        do {
            switch mode {
            case .expense, .income:
                let kind: TransactionKind = mode == .income ? .income : .expense
                byMonth     = try app.summaries.byMonth(fromYM: win.start, toYM: win.end, kind: kind, currency: currencyFilter)
                byDay       = trendUnit == .month ? [] : try app.summaries.dailyTotals(fromYM: win.start, toYM: win.end, kind: kind)
                byCategory  = try app.summaries.byCategory(fromYM: win.start, toYM: win.end, kind: kind, currency: currencyFilter)
                byAccount   = try app.summaries.byAccount(fromYM: win.start, toYM: win.end, kind: kind)
                    .filter { currencyFilter == nil || $0.currency == currencyFilter }
            case .net:
                func negated(_ rows: [GroupedSummary]) -> [GroupedSummary] {
                    rows.map { var r = $0; r.totalMinor = -r.totalMinor; return r }
                }
                byMonth = try app.summaries.byMonth(fromYM: win.start, toYM: win.end, kind: .income, currency: currencyFilter)
                    + negated(try app.summaries.byMonth(fromYM: win.start, toYM: win.end, kind: .expense, currency: currencyFilter))
                byDay = trendUnit == .month ? [] :
                    try app.summaries.dailyTotals(fromYM: win.start, toYM: win.end, kind: .income)
                    + (try app.summaries.dailyTotals(fromYM: win.start, toYM: win.end, kind: .expense)).map { var d = $0; d.minor = -d.minor; return d }
                byCategory = try app.summaries.byCategory(fromYM: win.start, toYM: win.end, kind: .income, currency: currencyFilter)
                    + negated(try app.summaries.byCategory(fromYM: win.start, toYM: win.end, kind: .expense, currency: currencyFilter))
                byAccount = try app.summaries.netByAccount(fromYM: win.start, toYM: win.end)
                    .filter { currencyFilter == nil || $0.currency == currencyFilter }
            }
            totals      = try app.summaries.totals(fromYM: win.start, toYM: win.end)
            availableCurrencies = try app.summaries.distinctCurrencies(fromYM: win.start, toYM: win.end)
            // Budgets always roll up to the home currency, regardless of the currency filter.
            let cats = try app.categories.list()
            let allCats = try app.categories.list(includeArchived: true)
            categoryLabels = Dictionary(uniqueKeysWithValues: allCats.map { ($0.id, $0.displayPath(in: allCats)) })
            let spentRows = try app.summaries.byCategory(fromYM: win.start, toYM: win.end, kind: .expense)
            let earnedRows = try app.summaries.byCategory(fromYM: win.start, toYM: win.end, kind: .income)
            budgetRows = BudgetMath.lines(categories: cats, expense: spentRows, income: earnedRows, months: monthsBack, sumToHome: app.sumToHome)
            // If the chosen filter no longer has data, fall back to all.
            if let c = currencyFilter, !availableCurrencies.contains(c) {
                currencyFilter = nil
            }
        } catch {
            print("Reports reload error: \(error)")
        }
    }
}
