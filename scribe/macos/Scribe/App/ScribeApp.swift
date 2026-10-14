import AppKit
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
        didSet { installToolKeys() }
    }

    private var keyMonitor: Any?

    /// Single-key tool switching (P, H, E, S, T) anywhere in the window,
    /// except while typing. Menu key equivalents cannot do this: they would
    /// fire inside text fields too.
    private func installToolKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let app = self?.app, app.page != nil,
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        app?.willTerminate()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Switching apps is a natural moment to have everything on disk.
        app?.save()
    }
}

/// Three velvet panels on a dark ground: notebooks, pages, and the page.
/// Narrow windows fold the first two into an icon rail; focus mode hides
/// them altogether.
struct ContentView: View {
    @Bindable var app: AppModel

    static let railBelow: CGFloat = 1120

    var body: some View {
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

struct ScribeCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Page") { app.newPage() }
                .keyboardShortcut("n")
            Button("New Notebook…") {
                app.prompt = PromptInfo(title: "New Notebook", label: "Notebook name", text: "My Notebook", confirm: "Create") {
                    app.newNotebook(named: $0)
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Notebook Folder…") { chooseFolder() }
                .keyboardShortcut("o")
            Button("Show Notebook Folder in Finder") { app.revealInFinder(app.root) }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.commitOpenPage() }
                .keyboardShortcut("s")
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Paste onto Page") { app.paste() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(app.page == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Search All Notebooks") {
                app.focusMode = false
                if let w = NSApp.keyWindow, w.frame.width < ContentView.railBelow { app.showLibrary = true }
                app.focusSearch = true
            }
            .keyboardShortcut("f")
        }

        CommandMenu("Insert") {
            Group {
                Button("Table…") { app.sheet = .table }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Equation…") { app.sheet = .latex(nil) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Image…") { app.chooseImage() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            .disabled(app.page == nil)
        }

        CommandMenu("Format") {
            Button("Bold") { app.activeTextView?.format { $0.bold.toggle() } }
                .keyboardShortcut("b")
            Button("Italic") { app.activeTextView?.format { $0.italic.toggle() } }
                .keyboardShortcut("i")
            Button("Underline") { app.activeTextView?.format { $0.underline.toggle() } }
                .keyboardShortcut("u")
            Button("Strikethrough") { app.activeTextView?.format { $0.strikethrough.toggle() } }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Menu("Style") {
                ForEach(HeadingPreset.allCases) { preset in
                    Button(preset.label) { app.activeTextView?.applyHeading(preset) }
                }
            }
            Divider()
            Button("Bigger") { app.activeTextView?.format { $0.size = min($0.size + 2, 96) } }
            Button("Smaller") { app.activeTextView?.format { $0.size = max($0.size - 2, 6) } }
        }

        CommandMenu("Tools") {
            ForEach([ToolKind.pen, .highlighter, .strokeEraser, .pointEraser, .select, .text, .pan]) { kind in
                // Tools switch with single keys (P, H, E, S, T, Space) while the
                // page has focus; menu equivalents would fire while typing.
                Button(kind.title + (kind.shortcut.map { "  (\(String($0).uppercased()))" } ?? "")) {
                    app.tool = kind
                }
            }
        }

        CommandGroup(before: .toolbar) {
            Button("Zoom In") { app.canvas?.zoom(by: 1.25) }
                .keyboardShortcut("=")
            Button("Zoom Out") { app.canvas?.zoom(by: 1 / 1.25) }
                .keyboardShortcut("-")
            Button("Actual Size") { app.canvas?.zoomToActualSize() }
                .keyboardShortcut("0")
            Button("Fit Page Width") { app.canvas?.zoomToFit() }
                .keyboardShortcut("9")
            Divider()
            Button(app.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") {
                app.focusMode = false
                app.sidebarCollapsed.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button(app.pageListCollapsed ? "Show Pages" : "Hide Pages") {
                app.focusMode = false
                app.pageListCollapsed.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            Button(app.focusMode ? "Show Notebooks" : "Focus on Page") {
                withAnimation(.spring(duration: 0.35)) { app.focusMode.toggle() }
            }
            .keyboardShortcut("\\", modifiers: .command)
            Divider()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Notebook Folder"
        panel.message = "Scribe keeps notebooks as plain folders. Pick the folder that holds them, or an empty one."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: app.root)
        if panel.runModal() == .OK, let url = panel.url {
            app.chooseWorkspace(url)
        }
    }
}
