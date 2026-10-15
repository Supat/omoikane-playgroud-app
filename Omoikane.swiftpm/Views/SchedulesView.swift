import SwiftUI

/// Settings → Scheduled transactions. Recurring templates that
/// `AppState.postDueSchedules` turns into real rows when due. Tap or
/// Return edits the selected row, ⌘N adds, ⌘⌫ deletes.
struct SchedulesView: View {
    @Environment(AppState.self) private var app
    @State private var schedules: [Schedule] = []
    @State private var accounts: [Int64: Account] = [:]
    @State private var categories: [Int64: LedgerCategory] = [:]
    @State private var editing: Schedule? = nil
    @State private var adding = false
    @State private var selectedId: Int64? = nil
    @FocusState private var listFocused: Bool

    var body: some View {
        List(selection: $selectedId) {
            if schedules.isEmpty {
                Text("No schedules yet. Add one here, or choose Repeat when entering a transaction.")
                    .foregroundStyle(.secondary)
            }
            ForEach(schedules) { sc in
                row(sc)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = sc }
                    .tag(sc.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            try? app.deleteSchedule(id: sc.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .focused($listFocused)
        .navigationTitle("Scheduled")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("New schedule")
            }
        }
        .keyboardListNavigation(selection: $selectedId,
                                onReturn: { id in editing = schedules.first { $0.id == id } },
                                onDelete: { id in try? app.deleteSchedule(id: id) })
        .sheet(item: $editing) { sc in ScheduleEditor(schedule: sc) }
        .sheet(isPresented: $adding) { ScheduleEditor(schedule: nil) }
        .task(id: app.dataVersion) { reload() }
        .onAppear { listFocused = true }
    }


    private func row(_ sc: Schedule) -> some View {
        let acct = accounts[sc.accountId]
        return HStack {
            Image(systemName: sc.kind.sfSymbol).foregroundStyle(.tint).leadingIcon()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if sc.isEssential {
                        Image(systemName: "lifepreserver")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .accessibilityLabel("Essential")
                    }
                    Text(sc.kind == .transfer ? "Transfer" : (categories[sc.categoryId]?.name ?? sc.kind.displayName))
                }
                Text("\(acct?.name ?? "—") · \(sc.cadenceLabel) · next \(Formatters.mediumDate.string(from: sc.nextDue))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Formatters.moneyText(sc.amountMinor, currency: acct?.currency ?? app.homeCurrency)
                .monospacedDigit()
        }
    }

    private func reload() {
        schedules = (try? app.schedules.list()) ?? []
        let accs = (try? app.accounts.list(includeArchived: true)) ?? []
        accounts = Dictionary(uniqueKeysWithValues: accs.map { ($0.id, $0) })
        let cats = (try? app.categories.list(includeArchived: true)) ?? []
        categories = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0) })
    }
}

extension Schedule {
    /// "every month", "every 2 weeks".
    var cadenceLabel: String {
        let unit: String
        switch frequency {
        case .daily:   unit = "day"
        case .weekly:  unit = "week"
        case .monthly: unit = "month"
        case .yearly:  unit = "year"
        }
        return interval > 1 ? "every \(interval) \(unit)s" : "every \(unit)"
    }
}

