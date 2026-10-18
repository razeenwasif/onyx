import SwiftUI

@main
struct ScribeApp: App {
    @State private var store = Store()
    @State private var vault = VaultStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            AppHost(scribe: store, electron: vault)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .background, .inactive:
                store.flush()
                store.finishSaving()
                vault.flush()
            case .active:
                store.refreshInBackground()
                vault.refresh()
            @unknown default: break
            }
        }
    }
}
