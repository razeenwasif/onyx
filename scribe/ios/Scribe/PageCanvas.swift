import PDFKit
import SwiftUI
import UIKit

/// The open page, for writing on. SwiftUI only says which page and how
/// input works; strokes reach the canvas straight from the store.
struct PageCanvas: UIViewRepresentable {
    let store: Store
    /// Not read here; passing them makes SwiftUI update the canvas when they change.
    let pageID: String?
    let fingerDraws: Bool

    func makeUIView(context: Context) -> CanvasView {
        CanvasView(store: store)
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        view.configureGestures()
        view.reloadIfNeeded()
    }
}

/// A scroll view holding the page. Fingers scroll and pinch; the Apple
/// Pencil writes (and fingers too, when finger drawing is on, in which case
/// scrolling takes two fingers).
final class CanvasView: UIView, UIScrollViewDelegate, UIPencilInteractionDelegate {
    private let store: Store
    private let scroll = UIScrollView()
    private let page = PageView()
    private var shownPageID: String?
    private let pen: PenInput
    private var undoTaps: UndoTaps?

    init(store: Store) {
        self.store = store
        pen = PenInput(store: store)
        super.init(frame: .zero)
        backgroundColor = Velvet.backdrop

        scroll.delegate = self
        scroll.delaysContentTouches = false
        scroll.showsHorizontalScrollIndicator = true
        scroll.isDirectionalLockEnabled = true
        scroll.indicatorStyle = .white
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 120, right: 0)
        addSubview(scroll)
        scroll.addSubview(page)
        scroll.alwaysBounceVertical = true
        addSubview(topHint)
        addSubview(bottomHint)

        page.pen = pen
        pen.zoom = { [weak self] in self?.scroll.zoomScale ?? 1 }
        pen.pencilSeen = { [weak self] in self?.configureGestures() }
        pen.activePage = { [weak self] in self?.page }
        undoTaps = UndoTaps(store: store, on: scroll)
        let pencil = UIPencilInteraction(delegate: self)
        addInteraction(pencil)

