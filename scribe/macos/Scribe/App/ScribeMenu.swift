import Foundation

/// Scribe's menus as data, for a host that embeds Scribe and owns the menu
/// bar (the Electron app). It mirrors ScribeCommands item for item; each
/// entry with an `id` runs `AppModel.perform(action:)`, `role` entries are the
/// host's standard Edit items, and accelerators use Electron's syntax.
public enum ScribeMenu {
    static let menuTools: [ToolKind] = [.pen, .highlighter, .strokeEraser, .pointEraser, .select, .text, .pan]

    static func toolTitle(_ kind: ToolKind) -> String {
        kind.title + (kind.shortcut.map { "  (\(String($0).uppercased()))" } ?? "")
    }

    /// JSON: `[{label, submenu: [{id, label, accelerator?} | {role} | {type: "separator"} | {label, submenu}]}]`.
    public static func hostMenuJSON() -> String {
        let separator: [String: Any] = ["type": "separator"]
        func item(_ label: String, _ action: ScribeAction, _ accelerator: String? = nil) -> [String: Any] {
            var out: [String: Any] = ["id": action.id, "label": label]
            if let accelerator { out["accelerator"] = accelerator }
            return out
        }
        func role(_ name: String) -> [String: Any] { ["role": name] }

        let menus: [[String: Any]] = [
            ["label": "File", "submenu": [
                item("New Page", .newPage, "Cmd+N"),
                item("New Notebook…", .newSection, "Cmd+Alt+N"),
                item("New Folder…", .newNotebook, "Cmd+Shift+N"),
                separator,
                item("Open Library Folder…", .openFolder, "Cmd+O"),
                item("Show Library in Finder", .revealFolder),
                separator,
                item("Import PDF or Goodnotes…", .importPDF, "Cmd+Shift+I"),
                item("Import from OneNote…", .importOneNote),
                separator,
                item("Save", .save, "Cmd+S"),
            ]],
            ["label": "Edit", "submenu": [
                role("undo"), role("redo"), separator,
                role("cut"), role("copy"), role("paste"),
                item("Paste onto Page", .pasteOntoPage, "Alt+Cmd+V"),
                role("selectAll"), separator,
                item("Search All Notes", .search, "Cmd+F"),
            ]],
            ["label": "Insert", "submenu": [
                item("Table…", .insertTable, "Alt+Cmd+T"),
                item("Equation…", .insertEquation, "Alt+Cmd+E"),
                item("Image…", .insertImage, "Alt+Cmd+I"),
            ]],
            ["label": "Format", "submenu": [
                item("Bold", .bold, "Cmd+B"),
                item("Italic", .italic, "Cmd+I"),
                item("Underline", .underline, "Cmd+U"),
                item("Strikethrough", .strikethrough, "Cmd+Shift+X"),
                separator,
                ["label": "Style", "submenu": HeadingPreset.allCases.map { item($0.label, .heading($0)) }],
                separator,
                item("Bigger", .bigger),
                item("Smaller", .smaller),
            ]],
            ["label": "Tools", "submenu": menuTools.map { item(toolTitle($0), .tool($0)) }],
            ["label": "View", "submenu": [
                item("Zoom In", .zoomIn, "Cmd+="),
                item("Zoom Out", .zoomOut, "Cmd+-"),
                item("Actual Size", .actualSize, "Cmd+0"),
                item("Fit Page Width", .fitWidth, "Cmd+9"),
                separator,
                item("Toggle Sidebar", .toggleSidebar, "Ctrl+Cmd+S"),
                item("Toggle Pages", .togglePages, "Ctrl+Cmd+P"),
                item("Focus on Page", .toggleFocus, "Cmd+\\"),
                item("Library", .library, "Cmd+L"),
                item("All Pages", .pageGrid, "Cmd+Shift+G"),
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: menus),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }
}
