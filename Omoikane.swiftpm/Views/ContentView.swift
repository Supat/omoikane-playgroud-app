import SwiftUI

/// AppTab identity for the multi-tab root. Lifted to file scope so the App
/// (and its `.commands` block) can refer to it without importing ContentView's
/// nested types.
enum AppTab: Hashable, CaseIterable {
    case dashboard, accounts, transactions, reports, categories, settings

    var title: String {
        switch self {
        case .dashboard:    return "Dashboard"
        case .accounts:     return "Accounts"
        case .transactions: return "Transactions"
        case .reports:      return "Reports"
        case .categories:   return "Categories"
        case .settings:     return "Settings"
        }
    }
}

/// Multi-tab root. The selection binding is owned by `OmoikaneApp` so the
/// `.commands { CommandMenu("AppTabs") { ... } }` block on the WindowGroup can
/// drive tab switching from keyboard shortcuts. (Putting `.keyboardShortcut`
/// on the tab content itself does not work — non-active tabs are lazy and
/// their views are not in the live hierarchy, so their shortcuts never
/// register.)
///
/// Keyboard navigation:
///   ⌘1…⌘6   — jump straight to a tab
///   ⌃AppTab   — next tab (wraps)
///   ⇧⌃AppTab  — previous tab (wraps)
struct ContentView: View {
    @Binding var selection: AppTab

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { DashboardView() }
                .tabItem { Label("Dashboard", systemImage: "chart.pie.fill") }
                .tag(AppTab.dashboard)

            NavigationStack { AccountsView() }
                .tabItem { Label("Accounts", systemImage: "creditcard.fill") }
                .tag(AppTab.accounts)

            NavigationStack { TransactionsView() }
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.transactions)

            NavigationStack { ReportsView() }
                .tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.reports)

            NavigationStack { CategoriesView() }
                .tabItem { Label("Categories", systemImage: "folder.fill") }
                .tag(AppTab.categories)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
    }
}
