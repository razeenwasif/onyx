import SwiftUI

/// The two apps in one, as on the desktop: Electron (the Markdown vault)
/// and Scribe (handwriting). The switch sits at the top-left of each.
enum AppChoice: String {
    case electron, scribe
}

private struct AppSwitchKey: EnvironmentKey {
    static let defaultValue: Binding<AppChoice> = .constant(.scribe)
}

extension EnvironmentValues {
    var appChoice: Binding<AppChoice> {
        get { self[AppSwitchKey.self] }
        set { self[AppSwitchKey.self] = newValue }
    }
}

/// Holds both apps and shows the chosen one.
struct AppHost: View {
    let scribe: Store
    let electron: VaultStore
    @AppStorage("activeApp") private var app: AppChoice = .electron

    var body: some View {
        ZStack {
            switch app {
            case .electron:
                ElectronRoot(store: electron)
                    .transition(.opacity)
            case .scribe:
                RootView(store: scribe)
                    .tint(.velvetAccent)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app)
        .environment(\.appChoice, $app)
        // Whatever was typed or drawn is saved before the other app shows.
        .onChange(of: app) { _, _ in
            scribe.flush()
            electron.flush()
        }
        .background {
            // The desktop's shortcuts: Ctrl-Cmd-1 and Ctrl-Cmd-2.
            Button("Electron") { switchTo(.electron) }.keyboardShortcut("1", modifiers: [.control, .command]).hidden()
            Button("Scribe") { switchTo(.scribe) }.keyboardShortcut("2", modifiers: [.control, .command]).hidden()
        }
    }

    private func switchTo(_ choice: AppChoice) {
        app = choice
    }
}

/// The switch itself: both apps' marks side by side, the open one lit.
struct AppSwitchButton: View {
    @Environment(\.appChoice) private var app

    var body: some View {
        HStack(spacing: 2) {
            mark(.electron, symbol: "atom", name: "Electron", tint: .evAccent)
            mark(.scribe, symbol: "pencil.and.scribble", name: "Scribe", tint: .velvetAccent)
        }
        .padding(2)
    }

    private func mark(_ choice: AppChoice, symbol: String, name: String, tint: Color) -> some View {
        let on = app.wrappedValue == choice
        return Button {
            guard !on else { return }
            withAnimation(.easeInOut(duration: 0.2)) { app.wrappedValue = choice }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? tint : Color.secondary)
                .frame(width: 36, height: 30)
                .background(on ? tint.opacity(0.18) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
