import SwiftUI

@main
struct ScribeApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .preferredColorScheme(.dark)
                .tint(.velvetAccent)
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .background, .inactive: store.flush()
            case .active: store.refresh()
            @unknown default: break
            }
        }
    }
}
