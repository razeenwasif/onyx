import AppKit

/// Single-key tool switching (P, H, E, S, T) anywhere in the window, except
/// while typing. Menu key equivalents cannot do this: they would fire inside
/// text fields too.
public enum ToolKeys {
    /// Installs the key monitor; keep the returned token alive. `model`
    /// returns the app to drive, or nil while Scribe isn't on screen (a host
    /// that embeds Scribe returns nil whenever its own view is showing, so
    /// the keys reach it instead).
    public static func install(_ model: @escaping () -> AppModel?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let app = model(), app.page != nil,
                  let window = event.window, window.attachedSheet == nil, !window.isSheet,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let kind = ToolKind.allCases.first(where: { $0.shortcut.map(String.init) == chars })
            else { return event }
            app.select(tool: kind)
            return nil
        }
    }
}
