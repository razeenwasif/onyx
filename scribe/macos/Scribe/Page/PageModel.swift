import AppKit
import Observation

/// Editing state of the open page.
///
/// Edits are registered with the window's `UndoManager` as paired actions
/// rather than page snapshots: a page of dense handwriting is megabytes of
/// stroke data, and snapshotting every pen lift would cost far more memory
/// than the edits themselves. Typing in a text box uses the same undo manager,
/// so ⌘Z walks back through ink and text in the order they happened.
@Observable
final class PageModel {
    /// A portrait sheet (A4 proportions) that sits whole and centred in the
    /// main pane beside the open panels.
    static let defaultSize = CGSize(width: 840, height: 1188)

    /// Blank space kept below the lowest content, so there is always room to
    /// keep writing.
    static let growthMargin: CGFloat = 600

    /// Room kept right of the widest content. Smaller than below: the page
    /// widens as you write towards its edge rather than starting out wide.
    static let sideMargin: CGFloat = 120

    private(set) var path: String
    let sectionPath: String

    var title: String
    var background: BackgroundDTO
    /// Fields of the loaded document that are not edited here.
    @ObservationIgnored private var base: PageDoc

    @ObservationIgnored private(set) var strokes: [InkStroke]
    var textBoxes: [TextBoxItem]
    var images: [ImageItem]
    var latexBlocks: [LatexItem]
    var tables: [TableItem]

    var selectedStrokes: Set<ObjectIdentifier> = []
    var selectedObjects: Set<String> = []

    /// Set to make a freshly placed text box take the caret.
    var focusRequest: String?

    private(set) var pageSize: CGSize = PageModel.defaultSize

    @ObservationIgnored weak var undoManager: UndoManager?

    /// Called on every content change; the app debounces it into a save.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Asks the ink view to repaint, optionally just one region.
    @ObservationIgnored var onInkInvalidated: ((CGRect?) -> Void)?

    init(path: String, sectionPath: String, doc: PageDoc) {
        self.path = path
        self.sectionPath = sectionPath
        self.base = doc
        self.title = doc.title
        self.background = doc.background
        self.strokes = doc.strokes.filter { $0.points.count >= 3 }.map(InkStroke.init)
        self.textBoxes = doc.textBoxes.map(TextBoxItem.init)
        self.images = doc.images.map { ImageItem($0, sectionPath: sectionPath) }
        self.latexBlocks = doc.latexBlocks.map(LatexItem.init)
        self.tables = doc.tables.map(TableItem.init)
        recomputeSize()
    }

    func moved(to newPath: String) { path = newPath }

    var createdStamp: String? { base.created }

    func toDoc() -> PageDoc {
        var doc = base
        doc.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled page" : title
        doc.background = background
        doc.strokes = strokes.map(\.dto)
        doc.textBoxes = textBoxes.map(\.dto).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        doc.images = images.map(\.dto)
        doc.latexBlocks = latexBlocks.map(\.dto).filter { !$0.latex.trimmingCharacters(in: .whitespaces).isEmpty }
        doc.tables = tables.map(\.dto).filter { !$0.rows.isEmpty }
        return doc
    }

    var allObjects: [PageObject] { textBoxes as [PageObject] + images + latexBlocks + tables }

    func object(id: String) -> PageObject? { allObjects.first { $0.objectID == id } }

    // ----------------------------------------------------------- change flow

    /// Records that content changed without an undo step (text typing, which
    /// the text view's own undo covers).
    func contentChanged(region: CGRect? = nil) {
        recomputeSize()
        onInkInvalidated?(region)
        onChange?()
    }

    private func registerUndo(_ name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        if let um = undoManager {
            um.registerUndo(withTarget: self) { model in
                undo()
                model.registerUndo(name, undo: redo, redo: undo)
            }
            um.setActionName(name)
        }
        contentChanged()
    }

    /// Applies an edit and makes it undoable.
    func perform(_ name: String, _ apply: @escaping () -> Void, undo: @escaping () -> Void) {
        apply()
        registerUndo(name, undo: undo, redo: apply)
    }

    func clearUndo() {
        undoManager?.removeAllActions(withTarget: self)
    }

    // ------------------------------------------------------------------- ink

    func addStroke(_ dto: StrokeDTO) {
        let stroke = InkStroke(dto)
        perform("Write", { [self] in
            strokes.append(stroke)
            onInkInvalidated?(stroke.bounds)
        }, undo: { [self] in
            strokes.removeAll { $0 === stroke }
            onInkInvalidated?(stroke.bounds)
        })
    }

    /// Replaces the stroke list in one step, e.g. at the end of an erase.
    func commitStrokes(from before: [InkStroke], to after: [InkStroke], name: String) {
        registerUndo(name, undo: { [self] in
            strokes = before
            onInkInvalidated?(nil)
        }, redo: { [self] in
            strokes = after
            onInkInvalidated?(nil)
        })
    }

