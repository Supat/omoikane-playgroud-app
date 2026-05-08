import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var transactionCount: Int = 0
    @State private var rebuilding = false
    @State private var lastRebuildTook: TimeInterval?

    var body: some View {
        Form {
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

            Section("Defaults") {
                Picker("Currency", selection: Binding(
                    get: { app.defaultCurrency },
                    set: { @MainActor newValue in app.defaultCurrency = newValue }
                )) {
                    ForEach(["JPY", "USD", "EUR", "GBP", "THB", "KRW", "TWD"], id: \.self) { c in
                        Text(c).tag(c)
                    }
                }
            }

            Section("About") {
                LabeledContent("App", value: "Omoikane")
                LabeledContent("Schema version", value: "\(Schema.latestVersion)")
            }
        }
        .navigationTitle("Settings")
        .task(id: app.dataVersion) { reload() }
    }

    private func reload() {
        transactionCount = (try? app.transactions.count()) ?? 0
    }

    private func rebuildSummaries() {
        rebuilding = true
        Task.detached(priority: .userInitiated) {
            let start = Date()
            try? await MainActor.run { try Schema.rebuildSummaries(app.db) }
            let took = Date().timeIntervalSince(start)
            await MainActor.run {
                rebuilding = false
                lastRebuildTook = took
                app.bump()
            }
        }
    }
}
