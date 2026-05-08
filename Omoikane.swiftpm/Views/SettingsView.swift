import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var transactionCount: Int = 0
    @State private var rebuilding = false
    @State private var lastRebuildTook: TimeInterval?
    @State private var activeCurrencies: [String] = []

    var body: some View {
        // @Bindable lets a Picker bind to a property of an @Observable.
        @Bindable var app = app

        Form {
            Section {
                CurrencyPicker(title: "Home currency", selection: $app.homeCurrency)
                Text("Dashboard and Reports roll all activity up to your home currency using the rates below. Per-currency cards are shown alongside.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Currency")
            }

            Section {
                if foreignCurrencies.isEmpty {
                    Text("No foreign currencies in use yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(foreignCurrencies, id: \.self) { code in
                        RateRow(currency: code)
                    }
                }
            } header: {
                Text("Exchange rates → \(app.homeCurrency)")
            } footer: {
                if !app.missingRates(among: activeCurrencies).isEmpty {
                    Text("Currencies marked with ⚠︎ have no rate set; entries in those currencies are left out of the home-currency rollup.")
                        .font(.footnote)
                }
            }

            Section("Database") {
                LabeledContent("Transactions", value: "\(transactionCount)")
                LabeledContent("Location", value: app.db.url.lastPathComponent)
                Button {
                    rebuildSummaries()
                } label: {
                    HStack {
                        Label("Rebuild summary cache", systemImage: "arrow.clockwise")
                        Spacer()
                        if rebuilding { ProgressView() }
                    }
                }
                .disabled(rebuilding)
                if let lastRebuildTook {
                    Text("Last rebuild: \(String(format: "%.0f", lastRebuildTook * 1000)) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("App", value: "Omoikane")
                LabeledContent("Schema version", value: "\(Schema.latestVersion)")
            }
        }
        .navigationTitle("Settings")
        .task(id: app.dataVersion) { reload() }
        .task(id: app.rateVersion) { reload() }
    }

    private var foreignCurrencies: [String] {
        let withActivity = Set(activeCurrencies)
        let withRates = Set(app.rates.keys)
        return withActivity.union(withRates)
            .filter { $0 != app.homeCurrency }
            .sorted()
    }

    private func reload() {
        transactionCount = (try? app.transactions.count()) ?? 0
        activeCurrencies = (try? app.summaries.distinctCurrencies()) ?? []
    }

    private func rebuildSummaries() {
        rebuilding = true
        let start = Date()
        try? app.db.sync { try Schema.rebuildSummaries(app.db) }
        lastRebuildTook = Date().timeIntervalSince(start)
        rebuilding = false
        app.bump()
    }
}

/// One row in the rates editor: currency name + editable rate-to-home with a
/// missing-rate warning. Persists on Set or Return.
private struct RateRow: View {
    @Environment(AppState.self) private var app
    let currency: String
    @State private var rateText: String = ""
    @State private var hasLoaded = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CurrencyPicker.label(currency))
                    .lineLimit(1)
                Text("1 \(currency) = ? \(app.homeCurrency)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if app.rates[currency] == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            TextField("rate", text: $rateText)
                .keyboardType(.decimalPad)
                .numericInputOnly($rateText)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .submitLabel(.done)
                .onSubmit(commit)
            Button("Set", action: commit)
                .buttonStyle(.borderless)
                .disabled(Double(rateText) == nil)
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            if let r = app.rates[currency] { rateText = formatRate(r) }
        }
    }

    private func commit() {
        guard let value = Double(rateText), value > 0 else { return }
        try? app.setRate(currency: currency, rateToHome: value)
    }

    private func formatRate(_ r: Double) -> String {
        if r >= 100 { return String(format: "%.2f", r) }
        if r >= 1   { return String(format: "%.4f", r) }
        return String(format: "%.6f", r)
    }
}