    /// Live edit during a gesture; the caller commits an undo step at the end.
    func setStrokesLive(_ list: [InkStroke]) {
        strokes = list
    }

    // --------------------------------------------------------------- objects

    func addTextBox(at point: CGPoint, text: String = "", width: Double = 360, focus: Bool = true) {
        let item = TextBoxItem(TextBoxDTO(x: max(0, point.x), y: max(0, point.y), width: width, text: text))
        perform("Add Text", { [self] in textBoxes.append(item) },
                undo: { [self] in textBoxes.removeAll { $0 === item } })
        if focus { focusRequest = item.dto.id }
    }

    func addImage(_ dto: ImageDTO) {
        let item = ImageItem(dto, sectionPath: sectionPath)
        perform("Add Image", { [self] in images.append(item) },
                undo: { [self] in images.removeAll { $0 === item } })
    }

    func addLatex(_ dto: LatexDTO) {
        let item = LatexItem(dto)
        perform("Add Equation", { [self] in latexBlocks.append(item) },
                undo: { [self] in latexBlocks.removeAll { $0 === item } })
    }

    func addTable(_ dto: TableDTO) {
        let item = TableItem(dto)
        perform("Add Table", { [self] in tables.append(item) },
                undo: { [self] in tables.removeAll { $0 === item } })
    }

    /// Adds a batch of content as one undo step and selects it, as a paste.
    func insert(strokes newStrokes: [StrokeDTO], textBoxes t: [TextBoxItem], images i: [ImageItem],
                latex l: [LatexItem], tables tb: [TableItem], name: String) {
        let before = captureLists()
        let added = newStrokes.map(InkStroke.init)
        strokes += added
        textBoxes += t
        images += i
        latexBlocks += l
        tables += tb
        let after = captureLists()
        registerUndo(name, undo: { [self] in restoreLists(before) }, redo: { [self] in restoreLists(after) })
        selectedStrokes = Set(added.map(ObjectIdentifier.init))
        selectedObjects = Set((t as [PageObject] + i + l + tb).map(\.objectID))
        onInkInvalidated?(nil)
    }

    func removeObject(id: String) {
        let lists = captureLists()
        removeObjectsLive([id])
        let after = captureLists()
        registerUndo("Delete", undo: { [self] in restoreLists(lists) },
                     redo: { [self] in restoreLists(after) })
    }

    /// Drops a text box that lost focus with nothing in it.
    func discardIfEmpty(_ item: TextBoxItem) {
        guard item.dto.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        textBoxes.removeAll { $0 === item }
        contentChanged()
    }

    private func removeObjectsLive(_ ids: Set<String>) {
        textBoxes.removeAll { ids.contains($0.dto.id) }
        images.removeAll { ids.contains($0.dto.id) }
        latexBlocks.removeAll { ids.contains($0.dto.id) }
        tables.removeAll { ids.contains($0.dto.id) }
    }

    /// Moves an object from `from` to its current origin as one undo step.
    func commitMove(of object: PageObject, from: CGPoint) {
        let to = object.origin
        guard to != from else { return }
        registerUndo("Move", undo: { object.origin = from }, redo: { object.origin = to })
    }

    /// Commits an in-place edit of an object's data, given before and after.
    func commitEdit<T: PageObject>(_ object: T, name: String, before: @escaping (T) -> Void, after: @escaping (T) -> Void) {
        registerUndo(name, undo: { before(object) }, redo: { after(object) })
    }

    // ------------------------------------------------------------- selection

    var hasSelection: Bool { !selectedStrokes.isEmpty || !selectedObjects.isEmpty }

    func clearSelection() {
        guard hasSelection else { return }
        selectedStrokes = []
        selectedObjects = []
        onInkInvalidated?(nil)
    }

    var selectedStrokeList: [InkStroke] { strokes.filter { selectedStrokes.contains(ObjectIdentifier($0)) } }
    var selectedObjectList: [PageObject] { allObjects.filter { selectedObjects.contains($0.objectID) } }

    var selectionBounds: CGRect? {
        let rects = selectedStrokeList.map(\.bounds) + selectedObjectList.map(\.frame)
        guard var r = rects.first else { return nil }
        for x in rects.dropFirst() { r = r.union(x) }
        return r
    }

