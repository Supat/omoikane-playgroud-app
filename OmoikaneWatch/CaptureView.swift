import SwiftUI

/// Pick a category, turn the crown for the amount, confirm. Three screens,
/// nothing else: the ledger lives on the iPad.
struct CaptureView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if let snap = store.snapshot {
                    categoryList(snap)
                } else {
                    ContentUnavailableView("No categories yet", systemImage: "icloud.and.arrow.down",
                                           description: Text(store.status.isEmpty ? "Waiting for iCloud." : store.status))
                }
            }
            .navigationTitle("Omoikane")
            .navigationDestination(for: WatchSnapshot.CategoryRef.self) { AmountView(category: $0) }
        }
    }

    private func categoryList(_ snap: WatchSnapshot) -> some View {
        List {
            Section {
                MonthLine(snapshot: snap)
                if !store.queue.isEmpty {
                    Label("\(store.queue.count) waiting to upload", systemImage: "arrow.up.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(snap.categories.filter { $0.parentId == nil }) { parent in
                let children = snap.categories.filter { $0.parentId == parent.id }
                Section {
                    row(parent)
                    ForEach(children) { row($0, indented: true) }
                }
            }
        }
    }

    private func row(_ c: WatchSnapshot.CategoryRef, indented: Bool = false) -> some View {
        NavigationLink(value: c) {
            Label {
                Text(c.name)
            } icon: {
                Image(systemName: c.icon ?? "tag")
                    .foregroundStyle(c.color.map { Color(hex: $0) } ?? .accentColor)
            }
            .padding(.leading, indented ? 12 : 0)
        }
    }
}

/// "¥12,300 of ¥150,000" or just the spend, from the snapshot.
struct MonthLine: View {
    let snapshot: WatchSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("This month").font(.footnote).foregroundStyle(.secondary)
            if let limit = snapshot.monthLimitMinor, limit > 0 {
                Text("\(Money.display(snapshot.monthSpentMinor, snapshot.homeCurrency)) of \(Money.display(limit, snapshot.homeCurrency))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(snapshot.monthSpentMinor > limit ? .red : .primary)
                ProgressView(value: Double(min(snapshot.monthSpentMinor, limit)), total: Double(limit))
            } else {
                Text(Money.display(snapshot.monthSpentMinor, snapshot.homeCurrency)).font(.footnote.monospacedDigit())
            }
        }
    }
}

struct AmountView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: WatchSnapshot.CategoryRef

    @State private var major: Double = 0          // crown value, in major units
    @State private var accountId: String = ""
    @State private var isEssential = false
    @State private var isReimbursable = false
    @State private var confirming = false

    private var accounts: [WatchSnapshot.AccountRef] { store.snapshot?.accounts ?? [] }
    private var account: WatchSnapshot.AccountRef? { accounts.first { $0.id == accountId } ?? accounts.first }
    private var currency: String { account?.currency ?? store.snapshot?.homeCurrency ?? "JPY" }
    private var minor: Int64 { Int64((major * pow(10, Double(Money.fractionDigits(for: currency)))).rounded()) }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(Money.display(minor, currency))
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .focusable()
                    .digitalCrownRotation($major, from: 0, through: 100_000_000, by: crownStep,
                                          sensitivity: .high, isContinuous: false, isHapticFeedbackEnabled: true)
                HStack {
                    ForEach(quickSteps, id: \.self) { step in
                        Button("+\(Money.display(Int64(step * pow(10, Double(Money.fractionDigits(for: currency)))), currency))") { major += step }
                            .buttonStyle(.bordered).font(.caption2).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                Picker("Account", selection: Binding(get: { account?.id ?? "" }, set: { accountId = $0 })) {
                    ForEach(accounts) { Text($0.name).tag($0.id) }
                }
                Toggle(isOn: $isEssential) { Label("Essential", systemImage: "lifepreserver") }
                Toggle(isOn: $isReimbursable) { Label("Reimbursable", systemImage: "arrow.uturn.backward.circle") }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(minor <= 0 || account == nil)
            }
        }
        .navigationTitle(category.name)
        .onAppear { accountId = store.lastAccountId ?? accounts.first?.id ?? "" }
        .overlay {
            if confirming {
                Label("Saved", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                    .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// Yen moves in hundreds, dollar-like currencies in units.
    private var crownStep: Double { Money.fractionDigits(for: currency) == 0 ? 100 : 1 }
    private var quickSteps: [Double] { Money.fractionDigits(for: currency) == 0 ? [100, 1000, 10000] : [1, 10, 100] }

    private func save() {
        guard let account else { return }
        store.add(WatchInboxEntry(id: WatchInboxEntry.newID(), amountMinor: minor, currency: account.currency,
                                  accountId: account.id, categoryId: category.id,
                                  occurredAt: Int64(Date().timeIntervalSince1970), note: nil,
                                  isEssential: isEssential, isReimbursable: isReimbursable))
        confirming = true
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            dismiss()
        }
    }
}

extension Money {
    /// "¥1,234" / "$12.34" for the Watch, which has no `Formatters`.
    static func display(_ minor: Int64, _ currency: String) -> String {
        let digits = fractionDigits(for: currency)
        let value = Decimal(minor) / pow(10, digits)
        return value.formatted(.currency(code: currency).precision(.fractionLength(digits)))
    }
}

extension Color {
    /// "#RRGGBB" → Color; the iOS app has the same initializer in Common.swift.
    init(hex: String) {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt32(h, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