        store.inkChanged = { [weak self] area in self?.inkChanged(area) }
        configureGestures()
        reloadIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Once in the window the navigation controller can be found.
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            blockSwipeBack(true)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { blockSwipeBack(false) }
    }

    func configureGestures() {
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.panGestureRecognizer.allowedTouchTypes = fingers
        scroll.pinchGestureRecognizer?.allowedTouchTypes = fingers
        scroll.panGestureRecognizer.minimumNumberOfTouches = store.fingerDraws ? 2 : 1
    }

    // ------------------------------------------------------------- layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = scroll.frame.size != bounds.size
        scroll.frame = bounds
        topHint.center = CGPoint(x: bounds.midX, y: safeAreaInsets.top + 34)
        // Above the tool dock.
        bottomHint.center = CGPoint(x: bounds.midX, y: bounds.maxY - safeAreaInsets.bottom - 110)
        if resized { fitZoom() }
    }

    /// Zoom limits from the page width: from the whole width on screen up to
    /// four times that.
    private func fitZoom() {
        guard bounds.width > 0, page.bounds.width > 0 else { return }
        // A standard page's width fills the screen; wider canvas pages
        // scroll sideways, and pinching out shows their whole width.
        let whole = (bounds.width - 24) / page.bounds.width
        let readable = (bounds.width - 24) / min(page.bounds.width, PDFBackground.standardSize.width)
        scroll.minimumZoomScale = whole
        scroll.maximumZoomScale = readable * 4
        if followsFit || scroll.zoomScale < whole { scroll.zoomScale = readable }
        centre()
    }

    private func centre() {
        let spare = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        scroll.contentInset.left = spare
        scroll.contentInset.right = spare
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    // ------------------------------------------------------- turning pages

    /// How far past the end of the page a pull must go to turn it.
    private let turnDistance: CGFloat = 110
    private let topHint = HintPill()
    private let bottomHint = HintPill()
    private var armed: (top: Bool, bottom: Bool) = (false, false)

    /// Past the top of the page (positive), or past the bottom.
    private var overscroll: (top: CGFloat, bottom: CGFloat) {
        let y = scroll.contentOffset.y
        let top = -scroll.contentInset.top - y
        let maxY = scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height
        let bottom = y - max(maxY, -scroll.contentInset.top)
        return (top, bottom)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scroll.isDragging, store.doc != nil else {
            if !scroll.isDragging { hideHints() }
            return
        }
        let (top, bottom) = overscroll
        let back = store.hasPreviousPage
        let forward = store.canTurnForward
        topHint.show(back ? (top >= turnDistance ? "Release for previous page" : "Pull for previous page") : nil,
                     progress: top / turnDistance)
        let forwardText = store.hasNextPage ? "next page" : "a new page"
        bottomHint.show(forward ? (bottom >= turnDistance ? "Release for \(forwardText)" : "Pull for \(forwardText)") : nil,
                        progress: bottom / turnDistance)

        // A tick as the pull passes the point of no return.
        let nowArmed = (back && top >= turnDistance, forward && bottom >= turnDistance)
        if (nowArmed.0 && !armed.top) || (nowArmed.1 && !armed.bottom) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        armed = nowArmed
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let turn = armed
        armed = (false, false)
        hideHints()
        guard turn.top || turn.bottom else { return }
        // After the gesture lets go, so the new page starts from rest.
        DispatchQueue.main.async { [store] in
            if turn.bottom { store.turnForward() } else { store.turnBack() }
        }
    }

    private func hideHints() {
        topHint.show(nil, progress: 0)
        bottomHint.show(nil, progress: 0)
    }

    /// Whether the page keeps fitting the width (when the sidebar opens or
    /// the iPad turns), which stops once you zoom in yourself.
    private var followsFit = true

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let readable = (bounds.width - 24) / min(max(page.bounds.width, 1), PDFBackground.standardSize.width)
        followsFit = abs(scale - readable) <= readable * 0.01
        pen.wetScale = scale * traitCollection.displayScale
    }

    // ------------------------------------------------------------ content

    /// Shows the store's page if it isn't the one on screen.
    func reloadIfNeeded() {
        guard store.doc?.id != shownPageID else { return }
        inkChanged(nil)
    }

    /// Redraws `area` of the page after the ink changed, or everything when
    /// nil (another page, or this one reloaded from disk).
    private func inkChanged(_ area: CGRect?) {
        redraw(area)
        pen.refreshSelection()
    }

    private func redraw(_ area: CGRect?) {
        if let area {
            page.update { $0.ink = store.ink }
            resize()
            page.setNeedsDisplay(area)
            return
        }
        let first = shownPageID != store.doc?.id
        shownPageID = store.doc?.id
        page.isHidden = store.doc == nil
        page.update { $0 = PageView.Content(store: store) }
        resize()
        page.setNeedsDisplay()
        if first {
            followsFit = true
            fitZoom()
            scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
        }
    }

    /// Fits the page view to the page, keeping the zoom: the page view is
    /// sized in page units and the scroll view's zoom scales it.
    private func resize() {
        let size = store.pageSize
        guard size != page.bounds.size else { return }
        let zoom = scroll.zoomScale
        page.bounds = CGRect(origin: .zero, size: size)
        page.center = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)
        scroll.contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
        fitZoom()
    }

    /// Double-tap on the Pencil: swap between the eraser and the pen.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        store.tool = store.tool.isEraser ? .pen : .strokeEraser
    }
}

/// The paper. A tiled layer, so it stays sharp at any zoom without holding
/// one giant bitmap; tiles draw on background threads from an immutable
/// copy of the page.
final class PageView: UIView {
    struct Content {
        var background = BackgroundDTO()
        var pdf: PDFPage?
        var ink: [Ink] = [] {
            didSet { splitInk() }
        }
        /// `ink` split once into highlighter (drawn under text) and pen
        /// (over it), rather than filtered again for every tile.
        private(set) var highlights: [Ink] = []
        private(set) var pens: [Ink] = []
        var texts: [TextBoxDTO] = []
        var images: [(CGRect, UIImage)] = []
        var latex: [LatexDTO] = []
        var tables: [TableDTO] = []

