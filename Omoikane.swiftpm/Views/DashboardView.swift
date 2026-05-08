import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(AppState.self) private var app

    @State private var totals: SummaryStore.CurrencyTotals = .init()
    @State private var byCategory: [GroupedSummary] = []
    @State private var trend: [GroupedSummary] = []
    @State private var topAccounts: [GroupedSummary] = []
    @State private var ymKey: Int = YearMonth.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !missing.isEmpty { missingRatesBanner }
                summaryCards
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
                            Text(Formatters.money(row.income, currency: row.currency))
                                .foregroundStyle(.green)
                                .monospacedDigit()
                            Text("·").foregroundStyle(.secondary)
                            Text(Formatters.money(row.expense, currency: row.currency))
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
                        x: .value("Month", row.label),
                        y: .value("Total", Double(row.minor))
                    )
                    .foregroundStyle(.red.gradient)
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
                        Text(Formatters.money(row.minor, currency: app.homeCurrency))
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
                        Text(Formatters.money(row.totalMinor, currency: row.currency))
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
