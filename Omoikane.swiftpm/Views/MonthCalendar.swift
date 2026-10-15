import SwiftUI
import UIKit

/// Month grid for the Dashboard, backed by UIKit's calendar view. Each day
/// with spending shows a compact total as its decoration; tapping a day
/// selects it. Paging the calendar to another month moves `yearMonth`,
/// so it stays in step with the Dashboard's month stepper.
struct MonthCalendar: UIViewRepresentable {
    @Binding var yearMonth: Int
    @Binding var selectedDay: Int?
    /// dayKey → spending in home-currency minor units.
    var dailyTotals: [Int: Int64]
    var currency: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar.current
        view.locale = Locale.current
        view.fontDesign = .rounded
        view.delegate = context.coordinator
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.selectionBehavior = selection
        view.visibleDateComponents = Self.components(for: yearMonth)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
        let target = Self.components(for: yearMonth)
        if view.visibleDateComponents.year != target.year || view.visibleDateComponents.month != target.month {
            view.setVisibleDateComponents(target, animated: true)
        }
        if let sel = view.selectionBehavior as? UICalendarSelectionSingleDate {
            let wanted = selectedDay.map { Calendar.current.dateComponents([.year, .month, .day], from: Date.from(dayKey: $0)) }
            if sel.selectedDate?.day != wanted?.day || sel.selectedDate?.month != wanted?.month {
                sel.setSelected(wanted, animated: false)
            }
        }
        if context.coordinator.lastTotals != dailyTotals {
            context.coordinator.lastTotals = dailyTotals
            let days = dailyTotals.keys.map { Calendar.current.dateComponents([.year, .month, .day], from: Date.from(dayKey: $0)) }
            view.reloadDecorations(forDateComponents: days + context.coordinator.decoratedDays, animated: false)
            context.coordinator.decoratedDays = days
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 360
        let fitted = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: max(fitted.height, 320))
    }

    static func components(for yearMonth: Int) -> DateComponents {
        let (y, m) = YearMonth.components(yearMonth)
        return DateComponents(year: y, month: m)
    }

    /// "12k", "1.2M", or the plain number: fits a calendar cell.
    static func compact(_ minor: Int64, currency: String) -> String {
        let units = Double(minor) / pow(10.0, Double(Money.fractionDigits(for: currency)))
        let a = abs(units)
        let sign = units < 0 ? "-" : ""
        switch a {
        case 1_000_000...: return sign + String(format: a >= 10_000_000 ? "%.0fM" : "%.1fM", a / 1_000_000)
        case 1_000...:     return sign + String(format: a >= 10_000 ? "%.0fk" : "%.1fk", a / 1_000)
        default:           return sign + String(format: a == a.rounded() ? "%.0f" : "%.1f", a)
        }
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: MonthCalendar
        var lastTotals: [Int: Int64] = [:]
        var decoratedDays: [DateComponents] = []
        init(_ parent: MonthCalendar) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = Calendar.current.date(from: dateComponents),
                  let total = parent.dailyTotals[date.dayKey], total != 0 else { return nil }
            let text = MonthCalendar.compact(total, currency: parent.currency)
            return .customView {
                let label = UILabel()
                label.text = text
                label.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
                label.textColor = .systemRed
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.7
                label.textAlignment = .center
                return label
            }
        }

        func calendarView(_ calendarView: UICalendarView, didChangeVisibleDateComponentsFrom previous: DateComponents) {
            let v = calendarView.visibleDateComponents
            if let y = v.year, let m = v.month {
                let key = YearMonth.key(year: y, month: m)
                if key != parent.yearMonth { parent.yearMonth = key }
            }
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dc = dateComponents, let date = Calendar.current.date(from: dc) else {
                parent.selectedDay = nil
                return
            }
            parent.selectedDay = date.dayKey
        }
    }
}
