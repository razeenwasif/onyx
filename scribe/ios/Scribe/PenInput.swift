import UIKit

/// Writing with the Apple Pencil (or a finger, when finger drawing is on) on
/// a page view: the wet stroke while drawing, the eraser, and handing the
/// finished stroke to the store. Shared by the one-page canvas and the
/// continuous one; each tells it how zoomed in it is.
@MainActor
final class PenInput {
    private let store: Store
    /// The canvas's current zoom, for sizing the eraser.
    var zoom: () -> CGFloat = { 1 }
    /// A Pencil was used: the canvas should let fingers scroll again.
    var pencilSeen: () -> Void = {}
    /// About to write on `page`; the continuous canvas makes it the
    /// store's page. Return false to ignore the touch.
    var willWrite: (PageView) -> Bool = { _ in true }
    /// Wet strokes are drawn at this many pixels per page unit.
    var wetScale: CGFloat = 2
    /// The page view showing the store's page, for the selection outline.
    var activePage: () -> PageView? = { nil }
    /// A layer above every page, in the same units as the pages' frames,
    /// to drag a selection in so it can cross onto another page (the
    /// continuous canvas). Without one, a selection moves on its page.
    var floatHost: () -> CALayer? = { nil }
    /// A dragged selection was let go: the page it came from and how far
    /// it moved, in page units. The canvas lands it on the page under it.
    var dropSelection: ((PageView, Double, Double) -> Void)?

