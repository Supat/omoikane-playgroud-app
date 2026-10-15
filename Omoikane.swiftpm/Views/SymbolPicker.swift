import SwiftUI

/// Glyph picker for categories. A searchable grid of SF Symbols that suit
/// a household ledger; typing a full symbol name that isn't in the list
/// (e.g. "fork.knife.circle") offers it too, so nothing is locked out.
/// Stock controls only: LazyVGrid of Buttons, .searchable, Return picks
/// the first match.
struct SymbolPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var query = ""

    static let symbols: [String] = [
        // money & accounts
        "tag", "banknote", "creditcard", "wallet.pass", "building.columns", "yensign.circle", "dollarsign.circle",
        "chart.line.uptrend.xyaxis", "percent", "arrow.left.arrow.right", "gift", "equal.circle",
        // food
        "fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "carrot", "birthday.cake", "wineglass", "cart",
        // home
        "house", "bed.double", "sofa", "lamp.desk", "washer", "refrigerator", "key", "wrench.and.screwdriver", "hammer",
        "lightbulb", "drop", "flame", "bolt", "wifi", "phone", "iphone", "tv", "antenna.radiowaves.left.and.right", "trash",
        // transport
        "tram", "bus", "car", "fuelpump", "bicycle", "airplane", "ferry", "parkingsign", "figure.walk",
        // shopping & items
        "bag", "shippingbox", "tshirt", "shoe", "eyeglasses", "watch", "laptopcomputer", "desktopcomputer", "headphones",
        "gamecontroller", "book", "pencil", "paintpalette", "camera", "guitars", "puzzlepiece",
        // personal
        "heart", "cross.case", "pills", "stethoscope", "scissors", "comb", "dumbbell", "figure.run", "sparkles",
        // services & work
        "briefcase", "graduationcap", "building.2", "doc.text", "envelope", "newspaper", "music.note", "film", "ticket",
        "theatermasks", "pawprint", "leaf", "sun.max", "umbrella", "globe", "map", "suitcase", "bed.double.circle",
        // misc
        "star", "flag", "bell", "clock", "calendar", "person", "person.2", "person.3", "hand.raised", "questionmark.circle",
        "ellipsis.circle", "shield", "lock", "checkmark.seal", "archivebox", "square.split.2x1"
    ]

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Self.symbols }
        var out = Self.symbols.filter { $0.contains(q) }
        // Exact names outside the curated set still work.
        if !out.contains(q), UIImage(systemName: q) != nil { out.insert(q, at: 0) }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                    ForEach(filtered, id: \.self) { name in
                        Button {
                            selection = name
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: name)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(name == selection ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                                    )
                                Text(name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(name == selection ? .isSelected : [])
                    }
                }
                .padding()
                if filtered.isEmpty {
                    Text("No symbol matches \"\(query)\".")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .searchable(text: $query, prompt: "Search symbols")
            .onSubmit(of: .search) {
                if let first = filtered.first { selection = first; dismiss() }
            }
            .navigationTitle("Glyph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