    func select(lasso: [Double]) {
        selectedStrokes = Set(strokes.filter { Core.lassoFraction(lasso: lasso, points: $0.dto.points) >= 0.6 }
            .map(ObjectIdentifier.init))
        selectedObjects = Set(allObjects.filter { obj in
            let f = obj.frame
            let corners = [f.origin, CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY),
                           CGPoint(x: f.midX, y: f.midY)]
            return corners.filter { Core.pointInPolygon(lasso, $0) }.count >= 3
        }.map(\.objectID))
        onInkInvalidated?(nil)
    }

    func deleteSelection() {
        guard hasSelection else { return }
        let lists = captureLists()
        let ids = selectedObjects
        let gone = selectedStrokes
        strokes.removeAll { gone.contains(ObjectIdentifier($0)) }
        removeObjectsLive(ids)
        let after = captureLists()
        selectedStrokes = []
        selectedObjects = []
        registerUndo("Delete", undo: { [self] in restoreLists(lists) },
                     redo: { [self] in restoreLists(after) })
    }

    /// Geometry of the selection, so a move or resize can be undone exactly.
    struct GeometrySnapshot {
        var strokes: [(InkStroke, StrokeDTO)]
        var objects: [(PageObject, CGRect)]
    }

    func captureSelectionGeometry() -> GeometrySnapshot {
        GeometrySnapshot(
            strokes: selectedStrokeList.map { ($0, $0.dto) },
            objects: selectedObjectList.map { ($0, $0.frame) }
        )
    }

    func restore(_ g: GeometrySnapshot) {
        for (s, dto) in g.strokes { s.dto = dto }
        for (o, frame) in g.objects { apply(frame: frame, to: o) }
        onInkInvalidated?(nil)
    }

    /// Moves the selection live from its snapshot by (dx, dy).
    func translateSelection(from g: GeometrySnapshot, dx: Double, dy: Double) {
        for (s, dto) in g.strokes {
            s.dto = dto
            s.dto = s.translated(dx: dx, dy: dy)
        }
        for (o, frame) in g.objects { o.origin = CGPoint(x: frame.minX + dx, y: frame.minY + dy) }
        onInkInvalidated?(nil)
    }

    /// Scales the selection live from its snapshot about `anchor`.
    func scaleSelection(from g: GeometrySnapshot, anchor: CGPoint, sx: Double, sy: Double) {
        for (s, dto) in g.strokes {
            s.dto = dto
            s.dto = s.scaled(from: anchor, sx: sx, sy: sy)
        }
        for (o, f) in g.objects {
            let frame = CGRect(
                x: anchor.x + (f.minX - anchor.x) * sx,
                y: anchor.y + (f.minY - anchor.y) * sy,
                width: f.width * sx,
                height: f.height * sy
            )
            apply(frame: frame, to: o)
        }
        onInkInvalidated?(nil)
    }

    /// Recolours the selected ink (highlighters keep theirs) as one step.
    func recolorSelection(_ hex: String) {
        guard !selectedStrokes.isEmpty else { return }
        let before = captureSelectionGeometry()
        for s in selectedStrokeList where !s.dto.highlighter { s.dto.color = hex }
        commitGeometry(from: before, name: "Recolour")
    }

    /// Where the selection's action pill floats, just above the selection.
    var selectionPillFrame: CGRect? {
        guard hasSelection, let b = selectionBounds else { return nil }
        return CGRect(x: max(0, b.minX), y: max(0, b.minY - 66), width: 430, height: 46)
    }

    func commitGeometry(from before: GeometrySnapshot, name: String) {
        let after = captureSelectionGeometry()
        registerUndo(name, undo: { [self] in restore(before) }, redo: { [self] in restore(after) })
    }

    private func apply(frame: CGRect, to o: PageObject) {
        o.origin = frame.origin
        switch o {
        case let img as ImageItem:
            img.dto.width = max(8, frame.width)
            img.dto.height = max(8, frame.height)
        case let tb as TextBoxItem:
            tb.dto.width = max(60, frame.width)
        default:
            break
        }
    }

    private struct Lists {
        var strokes: [InkStroke]
        var textBoxes: [TextBoxItem]
        var images: [ImageItem]
        var latex: [LatexItem]
        var tables: [TableItem]
    }

    private func captureLists() -> Lists {
        Lists(strokes: strokes, textBoxes: textBoxes, images: images, latex: latexBlocks, tables: tables)
    }

    private func restoreLists(_ l: Lists) {
        strokes = l.strokes
        textBoxes = l.textBoxes
        images = l.images
        latexBlocks = l.latex
        tables = l.tables
        selectedStrokes = []
        selectedObjects = []
        onInkInvalidated?(nil)
    }

    // ------------------------------------------------------------------ size

    /// The page grows downward and rightward with content and never shrinks
    /// while open, so the view does not jump under the pen.
    func recomputeSize() {
        var extent = CGRect(origin: .zero, size: Self.defaultSize)
        for s in strokes { extent = extent.union(s.bounds.insetBy(dx: -Self.sideMargin, dy: -Self.growthMargin)) }
        for o in allObjects { extent = extent.union(o.frame.insetBy(dx: -Self.sideMargin, dy: -Self.growthMargin)) }

        let size = CGSize(width: max(pageSize.width, ceil(extent.maxX)), height: max(pageSize.height, ceil(extent.maxY)))
        if size != pageSize { pageSize = size }
    }
}
