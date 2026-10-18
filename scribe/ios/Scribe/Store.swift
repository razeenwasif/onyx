import Observation
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
    private(set) var notebooks: [NotebookInfo] = []
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
        sectionPath = nil
        closePage()
    }

    private func open(_ url: URL) {
        root = url
        refresh()
        // Back to the page you were on, else the first section.
        if let rel = UserDefaults.standard.string(forKey: Self.lastPageKey) {
            let path = url.appendingPathComponent(rel).path
            if FileManager.default.fileExists(atPath: path) {
                sectionPath = (path as NSString).deletingLastPathComponent
                openPage(path)
            }
        }
        if sectionPath == nil { sectionPath = notebooks.first?.sections.first?.path }
        startPolling()
    }

    private static let lastPageKey = "lastPage"

    /// Notes `path` as the page to reopen next launch.
    private func remember(_ path: String) {
        guard let root, path.hasPrefix(root.path + "/") else { return }
        UserDefaults.standard.set(String(path.dropFirst(root.path.count + 1)), forKey: Self.lastPageKey)
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
        if list != pages { pages = list }
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
        let url = URL(fileURLWithPath: page.path)
        do {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                guard let root else { throw error }
                let bin = root.appendingPathComponent(".scribe/Recently Deleted", isDirectory: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent("\(stamp) \(url.lastPathComponent)"))
            }
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

    // ------------------------------------------- notebooks, sections, names

    /// A new section (a folder of pages) at the end of `notebook`, opened.
    func newSection(in notebook: NotebookInfo, named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let path: String = try Core.call("create_section", ["notebook": notebook.path, "name": name])
            refresh()
            sectionPath = path
        } catch {
            problem = "Could not create the section: \(error.localizedDescription)"
        }
    }

    func newNotebook(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !name.isEmpty else { return }
        do {
            _ = try Core.call("create_notebook", ["root": root.path, "name": name, "firstSection": "New Section"], as: String.self)
            refresh()
            sectionPath = notebooks.first { $0.name == name }?.sections.first?.path ?? sectionPath
        } catch {
            problem = "Could not create the notebook: \(error.localizedDescription)"
        }
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
        let area = hits.map { ink[$0].bounds }.reduce(CGRect.null) { $0.union($1) }
        for i in hits.reversed() { ink.remove(at: i) }
        inkChanged?(area)
        changed()
        return true
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
            let _: WriteResult = try Core.call("write_page", ["path": pagePath, "page": try Core.json(doc)])
            self.doc = doc
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
