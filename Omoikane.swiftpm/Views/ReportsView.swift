import SwiftUI
import Charts

struct ReportsView: View {
    @Environment(AppState.self) private var app

    @State private var monthsBack: Int = 6
    @State private var kind: TransactionKind = .expense
    /// nil = "All currencies → home rollup". Non-nil = isolate one currency.
    @State private var currencyFilter: String? = nil
    @State private var byMonth: [GroupedSummary] = []
    @State private var byCategory: [GroupedSummary] = []
    @State private var byAccount: [GroupedSummary] = []
    @State private var totals: SummaryStore.CurrencyTotals = .init()
    @State private var availableCurrencies: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                summaryRow

                section(currencyFilter == nil ? "Trend (\(app.homeCurrency))" : "Trend (\(currencyFilter!))") {
                    if trendRows.isEmpty {
                        EmptyStateView(title: "No data", message: "Try a longer range.", sfSymbol: "chart.bar")
                            .frame(height: 200)
                    } else {
                        Chart(trendRows, id: \.label) { row in
                            LineMark(
                                x: .value("Month", row.label),
                                y: .value("Total", Double(row.minor))
                            )
                            .interpolationMethod(.monotone)
                            PointMark(
                                x: .value("Month", row.label),
                                y: .value("Total", Double(row.minor))
                            )
                        }
                        .frame(height: 240)
                    }
                }

                section("By category") {
                    if categoryRows.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        Chart(categoryRows.prefix(10), id: \.name) { row in
                            BarMark(
                                x: .value("Total", Double(row.minor)),
                                y: .value("Category", row.name)
                            )
                        }
                        .frame(height: CGFloat(min(categoryRows.count, 10) * 36 + 60))
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
                                Text(Formatters.money(row.totalMinor, currency: row.currency))
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
        .onChange(of: kind)           { _, _ in reload() }
        .onChange(of: currencyFilter) { _, _ in reload() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: $kind) {
                Text("Expense").tag(TransactionKind.expense)
                Text("Income").tag(TransactionKind.income)
            }
            .pickerStyle(.segmented)

            Picker("Range", selection: $monthsBack) {
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Derived

    private var displayCurrency: String { currencyFilter ?? app.homeCurrency }

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

    private struct LabeledMinor: Hashable { let label: String; let minor: Int64 }

    private var trendRows: [LabeledMinor] {
        var bucket: [String: Int64] = [:]
        for row in byMonth {
            let amount: Int64?
            if currencyFilter != nil {
                amount = (row.currency == currencyFilter) ? row.totalMinor : nil
            } else {
                amount = app.convertedToHome(row.totalMinor, from: row.currency)
            }
            if let a = amount { bucket[row.key, default: 0] += a }
        }
        return bucket
            .sorted { $0.key < $1.key }
            .map { LabeledMinor(label: $0.key, minor: $0.value) }
    }

    private struct CategoryRow: Hashable { let name: String; let minor: Int64 }

    private var categoryRows: [CategoryRow] {
        var bucket: [String: Int64] = [:]
        for row in byCategory {
            let amount: Int64?
            if currencyFilter != nil {
                amount = (row.currency == currencyFilter) ? row.totalMinor : nil
            } else {
                amount = app.convertedToHome(row.totalMinor, from: row.currency)
            }
            if let a = amount { bucket[row.key, default: 0] += a }
        }
        return bucket
            .map { CategoryRow(name: $0.key, minor: $0.value) }
            .sorted { $0.minor > $1.minor }
    }

    // MARK: - Logic

    private func reload() {
        let win = YearMonth.window(endingAt: YearMonth.current(), monthsBack: monthsBack)
        do {
            byMonth     = try app.summaries.byMonth(fromYM: win.start, toYM: win.end, kind: kind, currency: currencyFilter)
            byCategory  = try app.summaries.byCategory(fromYM: win.start, toYM: win.end, kind: kind, currency: currencyFilter)
            byAccount   = try app.summaries.byAccount(fromYM: win.start, toYM: win.end, kind: kind)
                .filter { currencyFilter == nil || $0.currency == currencyFilter }
            totals      = try app.summaries.totals(fromYM: win.start, toYM: win.end)
            availableCurrencies = try app.summaries.distinctCurrencies(fromYM: win.start, toYM: win.end)
            // If the chosen filter no longer has data, fall back to all.
            if let c = currencyFilter, !availableCurrencies.contains(c) {
                currencyFilter = nil
            }
        } catch {
            print("Reports reload error: \(error)")
        }
    }
}
