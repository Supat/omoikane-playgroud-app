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

// MARK: - The keypad's SwiftUI surface

/// Visuals for the numpad. Lives in SwiftUI so each key can adopt Liquid
/// Glass via `.buttonStyle(.glass)` / `.glassProminent` (iOS 26+) without
/// us hand-rolling UIVisualEffectView backgrounds. Hosted inside a
/// `UIInputView` so UIKit treats it as a software keyboard.
fileprivate struct NumberPadKeysView: View {
    var onKey: (NumberPadAction) -> Void

    var body: some View {
        VStack(spacing: 8) {
            row([("7", .digit("7")), ("8", .digit("8")), ("9", .digit("9")), ("⌫", .backspace)])
            row([("4", .digit("4")), ("5", .digit("5")), ("6", .digit("6")), (",", .comma)])
            row([("1", .digit("1")), ("2", .digit("2")), ("3", .digit("3")), (".", .dot)])
            HStack(spacing: 8) {
                key("0", action: .digit("0"))
                key("Done", action: .done, prominent: true)
            }
        }
        .padding(12)
        // Cap width so each key stays roughly square on iPad landscape.
        // The outer .infinity frame with .trailing alignment pushes the
        // capped cluster against the right edge — easier to reach with
        // the right thumb on a held iPad.
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func row(_ cells: [(String, NumberPadAction)]) -> some View {
        HStack(spacing: 8) {
            ForEach(cells.indices, id: \.self) { i in
                key(cells[i].0, action: cells[i].1)
            }
        }
    }

    @ViewBuilder
    private func key(_ title: String, action: NumberPadAction, prominent: Bool = false) -> some View {
        // Two near-identical branches because `.buttonStyle(.glass)` and
        // `.buttonStyle(.glassProminent)` are different concrete style
        // types — there's no `AnyButtonStyle` to ternary between them.
        if prominent {
            Button { onKey(action) } label: {
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.glassProminent)
        } else {
            Button { onKey(action) } label: {
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.glass)
        }
    }
}

// MARK: - The keypad input view (UIKit shell)

/// Hosts `NumberPadKeysView` inside a `UIInputView`. Subclassing
/// `UIInputView` (rather than a plain `UIView`) makes UIKit treat the
/// view as a keyboard surface — it gets the right system blur and the
/// `UITextField` swaps its software keyboard for this when focus
/// arrives. The actual keys are drawn by SwiftUI for native Liquid
/// Glass styling.
final class NumberPadInputView: UIInputView {
    /// Set by the SwiftUI bridge. Each button tap fires this.
    var onKey: ((NumberPadAction) -> Void)? {
        didSet { rebuildHost() }
    }

    private var host: UIHostingController<NumberPadKeysView>?

    init() {
        // Initial frame is a starting hint; UIKit will resize via
        // `flexibleWidth` to match the screen. Height is what we care about.
        super.init(
            frame: CGRect(x: 0, y: 0, width: 320, height: 280),
            inputViewStyle: .keyboard
        )
        autoresizingMask = [.flexibleWidth]
        rebuildHost()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebuilds the SwiftUI host so the latest `onKey` closure is captured
    /// in the rootView. Called once at init and whenever the bridge
    /// rebinds the action handler.
    private func rebuildHost() {
        host?.view.removeFromSuperview()

        let onKey = self.onKey ?? { _ in }
        let controller = UIHostingController(rootView: NumberPadKeysView(onKey: onKey))
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        ])
        host = controller
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
        // Suppress iPadOS's input-assistant shortcut bar (Undo / Redo /
        // Paste). Those buttons are positioned above the keyboard layer
        // and were occasionally overflowing the top edge of our custom
        // numpad. We don't need them for amount entry — the numpad has
        // its own backspace, and undo/redo can still be invoked via
        // ⌘Z / ⇧⌘Z on a hardware keyboard.
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []

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