    /// With the lasso: drawing a loop, or dragging the selection.
    private enum Lasso { case drawing, moving }
    private var lasso: Lasso?
    private var lassoLayer: CAShapeLayer?
    private var lastPoint: CGPoint?
    private var firstMove = true
    /// A selection being dragged above the pages, and where the drag began.
    private var floating: FloatingInkLayer?
    private var dragStart: CGPoint?
    private let selectionLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = Velvet.accent.withAlphaComponent(0.07).cgColor
        layer.strokeColor = Velvet.accent.cgColor
        layer.lineDashPattern = [6, 5]
        return layer
    }()

    private var touch: UITouch?
    private weak var page: PageView?
    private var points: [Double] = []
    private var wet: CAShapeLayer?
    private var erasedThisDrag = false

    init(store: Store) {
        self.store = store
    }

    private var eraserRadius: Double { 6 / max(Double(zoom()), 0.5) }

    private func accepts(_ touch: UITouch) -> Bool {
        touch.type == .pencil || (store.fingerDraws && touch.type == .direct)
    }

    func began(_ touches: Set<UITouch>, with event: UIEvent?, on page: PageView) {
        guard touch == nil, let touch = touches.first(where: accepts), willWrite(page), store.doc != nil else { return }
        if touch.type == .pencil, store.fingerDraws {
            // A Pencil is here: from now on fingers scroll.
            store.fingerDraws = false
            pencilSeen()
        }
        self.touch = touch
        self.page = page
        erasedThisDrag = false
        points = []
        if store.tool == .select {
            beginLasso(at: touch.preciseLocation(in: page), on: page)
            return
        }
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

    func moved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        moved(touch, event)
    }

    func ended(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        moved(touch, event)
        finish(commit: true)
    }

    func cancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        finish(commit: false)
    }

    private func moved(_ touch: UITouch, _ event: UIEvent?) {
        guard let page else { return }
        if lasso != nil {
            lassoMoved(to: touch.preciseLocation(in: page))
            return
        }
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
        // Exactly as the finished stroke will be drawn (only the start
        // tapers), so nothing shifts when the Pencil lifts.
        wet.path = Core.outlinePath(points: points, width: pen.width, pressureSensitive: pen.pressureSensitive, fit: true, taper: true)
        CATransaction.commit()
    }

    /// Pencil force as 0…1. Everyday handwriting presses at only a fifth to
    /// a third of the Pencil's range, so the curve lifts it: a normal hand
    /// lands around 0.75, and pressing harder still swells the line.
    /// Fingers have no pressure and write at 0.75 too.
    private func pressure(_ t: UITouch) -> Double {
        guard t.type == .pencil, t.maximumPossibleForce > 0 else { return 0.75 }
        let force = min(1, Double(t.force / t.maximumPossibleForce))
        return min(1, 0.35 + 0.9 * pow(force, 0.6))
    }

    private func finish(commit: Bool) {
        touch = nil
        if lasso != nil {
            endLasso(commit: commit)
            page = nil
            return
        }
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
        page = nil
        // The page tile draws the stroke a moment later; keep the wet copy
        // until then so it doesn't blink.
        if let wet {
            DispatchQueue.main.asyncAfter(deadline: .now() + (commit ? 0.35 : 0)) { wet.removeFromSuperlayer() }
        }
        wet = nil
    }

    // ---------------------------------------------------------------- lasso

    private func beginLasso(at p: CGPoint, on page: PageView) {
        let hitSlop = 12 / max(Double(zoom()), 0.5)
        if let bounds = store.selectionBounds, bounds.insetBy(dx: -hitSlop, dy: -hitSlop).contains(p) {
            lasso = .moving
            lastPoint = p
            firstMove = true
            if let host = floatHost(), dropSelection != nil {
                // Lift it off the page, which clips what it draws, so it
                // can be carried across the gap onto another page.
                let layer = FloatingInkLayer(content: store.selectionContent ?? PageView.Content(),
                                             area: bounds.insetBy(dx: -10, dy: -10),
                                             scale: min(wetScale, 6), zoom: Double(zoom()))
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = layer.area.offsetBy(dx: page.frame.minX, dy: page.frame.minY)
                layer.zPosition = 10
                host.addSublayer(layer)
                CATransaction.commit()
                floating = layer
                dragStart = p
                store.liftSelection()
                selectionLayer.removeFromSuperlayer()
            }
            return
        }
        store.clearSelection()
        lasso = .drawing
        points = [p.x, p.y]
        let layer = CAShapeLayer()
        layer.contentsScale = wetScale
        layer.fillColor = Velvet.accent.withAlphaComponent(0.06).cgColor
        layer.strokeColor = Velvet.accent.cgColor
        layer.lineWidth = 1.5 / zoom()
        layer.lineDashPattern = [NSNumber(value: 5 / Double(zoom())), NSNumber(value: 4 / Double(zoom()))]
        page.layer.addSublayer(layer)
        lassoLayer = layer
    }

    private func lassoMoved(to p: CGPoint) {
        switch lasso {
        case .drawing:
            points += [p.x, p.y]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: points[0], y: points[1]))
            for i in stride(from: 2, to: points.count - 1, by: 2) { path.addLine(to: CGPoint(x: points[i], y: points[i + 1])) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lassoLayer?.path = path
            CATransaction.commit()
        case .moving:
            if let floating, let start = dragStart, let page {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                floating.frame.origin = CGPoint(x: page.frame.minX + floating.area.minX + p.x - start.x,
                                                y: page.frame.minY + floating.area.minY + p.y - start.y)
                CATransaction.commit()
                lastPoint = p
                return
            }
            guard let last = lastPoint else { return }
            store.moveSelection(dx: p.x - last.x, dy: p.y - last.y, first: firstMove)
            firstMove = false
            lastPoint = p
            refreshSelection()
        case nil:
            break
        }
    }

    private func endLasso(commit: Bool) {
        if lasso == .drawing, commit, isTap(points) {
            // A tap with the lasso on a text box, table or equation edits it.
            store.editObject(at: CGPoint(x: points[0], y: points[1]))
        } else if lasso == .drawing, commit, points.count >= 6 {
            store.select(lasso: points)
        }
        if let layer = floating {
            floating = nil
            let moved = commit ? (lastPoint ?? .zero) : (dragStart ?? .zero)
            let start = dragStart ?? .zero
            dragStart = nil
            if let page, let dropSelection {
                dropSelection(page, moved.x - start.x, moved.y - start.y)
            } else {
                store.dropSelection(dx: 0, dy: 0)
            }
            // Removed once the page has drawn the writing where it landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { layer.removeFromSuperlayer() }
        }
        lassoLayer?.removeFromSuperlayer()
        lassoLayer = nil
        lasso = nil
        lastPoint = nil
        points = []
        refreshSelection()
    }

    /// Whether a lasso loop (flat x, y pairs) is really a tap: it never
    /// strays more than a few points from where it began.
    private func isTap(_ loop: [Double]) -> Bool {
        guard loop.count >= 2 else { return false }
        let slop = 8 / max(Double(zoom()), 0.5)
        for i in stride(from: 0, to: loop.count - 1, by: 2)
        where abs(loop[i] - loop[0]) > slop || abs(loop[i + 1] - loop[1]) > slop {
            return false
        }
        return true
    }

    /// Draws the dashed outline around the selection, or removes it.
    func refreshSelection() {
        guard let bounds = store.selectionBounds, let page = activePage() else {
            selectionLayer.removeFromSuperlayer()
            return
        }
        if selectionLayer.superlayer !== page.layer { page.layer.addSublayer(selectionLayer) }
        let z = max(Double(zoom()), 0.1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.contentsScale = wetScale
        selectionLayer.lineWidth = 1.5 / z
        selectionLayer.lineDashPattern = [NSNumber(value: 6 / z), NSNumber(value: 5 / z)]
        selectionLayer.path = CGPath(roundedRect: bounds.insetBy(dx: -8, dy: -8), cornerWidth: 10, cornerHeight: 10, transform: nil)
        CATransaction.commit()
    }
}

