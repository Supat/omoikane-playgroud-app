import SwiftUI
import UIKit

// MARK: - Action vocabulary

/// Discrete events the custom numpad can emit. Carrying the digit as a
/// payload (instead of one case per digit) keeps the layout-builder code
/// terse and avoids a 10-arm switch statement on the receiving end.
enum NumberPadAction: Equatable {
    case digit(String)
    case dot
    case comma
    case backspace
    case done
}

// MARK: - The keypad input view (UIKit)

/// `UIInputView` subclass that draws a Numbers-app-style keypad. Subclassing
/// `UIInputView` (rather than a plain `UIView`) makes UIKit treat the view
/// as a keyboard surface — it gets the right background blur and the
/// `UITextField` swaps its software keyboard for this when focus arrives.
///
/// Layout is a 4-row vertical `UIStackView` of horizontal `UIStackView`s,
/// `fillEqually` distribution. The bottom row uses two buttons (0, Done)
/// at 50% width each, aligning visually with the 2-of-4 cells above.
final class NumberPadInputView: UIInputView {
    /// Set by the SwiftUI bridge. Each button tap fires this.
    var onKey: ((NumberPadAction) -> Void)?

    init() {
        // Initial frame is a starting hint; UIKit will resize via
        // `flexibleWidth` to match the screen. Height is what we care about.
        super.init(
            frame: CGRect(x: 0, y: 0, width: 320, height: 280),
            inputViewStyle: .keyboard
        )
        autoresizingMask = [.flexibleWidth]
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    private func buildLayout() {
        let row1 = makeRow([
            ("7", .digit("7")),
            ("8", .digit("8")),
            ("9", .digit("9")),
            ("⌫", .backspace),
        ])
        let row2 = makeRow([
            ("4", .digit("4")),
            ("5", .digit("5")),
            ("6", .digit("6")),
            (",", .comma),
        ])
        let row3 = makeRow([
            ("1", .digit("1")),
            ("2", .digit("2")),
            ("3", .digit("3")),
            (".", .dot),
        ])
        // Bottom row: 0 and Done at 50%/50%. Visually they each occupy two
        // of the upper rows' four cells.
        let row4 = makeRow([
            ("0", .digit("0")),
            ("Done", .done),
        ])

        let column = UIStackView(arrangedSubviews: [row1, row2, row3, row4])
        column.axis = .vertical
        column.distribution = .fillEqually
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    private func makeRow(_ cells: [(String, NumberPadAction)]) -> UIStackView {
        let buttons = cells.map { makeButton(title: $0.0, action: $0.1) }
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        return stack
    }

    private func makeButton(title: String, action: NumberPadAction) -> UIButton {
        // `UIButton.Configuration.gray()` gets us the standard rounded chip
        // background — close enough to the system keyboard's visual style
        // without us hand-rolling a background view.
        var config = UIButton.Configuration.gray()
        config.title = title
        config.baseBackgroundColor = .secondarySystemBackground
        config.background.cornerRadius = 10
        if action == .done {
            config.baseBackgroundColor = .tintColor
            config.baseForegroundColor = .white
        }
        let btn = UIButton(
            configuration: config,
            primaryAction: UIAction { [weak self] _ in
                self?.onKey?(action)
            }
        )
        // Bigger glyphs than the `.gray()` default for an iPad-sized pad.
        btn.titleLabel?.font = .systemFont(ofSize: 24, weight: .medium)
        return btn
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI text field that uses `NumberPadInputView` as its software
/// keyboard. The bound text is filtered to numeric characters at the
/// `UITextFieldDelegate` layer, so a connected hardware keyboard cannot
/// inject letters and `numericInputOnly` is unnecessary on the call site.
///
/// What this view *doesn't* try to do (yet):
/// - Bridge SwiftUI `@FocusState` for programmatic focus / chained focus.
///   Use `onSubmit` (fires on the Done key) to advance focus to a sibling
///   `TextField` if needed.
/// - Match every SwiftUI `TextField` modifier. It accepts the parameters
///   the existing call sites need (placeholder, font, alignment); other
///   chrome is intentionally omitted to keep the bridge small.
struct NumberPadField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var alignment: NSTextAlignment = .natural
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.font = font
        tf.textAlignment = alignment
        tf.text = text
        tf.delegate = context.coordinator
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )

        let pad = NumberPadInputView()
        let coord = context.coordinator
        pad.onKey = { [weak tf] action in
            guard let tf else { return }
            coord.handle(action: action, on: tf)
        }
        tf.inputView = pad
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        // Only push when the binding actually diverges from the field —
        // otherwise we churn the cursor on every parent rerender.
        if uiView.text != text {
            uiView.text = text
        }
        uiView.placeholder = placeholder
        uiView.font = font
        uiView.textAlignment = alignment
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NumberPadField

        init(_ parent: NumberPadField) { self.parent = parent }

        @objc func editingChanged(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }

        // Handles hardware-keyboard input (and any system paste). Filtering
        // here means the bound `text` only ever sees digits / `.` / `,`,
        // so the SwiftUI side doesn't need `numericInputOnly`.
        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            guard let r = Range(range, in: current) else { return false }
            let proposed = current.replacingCharacters(in: r, with: string)
            let filtered = NumericInput.filter(proposed)
            if filtered != proposed {
                textField.text = filtered
                textField.sendActions(for: .editingChanged)
                return false
            }
            return true
        }

        // Routes a numpad button tap to UITextField. `insertText` and
        // `deleteBackward` honor the current selection range, so partial
        // edits / mid-string corrections work the same way as the system
        // keyboard would handle them.
        func handle(action: NumberPadAction, on tf: UITextField) {
            switch action {
            case .digit(let d):
                tf.insertText(d)
            case .dot:
                // Refuse a second dot — easier than letting the filter
                // strip it after the fact (which would shift the cursor).
                if !(tf.text ?? "").contains(".") {
                    tf.insertText(".")
                }
            case .comma:
                tf.insertText(",")
            case .backspace:
                tf.deleteBackward()
            case .done:
                tf.resignFirstResponder()
                parent.onSubmit?()
            }
            parent.text = tf.text ?? ""
        }
    }
}