        init() {}

        @MainActor
        init(store: Store) {
            guard let doc = store.doc else {
                self.init()
                return
            }
            self.init(doc: doc, sectionPath: store.pageSectionPath, ink: store.ink)
        }

        init(doc: PageDoc, sectionPath section: String, ink: [Ink]) {
            background = doc.background
            pdf = PDFBackground.page(for: doc.background, sectionPath: section)
            self.ink = ink
            splitInk()
            texts = doc.textBoxes
            latex = doc.latexBlocks
            tables = doc.tables
            images = doc.images.compactMap { dto in
                let path = (section as NSString).appendingPathComponent(dto.file)
                guard let image = UIImage(contentsOfFile: path) else { return nil }
                return (CGRect(x: dto.x, y: dto.y, width: dto.width, height: dto.height), image)
            }
        }

        private mutating func splitInk() {
            highlights = ink.filter { $0.dto.highlighter }
            pens = ink.filter { !$0.dto.highlighter }
        }
    }

    weak var pen: PenInput?
    /// The page file shown, in the continuous canvas.
    var path: String?
    private let lock = NSLock()
    private var content = Content()

    override class var layerClass: AnyClass { InstantTiledLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tiled = layer as! InstantTiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 3
        tiled.tileSize = CGSize(width: 512, height: 512)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What the view shows now.
    var currentContent: Content? {
        lock.lock()
        defer { lock.unlock() }
        return content
    }

    func update(_ change: (inout Content) -> Void) {
        lock.lock()
        change(&content)
        lock.unlock()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        lock.lock()
        let c = content
        lock.unlock()

        ctx.setFillColor(Velvet.page.cgColor)
        ctx.fill(rect)
        drawBackground(c, in: rect, ctx)

        // Highlighter goes under the text and pictures, as on paper, so
        // highlighted words stay readable; pen ink goes on top.
        drawInk(c.highlights, in: rect, ctx)
        for (frame, image) in c.images where frame.intersects(rect) {
            image.draw(in: frame)
        }
        // Only what reaches this tile: laying out every text box on a big
        // imported page for each tile was much of the time drawing took.
        for table in c.tables where Self.frame(of: table).intersects(rect) { drawTable(table, ctx) }
        for box in c.texts where Self.frame(of: box).intersects(rect) { drawText(box) }
        for block in c.latex where CGRect(x: block.x, y: block.y - 10, width: 2000, height: block.scale * 4 + 40).intersects(rect) {
            drawLatex(block)
        }
        drawInk(c.pens, in: rect, ctx)
    }

    /// Generous bounds for a text box: its height if known, else enough for
    /// its lines, wrapped at its width.
    private static func frame(of box: TextBoxDTO) -> CGRect {
        let width: Double = max(box.width, 40)
        let perLine: Double = box.fontSize * 0.6 / width
        var lines: Double = 0
        for line in box.text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, ceil(Double(line.count) * perLine))
        }
        let height: Double = box.height ?? (lines * box.fontSize * 1.5)
        return CGRect(x: box.x - 8, y: box.y - 8, width: width + 16, height: max(height, lines * box.fontSize * 1.5) + 16)
    }

    private static func frame(of table: TableDTO) -> CGRect {
        let columns = table.rows.map(\.count).max() ?? 0
        var width: Double = 0
        for i in 0..<columns {
            if let widths = table.columnWidths, i < widths.count { width += widths[i] } else { width += 140 }
        }
        return CGRect(x: table.x - 4, y: table.y - 4, width: width + 8, height: Double(table.rows.count) * 30 + 8)
    }

    private func drawInk(_ ink: [Ink], in rect: CGRect, _ ctx: CGContext) {
        for s in ink where s.bounds.intersects(rect) {
            ctx.addPath(s.path)
            ctx.setFillColor(s.color)
            ctx.fillPath(using: .winding)
        }
    }

    private func drawBackground(_ c: Content, in rect: CGRect, _ ctx: CGContext) {
        let kind = c.background.kind.lowercased()
        if kind == "pdf" {
            if let pdf = c.pdf { PDFBackground.draw(pdf, in: ctx) }
            return
        }
        guard kind != "blank" else { return }
        let spacing = max(c.background.spacing, 4)
        let first = max(Int(floor(rect.minY / spacing)), 1)
        let last = max(Int(ceil(rect.maxY / spacing)), first)
        let firstX = max(Int(floor(rect.minX / spacing)), 1)
        let lastX = max(Int(ceil(rect.maxX / spacing)), firstX)

        ctx.setFillColor(Velvet.rule.cgColor)
        ctx.setStrokeColor(Velvet.rule.cgColor)
        ctx.setLineWidth(1)
        if kind == "dots" {
            for j in first...last {
                for i in firstX...lastX {
                    ctx.fillEllipse(in: CGRect(x: Double(i) * spacing - 1.1, y: Double(j) * spacing - 1.1, width: 2.2, height: 2.2))
                }
            }
            return
        }
        for j in first...last {
            let y = Double(j) * spacing
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        if kind == "grid" {
            for i in firstX...lastX {
                let x = Double(i) * spacing
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        }
        ctx.strokePath()
        if kind == "ruled" {
            // The margin rule, as on paper.
            let x = spacing * 3
            ctx.setStrokeColor(Velvet.marginRule.cgColor)
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            ctx.strokePath()
        }
    }

    private func drawText(_ box: TextBoxDTO) {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if box.bold || box.heading != nil { traits.insert(.traitBold) }
        if box.italic { traits.insert(.traitItalic) }
        let size = box.fontSize
        let base = UIFont.systemFont(ofSize: size)
        let font = base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? base
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(cgColor: InkPaint.color(hex: box.color, highlighter: false)),
        ]
        if box.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if box.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let frame = CGRect(x: box.x, y: box.y, width: box.width, height: box.height ?? 100_000)
        (box.text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
    }

    /// Formulas show as their source until the iPad can typeset them.
    private func drawLatex(_ block: LatexDTO) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: max(block.scale * 0.8, 10), weight: .regular),
            .foregroundColor: Velvet.muted,
        ]
        (block.latex as NSString).draw(at: CGPoint(x: block.x, y: block.y), withAttributes: attrs)
    }

    private func drawTable(_ table: TableDTO, _ ctx: CGContext) {
        let columns = table.rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let widths = (0..<columns).map { i in table.columnWidths.flatMap { i < $0.count ? $0[i] : nil } ?? 140 }
        let rowHeight = 30.0
        var y = table.y
        for (r, row) in table.rows.enumerated() {
            var x = table.x
            for (i, width) in widths.enumerated() {
                let cell = CGRect(x: x, y: y, width: width, height: rowHeight)
                ctx.setStrokeColor(Velvet.tableRule.cgColor)
                ctx.stroke(cell)
                let header = table.hasHeader && r == 0
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14, weight: header ? .semibold : .regular),
                    .foregroundColor: Velvet.text,
                ]
                let text = i < row.count ? row[i] : ""
                (text as NSString).draw(with: cell.insetBy(dx: 8, dy: 6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs, context: nil)
                x += width
            }
            y += rowHeight
        }
    }

    // Writing goes to the canvas; touches it doesn't want fall through to
    // the scroll view as usual.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { pen?.began(touches, with: event, on: self) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { pen?.moved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { pen?.ended(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { pen?.cancelled(touches, with: event) }
}

/// The small "Pull for a new page" label shown while pulling past an end.
final class HintPill: UILabel {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: 34))
        font = .systemFont(ofSize: 14, weight: .medium)
        textColor = Velvet.text
        textAlignment = .center
        backgroundColor = Velvet.control.withAlphaComponent(0.92)
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        alpha = 0
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ message: String?, progress: CGFloat) {
        guard let message, progress > 0.15 else {
            alpha = 0
            return
        }
        text = message
        alpha = min(1, (progress - 0.15) * 2)
        textColor = progress >= 1 ? Velvet.accent : Velvet.text
    }
}

/// A tiled layer without the fade-in, so new ink appears at once.
final class InstantTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}
