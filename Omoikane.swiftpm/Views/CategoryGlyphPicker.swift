import SwiftUI

/// Horizontal strip of category glyphs with the name underneath. Tapping a
/// parent that has sub-categories drills into them (the parent stays
/// selectable as the first tile, next to a Back tile); tapping a leaf
/// selects it. Stock ScrollView + Buttons, so every tile is focusable.
struct CategoryGlyphPicker: View {
    /// Categories of the right kind, unarchived, both levels.
    let categories: [LedgerCategory]
    @Binding var selection: Int64?
    /// Off for flat lists such as the category editor's Parent choice.
    var allowsDrillDown: Bool = true
    /// When set, a leading tile that selects nil (e.g. "Top level").
    var noneLabel: String? = nil
    /// nil = top level; otherwise the parent whose children are shown.
    @State private var browsingParentId: Int64? = nil

    private var topLevel: [LedgerCategory] { categories.filter { $0.parentId == nil } }
    private func children(of id: Int64) -> [LedgerCategory] { categories.filter { $0.parentId == id } }
    private var browsingParent: LedgerCategory? {
        browsingParentId.flatMap { id in categories.first { $0.id == id } }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    if let parent = browsingParent {
                        tile(icon: "chevron.left", label: "Back", selected: false, hasChildren: false,
                             accessibility: "Back to top-level categories") {
                            withAnimation(.snappy) { browsingParentId = nil }
                        }
                        categoryTile(parent, hasChildren: false)
                        ForEach(children(of: parent.id)) { c in
                            categoryTile(c, hasChildren: false)
                        }
                    } else {
                        if let noneLabel {
                            tile(icon: "rectangle.3.group", label: noneLabel, selected: selection == nil, hasChildren: false,
                                 accessibility: noneLabel) {
                                selection = nil
                            }
                        }
                        ForEach(topLevel) { c in
                            categoryTile(c, hasChildren: allowsDrillDown && !children(of: c.id).isEmpty)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear { syncBrowsingToSelection(); scrollToSelection(proxy) }
            .onChange(of: selection) { _, _ in scrollToSelection(proxy) }
            .onChange(of: categories) { _, _ in syncBrowsingToSelection() }
        }
    }

    /// Editing an entry on a sub-category opens inside its parent.
    private func syncBrowsingToSelection() {
        guard allowsDrillDown else { browsingParentId = nil; return }
        if let id = selection, let c = categories.first(where: { $0.id == id }), let p = c.parentId {
            browsingParentId = p
        } else if let p = browsingParentId, !categories.contains(where: { $0.id == p }) {
            browsingParentId = nil
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let id = selection { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
    }

    @ViewBuilder
    private func categoryTile(_ c: LedgerCategory, hasChildren: Bool) -> some View {
        let drillsIn = hasChildren && browsingParentId == nil
        tile(icon: c.icon ?? "tag", label: c.name, selected: selection == c.id, hasChildren: drillsIn,
             tint: c.displayColor(in: categories),
             accessibility: drillsIn ? "\(c.name), has sub-categories" : c.name) {
            selection = c.id
            if drillsIn { withAnimation(.snappy) { browsingParentId = c.id } }
        }
        .id(c.id)
    }

    @ViewBuilder
    private func tile(icon: String, label: String, selected: Bool, hasChildren: Bool,
                      tint: Color? = nil, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint ?? .primary)
                    .frame(width: 48, height: 48)
                    // Plain fill, not glass: a strip of glass tiles stutters while scrolling.
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill))
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if hasChildren {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .offset(x: 3, y: 3)
                        }
                    }
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
