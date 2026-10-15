import SwiftUI

/// Settings → Payees. Rename with Return or tap, ⌘N adds, ⌘⌫ deletes;
/// a payee still on transactions is archived instead of deleted.
struct PayeesView: View {
    @Environment(AppState.self) private var app
    @State private var payees: [Payee] = []
    @State private var selectedId: Int64? = nil
    @State private var renaming: Payee? = nil
    @State private var nameText = ""
    @State private var adding = false
    @State private var actionError: String? = nil
    @FocusState private var listFocused: Bool

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
                .onTapGesture { startRename(p) }
                .tag(p.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { remove(p) } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        var copy = p; copy.isArchived.toggle()
                        try? app.updatePayee(copy)
                    } label: {
                        Label(p.isArchived ? "Unarchive" : "Archive",
                              systemImage: p.isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .tint(.orange)
                }
            }
        }
        .focused($listFocused)
        .navigationTitle("Payees")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { nameText = ""; adding = true } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("New payee")
            }
        }
        .background(deleteShortcut)
        .onKeyPress(.return) {
            if let id = selectedId, let p = payees.first(where: { $0.id == id }) {
                startRename(p)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if selectedId != nil { selectedId = nil; return .handled }
            return .ignored
        }
        .alert("New payee", isPresented: $adding) {
            TextField("Name", text: $nameText)
            Button("Add") { _ = try? app.findOrCreatePayee(name: nameText) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename payee", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { p in
            TextField("Name", text: $nameText)
            Button("Save") {
                var copy = p; copy.name = nameText.trimmingCharacters(in: .whitespaces)
                if !copy.name.isEmpty {
                    do { try app.updatePayee(copy) } catch { actionError = "\(error)" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in EmptyView() }
        .alert("Action failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
               presenting: actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in Text(msg) }
        .task(id: app.dataVersion) { payees = (try? app.payees.list(includeArchived: true)) ?? [] }
        .onAppear { listFocused = true }
    }

    private var deleteShortcut: some View {
        Button(role: .destructive) {
            if let id = selectedId, let p = payees.first(where: { $0.id == id }) { remove(p) }
        } label: { EmptyView() }
        .keyboardShortcut(.delete, modifiers: .command)
        .frame(width: 1, height: 1)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func startRename(_ p: Payee) {
        nameText = p.name
        renaming = p
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
