import SwiftUI

/// Multi-tab root. iPad shows the sidebar style; iPhone falls back to bottom bar.
struct ContentView: View {
    @State private var selection: Tab = .dashboard

    enum Tab: Hashable {
        case dashboard, transactions, reports, manage, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { DashboardView() }
                .tabItem { Label("Dashboard", systemImage: "chart.pie.fill") }
                .tag(Tab.dashboard)

            NavigationStack { TransactionsView() }
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }
                .tag(Tab.transactions)

            NavigationStack { ReportsView() }
                .tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
                .tag(Tab.reports)

            NavigationStack { ManageView() }
                .tabItem { Label("Manage", systemImage: "folder.fill") }
                .tag(Tab.manage)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
    }
}
