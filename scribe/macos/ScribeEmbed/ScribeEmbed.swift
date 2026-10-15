import AppKit
import ScribeUI
import SwiftUI

// C entry points for a host that shows Scribe inside its own window: the
// Electron desktop app, through its scribe-bridge addon. The host owns the
// window, the menu bar and the app lifecycle; Scribe supplies one view, runs
// menu actions by name, and asks the host to switch back when its icon in the
// switcher is clicked. Everything here runs on the main thread.

private final class Embedded {
    static let shared = Embedded()

    let app = AppModel()
    var view: NSView?
    /// True while Scribe's view is the one on screen.
    var active = false
    var started = false
    var switchHandler: (@convention(c) () -> Void)?
    var keyMonitor: Any?
    var observers: [NSObjectProtocol] = []
    lazy var menuJSON: UnsafeMutablePointer<CChar> = strdup(ScribeMenu.hostMenuJSON())
}

/// Builds Scribe's view (once) and returns it retained, as an `NSView *` the
/// caller takes ownership of. `hostName` and the two icon paths feed the app
/// switcher drawn where the traffic lights would be.
///
/// The returned view is a plain container around SwiftUI's hosting view, and
/// the host hides that container, never the hosting view itself: NSHostingView
/// still answers hit tests while hidden, so a hidden Scribe laid over the
/// host's own view would swallow every click meant for it. AppKit skips a
/// hidden plain view, and everything inside it, when hit testing.
@_cdecl("scribe_embed_create_view")
public func scribeEmbedCreateView(
    _ hostName: UnsafePointer<CChar>?,
    _ hostIcon: UnsafePointer<CChar>?,
    _ scribeIcon: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer {
    let embedded = Embedded.shared
    if let view = embedded.view { return Unmanaged.passRetained(view).toOpaque() }

    Velvet.registerFonts()
    let name = hostName.map { String(cString: $0) } ?? "the host app"
    let hostImage = hostIcon.flatMap { NSImage(contentsOfFile: String(cString: $0)) }
    let scribeImage = scribeIcon.flatMap { NSImage(contentsOfFile: String(cString: $0)) }

    let root = ContentView(app: embedded.app)
        .environment(\.hostAccessory) { axis in
            AnyView(HostSwitcher(axis: axis, hostName: name, hostIcon: hostImage, scribeIcon: scribeImage) {
                embedded.switchHandler?()
            })
        }
    let hosting = NSHostingView(rootView: root)
    // Sized by the host's window; don't push SwiftUI's min size onto it.
    hosting.sizingOptions = []
    let view = NSView(frame: hosting.frame)
    hosting.autoresizingMask = [.width, .height]
    view.addSubview(hosting)
    embedded.view = view

    // Only while Scribe is on screen, so the host's own keys go to the host.
    embedded.keyMonitor = ToolKeys.install { embedded.active ? embedded.app : nil }

    // Read older handwriting in the background so the host's search finds
    // it, even if Scribe is never shown (showing it starts its own pass).
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        if !embedded.started { embedded.app.readHandwriting() }
    }

    // Save at the moments the standalone app does.
    let center = NotificationCenter.default
    embedded.observers = [
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            if embedded.started { embedded.app.save() }
        },
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            if embedded.started { embedded.app.willTerminate() }
        },
    ]
    return Unmanaged.passRetained(view).toOpaque()
}

/// The host shows (true) or hides (false) Scribe's view. Scribe opens its
/// notebooks the first time it's shown, and saves whenever it's hidden.
@_cdecl("scribe_embed_set_active")
public func scribeEmbedSetActive(_ active: Bool) {
    let embedded = Embedded.shared
    embedded.active = active
    if active { startIfNeeded() }
    if !active, embedded.started { embedded.app.save() }
}

private func startIfNeeded() {
    let embedded = Embedded.shared
    guard !embedded.started else { return }
    embedded.started = true
    embedded.app.start()
}

/// Pages matching `query`, as a JSON array (see HostSearchHit). The caller
/// frees the string with scribe_embed_free.
@_cdecl("scribe_embed_search")
public func scribeEmbedSearch(_ query: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    strdup(Embedded.shared.app.searchJSON(String(cString: query)))
}

/// Frees a string Scribe handed to the host.
@_cdecl("scribe_embed_free")
public func scribeEmbedFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

/// Opens the page at `path`. Starts Scribe first if it hasn't been shown
/// yet, so its usual "reopen the last page" doesn't replace this one.
@_cdecl("scribe_embed_open")
public func scribeEmbedOpen(_ path: UnsafePointer<CChar>) {
    startIfNeeded()
    Embedded.shared.app.showPage(at: String(cString: path))
}

/// Runs a menu action by name (see ScribeMenu). False for an unknown name.
@_cdecl("scribe_embed_perform")
public func scribeEmbedPerform(_ id: UnsafePointer<CChar>) -> Bool {
    Embedded.shared.app.perform(action: String(cString: id))
}

/// Scribe's menus as JSON, for the host's menu bar. Owned by Scribe; valid
/// for the life of the process.
@_cdecl("scribe_embed_menu_json")
public func scribeEmbedMenuJSON() -> UnsafePointer<CChar> {
    UnsafePointer(Embedded.shared.menuJSON)
}

/// Called when the host's icon in Scribe's switcher is clicked.
@_cdecl("scribe_embed_set_switch_handler")
public func scribeEmbedSetSwitchHandler(_ handler: @escaping @convention(c) () -> Void) {
    Embedded.shared.switchHandler = handler
}
