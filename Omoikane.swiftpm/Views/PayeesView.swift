import SwiftUI

/// Settings → Payees. Tap or Return edits the selected row, ⌘N adds,
/// ⌘⌫ deletes; a payee still on transactions is archived instead.
struct PayeesView: View {
    @Environment(AppState.self) private var app
    @State private var payees: [Payee] = []
    @State private var selectedId: Int64? = nil
    @State private var editing: Payee? = nil
    @State private var adding = false
    @State private var actionError: String? = nil

    var body: some View {
        List(selection: $selectedId) {
            if payees.isEmpty {
                Text("No payees yet. Add one here or from the entry form.")
                    .foregroundStyle(.secondary)
            }
            ForEach(payees) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    if p.isArchived {
                        Text("Archived").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = p }
                .tag(p.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { remove(p) } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        var copy = p; copy.isArchived.toggle()
                        do { try app.updatePayee(copy) } catch { actionError = "\(error)" }
                    } label: {
                        Label(p.isArchived ? "Unarchive" : "Archive",
                              systemImage: p.isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .tint(.orange)
                }
            }
        }
        .navigationTitle("Payees")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("New payee")
            }
        }
        .keyboardListNavigation(selection: $selectedId,
                                onReturn: { id in editing = payees.first { $0.id == id } },
                                onDelete: { id in if let p = payees.first(where: { $0.id == id }) { remove(p) } })
        .sheet(item: $editing) { p in PayeeEditor(payee: p) }
        .sheet(isPresented: $adding) { PayeeEditor(payee: nil) }
        .alert("Action failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
               presenting: actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in Text(msg) }
        .task(id: app.dataVersion) { payees = (try? app.payees.list(includeArchived: true)) ?? [] }
    }


    /// Hard delete when unreferenced, archive otherwise.
    private func remove(_ p: Payee) {
        do {
            if try app.payees.referenceCount(for: p.id) > 0 {
                var copy = p; copy.isArchived = true
                try app.updatePayee(copy)
            } else {
                try app.deletePayee(id: p.id)
            }
        } catch { actionError = "\(error)" }
    }
}

/// Add or rename one payee.
struct PayeeEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let payee: Payee?
    @State private var name = ""
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(payee == nil ? "New Payee" : "Rename Payee")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = payee?.name ?? "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(payee == nil ? "Add" : "Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if var p = payee {
                p.name = trimmed
                try app.updatePayee(p)
            } else {
                _ = try app.findOrCreatePayee(name: trimmed)
            }
            dismiss()
        } catch {
            saveError = "Save failed: \(error)"
        }
    }
}
