import SwiftUI

/// "Categories" tab. Two sections (Expense / Income); each renders top-level
/// categories with their sub-categories indented underneath. Tap any row to
/// edit; tap the "+" on a parent row to add a sub-category to it.
struct CategoriesView: View {
    @Environment(AppState.self) private var app

    @State private var categories: [LedgerCategory] = []
    @State private var editingCategory: LedgerCategory? = nil
    @State private var addingTopLevelKind: CategoryKind? = nil
    @State private var addingChildOf: LedgerCategory? = nil
    /// When non-nil, drives the delete-confirmation alert. Holds the target
    /// category plus a fresh reference count so the message can warn the
    /// user (or refuse) when the category is still in use.
    @State private var deletePrompt: DeletePrompt? = nil
    @State private var actionError: String? = nil

    var body: some View {
        List {
            section(for: .expense)
            section(for: .income)
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New expense category") { addingTopLevelKind = .expense }
                        .keyboardShortcut("n", modifiers: .command)
                    Button("New income category")  { addingTopLevelKind = .income }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add category")
            }
        }
        .sheet(item: $editingCategory) { cat in
            CategoryEditor(existing: cat)
        }
        .sheet(item: Binding(
            get: { addingTopLevelKind.map { AddInitial(kind: $0, parent: nil) } },
            set: { _ in addingTopLevelKind = nil }
        )) { init_ in
            CategoryEditor(initialKind: init_.kind, initialParent: init_.parent)
        }
        .sheet(item: $addingChildOf) { parent in
            CategoryEditor(initialKind: parent.kind, initialParent: parent)
        }
        .task(id: app.dataVersion) { reload() }
        .alert(
            "Delete '\(deletePrompt?.category.name ?? "")'?",
            isPresented: Binding(
                get: { deletePrompt != nil },
                set: { if !$0 { deletePrompt = nil } }
            ),
            presenting: deletePrompt
        ) { prompt in
            if prompt.isBlocked {
                // FK enforcement would refuse this anyway; offering Archive
                // gives the user a useful next step without a dead-end alert.
                Button("Archive instead") {
                    do { try app.archiveCategory(id: prompt.category.id) }
                    catch { actionError = "\(error)" }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("Delete", role: .destructive) {
                    do { try app.deleteCategory(id: prompt.category.id) }
                    catch { actionError = "\(error)" }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private func section(for kind: CategoryKind) -> some View {
        Section(kind == .expense ? "Expense" : "Income") {
            let topLevels = categories.filter { $0.kind == kind && $0.parentId == nil }
            if topLevels.isEmpty {
                Text("No \(kind == .expense ? "expense" : "income") categories yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topLevels) { parent in
                    parentRow(parent)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            rowActions(for: parent)
                        }
                    ForEach(children(of: parent)) { child in
                        childRow(child)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                rowActions(for: child)
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func parentRow(_ c: LedgerCategory) -> some View {
        // Two distinct focusable regions per row so keyboard users can Tab
        // between "edit this category" and "add a sub-category". Both buttons
        // use .borderless so the row's native list styling is preserved.
        HStack {
            Button {
                editingCategory = c
            } label: {
                HStack {
                    Image(systemName: c.icon ?? "tag")
                        .foregroundStyle(c.kind == .income ? .green : .red)
                    Text(c.name)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit category")

            Button {
                addingChildOf = c
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add sub-category")
        }
    }

    @ViewBuilder
    private func childRow(_ c: LedgerCategory) -> some View {
        Button {
            editingCategory = c
        } label: {
            HStack {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                Image(systemName: c.icon ?? "tag")
                    .foregroundStyle(c.kind == .income ? .green : .red)
                Text(c.name)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 24)
        .accessibilityHint("Edit sub-category")
    }

    private func children(of parent: LedgerCategory) -> [LedgerCategory] {
        categories.filter { $0.parentId == parent.id }
    }

    /// Trailing-swipe actions shared by parent and child rows. Delete is
    /// destructive but always routes through the alert — the user is told
    /// (a) what's still referencing this category and (b) whether the
    /// operation will succeed at all.
    @ViewBuilder
    private func rowActions(for c: LedgerCategory) -> some View {
        Button(role: .destructive) {
            startDelete(c)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        Button {
            do { try app.archiveCategory(id: c.id) }
            catch { actionError = "\(error)" }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .tint(.orange)
    }

    private func startDelete(_ c: LedgerCategory) {
        do {
            let refs = try app.categories.referenceCount(for: c.id)
            deletePrompt = DeletePrompt(category: c, refs: refs)
        } catch {
            actionError = "Couldn't check references: \(error)"
        }
    }

    private func reload() {
        do {
            categories = try app.categories.list(includeArchived: false)
        } catch {
            print("CategoriesView reload error: \(error)")
        }
    }
}

/// Bundled state for the delete-confirmation alert. Holds the category and
/// a snapshot of how many transactions / sub-categories still reference it
/// so the alert text can adapt to the situation.
private struct DeletePrompt: Identifiable {
    let category: LedgerCategory
    let refs: (transactions: Int, children: Int)
    var id: Int64 { category.id }

    var isBlocked: Bool {
        refs.transactions > 0 || refs.children > 0
    }

    var message: String {
        if isBlocked {
            let tx = "\(refs.transactions) transaction\(refs.transactions == 1 ? "" : "s")"
            let ch = "\(refs.children) sub-categor\(refs.children == 1 ? "y" : "ies")"
            return "Still referenced by \(tx) and \(ch). Hard delete would break referential integrity, so archive instead — it hides the category from pickers without touching history."
        } else {
            return "No transactions or sub-categories reference this category, so it's safe to delete. This cannot be undone."
        }
    }
}

/// Wrapper to feed `.sheet(item:)` for the top-level "Add" entry point —
/// `.sheet(item:)` requires Identifiable so we can't pass a raw enum.
private struct AddInitial: Identifiable {
    let kind: CategoryKind
    let parent: LedgerCategory?
    var id: String { "\(kind.rawValue)|\(parent?.id ?? -1)" }
}

/// Add or edit a single category. Used by:
/// - "+" menu in CategoriesView (top-level new)
/// - "+" button on a parent row (new child)
/// - tap on any row (edit)
struct CategoryEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// nil = new category. non-nil = editing.
    let existing: LedgerCategory?
    let initialKind: CategoryKind
    let initialParent: LedgerCategory?

    @State private var name: String
    @State private var kind: CategoryKind
    @State private var icon: String
    @State private var parentId: Int64?
    @State private var allCategories: [LedgerCategory] = []
    @State private var saveError: String?

    init(existing: LedgerCategory) {
        self.existing = existing
        self.initialKind = existing.kind
        self.initialParent = nil
        _name = State(initialValue: existing.name)
        _kind = State(initialValue: existing.kind)
        _icon = State(initialValue: existing.icon ?? "tag")
        _parentId = State(initialValue: existing.parentId)
    }

    init(initialKind: CategoryKind, initialParent: LedgerCategory?) {
        self.existing = nil
        self.initialKind = initialKind
        self.initialParent = initialParent
        _name = State(initialValue: "")
        _kind = State(initialValue: initialKind)
        _icon = State(initialValue: "tag")
        _parentId = State(initialValue: initialParent?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    Text("Expense").tag(CategoryKind.expense)
                    Text("Income").tag(CategoryKind.income)
                }
                .pickerStyle(.segmented)
                .disabled(existing != nil) // changing kind on an existing cat would orphan transactions
                TextField("SF Symbol", text: $icon)

                Picker("Parent", selection: $parentId) {
                    Text("Top level").tag(Int64?.none)
                    ForEach(eligibleParents) { p in
                        Text(p.name).tag(Int64?.some(p.id))
                    }
                }

                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .task { allCategories = (try? app.categories.list(includeArchived: false)) ?? [] }
            .onChange(of: kind) { _, _ in
                // If parent no longer matches (kind switched), clear it.
                if let pid = parentId,
                   !allCategories.contains(where: { $0.id == pid && $0.kind == kind }) {
                    parentId = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.isEmpty)
                }
            }
        }
    }

    /// Top-level same-kind categories. Excludes the currently-edited row
    /// (a category cannot be its own parent) and any of its descendants
    /// (we enforce a two-level hierarchy at the UI: only top-level items
    /// can be parents).
    private var eligibleParents: [LedgerCategory] {
        allCategories.filter { c in
            c.kind == kind &&
            c.parentId == nil &&
            c.id != existing?.id
        }
    }

    private func save() {
        do {
            if var copy = existing {
                copy.name = name
                copy.icon = icon.isEmpty ? nil : icon
                copy.parentId = parentId
                // kind is intentionally not edited (see disabled picker).
                try app.updateCategory(copy)
            } else {
                _ = try app.db.sync {
                    try app.categories.insert(name: name, kind: kind, icon: icon.isEmpty ? nil : icon, parentId: parentId)
                }
                app.bump()
            }
            dismiss()
        } catch {
            saveError = "Save failed: \(error)"
        }
    }
}
