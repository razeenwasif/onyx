import AppKit
import SwiftUI

/// Three velvet panels on a dark ground: notebooks, pages, and the page.
/// Narrow windows fold the first two into an icon rail; focus mode hides
/// them altogether.
public struct ContentView: View {
    @Bindable var app: AppModel

    static let railBelow: CGFloat = 1120

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < Self.railBelow
            HStack(spacing: 10) {
                if !app.focusMode {
                    if narrow || app.sidebarCollapsed {
                        Rail(app: app, narrow: narrow)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        Sidebar(app: app)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    if !narrow && !app.pageListCollapsed {
                        PageList(app: app)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                EditorView(app: app)
            }
            .padding(10)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Velvet.ground)
            .animation(.spring(duration: 0.35, bounce: 0.1), value: app.focusMode)
            .animation(.spring(duration: 0.35, bounce: 0.1), value: app.sidebarCollapsed)
            .animation(.spring(duration: 0.35, bounce: 0.1), value: app.pageListCollapsed)
            .animation(.spring(duration: 0.35, bounce: 0.1), value: narrow)
        }
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 560)
        .fontDesign(.rounded)
        .foregroundStyle(Velvet.text)
        .preferredColorScheme(.dark)
        .tint(Velvet.accent)
        .sheet(item: $app.sheet) { kind in
            switch kind {
            case .latex(let item): LatexSheet(app: app, editing: item)
            case .table: TableSheet(app: app)
            }
        }
        .overlay {
            if let progress = app.importing {
                ImportPopup(progress: progress, accent: Velvet.accent, text: Velvet.text, muted: Velvet.muted, card: Velvet.raised) {
                    app.importing = nil
                }
            }
        }
        .sheet(item: $app.prompt) { PromptSheet(info: $0) }
        .alert(item: $app.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
        .confirmationDialog(
            app.confirm?.title ?? "",
            isPresented: Binding(get: { app.confirm != nil }, set: { if !$0 { app.confirm = nil } }),
            titleVisibility: .visible,
            presenting: app.confirm
        ) { info in
            Button(info.action, role: .destructive) { info.perform() }
        } message: { info in
            Text(info.message)
        }
    }
}
