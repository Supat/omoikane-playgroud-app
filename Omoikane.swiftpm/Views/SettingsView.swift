import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var transactionCount: Int = 0
    @State private var rebuilding = false
    @State private var lastRebuildTook: TimeInterval?
    @State private var activeCurrencies: [String] = []
    @State private var showImporter = false
    @State private var pendingImportURL: URL? = nil
    @State private var confirmReplace = false
    @State private var importing = false
    @State private var importMessage = ""
    @State private var showImportResult = false
    @State private var confirmClear = false
    @State private var backupInterval: BackupStore.Interval = BackupStore.interval
    @State private var lastBackup: Date? = BackupStore.lastBackup
    @State private var backupCount = 0

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

            Section("Manage") {
                NavigationLink {
                    CategoriesView()
                } label: {
                    Label("Categories and Budget", systemImage: "folder")
                }
                NavigationLink {
                    SchedulesView()
                } label: {
                    Label("Scheduled transactions", systemImage: "calendar.badge.clock")
                }
                NavigationLink {
                    PayeesView()
                } label: {
                    Label("Payees", systemImage: "person.crop.circle")
                }
            }

            Section {
                Picker("Automatic backup", selection: $backupInterval) {
                    ForEach(BackupStore.Interval.allCases) { i in Text(i.displayName).tag(i) }
                }
                .onChange(of: backupInterval) { _, v in
                    BackupStore.interval = v
                    app.autoBackupIfDue()
                    reload()
                }
                LabeledContent("Last backup", value: lastBackup.map { Formatters.mediumDate.string(from: $0) + " " + Formatters.shortTime.string(from: $0) } ?? "Never")
                Button {
                    do { _ = try app.backupNow() }
                    catch { importMessage = "\(error)"; showImportResult = true }
                    reload()
                } label: {
                    Label("Back up now", systemImage: "externaldrive.badge.plus")
                }
                .keyboardShortcut("b", modifiers: .command)
                NavigationLink {
                    BackupsView()
                } label: {
                    LabeledContent("Backups", value: "\(backupCount)")
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("Backups are complete copies of the database kept in the app's own storage (newest \(BackupStore.keepCount)). Automatic backups run at launch and when the app returns to the foreground. Use the list to restore or share one.")
                    .font(.footnote)
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
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Delete all transactions…", systemImage: "trash")
                }
                .disabled(transactionCount == 0)
                .confirmationDialog("Delete all \(transactionCount) transactions?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Delete all transactions", role: .destructive) {
                        do { try app.clearAllTransactions() }
                        catch { importMessage = "\(error)"; showImportResult = true }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Accounts, categories, payees, schedules, exchange rates and statements are kept. Balances fall back to each account's opening balance. This cannot be undone.")
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Label("Import Money Pro backup…", systemImage: "square.and.arrow.down")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing)
            } header: {
                Text("Import")
            } footer: {
                Text("Replaces every account, category, and transaction with the contents of a Money Pro .back file.")
                    .font(.footnote)
            }

            Section("About") {
                LabeledContent("App", value: "Omoikane")
                LabeledContent("Schema version", value: "\(Schema.latestVersion)")
            }
        }
        .navigationTitle("Settings")
        .task(id: app.dataVersion) { reload() }
        .task(id: app.rateVersion) { reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                pendingImportURL = url
                confirmReplace = true
            }
        }
        .confirmationDialog("Replace all data?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace and Import", role: .destructive) { runImport() }
            Button("Cancel", role: .cancel) { pendingImportURL = nil }
        } message: {
            Text("Everything currently in Omoikane is deleted first. This cannot be undone.")
        }
        .alert("Import", isPresented: $showImportResult) {
            Button("OK") {}
        } message: {
            Text(importMessage)
        }
    }

    private func runImport() {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        importing = true
        do {
            let s = try app.importMoneyPro(from: url)
            importMessage = "Imported \(s.accounts) accounts, \(s.categories) categories, and \(s.transactions) transactions."
        } catch {
            importMessage = error.localizedDescription
        }
        importing = false
        showImportResult = true
    }

    private var foreignCurrencies: [String] {
        let withActivity = Set(activeCurrencies)
        let withRates = Set(app.rates.keys)
        return withActivity.union(withRates)
            .filter { $0 != app.homeCurrency }
            .sorted()
    }

    private func reload() {
        lastBackup = BackupStore.lastBackup
        backupCount = BackupStore.list(for: app.db).count
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


/// Settings → Backups. Share a copy out, restore one (confirmed), or
/// delete. Return restores the selected row, ⌘⌫ deletes it.
struct BackupsView: View {
    @Environment(AppState.self) private var app
    @State private var files: [BackupStore.BackupFile] = []
    @State private var selectedId: URL? = nil
    @State private var restoring: BackupStore.BackupFile? = nil
    @State private var message: String? = nil
    @FocusState private var listFocused: Bool

    var body: some View {
        List(selection: $selectedId) {
            if files.isEmpty {
                Text("No backups yet. Use Back up now in Settings.").foregroundStyle(.secondary)
            }
            ForEach(files) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Formatters.mediumDate.string(from: f.date) + " " + Formatters.shortTime.string(from: f.date))
                        Text(ByteCountFormatter.string(fromByteCount: f.bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Share backup")
                    Button("Restore") { restoring = f }
                        .buttonStyle(.borderless)
                }
                .tag(f.url)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { remove(f) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .focused($listFocused)
        .navigationTitle("Backups")
        .keyboardListNavigation(selection: $selectedId,
                                onReturn: { id in restoring = files.first { $0.url == id } },
                                onDelete: { id in if let f = files.first(where: { $0.url == id }) { remove(f) } })
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible, presenting: restoring) { f in
            Button("Replace current data", role: .destructive) {
                do { try app.restore(from: f.url); message = "Restored backup from \(Formatters.mediumDate.string(from: f.date))." }
                catch { message = "\(error)" }
            }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text("Everything currently in Omoikane is replaced by the backup from \(Formatters.mediumDate.string(from: f.date)) \(Formatters.shortTime.string(from: f.date)). This cannot be undone.")
        }
        .alert("Backups", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }), presenting: message) { _ in
            Button("OK") {}
        } message: { m in Text(m) }
        .task(id: app.dataVersion) { files = BackupStore.list(for: app.db) }
        .onAppear { listFocused = true; files = BackupStore.list(for: app.db) }
    }


    private func remove(_ f: BackupStore.BackupFile) {
        do { try BackupStore.delete(f); files = BackupStore.list(for: app.db) }
        catch { message = "\(error)" }
    }
}
