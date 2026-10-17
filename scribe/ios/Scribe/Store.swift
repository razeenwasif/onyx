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
    var pen = Pen.defaultPen
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
            if let root, path.hasPrefix(root.path + "/") {
                UserDefaults.standard.set(String(path.dropFirst(root.path.count + 1)), forKey: Self.lastPageKey)
            }
            pageStamp = Self.stamp(path)
            ink = loaded.strokes.filter { $0.points.count >= 3 }.map(Ink.init)
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

    /// The page's section folder, where its images and PDF live.
    var pageSectionPath: String {
        pagePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
    }

    /// The drawable size: the standard page, grown to fit its PDF and
    /// everything on it, with room below to keep writing.
    var pageSize: CGSize {
        var extent = CGRect(origin: .zero, size: PDFBackground.standardSize)
        if let doc, let pdf = PDFBackground.page(for: doc.background, sectionPath: pageSectionPath) {
            extent = extent.union(CGRect(origin: .zero, size: PDFBackground.size(of: pdf)))
        }
        for s in ink { extent = extent.union(s.bounds.insetBy(dx: -120, dy: -600)) }
        for t in doc?.textBoxes ?? [] {
            extent = extent.union(CGRect(x: t.x, y: t.y + 600, width: t.width, height: 1))
        }
        return CGSize(width: max(extent.maxX, PDFBackground.standardSize.width), height: ceil(extent.maxY))
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
