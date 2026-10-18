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
