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

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        backgroundColor = Velvet.backdrop

        scroll.delegate = self
        scroll.delaysContentTouches = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.indicatorStyle = .white
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 120, right: 0)
        addSubview(scroll)
        scroll.addSubview(page)

        page.input = self
        let pencil = UIPencilInteraction(delegate: self)
        addInteraction(pencil)

        store.inkChanged = { [weak self] area in self?.inkChanged(area) }
        configureGestures()
        reloadIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        if resized { fitZoom() }
    }

    /// Zoom limits from the page width: from the whole width on screen up to
    /// four times that.
    private func fitZoom() {
        guard bounds.width > 0, page.bounds.width > 0 else { return }
        let fit = (bounds.width - 24) / page.bounds.width
        let wasFit = abs(scroll.zoomScale - scroll.minimumZoomScale) < 0.001
        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = fit * 4
        if wasFit || scroll.zoomScale < fit { scroll.zoomScale = fit }
        centre()
    }

    private func centre() {
        let spare = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        scroll.contentInset.left = spare
        scroll.contentInset.right = spare
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        wetScale = scale * traitCollection.displayScale
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
            scroll.zoomScale = scroll.minimumZoomScale
            scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
        }
    }

    /// Fits the page view to the page, which grows as you write further down.
    private func resize() {
        let size = store.pageSize
        guard size != page.bounds.size else { return }
        let zoom = scroll.zoomScale
        let offset = scroll.contentOffset
        scroll.zoomScale = 1
        page.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        if scroll.minimumZoomScale == 1 && scroll.maximumZoomScale == 1 {
            fitZoom()
        } else {
            scroll.zoomScale = zoom
            scroll.contentOffset = offset
            fitZoom()
        }
    }

    // -------------------------------------------------------------- input

    private var active: UITouch?
    private var points: [Double] = []
    private var wet: CAShapeLayer?
    private var wetScale: CGFloat = 2
    private var erasedThisDrag = false
    private var eraserRadius: Double { 6 / max(Double(scroll.zoomScale), 0.5) }

    private func accepts(_ touch: UITouch) -> Bool {
        touch.type == .pencil || (store.fingerDraws && touch.type == .direct)
    }

    fileprivate func penBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, store.doc != nil, let touch = touches.first(where: accepts) else { return }
        if touch.type == .pencil, store.fingerDraws {
            // A Pencil is here: from now on fingers scroll.
            store.fingerDraws = false
            configureGestures()
        }
        active = touch
        erasedThisDrag = false
        points = []
        if store.tool.isInk {
            let layer = CAShapeLayer()
            layer.contentsScale = wetScale
            layer.fillRule = .nonZero
            layer.fillColor = InkPaint.color(hex: store.currentPen.color, highlighter: store.currentPen.highlighter)
            page.layer.addSublayer(layer)
            wet = layer
        }
        moved(touch, event)
    }

    fileprivate func penMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        moved(active, event)
    }

    fileprivate func penEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        moved(active, event)
        finish(commit: true)
    }

    fileprivate func penCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        finish(commit: false)
    }

    private func moved(_ touch: UITouch, _ event: UIEvent?) {
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for t in samples {
            let p = t.preciseLocation(in: page)
            if store.tool.isEraser {
                if store.erase(at: p, radius: eraserRadius, recordUndo: !erasedThisDrag) { erasedThisDrag = true }
            } else {
                points += [p.x, p.y, pressure(t)]
            }
        }
        guard let wet, points.count >= 3 else { return }
        let pen = store.currentPen
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wet.path = Core.outlinePath(points: points, width: pen.width, pressureSensitive: pen.pressureSensitive, fit: true, taper: false)
        CATransaction.commit()
    }

    /// Pencil force as 0…1, eased so a light hand still gets a usable line.
    /// Fingers have no pressure and write at half.
    private func pressure(_ t: UITouch) -> Double {
        guard t.type == .pencil, t.maximumPossibleForce > 0 else { return 0.5 }
        return pow(min(1, Double(t.force / t.maximumPossibleForce)), 0.75)
    }

    private func finish(commit: Bool) {
        active = nil
        if commit, store.tool.isInk, points.count >= 3 {
            // A tap leaves a dot.
            if points.count == 3 { points += [points[0] + 0.1, points[1], points[2]] }
            let pen = store.currentPen
            store.add(StrokeDTO(
                color: pen.color, width: pen.width, height: pen.width, tip: "ellipse",
                highlighter: pen.highlighter, fit: true, pressureSensitive: pen.pressureSensitive, points: points
            ))
        }
        points = []
        // The page tile draws the stroke a moment later; keep the wet copy
        // until then so it doesn't blink.
        if let wet {
            DispatchQueue.main.asyncAfter(deadline: .now() + (commit ? 0.35 : 0)) { wet.removeFromSuperlayer() }
        }
        wet = nil
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
        var ink: [Ink] = []
        var texts: [TextBoxDTO] = []
        var images: [(CGRect, UIImage)] = []
        var latex: [LatexDTO] = []
        var tables: [TableDTO] = []

        init() {}

        @MainActor
        init(store: Store) {
            guard let doc = store.doc else { return }
            let section = store.pageSectionPath
            background = doc.background
            pdf = PDFBackground.page(for: doc.background, sectionPath: section)
            ink = store.ink
            texts = doc.textBoxes
            latex = doc.latexBlocks
            tables = doc.tables
            images = doc.images.compactMap { dto in
                let path = (section as NSString).appendingPathComponent(dto.file)
                guard let image = UIImage(contentsOfFile: path) else { return nil }
                return (CGRect(x: dto.x, y: dto.y, width: dto.width, height: dto.height), image)
            }
        }
    }

    fileprivate weak var input: CanvasView?
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
        drawInk(c.ink.filter { $0.dto.highlighter }, in: rect, ctx)
        for (frame, image) in c.images where frame.intersects(rect) {
            image.draw(in: frame)
        }
        for table in c.tables { drawTable(table, ctx) }
        for box in c.texts { drawText(box) }
        for block in c.latex { drawLatex(block) }
        drawInk(c.ink.filter { !$0.dto.highlighter }, in: rect, ctx)
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
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { input?.penBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { input?.penMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { input?.penEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { input?.penCancelled(touches, with: event) }
}

/// A tiled layer without the fade-in, so new ink appears at once.
final class InstantTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}
