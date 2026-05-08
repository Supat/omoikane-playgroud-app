import SwiftUI

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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
