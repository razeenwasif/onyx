import AppKit
import Observation
import SwiftUI

/// Window-level state: the notebook tree, the open page, the active tool.
@Observable
final class AppModel {
    var settings: Settings
    private(set) var root: String

    var notebooks: [NotebookInfo] = []
    var selectedSectionPath: String?
    var pages: [PageInfo] = []
    var selectedPagePath: String?

    var searchText = "" {
        didSet { scheduleSearch() }
    }
    private(set) var searchResults: [PageInfo]?

    private(set) var page: PageModel?
    /// Title as it was when the page was opened; the file follows the title
    /// only when the page is closed, not on every keystroke.
    @ObservationIgnored private var titleAtLoad = ""
    @ObservationIgnored private var dirty = false

    var tool: ToolKind = .pen
    var pen = Pen.defaultPen
    var highlighter = Pen.defaultHighlighter

    /// Velvet dark is the only theme. Kept as a property so the canvas and
    /// ink code stay theme-aware for the self-test.
    var dark: Bool { true }

    /// Sidebar and page list hidden: just the page and the dock.
    var focusMode = false
    /// The pen tray (colours, width, pressure) above the dock.
    var trayOpen = false
    /// The Insert menu above the dock.
    var insertOpen = false
    /// Notebooks and pages in a popover, when the window is narrow.
    var showLibrary = false

    /// The notebooks sidebar folded down to its icon rail.
    var sidebarCollapsed = false {
        didSet {
            settings.sidebarCollapsed = sidebarCollapsed
            saveSettings()
        }
    }

    /// The page list tucked away.
    var pageListCollapsed = false {
        didSet {
            settings.pageListCollapsed = pageListCollapsed
            saveSettings()
        }
    }

    var zoom: CGFloat = 1
    var status = ""
    var alert: AlertInfo?
    var prompt: PromptInfo?
    var confirm: ConfirmInfo?
    var focusSearch = false
    var sheet: SheetKind?

    /// The text view being edited, for the formatting bar.
    @ObservationIgnored weak var activeTextView: ScribeTextView?
    var textFormat = TextFormatState()

    /// The canvas, for zoom and viewport queries.
    @ObservationIgnored weak var canvas: PageScrollView?

    @ObservationIgnored private var autosave: DispatchWorkItem?
    @ObservationIgnored private var searchWork: DispatchWorkItem?

    init() {
        let loaded = (try? Core.call("load_settings", as: Settings.self)) ?? Settings()
        settings = loaded
        sidebarCollapsed = loaded.sidebarCollapsed
        pageListCollapsed = loaded.pageListCollapsed
        let fallback = (try? Core.call("default_root", as: String.self)) ?? NSHomeDirectory() + "/Documents/Scribe Notebooks"
        root = loaded.workspaceRoot ?? fallback
        applyPenWidths()
    }

    // --------------------------------------------------------------- startup

    func start() {
        do {
            _ = try Core.call("ensure_starter", ["root": root], as: String?.self)
        } catch {
            show(error, title: "Could not open your notebooks")
        }
        reloadTree()
        restoreLastPage()
    }

    private func restoreLastPage() {
        if let last = settings.lastPageFile, FileManager.default.fileExists(atPath: last),
           let section = allSections.first(where: { last.hasPrefix($0.path + "/") }) {
            selectSection(section.path, openFirst: false)
            if pages.contains(where: { $0.path == last }) {
                openPage(last)
                return
            }
        }
        if let first = allSections.first {
            selectSection(first.path)
        }
    }

    func chooseWorkspace(_ url: URL) {
        commitOpenPage()
        root = url.path
        settings.workspaceRoot = url.path
        settings.lastPageFile = nil
        saveSettings()
        closePage()
        selectedSectionPath = nil
        pages = []
        start()
    }

    var allSections: [SectionInfo] { notebooks.flatMap(\.sections) }

    func section(at path: String?) -> SectionInfo? { allSections.first { $0.path == path } }

    func notebook(containing section: SectionInfo) -> NotebookInfo? {
        notebooks.first { $0.path == section.notebookPath }
    }

    // ------------------------------------------------------------------ tree

    func reloadTree() {
        do {
            notebooks = try Core.call("tree", ["root": root])
        } catch {
            show(error, title: "Could not read the notebook folder")
        }
        if let sel = selectedSectionPath, section(at: sel) == nil {
            selectedSectionPath = nil
            pages = []
        }
    }

    func selectSection(_ path: String?, openFirst: Bool = true) {
        guard path != selectedSectionPath || pages.isEmpty else { return }
        commitOpenPage()
        selectedSectionPath = path
        searchText = ""
        reloadPages()

        if openFirst {
            if let first = pages.first { openPage(first.path) } else { closePage() }
        }
    }

    func reloadPages() {
        guard let sec = selectedSectionPath else {
            pages = []
            return
        }
        pages = (try? Core.call("pages", ["section": sec])) ?? []
    }

    // ----------------------------------------------------------------- pages

