import AppKit
import SwiftUI

/// Everything Scribe's menus can do, by name. The standalone menu bar
/// (ScribeCommands) and a host that embeds Scribe (the Electron app, whose
/// menu is built from ScribeMenu) both run their items through here, so the
/// two can't drift apart.
enum ScribeAction: Hashable {
    case newPage, newNotebook, openFolder, revealFolder, save, importPDF
    case pasteOntoPage, search
    case insertTable, insertEquation, insertImage
    case bold, italic, underline, strikethrough, bigger, smaller
    case heading(HeadingPreset)
    case tool(ToolKind)
    case zoomIn, zoomOut, actualSize, fitWidth
    case toggleSidebar, togglePages, toggleFocus

    /// The name a host uses for this action, e.g. "newPage" or "tool:pen".
    var id: String {
        switch self {
        case .heading(let preset): "heading:\(preset.rawValue)"
        case .tool(let kind): "tool:\(kind.rawValue)"
        default: "\(self)"
        }
    }

    init?(id: String) {
        if id.hasPrefix("heading:") {
            guard let preset = HeadingPreset(rawValue: String(id.dropFirst(8))) else { return nil }
            self = .heading(preset)
            return
        }
        if id.hasPrefix("tool:") {
            guard let kind = ToolKind(rawValue: String(id.dropFirst(5))) else { return nil }
            self = .tool(kind)
            return
        }
        let simple: [ScribeAction] = [
            .newPage, .newNotebook, .openFolder, .revealFolder, .save, .importPDF, .pasteOntoPage, .search,
            .insertTable, .insertEquation, .insertImage,
            .bold, .italic, .underline, .strikethrough, .bigger, .smaller,
            .zoomIn, .zoomOut, .actualSize, .fitWidth,
            .toggleSidebar, .togglePages, .toggleFocus,
        ]
        guard let match = simple.first(where: { $0.id == id }) else { return nil }
        self = match
    }

    /// Needs an open page; the menus disable these when there isn't one.
    var needsPage: Bool {
        switch self {
        case .pasteOntoPage, .insertTable, .insertEquation, .insertImage: true
        default: false
        }
    }

    func run(on app: AppModel) {
        if needsPage, app.page == nil { return }
        switch self {
        case .newPage:
            app.newPage()
        case .newNotebook:
            app.prompt = PromptInfo(title: "New Notebook", label: "Notebook name", text: "My Notebook", confirm: "Create") {
                app.newNotebook(named: $0)
            }
        case .openFolder:
            Self.chooseFolder(app)
        case .revealFolder:
            app.revealInFinder(app.root)
        case .save:
            app.commitOpenPage()
        case .importPDF:
            app.chooseAndImportPDFs()
        case .pasteOntoPage:
            app.paste()
        case .search:
            app.focusMode = false
            if let w = NSApp.keyWindow, w.frame.width < ContentView.railBelow { app.showLibrary = true }
            app.focusSearch = true
        case .insertTable:
            app.sheet = .table
        case .insertEquation:
            app.sheet = .latex(nil)
        case .insertImage:
            app.chooseImage()
        case .bold:
            app.activeTextView?.format { $0.bold.toggle() }
        case .italic:
            app.activeTextView?.format { $0.italic.toggle() }
        case .underline:
            app.activeTextView?.format { $0.underline.toggle() }
        case .strikethrough:
            app.activeTextView?.format { $0.strikethrough.toggle() }
        case .bigger:
            app.activeTextView?.format { $0.size = min($0.size + 2, 96) }
        case .smaller:
            app.activeTextView?.format { $0.size = max($0.size - 2, 6) }
        case .heading(let preset):
            app.activeTextView?.applyHeading(preset)
        case .tool(let kind):
            app.tool = kind
        case .zoomIn:
            app.canvas?.zoom(by: 1.25)
        case .zoomOut:
            app.canvas?.zoom(by: 1 / 1.25)
        case .actualSize:
            app.canvas?.zoomToActualSize()
        case .fitWidth:
            app.canvas?.zoomToFit()
        case .toggleSidebar:
            app.focusMode = false
            app.sidebarCollapsed.toggle()
        case .togglePages:
            app.focusMode = false
            app.pageListCollapsed.toggle()
        case .toggleFocus:
            withAnimation(.spring(duration: 0.35)) { app.focusMode.toggle() }
        }
    }

    private static func chooseFolder(_ app: AppModel) {
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

extension AppModel {
    /// Run a menu action by name (see `ScribeAction.id`). Returns false for a
    /// name Scribe doesn't know.
    @discardableResult
    public func perform(action id: String) -> Bool {
        guard let action = ScribeAction(id: id) else { return false }
        action.run(on: self)
        return true
    }
}
