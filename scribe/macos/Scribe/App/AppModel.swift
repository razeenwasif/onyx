import AppKit
import Observation
import SwiftUI

/// Window-level state: the notebook tree, the open page, the active tool.
@Observable
public final class AppModel {
    var settings: Settings
    private(set) var root: String

    var notebooks: [NotebookInfo] = []
    var selectedSectionPath: String?
    var pages: [PageInfo] = []
    var selectedPagePath: String?
    /// The section's pages as a grid of thumbnails, in place of the editor.
    var showingPageGrid = false
    /// The library (folders and notebook covers), in place of the editor.
    var showingHome = false
    /// The folder open in the library, or nil for the library's front.
    var homeFolderPath: String?
    /// Pages edited most recently, for the library's Recent row.
    var recents: [PageInfo] = []
    /// A PDF import in progress, for the import popup.
    var importing: ImportProgress?

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

    /// Notes in the Electron vault that link to the open page.
    var linkedNotes: [LinkingNote] = []
    /// The Electron vault, when a host that has one says where (links.rs).
    @ObservationIgnored public var vaultRoot: String? {
        didSet { if vaultRoot != oldValue { loadLinkedNotes() } }
    }
    /// Opens a vault note (vault-relative path) in the host; nil when Scribe
    /// runs on its own.
    @ObservationIgnored public var openNoteHandler: ((String) -> Void)?
    /// An area of a page to show once the page is on screen (a link to it).
    @ObservationIgnored var pendingReveal: (path: String, area: CGRect)?

    @ObservationIgnored private var autosave: DispatchWorkItem?
    /// Reads handwriting into searchable text.
    @ObservationIgnored let inkReader = InkReader()
    @ObservationIgnored private var searchWork: DispatchWorkItem?

    public init() {
        let loaded = (try? Core.call("load_settings", as: Settings.self)) ?? Settings()
        settings = loaded
        sidebarCollapsed = loaded.sidebarCollapsed
        pageListCollapsed = loaded.pageListCollapsed
        let fallback = (try? Core.call("default_root", as: String.self)) ?? NSHomeDirectory() + "/Documents/Scribe Notebooks"
        root = loaded.workspaceRoot ?? fallback
        #if DEBUG
        // For trying a debug build on a copy of a library:
        //   .build/debug/Scribe -ScribeTestRoot /path
        if let test = UserDefaults.standard.string(forKey: "ScribeTestRoot") { root = test }
        #endif
        applyPenWidths()
    }

    // --------------------------------------------------------------- startup

