import SwiftUI

/// The standalone app's menu bar. Each item runs a `ScribeAction`; when Scribe
/// is embedded, the host builds the same menus from `ScribeMenu` instead.
public struct ScribeCommands: Commands {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    private func button(_ title: String, _ action: ScribeAction) -> some View {
        Button(title) { action.run(on: app) }
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            button("New Page", .newPage)
                .keyboardShortcut("n")
            button("New Notebook…", .newNotebook)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            button("Open Notebook Folder…", .openFolder)
                .keyboardShortcut("o")
            button("Show Notebook Folder in Finder", .revealFolder)
            Divider()
            button("Import PDF or Goodnotes…", .importPDF)
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            button("Save", .save)
                .keyboardShortcut("s")
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            button("Paste onto Page", .pasteOntoPage)
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(app.page == nil)
        }

        CommandGroup(after: .textEditing) {
            button("Search All Notebooks", .search)
                .keyboardShortcut("f")
        }

        CommandMenu("Insert") {
            Group {
                button("Table…", .insertTable)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                button("Equation…", .insertEquation)
                    .keyboardShortcut("e", modifiers: [.command, .option])
                button("Image…", .insertImage)
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            .disabled(app.page == nil)
        }

        CommandMenu("Format") {
            button("Bold", .bold)
                .keyboardShortcut("b")
            button("Italic", .italic)
                .keyboardShortcut("i")
            button("Underline", .underline)
                .keyboardShortcut("u")
            button("Strikethrough", .strikethrough)
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Menu("Style") {
                ForEach(HeadingPreset.allCases) { preset in
                    button(preset.label, .heading(preset))
                }
            }
            Divider()
            button("Bigger", .bigger)
            button("Smaller", .smaller)
        }

        CommandMenu("Tools") {
            ForEach(ScribeMenu.menuTools) { kind in
                // Tools switch with single keys (P, H, E, S, T, Space) while the
                // page has focus; menu equivalents would fire while typing.
                button(ScribeMenu.toolTitle(kind), .tool(kind))
            }
        }

        CommandGroup(before: .toolbar) {
            button("Zoom In", .zoomIn)
                .keyboardShortcut("=")
            button("Zoom Out", .zoomOut)
                .keyboardShortcut("-")
            button("Actual Size", .actualSize)
                .keyboardShortcut("0")
            button("Fit Page Width", .fitWidth)
                .keyboardShortcut("9")
            Divider()
            button(app.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar", .toggleSidebar)
                .keyboardShortcut("s", modifiers: [.command, .control])
            button(app.pageListCollapsed ? "Show Pages" : "Hide Pages", .togglePages)
                .keyboardShortcut("p", modifiers: [.command, .control])
            button(app.focusMode ? "Show Notebooks" : "Focus on Page", .toggleFocus)
                .keyboardShortcut("\\", modifiers: .command)
            button(app.showingPageGrid ? "Hide All Pages" : "All Pages", .pageGrid)
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
        }
    }
}
