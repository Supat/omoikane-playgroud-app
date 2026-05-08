import SwiftUI

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

    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()
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
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
