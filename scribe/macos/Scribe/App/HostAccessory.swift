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
        let size: CGFloat = axis == .horizontal ? 22 : 30
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 6))
            : AnyLayout(VStackLayout(spacing: 8))
        layout {
            AppIcon(image: hostIcon, size: size, current: false, help: "Switch to \(hostName)", action: switchToHost)
            AppIcon(image: scribeIcon, size: size, current: true, help: "Scribe", action: {})
        }
        .padding(.leading, axis == .horizontal ? 6 : 0)
    }
}

private struct AppIcon: View {
    var image: NSImage?
    var size: CGFloat
    var current: Bool
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Velvet.control)
                }
            }
            .frame(width: size, height: size)
            .opacity(current || hovering ? 1 : 0.55)
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
                    .fill(current ? Velvet.accentSoft : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
                    .strokeBorder(Velvet.accentRing, lineWidth: current ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}
