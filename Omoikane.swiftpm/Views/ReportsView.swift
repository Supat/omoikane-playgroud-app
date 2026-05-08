import SwiftUI
import Charts

struct ReportsView: View {
    @Environment(AppState.self) private var app

    @State private var monthsBack: Int = 6
    @State private var kind: TransactionKind = .expense
    @State private var byMonth: [GroupedSummary] = []
    @State private var byCategory: [GroupedSummary] = []
    @State private var byAccount: [GroupedSummary] = []
    @State private var totals: SummaryStore.KindTotals = .init()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls

                summaryRow

                section("Trend") {
                    if byMonth.isEmpty {
                        EmptyStateView(title: "No data", message: "Try a longer range.", sfSymbol: "chart.bar")
                            .frame(height: 200)
                    } else {
                        Chart(byMonth) { row in
                            LineMark(
                                x: .value("Month", row.key),
                                y: .value("Total", Double(row.totalMinor))
                            )
                            .interpolationMethod(.monotone)
                            PointMark(
                                x: .value("Month", row.key),
                                y: .value("Total", Double(row.totalMinor))
                            )
                        }
                        .frame(height: 240)
                    }
                }

                section("By category") {
                    if byCategory.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        Chart(byCategory.prefix(10)) { row in
                            BarMark(
                                x: .value("Total", Double(row.totalMinor)),
                                y: .value("Category", row.key)
                            )
                        }
                        .frame(height: CGFloat(min(byCategory.count, 10) * 36 + 60))
                    }
                }

                section("By account") {
                    if byAccount.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        ForEach(byAccount) { row in
                            HStack {
                                Text(row.key)
                                Spacer()
                                Text(Formatters.money(row.totalMinor))
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
        .onChange(of: monthsBack) { _, _ in reload() }
        .onChange(of: kind)       { _, _ in reload() }
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
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            StatCard(title: "Income", value: Formatters.money(totals.income), tint: .green)
            StatCard(title: "Expense", value: Formatters.money(totals.expense), tint: .red)
            StatCard(title: "Net", value: Formatters.money(totals.net), tint: totals.net >= 0 ? .green : .red)
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

    private func reload() {
        let win = YearMonth.window(endingAt: YearMonth.current(), monthsBack: monthsBack)
        do {
            byMonth = try app.summaries.byMonth(fromYM: win.start, toYM: win.end, kind: kind)
            byCategory = try app.summaries.byCategory(fromYM: win.start, toYM: win.end, kind: kind)
            byAccount = try app.summaries.byAccount(fromYM: win.start, toYM: win.end, kind: kind)
            totals = try app.summaries.totals(fromYM: win.start, toYM: win.end)
        } catch {
            print("Reports reload error: \(error)")
        }
    }
}
