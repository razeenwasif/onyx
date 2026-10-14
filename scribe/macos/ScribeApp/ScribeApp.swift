import AppKit
import ScribeUI
import SwiftUI

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    init() {
        Velvet.registerFonts()

        // Headless entry point for checking the ink engine without a tablet:
        //   Scribe --render-selftest out.png
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-selftest") {
            let out = i + 1 < args.count ? args[i + 1] : "scribe-selftest.png"
            do {
                try InkSelfTest.render(to: URL(fileURLWithPath: out))
                print("wrote \(out)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        // A window group always opens a window at launch, even after a crash
        // or forced quit; "New Window" is replaced by New Page below, so it
        // stays a single-window app.
        WindowGroup("Scribe", id: "main") {
            ContentView(app: app)
                .onAppear {
                    delegate.app = app
                    app.start()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { ScribeCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppModel? {
        didSet {
            guard keyMonitor == nil else { return }
            keyMonitor = ToolKeys.install { [weak self] in self?.app }
        }
    }

    private var keyMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        app?.willTerminate()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Switching apps is a natural moment to have everything on disk.
        app?.save()
    }
}