    public func start() {
        do {
            _ = try Core.call("ensure_starter", ["root": root], as: String?.self)
        } catch {
            show(error, title: "Could not open your library")
        }
        reloadTree()
        restoreLastPage()
        // Catch up on handwriting written before it was searchable, once
        // the window has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.inkReader.backfill(root: self.root)
        }
        thinImportedInk()
    }

    /// Once: thins the ink of OneNote pages imported before import did it
    /// (scribe-core thin_imported_pages), a few pages at a time in the
    /// background, never the page that's open. Only the Mac does this, so
    /// the iPad never rewrites the same files at the same time.
    private func thinImportedInk() {
        let root = self.root
        let openPage: @MainActor () -> String? = { [weak self] in self?.page?.path }
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                let open = await openPage()
                var args: [String: Any] = ["root": root, "limit": 3]
                if let open { args["skip"] = open }
                guard let done = try? Core.call("thin_imported_pages", args, as: Int.self), done > 0 else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
            show(error, title: "Could not read the library folder")
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
        // A page left a moment ago may still be on its way to disk.
        finishSaving()

        guard FileManager.default.fileExists(atPath: path) else {
            // Most likely a sync client removed it underneath us.
            reloadTree()
            reloadPages()
            return
        }

        let sectionPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            let doc: PageDoc = try Core.readPage(path)
            let model = PageModel(path: path, sectionPath: sectionPath, doc: doc)
            model.onChange = { [weak self] in self?.markDirty() }
            page = model
            linkedNotes = []
            loadLinkedNotes()
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
        // The file may be deleted or moved next; let its save land first.
        finishSaving()
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

    /// Pages are written here, in order, off the main thread: a big page
    /// took the better part of a second to save, and autosave froze the
    /// app each time.
    @ObservationIgnored private let saver = DispatchQueue(label: "app.scribe.save", qos: .userInitiated)

    public func save() {
        autosave?.cancel()
        guard let page, dirty else { return }

        // A text box mid-edit holds its latest text in the view.
        activeTextView?.flush()

        let doc = page.toDoc()
        let path = page.path
        let sectionPath = page.sectionPath
        let root = self.root
        dirty = false
        saver.async { [weak self] in
            do {
                let result = try Core.writePage(path, doc)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inkReader.pageSaved(doc, modified: result.modifiedUnix, root: root, sectionPath: sectionPath)
                    self.status = "Saved " + Date().formatted(date: .omitted, time: .shortened)
                    if let i = self.pages.firstIndex(where: { $0.path == path }) {
                        self.pages[i].title = doc.title
                        self.pages[i].modified = result.modifiedUnix
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.page?.path == path { self.dirty = true }
                    self.status = "Could not save"
                    self.show(error, title: "Scribe could not save this page")
                }
            }
        }
    }

    /// Waits for saves still being written: before the page file is
    /// renamed, moved or deleted, and before quitting.
    public func finishSaving() {
        saver.sync {}
    }

    /// Saves and renames the page file to follow its title. Deferred until
    /// the page is left, so typing a title does not create a file for every
    /// intermediate spelling.
    func commitOpenPage() {
        guard let page else { return }
        save()

        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != titleAtLoad else { return }
        finishSaving()
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
            var doc: PageDoc = try Core.readPage(info.path)
            doc.title = name
            let _: WriteResult = try Core.writePage(info.path, doc)
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

    // -------------------------------------------------------------- library
    // The library calls Scribe's notebooks "folders" and its sections
    // "notebooks"; the files keep their own names.

    func toggleHome() {
        if showingHome && page != nil {
            showingHome = false
            return
        }
        commitOpenPage()
        reloadTree()
        loadRecents()
        focusMode = false
        showingPageGrid = false
        homeFolderPath = nil
        showingHome = true
    }

    func loadRecents() {
        recents = (try? Core.call("recent_pages", ["root": root, "limit": 12], as: [PageInfo].self)) ?? []
    }

    var libraryActions: LibraryActions {
        LibraryActions(
            openFolder: { [weak self] in self?.homeFolderPath = $0.path },
            openNotebook: { [weak self] notebook in
                self?.showingHome = false
                self?.selectSection(notebook.path)
            },
            openPage: { [weak self] info in
                guard let self else { return }
                showingHome = false
                selectSection(info.sectionPath, openFirst: false)
                openPage(info.path)
            },
            newFolder: { [weak self] in self?.promptNewFolder() },
            newNotebook: { [weak self] in self?.promptNewNotebook(in: $0) },
            rename: { [weak self] item in
                guard let self else { return }
                switch item {
                case .folder(let f):
                    prompt = PromptInfo(title: "Rename Folder", label: "Folder name", text: f.name, confirm: "Rename") { [weak self] in
                        self?.rename(notebook: f, to: $0)
                    }
                case .notebook(let n):
                    prompt = PromptInfo(title: "Rename Notebook", label: "Notebook name", text: n.name, confirm: "Rename") { [weak self] in
                        self?.rename(section: n, to: $0)
                    }
                }
            },
            recolor: { [weak self] item, hex in
                guard let self else { return }
                do {
                    switch item {
                    case .folder(let f): try Core.run("set_notebook_color", ["path": f.path, "color": hex])
                    case .notebook(let n): try Core.run("set_section_color", ["path": n.path, "color": hex])
                    }
                    reloadTree()
                } catch {
                    show(error, title: "Could not change the colour")
                }
            },
            setCover: { [weak self] notebook, choice in
                guard let self else { return }
                do {
                    try Core.run("set_section_cover", ["path": notebook.path, "cover": choice])
                    reloadTree()
                } catch {
                    show(error, title: "Could not change the cover")
                }
            },
            delete: { [weak self] item in
                guard let self else { return }
                switch item {
                case .folder(let f):
                    trash(notebook: f)
                    if homeFolderPath == f.path { homeFolderPath = nil }
                case .notebook(let n):
                    trash(section: n)
                }
                loadRecents()
            }
,
            folders: notebooks,
            move: { [weak self] in self?.move(section: $0, to: $1) }
        )
    }

    func promptNewFolder() {
        prompt = PromptInfo(title: "New Folder", label: "Folder name", text: "New Folder", confirm: "Create") { [weak self] in
            self?.newNotebook(named: $0)
        }
    }

    /// A new notebook (Scribe section) in `folder`, else the current one.
    func promptNewNotebook(in folder: NotebookInfo? = nil) {
        guard let folder = folder
            ?? section(at: selectedSectionPath).flatMap({ notebook(containing: $0) })
            ?? notebooks.first
        else { return promptNewFolder() }
        prompt = PromptInfo(title: "New Notebook in \(folder.name)", label: "Notebook name", text: "New Notebook", confirm: "Create") { [weak self] in
            self?.newSection(in: folder, named: $0)
        }
    }

    // ------------------------------------------------------------ page grid

    func togglePageGrid() {
        if showingPageGrid {
            showingPageGrid = false
            return
        }
        commitOpenPage()
        reloadPages()
        focusMode = false
        showingPageGrid = true
    }

    func openFromGrid(_ info: PageInfo) {
        showingPageGrid = false
        if page?.path != info.path { openPage(info.path) }
    }

    func toggleBookmark(_ info: PageInfo) {
        do {
            try Core.run("set_bookmarked", ["path": info.path, "bookmarked": !info.isBookmarked])
            reloadPages()
        } catch {
            show(error, title: "Could not star the page")
        }
    }

    /// Puts the section's pages in `paths` order, after a drag in the grid.
    func setPageOrder(_ paths: [String]) {
        guard let sec = selectedSectionPath else { return }
        let byPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
        pages = paths.compactMap { byPath[$0] }
        do {
            try Core.run("set_page_order", ["section": sec, "paths": paths])
        } catch {
            show(error, title: "Could not reorder pages")
        }
    }

    func promptRename(_ info: PageInfo) {
        prompt = PromptInfo(title: "Rename Page", label: "Page title", text: info.title, confirm: "Rename") { [weak self] in
            self?.renamePage(info, to: $0)
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

    /// Moves a notebook (section) into another folder; what was open in it
    /// stays open at its new place.
    func move(section: SectionInfo, to folder: NotebookInfo) {
        guard section.notebookPath != folder.path else { return }
        let openPath = page?.path
        let wasSelected = selectedSectionPath == section.path
        let inside = openPath.map { $0.hasPrefix(section.path + "/") } ?? false
        if inside { commitOpenPage(); closePage() }
        do {
            let newPath: String = try Core.call("move_section", ["root": root, "path": section.path, "notebook": folder.path])
            reloadTree()
            if wasSelected { selectSection(newPath, openFirst: false) }
            if inside, let openPath { openPage(newPath + openPath.dropFirst(section.path.count)) }
            if showingHome { loadRecents() }
        } catch {
            show(error, title: "Could not move the notebook")
        }
    }

    // ---------------------------------------------------- notebooks/sections

    func newNotebook(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let path: String = try Core.call("create_notebook", ["root": root, "name": name, "firstSection": "Notebook"])
            reloadTree()
            if showingHome { homeFolderPath = path; loadRecents() }
        } catch {
            show(error, title: "Could not create the folder")
        }
    }

    func newSection(in notebook: NotebookInfo, named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let path: String = try Core.call("create_section", ["notebook": notebook.path, "name": name])
            reloadTree()
            showingHome = false
            selectSection(path)
        } catch {
            show(error, title: "Could not create the notebook")
        }
    }

    func rename(notebook: NotebookInfo, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try Core.run("rename_notebook", ["path": notebook.path, "name": name])
            reloadTree()
        } catch {
            show(error, title: "Could not rename the folder")
        }
    }

    func rename(section: SectionInfo, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try Core.run("rename_section", ["path": section.path, "name": name])
            reloadTree()
        } catch {
            show(error, title: "Could not rename the notebook")
        }
    }

    func trash(notebook: NotebookInfo) {
        if let page, page.path.hasPrefix(notebook.path + "/") { closePage() }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: notebook.path), resultingItemURL: nil)
        } catch {
            show(error, title: "Could not delete the folder")
        }
        afterRemoval()
    }

    func trash(section: SectionInfo) {
        if let page, page.path.hasPrefix(section.path + "/") { closePage() }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: section.path), resultingItemURL: nil)
            try Core.run("forget_section", ["notebook": section.notebookPath, "section": section.path])
        } catch {
            show(error, title: "Could not delete the notebook")
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
        // New pages in this notebook follow.
        try? Core.run("set_section_paper", ["path": page.sectionPath, "kind": kind, "spacing": after.spacing])
    }

    func recolorSelection(_ hex: String) {
        page?.recolorSelection(hex)
    }

    // ------------------------------------------------------------- settings

    func saveSettings() {
        try? Core.run("save_settings", ["settings": (try? Core.json(settings)) ?? [:]])
    }

    public func willTerminate() {
        commitOpenPage()
        finishSaving()
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
    case oneNote

    var id: String {
        switch self {
        case .latex(let item): "latex-\(item?.dto.id ?? "new")"
        case .table: "table"
        case .oneNote: "onenote"
        }
    }
}
