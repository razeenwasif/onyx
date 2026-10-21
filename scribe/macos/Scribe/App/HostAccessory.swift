import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Set by a host that embeds Scribe in its own window (the Electron app):
    /// drawn where the window's traffic lights would sit, since an embedded
    /// window hides them. The axis says which way to lay out: horizontal in
    /// the sidebar's top row, vertical at the top of the icon rail. The
    /// standalone app leaves this nil and looks exactly as it always has.
    @Entry public var hostAccessory: ((Axis) -> AnyView)? = nil
}

/// The app switcher a host shows inside Scribe: the host's icon, which
/// switches back to it, and Scribe's own, marked as the one on screen.
public struct HostSwitcher: View {
    var axis: Axis
    var hostName: String
    var hostIcon: NSImage?
    var scribeIcon: NSImage?
    var switchToHost: () -> Void

    public init(axis: Axis, hostName: String, hostIcon: NSImage?, scribeIcon: NSImage?, switchToHost: @escaping () -> Void) {
        self.axis = axis
        self.hostName = hostName
        self.hostIcon = hostIcon
        self.scribeIcon = scribeIcon
        self.switchToHost = switchToHost
    }

    public var body: some View {
        // As on the iPad: both marks in one capsule, Scribe's lit.
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 2))
            : AnyLayout(VStackLayout(spacing: 2))
        layout {
            Mark(symbol: "atom", tint: Color(red: 0xB3 / 255, green: 0x9D / 255, blue: 0xFB / 255),
                 current: false, help: "Switch to \(hostName)", action: switchToHost)
            Mark(symbol: "pencil.and.scribble", tint: Velvet.accent,
                 current: true, help: "Scribe", action: {})
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
        .padding(.leading, axis == .horizontal ? 6 : 0)
    }
}

private struct Mark: View {
    var symbol: String
    var tint: Color
    var current: Bool
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(current ? tint : hovering ? Color.white.opacity(0.9) : Color.white.opacity(0.5))
                .frame(width: 34, height: 28)
                .background(current ? tint.opacity(0.18) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}