/// A selection being dragged: its ink and objects drawn once into a layer
/// that moves with the pen, above every page, with the selection's outline.
final class FloatingInkLayer: CALayer {
    /// The selection's area on its page, in page units.
    let area: CGRect
    private let content: PageView.Content
    private let zoom: Double

    init(content: PageView.Content, area: CGRect, scale: CGFloat, zoom: Double) {
        self.content = content
        self.area = area
        self.zoom = max(zoom, 0.1)
        super.init()
        bounds = CGRect(origin: .zero, size: area.size)
        anchorPoint = .zero
        contentsScale = scale
        setNeedsDisplay()
    }

    override init(layer: Any) {
        let other = layer as! FloatingInkLayer
        content = other.content
        area = other.area
        zoom = other.zoom
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        ctx.translateBy(x: -area.minX, y: -area.minY)
        // Text is drawn through UIKit, which needs this context current.
        UIGraphicsPushContext(ctx)
        PageView.draw(content, in: area, ctx, paper: false)
        UIGraphicsPopContext()
        let outline = CGPath(roundedRect: area.insetBy(dx: 2, dy: 2), cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(outline)
        ctx.setStrokeColor(Velvet.accent.cgColor)
        ctx.setLineWidth(1.5 / zoom)
        ctx.setLineDash(phase: 0, lengths: [6 / zoom, 5 / zoom])
        ctx.strokePath()
    }
}

/// Two-finger tap to undo, three-finger tap to redo, with fingers only (the
/// Pencil keeps writing). A tap cancels the touch it began with, so no dot
/// is left behind.
@MainActor
final class UndoTaps: NSObject {
    private let store: Store

    init(store: Store, on view: UIView) {
        self.store = store
        super.init()
        for (fingers, action) in [(2, #selector(undo)), (3, #selector(redo))] {
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.numberOfTouchesRequired = fingers
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            view.addGestureRecognizer(tap)
        }
    }

    @objc private func undo() { store.undo() }
    @objc private func redo() { store.redo() }
}

extension UIView {
    /// Swipe-back (from the edge, and since iPadOS 26 from anywhere) would
    /// take a sideways pen or finger stroke for "go back". A writing surface
    /// switches it off while on screen; the back button still works.
    func blockSwipeBack(_ block: Bool) {
        var responder: UIResponder? = self
        while let r = responder, !(r is UIViewController) { responder = r.next }
        guard let nav = (responder as? UIViewController)?.navigationController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = !block
        if #available(iOS 26.0, *) {
            nav.interactiveContentPopGestureRecognizer?.isEnabled = !block
        }
    }
}
