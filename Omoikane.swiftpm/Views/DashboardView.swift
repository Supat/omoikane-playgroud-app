import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(AppState.self) private var app

    @State private var totals: SummaryStore.KindTotals = .init()
    @State private var byCategory: [GroupedSummary] = []
    @State private var trend: [GroupedSummary] = []
    @State private var topAccounts: [GroupedSummary] = []
    @State private var ymKey: Int = YearMonth.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summaryCards
                trendChart
                categoryBreakdown
                accountBreakdown
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        .task(id: app.dataVersion) { reload() }
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
            Stepper(
                value: Binding(
                    get: { ymKey },
                    set: { ymKey = $0 }
                ),
                in: minYM ... maxYM,
                step: 1,
                onEditingChanged: { _ in normalizeYM() }
            ) { EmptyView() }
            .labelsHidden()
        }
    }

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            StatCard(
                title: "Income",
                value: Formatters.money(totals.income),
                tint: .green,
                sfSymbol: "arrow.down.circle.fill"
            )
            StatCard(
                title: "Expense",
                value: Formatters.money(totals.expense),
                tint: .red,
                sfSymbol: "arrow.up.circle.fill"
            )
            StatCard(
                title: "Net",
                value: Formatters.money(totals.net),
                tint: totals.net >= 0 ? .green : .red,
                sfSymbol: "equal.circle.fill"
            )
            StatCard(
                title: "Transactions",
                value: "\(byCategory.reduce(0) { $0 + $1.count })",
                tint: .blue,
                sfSymbol: "list.number"
            )
        }
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 6 months").font(.headline)
            if trend.isEmpty {
                EmptyStateView(title: "No data", message: "Add a few entries to see trends.", sfSymbol: "chart.bar")
                    .frame(height: 180)
            } else {
                Chart(trend) { row in
                    BarMark(
                        x: .value("Month", row.key),
                        y: .value("Total", Double(row.totalMinor))
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
            Text("Spending by category").font(.headline)
            if byCategory.isEmpty {
                EmptyStateView(title: "No expenses", message: "Add an expense to see a breakdown.", sfSymbol: "chart.pie")
            } else {
                ForEach(byCategory.prefix(8)) { row in
                    HStack {
                        Text(row.key)
                        Spacer()
                        Text(Formatters.money(row.totalMinor))
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
                        Spacer()
                        Text(Formatters.money(row.totalMinor))
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

    private var minYM: Int { 200001 }
    private var maxYM: Int { 209912 }

    private func normalizeYM() {
        // Stepper uses a strict integer step. Wrap month boundaries.
        let (y, m) = YearMonth.components(ymKey)
        if m < 1 { ymKey = YearMonth.key(year: y - 1, month: 12) }
        else if m > 12 { ymKey = YearMonth.key(year: y + 1, month: 1) }
    }
}