/// Add or edit one schedule. Same fields as a transaction plus cadence.
struct ScheduleEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let schedule: Schedule?

    @State private var kind: TransactionKind = .expense
    @State private var amountText = ""
    @State private var counterpartyAmountText = ""
    @State private var categoryId: Int64? = nil
    @State private var accountId: Int64? = nil
    @State private var counterpartyAccountId: Int64? = nil
    @State private var payeeId: Int64? = nil
    @State private var note = ""
    @State private var frequency: ScheduleFrequency = .monthly
    @State private var interval = 1
    @State private var nextDue = Date()
    @State private var hasEnd = false
    @State private var endOn = Date()
    @State private var isEssential = false

    @State private var categories: [LedgerCategory] = []
    @State private var accounts: [Account] = []
    @State private var payees: [Payee] = []
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(TransactionKind.allCases) { k in
                            Label(k.displayName, systemImage: k.sfSymbol).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent(kind == .transfer ? "From amount" : "Amount") {
                        NumberPadField(text: $amountText, placeholder: "0", alignment: .right)
                    }
                    Picker("Account", selection: $accountId) {
                        accountOptions(accounts)
                    }
                    if kind == .transfer {
                        Picker("To account", selection: $counterpartyAccountId) {
                            accountOptions(accounts.filter { $0.id != accountId })
                        }
                        if isCrossCurrency {
                            LabeledContent("To amount") {
                                NumberPadField(text: $counterpartyAmountText, placeholder: "0", alignment: .right)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Category")
                                Spacer()
                                Text(categoryPath)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            CategoryGlyphPicker(categories: availableCategories, selection: $categoryId)
                        }
                        .listRowInsets(EdgeInsets())
                        Picker("Payee", selection: $payeeId) {
                            Text("None").tag(Int64?.none)
                            ForEach(payees) { p in Text(p.name).tag(Int64?.some(p.id)) }
                        }
                    }
                    TextField("Note", text: $note)
                    if kind == .expense {
                        Toggle(isOn: $isEssential) {
                            Label("Essential", systemImage: "lifepreserver")
                        }
                    }
                }

                Section("Repeat") {
                    Picker("Every", selection: $frequency) {
                        ForEach(ScheduleFrequency.allCases, id: \.self) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    Stepper("Interval: \(interval)", value: $interval, in: 1...365)
                    DatePicker("Next due", selection: $nextDue, displayedComponents: .date)
                    Toggle("Ends", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("End date", selection: $endOn, in: nextDue..., displayedComponents: .date)
                    }
                }

                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(schedule == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .task { load() }
            .onChange(of: kind) { _, _ in
                if kind != .transfer, let id = categoryId,
                   !availableCategories.contains(where: { $0.id == id }) {
                    categoryId = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(schedule == nil ? "Add" : "Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var fromCurrency: String { accounts.first { $0.id == accountId }?.currency ?? app.homeCurrency }
    private var toCurrency: String { accounts.first { $0.id == counterpartyAccountId }?.currency ?? fromCurrency }
    private var isCrossCurrency: Bool { kind == .transfer && fromCurrency != toCurrency }

    /// Same four groups as the Accounts tab and the entry form.
    @ViewBuilder
    private func accountOptions(_ list: [Account]) -> some View {
        ForEach(list.displayGroups(), id: \.title) { group in
            Section(group.title) {
                ForEach(group.accounts) { a in
                    Label("\(a.name) (\(a.currency))", systemImage: a.kind.sfSymbol).tag(Int64?.some(a.id))
                }
            }
        }
    }
    private var availableCategories: [LedgerCategory] {
        categories.filter { $0.kind == (kind == .income ? .income : .expense) }
    }
    private var categoryPath: String {
        guard let id = categoryId, let c = categories.first(where: { $0.id == id }) else { return "Choose a category" }
        return c.displayPath(in: categories)
    }
    private var canSave: Bool {
        guard (Money.parseMinor(amountText, currency: fromCurrency) ?? 0) > 0, accountId != nil else { return false }
        if kind == .transfer {
            guard let cp = counterpartyAccountId, cp != accountId else { return false }
            if isCrossCurrency, (Money.parseMinor(counterpartyAmountText, currency: toCurrency) ?? 0) <= 0 { return false }
            return true
        }
        return categoryId != nil
    }

    private func load() {
        categories = (try? app.categories.list()) ?? []
        accounts = (try? app.accounts.list()) ?? []
        payees = (try? app.payees.list()) ?? []
        if let sc = schedule {
            kind = sc.kind
            amountText = Money.formatMinorText(sc.amountMinor, currency: accounts.first { $0.id == sc.accountId }?.currency ?? app.homeCurrency)
            if let cp = sc.counterpartyAmountMinor {
                counterpartyAmountText = Money.formatMinorText(cp, currency: accounts.first { $0.id == sc.counterpartyAccountId }?.currency ?? app.homeCurrency)
            }
            categoryId = sc.categoryId
            accountId = sc.accountId
            counterpartyAccountId = sc.counterpartyAccountId
            payeeId = sc.payeeId
            note = sc.note ?? ""
            frequency = sc.frequency
            interval = sc.interval
            nextDue = sc.nextDue
            hasEnd = sc.endOn != nil
            endOn = sc.endOn ?? sc.nextDue
            isEssential = sc.isEssential
        } else {
            accountId = accounts.first?.id
        }
    }

    private func save() {
        guard let amt = Money.parseMinor(amountText, currency: fromCurrency), let acct = accountId else { return }
        let cat: Int64
        if kind == .transfer {
            cat = categories.first?.id ?? 0
        } else {
            guard let chosen = categoryId else { return }
            cat = chosen
        }
        let sc = Schedule(
            id: schedule?.id ?? 0,
            kind: kind,
            amountMinor: amt,
            categoryId: cat,
            accountId: acct,
            counterpartyAccountId: kind == .transfer ? counterpartyAccountId : nil,
            counterpartyAmountMinor: isCrossCurrency ? Money.parseMinor(counterpartyAmountText, currency: toCurrency) : nil,
            payeeId: kind == .transfer ? nil : payeeId,
            note: note.isEmpty ? nil : note,
            frequency: frequency,
            interval: interval,
            nextDue: nextDue,
            endOn: hasEnd ? endOn : nil,
            isEssential: kind == .expense && isEssential,
            dayOfMonth: Calendar.current.component(.day, from: nextDue)
        )
        do {
            if schedule == nil { try app.addSchedule(sc) } else { try app.updateSchedule(sc) }
            dismiss()
        } catch {
            saveError = "Save failed: \(error)"
        }
    }
}