    func openPage(_ path: String) {
        if page?.path == path { return }
        commitOpenPage()

        guard FileManager.default.fileExists(atPath: path) else {
            // Most likely a sync client removed it underneath us.
            reloadTree()
            reloadPages()
            return
        }

        let sectionPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            let doc: PageDoc = try Core.call("read_page", ["path": path])
            let model = PageModel(path: path, sectionPath: sectionPath, doc: doc)
            model.onChange = { [weak self] in self?.markDirty() }
            page = model
            titleAtLoad = doc.title
            dirty = false
            selectedPagePath = path
            if selectedSectionPath != sectionPath, searchResults == nil {
                selectedSectionPath = sectionPath
                reloadPages()
            }
            settings.lastPageFile = path
            saveSettings()
            status = ""
        } catch {
            show(error, title: "Could not open this page")
        }
    }

    func closePage() {
        page?.clearUndo()
        page = nil
        selectedPagePath = nil
        activeTextView = nil
    }

    func markDirty() {
        dirty = true
        status = "Edited"
        autosave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        autosave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func save() {
        autosave?.cancel()
        guard let page, dirty else { return }

        // A text box mid-edit holds its latest text in the view.
        activeTextView?.flush()

        do {
            let doc = page.toDoc()
            let result: WriteResult = try Core.call("write_page", ["path": page.path, "page": try Core.json(doc)])
            dirty = false
            status = "Saved " + Date().formatted(date: .omitted, time: .shortened)
            if let i = pages.firstIndex(where: { $0.path == page.path }) {
                pages[i].title = doc.title
                pages[i].modified = result.modifiedUnix
            }
        } catch {
            status = "Could not save"
            show(error, title: "Scribe could not save this page")
        }
    }

    /// Saves and renames the page file to follow its title. Deferred until
    /// the page is left, so typing a title does not create a file for every
    /// intermediate spelling.
    func commitOpenPage() {
        guard let page else { return }
        save()

        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != titleAtLoad else { return }
        do {
            let newPath: String = try Core.call("rename_page", ["section": page.sectionPath, "path": page.path, "title": title])
            if newPath != page.path {
                if selectedPagePath == page.path { selectedPagePath = newPath }
                page.moved(to: newPath)
                settings.lastPageFile = newPath
                saveSettings()
            }
            titleAtLoad = title
            reloadPages()
        } catch {
            status = "Rename failed: \(error.localizedDescription)"
        }
    }

    func titleEdited() {
        markDirty()
        if let page, let i = pages.firstIndex(where: { $0.path == page.path }) {
            pages[i].title = page.title
        }
    }

    func newPage() {
        guard let sec = selectedSectionPath ?? allSections.first?.path else {
            alert = AlertInfo(title: "New Page", message: "Create a notebook first.")
            return
        }
        commitOpenPage()
        do {
            let file: String = try Core.call("create_page", ["section": sec, "title": "Untitled page"])
            if selectedSectionPath != sec {
                selectedSectionPath = sec
            }
            searchText = ""
            reloadTree()
            reloadPages()
            openPage(file)
            focusTitle = true
        } catch {
            show(error, title: "Could not create a page")
        }
    }

    var focusTitle = false

    func renamePage(_ info: PageInfo, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if page?.path == info.path, let page {
            page.title = name
            dirty = true
            commitOpenPage()
            return
        }
        do {
            var doc: PageDoc = try Core.call("read_page", ["path": info.path])
            doc.title = name
            let _: WriteResult = try Core.call("write_page", ["path": info.path, "page": try Core.json(doc)])
            _ = try Core.call("rename_page", ["section": info.sectionPath, "path": info.path, "title": name], as: String.self)
            reloadPages()
        } catch {
            show(error, title: "Could not rename the page")
        }
    }

    /// Moves a page to the Trash, where it can still be recovered.
    func trashPage(_ info: PageInfo) {
        if page?.path == info.path { closePage() }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: info.path), resultingItemURL: nil)
            try Core.run("forget_page", ["section": info.sectionPath, "path": info.path])
        } catch {
            show(error, title: "Could not delete the page")
        }
        reloadTree()
        reloadPages()
        if searchResults != nil { runSearch() }
        if page == nil, let first = pages.first { openPage(first.path) }
    }

    func movePages(from offsets: IndexSet, to destination: Int) {
        guard let sec = selectedSectionPath, searchResults == nil else { return }
        pages.move(fromOffsets: offsets, toOffset: destination)
        do {
            try Core.run("set_page_order", ["section": sec, "paths": pages.map(\.path)])
        } catch {
            show(error, title: "Could not reorder pages")
        }
    }

    func movePage(_ info: PageInfo, to section: SectionInfo) {
        let wasOpen = page?.path == info.path
        if wasOpen { commitOpenPage(); closePage() }
        do {
            let newPath: String = try Core.call("move_page", ["path": info.path, "section": section.path])
            reloadTree()
            reloadPages()
            if wasOpen { openPage(newPath) }
        } catch {
            show(error, title: "Could not move the page")
        }
    }

    // ---------------------------------------------------- notebooks/sections

    func newNotebook(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try Core.call("create_notebook", ["root": root, "name": name, "firstSection": "New Section"], as: String.self)
            reloadTree()
        } catch {
            show(error, title: "Could not create the notebook")
        }
    }

    func newSection(in notebook: NotebookInfo, named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let path: String = try Core.call("create_section", ["notebook": notebook.path, "name": name])
            reloadTree()
            selectSection(path)
        } catch {
            show(error, title: "Could not create the section")
        }
    }

    func rename(notebook: NotebookInfo, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try Core.run("rename_notebook", ["path": notebook.path, "name": name])
            reloadTree()
        } catch {
            show(error, title: "Could not rename the notebook")
        }
    }

    func rename(section: SectionInfo, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try Core.run("rename_section", ["path": section.path, "name": name])
            reloadTree()
        } catch {
            show(error, title: "Could not rename the section")
        }
    }

    func trash(notebook: NotebookInfo) {
        if let page, page.path.hasPrefix(notebook.path + "/") { closePage() }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: notebook.path), resultingItemURL: nil)
        } catch {
            show(error, title: "Could not delete the notebook")
        }
        afterRemoval()
    }

    func trash(section: SectionInfo) {
        if let page, page.path.hasPrefix(section.path + "/") { closePage() }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: section.path), resultingItemURL: nil)
            try Core.run("forget_section", ["notebook": section.notebookPath, "section": section.path])
        } catch {
            show(error, title: "Could not delete the section")
        }
        afterRemoval()
    }

    private func afterRemoval() {
        reloadTree()
        if section(at: selectedSectionPath) == nil {
            selectedSectionPath = nil
            pages = []
            if let first = allSections.first { selectSection(first.path) }
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // ---------------------------------------------------------------- search

    private func scheduleSearch() {
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Searches every notebook, not just the open section: when you cannot
    /// remember where you wrote something, scoping to one section is exactly
    /// the wrong default.
    func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = nil
            return
        }
        save()
        searchResults = (try? Core.call("search", ["root": root, "query": q])) ?? []
    }

    func sectionName(for path: String) -> String {
        guard let sec = section(at: path) else { return "" }
        let nb = notebook(containing: sec)?.name ?? ""
        return nb.isEmpty ? sec.name : "\(nb) › \(sec.name)"
    }

    // ----------------------------------------------------------------- tools

    func select(tool kind: ToolKind) {
        insertOpen = false
        if kind == tool, kind.isInk {
            // A second press of the pen or highlighter opens its tray.
            trayOpen.toggle()
            return
        }
        trayOpen = false

        // A second press of the eraser switches to rubbing out part of a
        // stroke, the distinction OneNote buries in a submenu.
        if kind == .strokeEraser, tool == .strokeEraser {
            tool = .pointEraser
        } else if kind == .strokeEraser, tool == .pointEraser {
            tool = .strokeEraser
        } else {
            tool = kind
        }
        if !tool.isInk, tool != .select { page?.clearSelection() }
        if tool != .text { canvas?.window?.makeFirstResponder(canvas?.inkView) }
    }

    /// Picks an ink colour and switches to the pen.
    func chooseInk(_ hex: String) {
        pen.color = hex
        if tool != .pen { select(tool: .pen) }
    }

    func chooseHighlight(_ hex: String) {
        highlighter.color = hex
        if tool != .highlighter { select(tool: .highlighter) }
    }

    /// The pen the tray is editing: the highlighter while it is active.
    var trayPen: Pen { tool == .highlighter ? highlighter : pen }

    var eraserWidth: Double = 18

    func setWidth(_ w: Double) {
        switch tool {
        case .highlighter:
            highlighter.width = w
            settings.penWidths["highlighter"] = w
        case .pointEraser:
            eraserWidth = w
            return
        default:
            pen.width = w
            settings.penWidths["pen"] = w
        }
        saveSettings()
    }

    func setPressure(_ on: Bool) {
        pen.pressureSensitive = on
    }

    private func applyPenWidths() {
        if let w = settings.penWidths["pen"] { pen.width = w }
        if let w = settings.penWidths["highlighter"] { highlighter.width = w }
    }

    func setPaper(_ kind: String) {
        guard let page, page.background.kind != kind else { return }
        let before = page.background
        var after = before
        after.kind = kind
        page.perform("Change Paper", { page.background = after }, undo: { page.background = before })
    }

    func recolorSelection(_ hex: String) {
        page?.recolorSelection(hex)
    }

    // ------------------------------------------------------------- settings

    func saveSettings() {
        try? Core.run("save_settings", ["settings": (try? Core.json(settings)) ?? [:]])
    }

    func willTerminate() {
        commitOpenPage()
        saveSettings()
    }

    func show(_ error: Error, title: String) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// A one-field text prompt (rename, new notebook…).
struct PromptInfo: Identifiable {
    let id = UUID()
    var title: String
    var label: String
    var text: String
    var confirm: String = "OK"
    var action: (String) -> Void
}

enum SheetKind: Identifiable {
    case latex(LatexItem?)
    case table

    var id: String {
        switch self {
        case .latex(let item): "latex-\(item?.dto.id ?? "new")"
        case .table: "table"
        }
    }
}
