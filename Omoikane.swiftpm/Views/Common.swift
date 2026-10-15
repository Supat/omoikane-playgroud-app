import SwiftUI
import Charts

extension View {
    /// Restricts the bound text to characters that look like a number entry
    /// (digits, decimal point, thousands comma) by stripping anything else
    /// on every change. `.keyboardType(.decimalPad)` already constrains the
    /// on-screen keyboard, but a connected hardware keyboard can still emit
    /// letters; this modifier closes that gap.
    ///
    /// Apply on top of `TextField` for amount / balance / rate inputs.
    func numericInputOnly(_ binding: Binding<String>) -> some View {
        self.onChange(of: binding.wrappedValue) { _, newValue in
            let filtered = NumericInput.filter(newValue)
            if filtered != newValue {
                binding.wrappedValue = filtered
            }
        }
    }
}

extension Array where Element == Account {
    /// Splits accounts into the two display groups used across the app:
    /// **Payment Accounts** (cash / bank / investment / other) and
    /// **Credit Cards** (kind == `.credit`). Order within each group is
    /// preserved so call sites don't need to re-sort after grouping.
    func splitForDisplay() -> (payment: [Account], credit: [Account]) {
        var payment: [Account] = []
        var credit: [Account] = []
        for a in self {
            if a.kind == .credit {
                credit.append(a)
            } else {
                payment.append(a)
            }
        }
        return (payment, credit)
    }
}

enum NumericInput {
    /// Keep digits and the first decimal point; drop everything else.
    /// Commas (thousands separators) are kept because the existing
    /// `parseMinor` strips them at parse time.
    static func filter(_ s: String) -> String {
        var seenDot = false
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch.isASCII && ch.isNumber {
                out.append(ch)
            } else if ch == "," {
                out.append(ch)
            } else if ch == "." && !seenDot {
                seenDot = true
                out.append(ch)
            }
            // anything else (letters, symbols, whitespace) is dropped
        }
        return out
    }
}

/// Shared formatters and small UI helpers.
enum Formatters {
    static func money(_ minor: Int64, currency: String = "JPY") -> String {
        Money(minor: minor, currency: currency).format()
    }

    /// Every amount on screen goes through this so money always reads in a
    /// monospaced face with tabular digits. Returns `Text` so callers can
    /// keep chaining `.font` / `.foregroundStyle`.
    static func moneyText(_ minor: Int64, currency: String = "JPY") -> Text {
        Text(money(minor, currency: currency)).moneyStyle()
    }

    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Short hour-minute time only (no date). Honors the user's locale,
    /// so it's 24-hour where the system is set that way.
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()
}

extension Text {
    /// Monospaced face + tabular digits, the house style for amounts.
    func moneyStyle() -> Text { fontDesign(.monospaced).monospacedDigit() }
}

extension Color {
    /// "#RRGGBB" → Color; nil for anything else.
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Color → "#RRGGBB" in sRGB.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

extension LedgerCategory {
    /// Assigned colour, or the kind's default. Children inherit the parent's
    /// colour via `displayColor(in:)`.
    var ownColor: Color? { color.flatMap(Color.init(hex:)) }
    func displayColor(in all: [LedgerCategory]) -> Color {
        if let c = ownColor { return c }
        if let p = parentId, let parent = all.first(where: { $0.id == p }), let c = parent.ownColor { return c }
        return kind == .income ? .green : .red
    }
}

extension View {
    /// Fixed-width slot for a row's leading symbol so titles line up no
    /// matter how wide the glyph is.
    func leadingIcon() -> some View { frame(width: 28, alignment: .center) }

    /// Liquid Glass card surface, the house style for every custom panel.
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var tint: Color = .accentColor
    var sfSymbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let sfSymbol {
                    Image(systemName: sfSymbol).foregroundStyle(tint)
                }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .moneyStyle()
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var sfSymbol: String = "tray"

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: sfSymbol)
        } description: {
            Text(message)
        }
    }
}

/// Native currency picker driven by `Locale.Currency.isoCurrencies`.
/// Display label is the localized name plus the ISO code so users see
/// "Japanese Yen (JPY)" rather than just a code.
struct CurrencyPicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Self.codes, id: \.self) { code in
                Text(Self.label(code)).tag(code)
            }
        }
    }

    static let codes: [String] = Locale.Currency.isoCurrencies
        .map(\.identifier)
        .sorted()

    static func label(_ code: String) -> String {
        if let name = Locale.current.localizedString(forCurrencyCode: code) {
            return "\(name) (\(code))"
        }
        return code
    }
}

/// Horizontal stacked bar: one segment per slice in its colour against a
/// capacity, with the unfilled remainder in grey and any overshoot in red,
/// plus a legend. Used for budget composition on Dashboard and in
/// Categories and Budget.
struct StackedShareBar: View {
    struct Slice: Identifiable {
        var name: String
        var amount: Int64
        var color: Color
        var id: String { name }
    }
    var slices: [Slice]
    var capacity: Int64
    var remainderLabel: String = "Unallocated"
    var overflowLabel: String = "Over the limit"

    var body: some View {
        let used = slices.reduce(Int64(0)) { $0 + $1.amount }
        let rest = max(capacity - used, 0)
        let over = max(used - capacity, 0)
        let names = slices.map(\.name) + (rest > 0 ? [remainderLabel] : []) + (over > 0 ? [overflowLabel] : [])
        let colors = slices.map(\.color) + (rest > 0 ? [Color.secondary.opacity(0.3)] : []) + (over > 0 ? [Color.red] : [])
        Chart {
            ForEach(slices) { sl in
                BarMark(x: .value("Amount", Double(sl.amount)), y: .value("", "bar"))
                    .foregroundStyle(by: .value("Category", sl.name))
            }
            if rest > 0 {
                BarMark(x: .value("Amount", Double(rest)), y: .value("", "bar"))
                    .foregroundStyle(by: .value("Category", remainderLabel))
            }
            if over > 0 {
                BarMark(x: .value("Amount", Double(over)), y: .value("", "bar"))
                    .foregroundStyle(by: .value("Category", overflowLabel))
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartXScale(domain: 0 ... Double(max(capacity, used, 1)))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .frame(height: 28 + CGFloat((names.count + 2) / 3) * 22)
    }
}
