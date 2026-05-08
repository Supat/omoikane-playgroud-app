import SwiftUI

@main
struct OmoikaneApp: App {
    @State private var bootstrap: Bootstrap = .loading

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
                ContentView()
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
