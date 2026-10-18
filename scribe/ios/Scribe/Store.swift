import Observation
import PDFKit
import UIKit

/// One stroke ready to draw: its outline and colour are built once, on the
/// main thread, and never change, so the tiled page can draw it from any
/// thread.
struct Ink {
    let dto: StrokeDTO
    let path: CGPath
    let bounds: CGRect
    let color: CGColor

    init(_ dto: StrokeDTO) {
        self.dto = dto
        let nib = max(dto.width, dto.height)
        path = Core.outlinePath(points: dto.points, width: nib, pressureSensitive: dto.pressureSensitive, fit: dto.fit, taper: true)
        bounds = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
        color = InkPaint.color(hex: dto.color, highlighter: dto.highlighter)
    }
}

/// Everything the app shows: the notebook folder, its notebooks and pages,
/// and the page open for writing. Talks to the shared Rust core, which owns
/// the file format, exactly as the Mac app does.
@MainActor
@Observable
final class Store {
    private(set) var root: URL?
    /// Scribe's notebooks, which the library calls folders.
    private(set) var notebooks: [NotebookInfo] = []
    /// Pages edited most recently, for the library's Recent row.
    private(set) var recents: [PageInfo] = []
    /// Where you are: the library, then a folder, then a notebook's pages.
    var route: [Route] = []
    var sectionPath: String? {
        didSet { if sectionPath != oldValue { reloadPages() } }
    }
    private(set) var pages: [PageInfo] = []
    private(set) var pagePath: String?
    private(set) var doc: PageDoc?
    /// Files iCloud is still bringing down to this iPad.
    private(set) var downloading = 0
    var problem: String?

    var tool: ToolKind = .pen
    /// Bolder than the Mac's default: Pencil handwriting on the small
    /// screen reads better with a heavier line (ToolDock.penSizes' Medium).
    var pen = Pen(color: Pen.defaultPen.color, width: 3.4, pressureSensitive: true, highlighter: false)
    var highlighter = Pen.defaultHighlighter
    /// Off once an Apple Pencil is seen: then fingers only scroll and zoom.
    var fingerDraws: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()

    private(set) var canUndo = false
    private(set) var canRedo = false

    /// The open page's strokes. Not observed: the canvas is told directly
    /// through `inkChanged`, so writing never re-renders SwiftUI.
    @ObservationIgnored private(set) var ink: [Ink] = []
    /// Called with the area to redraw, or nil for the whole page.
    @ObservationIgnored var inkChanged: ((CGRect?) -> Void)?

    @ObservationIgnored private var undoStack: [[StrokeDTO]] = []
    @ObservationIgnored private var redoStack: [[StrokeDTO]] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    /// When the open page's file last changed on disk, as we know it.
    @ObservationIgnored private var pageStamp: Date?
    @ObservationIgnored private var poll: Task<Void, Never>?

    var currentPen: Pen { tool == .highlighter ? highlighter : pen }

    var section: SectionInfo? {
        notebooks.lazy.flatMap(\.sections).first { $0.path == sectionPath }
    }

    init() {
        #if targetEnvironment(simulator)
        // For trying the app on a copy of a notebook folder on the Mac:
        //   xcrun simctl launch booted app.scribe.ipad -ScribeTestRoot /path
        if let path = UserDefaults.standard.string(forKey: "ScribeTestRoot") {
            open(URL(fileURLWithPath: path))
            // And to try importing:  -ScribeTestImport /path/to/file.pdf
            if let pdf = UserDefaults.standard.string(forKey: "ScribeTestImport") {
                importPDFs([URL(fileURLWithPath: pdf)], into: notebooks.first)
            }
            return
        }
        #endif
        if let url = Library.restore() { open(url) }
    }

    // ------------------------------------------------------------- folder

    func choose(_ url: URL) {
        do {
            open(try Library.choose(url))
        } catch {
            problem = error.localizedDescription
        }
    }

    func forgetFolder() {
        flush()
        poll?.cancel()
        root?.stopAccessingSecurityScopedResource()
        Library.forget()
        root = nil
        notebooks = []
        recents = []
        tabs = []
        route = []
        sectionPath = nil
        closePage()
    }

