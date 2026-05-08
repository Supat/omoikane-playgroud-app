import SwiftUI

@main
struct OmoikaneApp: App {
    @State private var bootstrap: Bootstrap = .loading
    /// Selected tab is owned at Scene level so `.commands { ... }` can mutate
    /// it from keyboard shortcuts. Putting selection inside ContentView and
    /// hanging shortcut buttons in the view hierarchy does not work for
    /// "switch to non-active tab" — those tabs are lazy and their attached
    /// shortcuts never register.
    @State private var tab: AppTab = .dashboard

    enum Bootstrap {
        case loading
        case ready(AppState)
        case failed(String)
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .loading:
                ProgressView("Opening database…")
                    .task { await boot() }
            case .ready(let state):
                ContentView(selection: $tab)
                    .environment(state)
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Failed to open database")
                        .font(.headline)
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .commands {
            // On iPadOS 26+, `.commands` populates the new Mac-style menu
            // bar (revealed via swipe-down from the top of the screen or by
            // moving the pointer to the top edge). Each Button's
            // `keyboardShortcut` is registered at Scene scope so it works
            // regardless of which tab is currently visible.
            //
            // Buttons are unrolled (rather than driven by ForEach) because
            // SwiftUI's command-content view-builder has historically had
            // edge cases with dynamic content; unrolled is the form Apple's
            // own samples use.
            CommandMenu("Tabs") {
                Button("Dashboard")    { tab = .dashboard    }.keyboardShortcut("1", modifiers: .command)
                Button("Accounts")     { tab = .accounts     }.keyboardShortcut("2", modifiers: .command)
                Button("Transactions") { tab = .transactions }.keyboardShortcut("3", modifiers: .command)
                Button("Reports")      { tab = .reports      }.keyboardShortcut("4", modifiers: .command)
                Button("Categories")   { tab = .categories   }.keyboardShortcut("5", modifiers: .command)
                Button("Settings")     { tab = .settings     }.keyboardShortcut("6", modifiers: .command)
                Divider()
                Button("Next Tab")     { cycleTab(by:  1) }.keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { cycleTab(by: -1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
        }
    }

    private func cycleTab(by delta: Int) {
        let all = AppTab.allCases
        guard let i = all.firstIndex(of: tab) else { return }
        tab = all[(i + delta + all.count) % all.count]
    }

    private func boot() async {
        do {
            let state = try AppState()
            await MainActor.run { bootstrap = .ready(state) }
        } catch {
            await MainActor.run { bootstrap = .failed("\(error)") }
        }
    }
}
