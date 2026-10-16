import SwiftUI

/// Sheet wrapper around `TransactionEntryView`. The form's logic lives in
/// `TransactionEntryView` so the same body can be embedded inline in the
/// landscape split view; this wrapper just adds the modal chrome (Cancel
/// button + dismiss-on-save).
struct TransactionEditor: View {
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction?
    var initialAccountId: Int64? = nil

    var body: some View {
        NavigationStack {
            TransactionEntryView(
                transaction: transaction,
                initialAccountId: initialAccountId,
                onSaveCompletion: { dismiss() }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