    private func open(_ url: URL) {
        root = url
        refresh()
        restoreTabs()
        purgeRecentlyDeleted()
        // Read handwriting written since the index last caught up (on this
        // iPad or the Mac), a moment after starting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let root = self.root else { return }
            inkReader.backfill(root: root.path)
        }
        // Back to the page you were on; the back button leads to its folder
        // and then the library.
        if let rel = UserDefaults.standard.string(forKey: Self.lastPageKey) {
            let path = url.appendingPathComponent(rel).path
            if FileManager.default.fileExists(atPath: path) { show(pageAt: path) }
        }
        startPolling()
    }

    private static let lastPageKey = "lastPage"
    private static let lastInNotebookKey = "lastPageInNotebook"

    /// Notes `path` as the page to reopen next launch, and in its notebook.
    private func remember(_ path: String) {
        guard let rel = relative(path) else { return }
        UserDefaults.standard.set(rel, forKey: Self.lastPageKey)
        if let section = relative((path as NSString).deletingLastPathComponent) {
            var last = UserDefaults.standard.dictionary(forKey: Self.lastInNotebookKey) as? [String: String] ?? [:]
            last[section] = rel
            UserDefaults.standard.set(last, forKey: Self.lastInNotebookKey)
        }
    }

    private func relative(_ path: String) -> String? {
        guard let root, path.hasPrefix(root.path + "/") else { return nil }
        return String(path.dropFirst(root.path.count + 1))
    }

    // ------------------------------------------------------------- library

    enum Route: Hashable {
        case folder(String)
        case notebook(String)
    }

    func folder(at path: String) -> NotebookInfo? { notebooks.first { $0.path == path } }

    func notebook(at path: String) -> SectionInfo? { notebooks.lazy.flatMap(\.sections).first { $0.path == path } }

    func openFolder(_ folder: NotebookInfo) {
        route = [.folder(folder.path)]
    }

    /// Opens a notebook at the page you last had open in it, else its first
    /// page; an empty notebook gets one.
    func openNotebook(_ notebook: SectionInfo) {
        flush()
        showingGrid = false
        sectionPath = notebook.path
        let last = (UserDefaults.standard.dictionary(forKey: Self.lastInNotebookKey) as? [String: String])?[relative(notebook.path) ?? ""]
        if let last, let root, let page = pages.first(where: { $0.path == root.appendingPathComponent(last).path }) {
            openPage(page.path)
        } else if let first = pages.first {
            openPage(first.path)
        } else {
            newPage()
        }
        route = [.folder(notebook.notebookPath), .notebook(notebook.path)]
        scrollTarget = pagePath
        addTab(notebook.path)
    }

    func openRecent(_ page: PageInfo) {
        flush()
        showingGrid = false
        show(pageAt: page.path)
    }

    /// Opens the page at `path` with the library behind it.
    private func show(pageAt path: String) {
        let section = (path as NSString).deletingLastPathComponent
        sectionPath = section
        openPage(path)
        route = [.folder((section as NSString).deletingLastPathComponent), .notebook(section)]
        scrollTarget = path
        addTab(section)
    }

    /// Back out of a notebook: save, and leave the grid.
    func leftNotebook() {
        flush()
        showingGrid = false
    }

    /// Picks up changes made on the Mac: downloads new files, rereads the
    /// notebooks, and reloads the open page if it changed and has no unsaved
    /// writing.
    func refresh() {
        guard let root else { return }
        downloading = Library.requestDownloads(in: root)
        do {
            let tree: [NotebookInfo] = try Core.call("tree", ["root": root.path])
            if tree != notebooks { notebooks = tree }
            let recent: [PageInfo] = try Core.call("recent_pages", ["root": root.path, "limit": 10])
            if recent != recents { recents = recent }
        } catch {
            problem = error.localizedDescription
        }
        reloadPages()
        if let pagePath, !dirty, let stamp = Self.stamp(pagePath), stamp != pageStamp {
            openPage(pagePath)
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                self?.refresh()
            }
        }
    }

    private func reloadPages() {
        guard let sectionPath else { pages = []; return }
        let list = (try? Core.call("pages", ["section": sectionPath], as: [PageInfo].self)) ?? []
        guard list != pages else { return }
        // Pages added, moved or removed, or changed on another device: the
        // continuous canvas lays them out again. Saving the page you're
        // writing on doesn't count.
        let old = Dictionary(pages.map { ($0.path, $0.modified) }, uniquingKeysWith: { a, _ in a })
        let moved = list.map(\.path) != pages.map(\.path)
        let changedElsewhere = list.contains { $0.path != pagePath && old[$0.path] != $0.modified }
        pages = list
        if moved || changedElsewhere { layoutVersion += 1 }
    }

    // ------------------------------------------------- continuous writing

    /// Scroll through all of a notebook's pages (true), or one page at a
    /// time with pull-to-turn (false).
    var continuous: Bool = UserDefaults.standard.object(forKey: "continuousPages") as? Bool ?? true {
        didSet { UserDefaults.standard.set(continuous, forKey: "continuousPages") }
    }

    /// Bumped whenever the notebook's pages change, for the canvas.
    private(set) var layoutVersion = 0

    /// A page the canvas should scroll to (opened from the grid, a new page).
    var scrollTarget: String?

    struct PageLayout: Decodable {
        var path: String
        var pageId: String
        var background: BackgroundDTO
        var contentWidth: Double
        var contentHeight: Double
        var blank: Bool
    }

    /// Every page of the open notebook, in order, with what laying them out needs.
    func pageLayouts() -> [PageLayout] {
        guard let section = pagePath.map({ ($0 as NSString).deletingLastPathComponent }) ?? sectionPath else { return [] }
        return (try? Core.call("page_layouts", ["section": section], as: [PageLayout].self)) ?? []
    }

    /// A page's size as paper: the standard page or its PDF, grown only to
    /// fit what is already on it (the same rule as `pageSize`).
    func size(of layout: PageLayout) -> CGSize {
        let section = (layout.path as NSString).deletingLastPathComponent
        var size = PDFBackground.standardSize
        if let pdf = PDFBackground.page(for: layout.background, sectionPath: section) { size = PDFBackground.size(of: pdf) }
        return CGSize(width: max(size.width, ceil(layout.contentWidth + 24)), height: max(size.height, ceil(layout.contentHeight + 24)))
    }

    /// What a page that isn't the one being edited looks like.
    func content(of path: String) -> PageView.Content? {
        if path == pagePath { return PageView.Content(store: self) }
        guard let doc = try? Core.call("read_page", ["path": path], as: PageDoc.self) else { return nil }
        let ink = doc.strokes.filter { $0.points.count >= 3 }.map(Ink.init)
        return PageView.Content(doc: doc, sectionPath: (path as NSString).deletingLastPathComponent, ink: ink)
    }

    /// Makes the page at `path` the one being written on, after saving the
    /// last one; the view stays where it is.
    func activate(_ path: String) {
        guard path != pagePath else { return }
        openPage(path)
    }

    /// Whether the last page has anything on it, so a new one may follow.
    func canAddAfter(_ layouts: [PageLayout]) -> Bool {
        guard let last = layouts.last else { return true }
        if last.path == pagePath { return !pageIsBlank }
        return !last.blank
    }

    // --------------------------------------------------------------- tabs

    /// Notebooks open as tabs above the page, by section path.
    private(set) var tabs: [String] = []

    private func addTab(_ section: String) {
        if !tabs.contains(section) {
            tabs.append(section)
            if tabs.count > 8 { tabs.removeFirst() }
        }
        saveTabs()
    }

    /// Closes a notebook's tab; closing the one you're in moves to its
    /// neighbour, or back to its folder when it was the last.
    func closeTab(_ section: String) {
        guard let i = tabs.firstIndex(of: section) else { return }
        tabs.remove(at: i)
        saveTabs()
        guard section == pageSectionPath else { return }
        if !tabs.isEmpty, let next = notebook(at: tabs[min(i, tabs.count - 1)]) {
            openNotebook(next)
        } else {
            leftNotebook()
            route = route.filter { if case .notebook = $0 { false } else { true } }
        }
    }

    private func saveTabs() {
        UserDefaults.standard.set(tabs.compactMap(relative), forKey: "openNotebooks")
    }

    private func restoreTabs() {
        guard let root else { return }
        let saved = UserDefaults.standard.stringArray(forKey: "openNotebooks") ?? []
        tabs = saved.map { root.appendingPathComponent($0).path }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    // --------------------------------------------------------------- pages

    func openPage(_ path: String) {
        if path != pagePath { flush() }
        do {
            let loaded: PageDoc = try Core.call("read_page", ["path": path])
            if path != pagePath {
                undoStack = []
                redoStack = []
                updateUndo()
            }
            pagePath = path
            doc = loaded
            remember(path)
            pageStamp = Self.stamp(path)
            selection = []
            hasSelection = false
            ink = loaded.strokes.filter { $0.points.count >= 3 }.map(Ink.init)
            measurePage()
            inkChanged?(nil)
        } catch {
            problem = error.localizedDescription
        }
    }

    func closePage() {
        flush()
        pagePath = nil
        doc = nil
        ink = []
    }

    func newPage() {
        guard let sectionPath else { return }
        do {
            let path: String = try Core.call("create_page", ["section": sectionPath, "title": "Untitled page"])
            reloadPages()
            openPage(path)
            scrollTarget = path
        } catch {
            problem = error.localizedDescription
        }
    }

    // ----------------------------------------------------------- page grid

    /// The section's pages as thumbnails, in place of the open page.
    var showingGrid = false

    var rootPath: String { root?.path ?? "" }

    func toggleGrid() {
        if showingGrid {
            showingGrid = false
            return
        }
        flush()
        // The grid shows the open page's own section.
        if pagePath != nil, sectionPath != pageSectionPath { sectionPath = pageSectionPath } else { reloadPages() }
        showingGrid = true
    }

    func openFromGrid(_ page: PageInfo) {
        showingGrid = false
        if page.path != pagePath { openPage(page.path) }
        scrollTarget = page.path
    }

    func toggleStar(_ page: PageInfo) {
        do {
            try Core.run("set_bookmarked", ["path": page.path, "bookmarked": !page.isBookmarked])
            reloadPages()
        } catch {
            problem = "Could not star the page: \(error.localizedDescription)"
        }
    }

    /// Puts the section's pages in `paths` order, after a drag in the grid.
    func setPageOrder(_ paths: [String]) {
        guard let sectionPath else { return }
        let byPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
        pages = paths.compactMap { byPath[$0] }
        do {
            try Core.run("set_page_order", ["section": sectionPath, "paths": paths])
        } catch {
            problem = "Could not reorder pages: \(error.localizedDescription)"
        }
    }

    /// Deletes a page to Recently Deleted (iCloud Drive's, in the Files app),
    /// or, where the system has no bin for the folder, to the workspace's own
    /// `.scribe/Recently Deleted` folder.
    func deletePage(_ page: PageInfo) {
        let wasOpen = page.path == pagePath
        let index = pages.firstIndex(of: page)
        if wasOpen { flush() }
        do {
            try discard(page.path)
            try Core.run("forget_page", ["section": page.sectionPath, "path": page.path])
        } catch {
            problem = "Could not delete the page: \(error.localizedDescription)"
        }
        refresh()
        guard wasOpen else { return }
        if let index, !pages.isEmpty {
            openPage(pages[min(index, pages.count - 1)].path)
        } else {
            closePage()
        }
    }

    // ------------------------------------------------------ recently deleted

    @ObservationIgnored let inkReader = InkReader()

    /// Something deleted on the iPad, kept for 30 days in the workspace's
    /// `.scribe/Recently Deleted/<when>/<where it was>`, so it can go back.
    struct DeletedItem: Identifiable {
        var url: URL
        var original: String
        var deleted: Date
        var id: String { url.path }
        var name: String { ((original as NSString).lastPathComponent as NSString).deletingPathExtension }
        var kind: String {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.appendingPathComponent("notebook.json").path) { return "Folder" }
            if fm.fileExists(atPath: url.appendingPathComponent("section.json").path) { return "Notebook" }
            return "Page"
        }
        /// The folder and notebook it was in.
        var place: String { (original as NSString).deletingLastPathComponent }
    }

    private var binURL: URL? { root?.appendingPathComponent(".scribe/Recently Deleted", isDirectory: true) }
    private static let binStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return f
    }()

    /// Moves a page, notebook or folder to Recently Deleted.
    private func discard(_ path: String) throws {
        guard let bin = binURL, let rel = relative(path) else { throw Core.Failure(message: "It isn't in the library folder.") }
        let target = bin.appendingPathComponent(Self.binStamp.string(from: Date())).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: target)
    }

    func recentlyDeleted() -> [DeletedItem] {
        guard let bin = binURL, let batches = try? FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil) else { return [] }
        var items: [DeletedItem] = []
        for batch in batches {
            guard let when = Self.binStamp.date(from: batch.lastPathComponent) else { continue }
            // The deleted thing is the deepest single path under the batch.
            var url = batch
            var parts: [String] = []
            while let inside = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter({ !$0.lastPathComponent.hasPrefix(".") }),
                  inside.count == 1, parts.count < 3 {
                url = inside[0]
                parts.append(url.lastPathComponent)
                if url.pathExtension == "json" || FileManager.default.fileExists(atPath: url.appendingPathComponent("section.json").path)
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("notebook.json").path) { break }
            }
            guard !parts.isEmpty else { continue }
            items.append(DeletedItem(url: url, original: parts.joined(separator: "/"), deleted: when))
        }
        return items.sorted { $0.deleted > $1.deleted }
    }

    /// Puts it back where it was (beside anything that has taken its name).
    func restore(_ item: DeletedItem) {
        guard let root else { return }
        var target = root.appendingPathComponent(item.original)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            let ext = target.pathExtension
            let stem = target.deletingPathExtension().lastPathComponent
            target = target.deletingLastPathComponent().appendingPathComponent(stem + " (restored)" + (ext.isEmpty ? "" : "." + ext))
        }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: item.url, to: target)
            removeEmptyBatch(of: item)
        } catch {
            problem = "Could not restore it: \(error.localizedDescription)"
        }
        refresh()
    }

    func deleteForever(_ item: DeletedItem) {
        try? FileManager.default.removeItem(at: item.url)
        removeEmptyBatch(of: item)
    }

    private func removeEmptyBatch(of item: DeletedItem) {
        guard let bin = binURL else { return }
        var dir = item.url.deletingLastPathComponent()
        while dir.path.hasPrefix(bin.path + "/"),
              (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Anything deleted more than 30 days ago goes for good.
    private func purgeRecentlyDeleted() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for item in recentlyDeleted() where item.deleted < cutoff { deleteForever(item) }
    }

    // ---------------------------------------------------------- search, PDFs

    /// Pages whose title, typed text or handwriting matches.
    func search(_ query: String) -> [PageInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let root, !q.isEmpty else { return [] }
        return (try? Core.call("search", ["root": root.path, "query": q], as: [PageInfo].self)) ?? []
    }

    /// The import in progress, for the import popup.
    var importing: ImportProgress?

    /// Imports PDFs (and Goodnotes exports) into `folder`: each becomes a
    /// notebook with one page per PDF page, written on top of the PDF, the
    /// same layout the Mac makes. Runs in the background; `importing`
    /// follows it.
    func importPDFs(_ urls: [URL], into folder: NotebookInfo?) {
        guard let root, !urls.isEmpty, importing == nil else { return }
        let progress = ImportProgress()
        importing = progress
        Task {
            var target = folder?.path ?? notebooks.first?.path
            if target == nil {
                target = try? Core.call("create_notebook", ["root": root.path, "name": "Imported"], as: String.self)
            }
            guard let target else {
                progress.phase = .failed("Could not make a folder to import into.")
                return
            }
            await PDFImportJob.run(urls, into: target, progress: progress)
            refresh()
            route = [.folder(target)]
            inkReader.backfill(root: root.path)
        }
    }

    // ----------------------------------------- folders, notebooks, names
    // (A "folder" is a Scribe notebook; a "notebook" is a Scribe section.)

    /// A new notebook at the end of `folder`, opened on its first page.
    func newNotebook(in folder: NotebookInfo, named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let path: String = try Core.call("create_section", ["notebook": folder.path, "name": name])
            refresh()
            if let created = notebook(at: path) { openNotebook(created) }
        } catch {
            problem = "Could not create the notebook: \(error.localizedDescription)"
        }
    }

    /// A new folder holding one empty notebook, opened.
    func newFolder(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !name.isEmpty else { return }
        do {
            let path: String = try Core.call("create_notebook", ["root": root.path, "name": name, "firstSection": "Notebook"])
            refresh()
            route = [.folder(path)]
        } catch {
            problem = "Could not create the folder: \(error.localizedDescription)"
        }
    }

    func rename(_ item: LibraryItem, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            switch item {
            case .folder(let f): try Core.run("rename_notebook", ["path": f.path, "name": name])
            case .notebook(let n): try Core.run("rename_section", ["path": n.path, "name": name])
            }
            refresh()
        } catch {
            problem = "Could not rename it: \(error.localizedDescription)"
        }
    }

    func recolor(_ item: LibraryItem, _ hex: String) {
        do {
            switch item {
            case .folder(let f): try Core.run("set_notebook_color", ["path": f.path, "color": hex])
            case .notebook(let n): try Core.run("set_section_color", ["path": n.path, "color": hex])
            }
            refresh()
        } catch {
            problem = "Could not change the colour: \(error.localizedDescription)"
        }
    }

    func setCover(_ notebook: SectionInfo, _ choice: String) {
        do {
            try Core.run("set_section_cover", ["path": notebook.path, "cover": choice])
            refresh()
        } catch {
            problem = "Could not change the cover: \(error.localizedDescription)"
        }
    }

    func delete(_ item: LibraryItem) {
        let path: String
        switch item {
        case .folder(let f): path = f.path
        case .notebook(let n): path = n.path
        }
        // Closing what's being deleted first.
        if let pagePath, pagePath.hasPrefix(path + "/") {
            flush()
            closePage()
            route = []
        }
        do {
            try discard(path)
            if case .notebook(let n) = item {
                try Core.run("forget_section", ["notebook": n.notebookPath, "section": n.path])
            }
        } catch {
            problem = "Could not delete it: \(error.localizedDescription)"
        }
        if sectionPath?.hasPrefix(path) == true { sectionPath = nil }
        tabs.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        saveTabs()
        if case .folder = item { route.removeAll { $0 == .folder(path) } }
        refresh()
    }

    /// Retitles a page. Its file is renamed to match, as on the Mac.
    func renamePage(_ path: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let section = (path as NSString).deletingLastPathComponent
        do {
            if path == pagePath {
                flush()
            }
            var page: PageDoc = try Core.call("read_page", ["path": path])
            guard page.title != title else { return }
            page.title = title
            let _: WriteResult = try Core.call("write_page", ["path": path, "page": try Core.json(page)])
            let moved: String = try Core.call("rename_page", ["section": section, "path": path, "title": title])
            if path == pagePath {
                // Same page under its new name; keep its undo history.
                pagePath = moved
                doc?.title = title
                pageStamp = Self.stamp(moved)
                remember(moved)
            }
            reloadPages()
        } catch {
            problem = "Could not rename the page: \(error.localizedDescription)"
        }
    }

    // Pulling past the end of a page turns to the next (see CanvasView).

    private var pageIndex: Int? { pages.firstIndex { $0.path == pagePath } }

    var hasPreviousPage: Bool { (pageIndex ?? 0) > 0 }
    var hasNextPage: Bool { pageIndex.map { $0 + 1 < pages.count } ?? false }

    /// Nothing written, typed or placed: no point adding another page after it.
    var pageIsBlank: Bool {
        guard let doc else { return true }
        return ink.isEmpty && doc.textBoxes.isEmpty && doc.images.isEmpty && doc.tables.isEmpty
            && doc.latexBlocks.isEmpty && doc.background.kind.lowercased() != "pdf"
    }

    /// Whether pulling past the bottom does anything on this page.
    var canTurnForward: Bool { hasNextPage || !pageIsBlank }

    /// The next page in the section, or a fresh one after the last.
    func turnForward() {
        flush()
        reloadPages()
        if let i = pageIndex, i + 1 < pages.count {
            openPage(pages[i + 1].path)
        } else if !pageIsBlank {
            newPage()
        }
    }

    func turnBack() {
        flush()
        reloadPages()
        if let i = pageIndex, i > 0 { openPage(pages[i - 1].path) }
    }

    /// The page's section folder, where its images and PDF live.
    var pageSectionPath: String {
        pagePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
    }

    /// The page as paper: the standard size (or the PDF's), stretched only
    /// to fit what is already on it, such as writing that grew the page on
    /// the Mac. Set when the page opens and fixed while you write, so ink
    /// near an edge never resizes or re-zooms the page; for more room, pull
    /// past the end for a new page.
    private(set) var pageSize = PDFBackground.standardSize

    private func measurePage() {
        var extent = CGRect(origin: .zero, size: PDFBackground.standardSize)
        if let doc, let pdf = PDFBackground.page(for: doc.background, sectionPath: pageSectionPath) {
            extent = CGRect(origin: .zero, size: PDFBackground.size(of: pdf))
        }
        for s in ink { extent = extent.union(s.bounds.insetBy(dx: -24, dy: -24)) }
        for t in doc?.textBoxes ?? [] {
            extent = extent.union(CGRect(x: t.x, y: t.y, width: t.width, height: t.height ?? 40))
        }
        for i in doc?.images ?? [] { extent = extent.union(CGRect(x: i.x, y: i.y, width: i.width, height: i.height)) }
        pageSize = CGSize(width: ceil(extent.maxX), height: ceil(extent.maxY))
    }

    // ----------------------------------------------------------------- ink

    func add(_ stroke: StrokeDTO) {
        let item = Ink(stroke)
        record()
        ink.append(item)
        inkChanged?(item.bounds)
        changed()
    }

    /// Removes the strokes under `point` (page units). True when any went.
    @discardableResult
    func erase(at point: CGPoint, radius: Double, recordUndo: Bool) -> Bool {
        let hits = ink.indices.filter {
            ink[$0].bounds.insetBy(dx: -radius, dy: -radius).contains(point)
                && Core.strokeHit(points: ink[$0].dto.points, width: max(ink[$0].dto.width, ink[$0].dto.height), at: point, radius: radius)
        }
        guard !hits.isEmpty else { return false }
        if recordUndo { record() }
        selection = []
        hasSelection = false
        let area = hits.map { ink[$0].bounds }.reduce(CGRect.null) { $0.union($1) }
        for i in hits.reversed() { ink.remove(at: i) }
        inkChanged?(area)
        changed()
        return true
    }

    // ---------------------------------------------------------------- paper

    var paperKind: String { doc?.background.kind.lowercased() ?? "ruled" }
    var paperSpacing: Double { doc?.background.spacing ?? 32 }
    var pageIsPDF: Bool { paperKind == "pdf" }

    /// Changes the open page's paper; new pages in the notebook follow it.
    func setPaper(kind: String? = nil, spacing: Double? = nil) {
        guard var page = doc, !pageIsPDF else { return }
        if let kind { page.background.kind = kind }
        if let spacing { page.background.spacing = spacing }
        doc = page
        inkChanged?(nil)
        changed()
        try? Core.run("set_section_paper", ["path": pageSectionPath, "kind": page.background.kind, "spacing": page.background.spacing])
    }

    // ------------------------------------------------------------ selection

    /// Strokes picked with the lasso, by index into `ink`.
    @ObservationIgnored private(set) var selection: Set<Int> = []
    /// Whether anything is selected, for the dock.
    private(set) var hasSelection = false

    var selectionBounds: CGRect? {
        guard !selection.isEmpty else { return nil }
        return selection.map { ink[$0].bounds }.reduce(CGRect.null) { $0.union($1) }
    }

    /// Selects the strokes mostly inside `lasso` (flat x, y pairs in page
    /// units), the same rule as the Mac.
    func select(lasso: [Double]) {
        selection = Set(ink.indices.filter { Core.lassoFraction(lasso: lasso, points: ink[$0].dto.points) >= 0.6 })
        hasSelection = !selection.isEmpty
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
        hasSelection = false
        inkChanged?(nil)
    }

    /// Moves the selected strokes; `first` marks the start of one drag.
    func moveSelection(dx: Double, dy: Double, first: Bool) {
        guard !selection.isEmpty, dx != 0 || dy != 0 else { return }
        if first { record() }
        var area = CGRect.null
        for i in selection {
            area = area.union(ink[i].bounds)
            var dto = ink[i].dto
            for j in stride(from: 0, to: dto.points.count - 2, by: 3) {
                dto.points[j] += dx
                dto.points[j + 1] += dy
            }
            ink[i] = Ink(dto)
            area = area.union(ink[i].bounds)
        }
        inkChanged?(area.insetBy(dx: -4, dy: -4))
        changed()
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        record()
        let area = selectionBounds ?? .null
        for i in selection.sorted(by: >) { ink.remove(at: i) }
        selection = []
        hasSelection = false
        inkChanged?(area)
        changed()
    }

    func recolorSelection(_ hex: String) {
        guard !selection.isEmpty else { return }
        record()
        for i in selection where !ink[i].dto.highlighter {
            var dto = ink[i].dto
            dto.color = hex
            ink[i] = Ink(dto)
        }
        inkChanged?(selectionBounds)
        changed()
    }

    /// Marks the start of one undoable change (a stroke, or one eraser drag).
    func record() {
        undoStack.append(ink.map(\.dto))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        updateUndo()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(ink.map(\.dto))
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(ink.map(\.dto))
        restore(next)
    }

    private func restore(_ strokes: [StrokeDTO]) {
        selection = []
        hasSelection = false
        ink = strokes.map(Ink.init)
        inkChanged?(nil)
        updateUndo()
        changed()
    }

    private func updateUndo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // ---------------------------------------------------------------- save

    /// Saves a moment after writing pauses, so the Mac sees it soon.
    private func changed() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the open page now if it has unsaved changes.
    func flush() {
        saveTask?.cancel()
        guard dirty, let pagePath, var doc else { return }
        doc.strokes = ink.map(\.dto)
        do {
            let result: WriteResult = try Core.call("write_page", ["path": pagePath, "page": try Core.json(doc)])
            self.doc = doc
            if let root {
                inkReader.pageSaved(doc, modified: result.modifiedUnix, root: root.path, sectionPath: pageSectionPath)
            }
            pageStamp = Self.stamp(pagePath)
            dirty = false
            reloadPages()
        } catch {
            problem = "Could not save: \(error.localizedDescription)"
        }
    }

    private static func stamp(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// How ink looks on the dark page: the stored colour adapted for dark mode
/// (black ink shows as warm cream), highlighters see-through. Same rule as
/// the Mac app (InkPaint in Theme.swift).
enum InkPaint {
    static func color(hex: String, highlighter: Bool) -> CGColor {
        var rgba = Core.adapt(Core.parseColor(hex), dark: true)
        if highlighter {
            rgba = (rgba & 0xFFFF_FF00) | UInt32(Core.highlighterAlpha(dark: true))
        }
        return UIColor(rgba: rgba).cgColor
    }
}

extension UIColor {
    convenience init(rgba: UInt32) {
        self.init(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }

    convenience init(hex: String) {
        self.init(rgba: Core.parseColor(hex))
    }
}
