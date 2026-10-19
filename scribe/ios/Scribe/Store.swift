import Observation
import PDFKit
import UIKit
import UniformTypeIdentifiers

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
    /// Another page's file was rewritten (moving writing between pages, or
    /// undoing that), for a canvas that shows it.
    @ObservationIgnored var pageRewritten: ((String) -> Void)?

    @ObservationIgnored private var undoStack: [InkSnapshot] = []
    @ObservationIgnored private var redoStack: [InkSnapshot] = []
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
        refreshInBackground()
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
        // After the first frame: a big page takes a moment to read, and the
        // app has to be on screen quickly or iPadOS stops it.
        if let rel = UserDefaults.standard.string(forKey: Self.lastPageKey) {
            let path = url.appendingPathComponent(rel).path
            DispatchQueue.main.async { [weak self] in
                if FileManager.default.fileExists(atPath: path) { self?.show(pageAt: path) }
            }
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

    /// Opens the page at `path` with the library behind it (a link to it).
    func showPage(at path: String) {
        show(pageAt: path)
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

    /// Rereads the notebooks now, after a change made here. Cheap: the core
    /// caches what it knows about each page until the file changes.
    func refresh() {
        guard let root else { return }
        do {
            let tree: [NotebookInfo] = try Core.call("tree", ["root": root.path])
            if tree != notebooks { notebooks = tree }
            let recent: [PageInfo] = try Core.call("recent_pages", ["root": root.path, "limit": 10])
            if recent != recents { recents = recent }
        } catch {
            problem = error.localizedDescription
        }
        reloadPages()
    }

    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var lastDownloadSweep = Date.distantPast

    // ---------------------------------------------- links (see PageLinks)

    /// Every page with its id and the `[[…]]` typed on it, as last read.
    @ObservationIgnored var linkIndex: [LinkedPage] = []
    /// Hears the link index whenever it changes (AppHost hands it to Electron).
    @ObservationIgnored var onLinkIndex: (([LinkedPage]) -> Void)?
    /// The Electron notes that link to a page, by page id (AppHost).
    @ObservationIgnored var notesLinking: ((String) -> [LinkingNote])?
    /// Opens an Electron note, by vault path, and shows Electron (AppHost).
    @ObservationIgnored var openNote: ((String) -> Void)?
    /// An area of a page to show once the canvas has the page: a link to it.
    @ObservationIgnored var revealArea: (path: String, area: CGRect)?
    /// Bumped with each such area, so the one-page canvas hears of it.
    var revealVersion = 0

    /// Picks up changes made on the Mac, off the main thread: asks iCloud
    /// for new files (once a minute; walking the folder is slow), rereads
    /// the notebooks, and reloads the open page if it changed and has no
    /// unsaved writing. iCloud can make any of this block for a while, and
    /// on the main thread that froze the app until iPadOS killed it.
    func refreshInBackground() {
        guard let root, !refreshing else { return }
        refreshing = true
        let rootPath = root.path
        let section = sectionPath
        let open = pagePath
        let sweep = Date().timeIntervalSince(lastDownloadSweep) > 60
        if sweep { lastDownloadSweep = Date() }
        Task.detached(priority: .utility) { [weak self] in
            let downloading = sweep ? Library.requestDownloads(in: root) : nil
            let tree = Result { try Core.call("tree", ["root": rootPath], as: [NotebookInfo].self) }
            let recent = try? Core.call("recent_pages", ["root": rootPath, "limit": 10], as: [PageInfo].self)
            let pages = section.map { (try? Core.call("pages", ["section": $0], as: [PageInfo].self)) ?? [] }
            // Cheap once read: the core reopens only pages that changed.
            let links = try? Core.call("link_index", ["root": rootPath], as: [LinkedPage].self)
            let stamp = open.flatMap { Store.stamp($0) }
            await MainActor.run {
                guard let self else { return }
                self.refreshing = false
                guard self.root?.path == rootPath else { return }
                if let downloading { self.downloading = downloading }
                switch tree {
                case .success(let tree): if tree != self.notebooks { self.notebooks = tree }
                case .failure(let error): self.problem = error.localizedDescription
                }
                if let recent, recent != self.recents { self.recents = recent }
                if let links, links != self.linkIndex {
                    self.linkIndex = links
                    self.onLinkIndex?(links)
                }
                if let pages, section == self.sectionPath { self.apply(pages: pages) }
                if let open, open == self.pagePath, !self.dirty, let stamp, stamp != self.pageStamp {
                    self.openPage(open)
                }
            }
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                self?.refreshInBackground()
            }
        }
    }

    private func reloadPages() {
        guard let sectionPath else { pages = []; return }
        apply(pages: (try? Core.call("pages", ["section": sectionPath], as: [PageInfo].self)) ?? [])
    }

    private func apply(pages list: [PageInfo]) {
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
        var canvas: Bool?
    }

    /// Room a canvas page keeps beyond its content, so there's always space
    /// to carry on writing to the right and below.
    static let canvasRoom = CGSize(width: 400, height: 600)

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
        let room = layout.canvas == true ? Self.canvasRoom : CGSize(width: 24, height: 24)
        return CGSize(width: max(size.width, ceil(layout.contentWidth + room.width)),
                      height: max(size.height, ceil(layout.contentHeight + room.height)))
    }

    /// What a page that isn't the one being edited looks like.
    func content(of path: String) -> PageView.Content? {
        if path == pagePath { return PageView.Content(store: self) }
        guard let doc = try? Core.readPage(path) else { return nil }
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
    /// Pulling past the end always offers a new page, blank last page or
    /// not: you may want a few empty pages ready to write on.
    func canAddAfter(_ layouts: [PageLayout]) -> Bool { true }

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
        // A page left a moment ago may still be on its way to disk.
        finishSaving()
        do {
            let loaded: PageDoc = try Core.readPage(path)
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
            selectedObjects = []
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

    /// Adds `count` blank pages at the end of the notebook, staying where
    /// you are (the page grid).
    func addPages(_ count: Int) {
        guard let sectionPath, count > 0 else { return }
        flush()
        for _ in 0..<count {
            do {
                _ = try Core.call("create_page", ["section": sectionPath, "title": "Untitled page"], as: String.self)
            } catch {
                problem = error.localizedDescription
                break
            }
        }
        reloadPages()
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
        // A save on its way would otherwise put the file back.
        finishSaving()
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
        finishSaving()
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

    /// Moves a notebook into another folder. What was open in it stays
    /// open, and its tab and "where you were" follow it.
    func move(_ notebook: SectionInfo, to folder: NotebookInfo) {
        guard notebook.notebookPath != folder.path, let root else { return }
        flush()
        finishSaving()
        let old = notebook.path
        let newPath: String
        do {
            newPath = try Core.call("move_section", ["root": root.path, "path": old, "notebook": folder.path])
        } catch {
            problem = "Could not move it: \(error.localizedDescription)"
            return
        }
        func moved(_ path: String) -> String {
            if path == old { return newPath }
            if path.hasPrefix(old + "/") { return newPath + path.dropFirst(old.count) }
            return path
        }
        let openPath = pagePath
        if let current = sectionPath, current == old || current.hasPrefix(old + "/") { sectionPath = moved(current) }
        if let openPath, openPath.hasPrefix(old + "/") { openPage(moved(openPath)) }
        route = route.map { if case .notebook(let p) = $0 { .notebook(moved(p)) } else { $0 } }
        tabs = tabs.map(moved)
        saveTabs()
        // Reopen-where-you-were is kept by relative path.
        if let oldRel = relative(old), let newRel = relative(newPath) {
            func movedRel(_ r: String) -> String { r == oldRel ? newRel : r.hasPrefix(oldRel + "/") ? newRel + r.dropFirst(oldRel.count) : r }
            if let last = UserDefaults.standard.dictionary(forKey: Self.lastInNotebookKey) as? [String: String] {
                UserDefaults.standard.set(Dictionary(last.map { (movedRel($0.key), movedRel($0.value)) }, uniquingKeysWith: { a, _ in a }), forKey: Self.lastInNotebookKey)
            }
            if let lastPage = UserDefaults.standard.string(forKey: Self.lastPageKey) {
                UserDefaults.standard.set(movedRel(lastPage), forKey: Self.lastPageKey)
            }
        }
        refresh()
    }

    func delete(_ item: LibraryItem) {
        finishSaving()
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
        finishSaving()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let section = (path as NSString).deletingLastPathComponent
        do {
            if path == pagePath {
                flush()
            }
            var page: PageDoc = try Core.readPage(path)
            guard page.title != title else { return }
            page.title = title
            let _: WriteResult = try Core.writePage(path, page)
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
    var canTurnForward: Bool { true }

    /// The next page in the section, or a fresh one after the last.
    func turnForward() {
        flush()
        reloadPages()
        if let i = pageIndex, i + 1 < pages.count {
            openPage(pages[i + 1].path)
        } else {
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
        if doc?.isCanvas == true {
            // Canvas pages keep room to carry on writing (see canvasRoom).
            extent.size.width += Self.canvasRoom.width
            extent.size.height += Self.canvasRoom.height
        }
        pageSize = CGSize(width: ceil(extent.maxX), height: ceil(extent.maxY))
    }

    /// A canvas page grows once writing nears its right or bottom edge.
    private func growCanvas(for bounds: CGRect) {
        guard doc?.isCanvas == true else { return }
        let near = bounds.maxX > pageSize.width - Self.canvasRoom.width / 2
            || bounds.maxY > pageSize.height - Self.canvasRoom.height / 2
        guard near else { return }
        measurePage()
        // The continuous canvas sizes pages from the saved files.
        flush()
        layoutVersion += 1
    }

    // ----------------------------------------------------------------- ink

    func add(_ stroke: StrokeDTO) {
        let item = Ink(stroke)
        record()
        ink.append(item)
        inkChanged?(item.bounds)
        changed()
        growCanvas(for: item.bounds)
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
        selectedObjects = []
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
    /// Text boxes, pictures, equations and tables picked with the lasso, by id.
    @ObservationIgnored private(set) var selectedObjects: Set<String> = []
    /// Whether anything is selected, for the dock.
    private(set) var hasSelection = false

    private func selectionChanged() {
        hasSelection = !selection.isEmpty || !selectedObjects.isEmpty
    }

    /// The page's objects as they are now.
    var objects: PageObjects { PageObjects(doc: doc) }

    var selectionBounds: CGRect? {
        var r = CGRect.null
        for i in selection { r = r.union(ink[i].bounds) }
        if !selectedObjects.isEmpty {
            for (_, frame) in objects.only(selectedObjects).frames { r = r.union(frame) }
        }
        return r.isNull ? nil : r
    }

    /// Selects the strokes mostly inside `lasso` (flat x, y pairs in page
    /// units), and the objects with most of their corners and middle inside,
    /// the same rules as the Mac.
    func select(lasso: [Double]) {
        selection = Set(ink.indices.filter { Core.lassoFraction(lasso: lasso, points: ink[$0].dto.points) >= 0.6 })
        selectedObjects = Set(objects.frames.filter { _, f in
            let points = [f.origin, CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY),
                          CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.midX, y: f.midY)]
            return points.filter { Core.pointInPolygon(lasso, $0) }.count >= 3
        }.map(\.id))
        selectionChanged()
    }

    func clearSelection() {
        guard hasSelection || !selection.isEmpty || !selectedObjects.isEmpty else { return }
        selection = []
        selectedObjects = []
        selectionChanged()
        inkChanged?(nil)
    }

    /// Moves the selection; `first` marks the start of one drag.
    func moveSelection(dx: Double, dy: Double, first: Bool) {
        guard hasSelection, dx != 0 || dy != 0 else { return }
        if first { record() }
        var area = selectionBounds ?? .null
        for i in selection {
            var dto = ink[i].dto
            for j in stride(from: 0, to: dto.points.count - 2, by: 3) {
                dto.points[j] += dx
                dto.points[j + 1] += dy
            }
            ink[i] = Ink(dto)
        }
        if !selectedObjects.isEmpty, var page = doc {
            objects.translated(selectedObjects, dx: dx, dy: dy).apply(to: &page)
            doc = page
        }
        area = area.union(selectionBounds ?? .null)
        inkChanged?(selectedObjects.isEmpty ? area.insetBy(dx: -4, dy: -4) : nil)
        changed()
    }

    // -------------------------------------------- copy, cut, paste, move

    /// The selection is being dragged in a layer of its own (so it can
    /// cross onto another page); the page leaves it out until it lands.
    @ObservationIgnored private(set) var floating = false

    /// The ink the page shows: all of it, less a selection being dragged.
    var visibleInk: [Ink] {
        guard floating, !selection.isEmpty else { return ink }
        return ink.indices.filter { !selection.contains($0) }.map { ink[$0] }
    }

    /// The page as the page view shows it: less any objects being dragged.
    var visibleDoc: PageDoc? {
        guard floating, !selectedObjects.isEmpty, var page = doc else { return doc }
        objects.without(selectedObjects).apply(to: &page)
        return page
    }

    /// The selected strokes, for drawing them while they're dragged.
    var selectedInk: [Ink] { selection.sorted().map { ink[$0] } }

    /// The whole selection, ink and objects, drawn while it's dragged.
    var selectionContent: PageView.Content? {
        guard var page = doc, hasSelection else { return nil }
        objects.only(selectedObjects).apply(to: &page)
        return PageView.Content(doc: page, sectionPath: pageSectionPath, ink: selectedInk)
    }

    func liftSelection() {
        guard hasSelection, !floating else { return }
        floating = true
        inkChanged?(selectedObjects.isEmpty ? selectionBounds?.insetBy(dx: -4, dy: -4) : nil)
    }

    /// Lands a lifted selection on this page, moved by (dx, dy).
    func dropSelection(dx: Double, dy: Double) {
        guard floating else { return }
        floating = false
        if dx == 0 && dy == 0 {
            inkChanged?(nil)
        } else {
            moveSelection(dx: dx, dy: dy, first: true)
        }
    }

    /// Moves the selection onto the page at `path`, by (dx, dy) in that
    /// page's units, and makes it the page being written on with it still
    /// selected. One undo there puts it back on this page.
    func moveSelection(toPage path: String, dx: Double, dy: Double) {
        guard let source = pagePath, path != source, hasSelection else { return dropSelection(dx: 0, dy: 0) }
        floating = false
        let before = state
        let moving = selection.sorted().map { Self.translated(ink[$0].dto, dx: dx, dy: dy) }
        let movingObjects = objects.only(selectedObjects).translated(dx: dx, dy: dy)
        for i in selection.sorted(by: >) { ink.remove(at: i) }
        if var page = doc {
            objects.without(selectedObjects).apply(to: &page)
            doc = page
        }
        selection = []
        selectedObjects = []
        selectionChanged()
        dirty = true
        flush()
        openPage(path)
        guard pagePath == path else { return }
        record(other: (source, before))
        add(strokes: moving, objects: movingObjects)
        pageRewritten?(source)
    }

    /// Adds strokes and objects to the page, selected, as one change
    /// (already recorded for undo).
    private func add(strokes: [StrokeDTO], objects added: PageObjects) {
        let start = ink.count
        ink += strokes.map(Ink.init)
        selection = Set(start..<ink.count)
        if var page = doc {
            var all = objects
            all.textBoxes += added.textBoxes
            all.images += added.images
            all.latex += added.latex
            all.tables += added.tables
            all.apply(to: &page)
            doc = page
        }
        selectedObjects = Set(added.ids)
        selectionChanged()
        inkChanged?(nil)
        changed()
        if let area = selectionBounds { growCanvas(for: area) }
    }

    static let fragmentType = "app.scribe.fragment"

    /// A copied selection, in the Mac's format (AppModel.Fragment), so
    /// writing copied on one pastes on the other.
    struct Fragment: Codable {
        var sectionPath: String
        var strokes: [StrokeDTO]
        var textBoxes: [TextBoxDTO] = []
        var images: [ImageDTO] = []
        var latexBlocks: [LatexDTO] = []
        var tables: [TableDTO] = []
    }

    func copySelection() {
        guard hasSelection else { return }
        let picked = objects.only(selectedObjects)
        let fragment = Fragment(sectionPath: pageSectionPath, strokes: selectedInk.map(\.dto),
                                textBoxes: picked.textBoxes, images: picked.images,
                                latexBlocks: picked.latex, tables: picked.tables)
        guard let data = try? JSONEncoder().encode(fragment) else { return }
        var items: [String: Any] = [Self.fragmentType: data]
        // Typed text goes out as plain text too, for pasting elsewhere.
        let text = picked.textBoxes.map(\.text).joined(separator: "\n\n")
        if !text.isEmpty { items[UTType.utf8PlainText.identifier] = text }
        UIPasteboard.general.setItems([items])
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Whether there's copied writing to paste.
    var canPaste: Bool { UIPasteboard.general.contains(pasteboardTypes: [Self.fragmentType]) }

    /// Where pasted and inserted things land: the middle of what's on
    /// screen (page units), from the canvas.
    @ObservationIgnored var visibleCentre: (() -> CGPoint?)?

    /// Pastes copied writing (and objects) in the middle of the screen,
    /// selected, so it can be dragged into place.
    func paste() {
        guard doc != nil,
              let data = UIPasteboard.general.data(forPasteboardType: Self.fragmentType),
              let fragment = try? JSONDecoder().decode(Fragment.self, from: data) else { return }
        let strokes = fragment.strokes.filter { $0.points.count >= 3 }
        var pasted = PageObjects()
        pasted.textBoxes = fragment.textBoxes
        pasted.images = fragment.images
        pasted.latex = fragment.latexBlocks
        pasted.tables = fragment.tables
        pasted = pasted.withNewIDs()
        guard !strokes.isEmpty || !pasted.isEmpty else { return }
        // Pictures live beside their section's pages; bring them along.
        if fragment.sectionPath != pageSectionPath {
            for i in pasted.images.indices {
                let src = URL(fileURLWithPath: fragment.sectionPath).appendingPathComponent(pasted.images[i].file)
                if let slot = try? Core.call("new_asset", ["section": pageSectionPath, "ext": src.pathExtension], as: AssetSlot.self),
                   (try? FileManager.default.copyItem(at: src, to: URL(fileURLWithPath: slot.path))) != nil {
                    pasted.images[i].file = slot.rel
                }
            }
        }
        var bounds = strokes.map { Ink($0).bounds }.reduce(CGRect.null) { $0.union($1) }
        for (_, frame) in pasted.frames { bounds = bounds.union(frame) }
        let centre = visibleCentre?() ?? CGPoint(x: bounds.midX + 24, y: bounds.midY + 24)
        let dx = centre.x - bounds.midX, dy = centre.y - bounds.midY
        record()
        add(strokes: strokes.map { Self.translated($0, dx: dx, dy: dy) }, objects: pasted.translated(dx: dx, dy: dy))
        tool = .select
    }

    private static func translated(_ stroke: StrokeDTO, dx: Double, dy: Double) -> StrokeDTO {
        var s = stroke
        for j in stride(from: 0, to: s.points.count - 2, by: 3) {
            s.points[j] += dx
            s.points[j + 1] += dy
        }
        return s
    }

    func deleteSelection() {
        guard hasSelection else { return }
        record()
        for i in selection.sorted(by: >) { ink.remove(at: i) }
        if !selectedObjects.isEmpty, var page = doc {
            objects.without(selectedObjects).apply(to: &page)
            doc = page
        }
        selection = []
        selectedObjects = []
        selectionChanged()
        inkChanged?(nil)
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

    // ------------------------------------------- inserting and editing objects

    /// The text box, table or equation being written or edited, for its sheet.
    var editing: ObjectEditing?

    /// Where a new object goes: centred on the middle of the screen, or
    /// moved down below whatever it would cover (other objects and ink),
    /// so two inserts in a row don't land on top of each other.
    private func placement(width: Double, height: Double) -> CGPoint {
        let c = visibleCentre?() ?? CGPoint(x: 240, y: 240)
        var r = CGRect(x: max(8, c.x - width / 2), y: max(8, c.y - height / 2), width: width, height: height)
        let taken = objects.frames.map(\.frame) + ink.map(\.bounds)
        for _ in 0..<40 {
            guard let hit = taken.first(where: { $0.intersects(r.insetBy(dx: -6, dy: -6)) }) else { break }
            r.origin.y = hit.maxY + 16
        }
        return r.origin
    }

    /// Adds `added` to the page, selected with the lasso so it can be
    /// dragged into place.
    private func insert(_ added: PageObjects) {
        guard doc != nil else { return }
        record()
        add(strokes: [], objects: added)
        tool = .select
    }

    func insert(textBox: TextBoxDTO) {
        var box = textBox
        let at = placement(width: box.width, height: ObjectGeometry.frame(of: box).height)
        box.x = at.x; box.y = at.y
        var added = PageObjects()
        added.textBoxes = [box]
        insert(added)
    }

    func insert(table: TableDTO) {
        var t = table
        let frame = ObjectGeometry.frame(of: t)
        let at = placement(width: frame.width, height: frame.height)
        t.x = at.x; t.y = at.y
        var added = PageObjects()
        added.tables = [t]
        insert(added)
    }

    func insert(latex: LatexDTO) {
        var l = latex
        let frame = ObjectGeometry.frame(of: l, size: ObjectGeometry.latexSize(l))
        let at = placement(width: frame.width, height: frame.height)
        l.x = at.x; l.y = at.y
        var added = PageObjects()
        added.latex = [l]
        insert(added)
    }

    /// Saves a photo beside the section's pages and places it, at most
    /// 420 units wide.
    func insert(image: UIImage) {
        guard doc != nil, let data = image.jpegData(compressionQuality: 0.88) else { return }
        do {
            let slot: AssetSlot = try Core.call("new_asset", ["section": pageSectionPath, "ext": "jpg"])
            try data.write(to: URL(fileURLWithPath: slot.path), options: .atomic)
            let scale = min(1, 420 / max(image.size.width, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let at = placement(width: size.width, height: size.height)
            var added = PageObjects()
            added.images = [ImageDTO(x: at.x, y: at.y, width: size.width, height: size.height, file: slot.rel)]
            insert(added)
        } catch {
            problem = "Could not add the photo: \(error.localizedDescription)"
        }
    }

    private func replace(_ change: (inout PageObjects) -> Void) {
        guard var page = doc else { return }
        record()
        var all = objects
        change(&all)
        all.apply(to: &page)
        doc = page
        inkChanged?(nil)
        changed()
    }

    func update(textBox: TextBoxDTO) {
        replace { all in if let i = all.textBoxes.firstIndex(where: { $0.id == textBox.id }) { all.textBoxes[i] = textBox } }
    }

    func update(table: TableDTO) {
        replace { all in if let i = all.tables.firstIndex(where: { $0.id == table.id }) { all.tables[i] = table } }
    }

    func update(latex: LatexDTO) {
        replace { all in if let i = all.latex.firstIndex(where: { $0.id == latex.id }) { all.latex[i] = latex } }
    }

    func deleteObject(id: String) {
        selectedObjects.remove(id)
        selectionChanged()
        replace { all in all = all.without([id]) }
    }

    /// Opens the editor for the text box, table or equation at `point`
    /// (page units). True if there was one.
    @discardableResult
    func editObject(at point: CGPoint) -> Bool {
        let all = objects
        // The topmost: drawn last.
        for (id, frame) in all.frames.reversed() where frame.contains(point) {
            if let box = all.textBoxes.first(where: { $0.id == id }) {
                editing = .text(box, isNew: false)
            } else if let table = all.tables.first(where: { $0.id == id }) {
                editing = .table(table, isNew: false)
            } else if let block = all.latex.first(where: { $0.id == id }) {
                editing = .equation(block, isNew: false)
            } else {
                continue
            }
            return true
        }
        return false
    }

    // ---------------------------------------------------------------- undo

    /// A page's ink and objects.
    struct PageState {
        var ink: [StrokeDTO]
        var objects: PageObjects
    }

    var state: PageState { PageState(ink: ink.map(\.dto), objects: objects) }

    /// One undo step: the page before a change, and, when writing was moved
    /// here from another page, that page before too, so one undo puts it
    /// back where it was.
    struct InkSnapshot {
        var state: PageState
        var other: (path: String, state: PageState)?
    }

    /// Marks the start of one undoable change (a stroke, or one eraser drag).
    func record(other: (path: String, state: PageState)? = nil) {
        undoStack.append(InkSnapshot(state: state, other: other))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        updateUndo()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(InkSnapshot(state: state, other: last.other.map { ($0.path, stateOnDisk($0.path)) }))
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(InkSnapshot(state: state, other: next.other.map { ($0.path, stateOnDisk($0.path)) }))
        restore(next)
    }

    private func restore(_ snapshot: InkSnapshot) {
        selection = []
        selectedObjects = []
        selectionChanged()
        floating = false
        if let other = snapshot.other { writeState(other.state, to: other.path) }
        ink = snapshot.state.ink.map(Ink.init)
        if var page = doc {
            snapshot.state.objects.apply(to: &page)
            doc = page
        }
        inkChanged?(nil)
        updateUndo()
        changed()
    }

    /// Another page as saved.
    private func stateOnDisk(_ path: String) -> PageState {
        finishSaving()
        let other = try? Core.readPage(path)
        return PageState(ink: other?.strokes ?? [], objects: PageObjects(doc: other))
    }

    /// Replaces another page's ink and objects in its file.
    private func writeState(_ state: PageState, to path: String) {
        finishSaving()
        guard var other = try? Core.readPage(path) else { return }
        other.strokes = state.ink
        state.objects.apply(to: &other)
        do {
            try Core.writePage(path, other)
        } catch {
            problem = "Could not save: \(error.localizedDescription)"
        }
        pageRewritten?(path)
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
    /// Pages are written here, in order, off the main thread: saving a big
    /// page took long enough to make writing stutter.
    @ObservationIgnored private let saver = DispatchQueue(label: "app.scribe.ipad.save", qos: .userInitiated)

    func flush() {
        saveTask?.cancel()
        guard dirty, let pagePath, var doc else { return }
        doc.strokes = ink.map(\.dto)
        self.doc = doc
        dirty = false
        let root = self.root?.path
        let section = pageSectionPath
        saver.async { [weak self] in
            do {
                let result = try Core.writePage(pagePath, doc)
                let stamp = Store.stamp(pagePath)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let root { self.inkReader.pageSaved(doc, modified: result.modifiedUnix, root: root, sectionPath: section) }
                    if self.pagePath == pagePath { self.pageStamp = stamp }
                    self.reloadPages()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.pagePath == pagePath { self.dirty = true }
                    self.problem = "Could not save: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Waits for saves still being written: before a page file is renamed,
    /// moved or deleted, before reading one again, and when the app goes
    /// to the background.
    func finishSaving() {
        saver.sync {}
    }

    nonisolated private static func stamp(_ path: String) -> Date? {
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
