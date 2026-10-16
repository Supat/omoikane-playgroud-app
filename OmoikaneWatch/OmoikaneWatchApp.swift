import SwiftUI

/// Standalone Watch app: capture an expense, hand it to iCloud. No ledger,
/// no iPhone app required; the iPad or iPhone app ingests the inbox.
@main
struct OmoikaneWatchApp: App {
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CaptureView()
                .environment(store)
                .task { await store.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await store.refresh() } }
                }
        }
    }
}
