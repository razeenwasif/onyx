import SwiftUI
import UIKit

/// The open notebook as one long scroll of pages, Goodnotes-style. The
/// values passed in only make SwiftUI update the canvas when they change.
struct NotebookCanvasView: UIViewRepresentable {
    let store: Store
    let layoutVersion: Int
    let scrollTarget: String?
    let pagePath: String?
    let fingerDraws: Bool

    func makeUIView(context: Context) -> NotebookCanvas {
        NotebookCanvas(store: store)
    }

    func updateUIView(_ view: NotebookCanvas, context: Context) {
        view.configureGestures()
        view.sync()
    }
}

/// Pages one under another in a zoomable scroll view. Only the pages near
/// the screen have views (each a tiled PageView), so long notebooks stay
/// light. Writing on a page makes it the store's page; so does stopping on
/// one, which keeps the title, saving and "reopen where you were" on the
/// page you're looking at.
final class NotebookCanvas: UIView, UIScrollViewDelegate, UIPencilInteractionDelegate {
    private struct Slot {
        var layout: Store.PageLayout
        var frame: CGRect
    }

    private let store: Store
    private let scroll = UIScrollView()
    /// Holds the pages, in page units; the scroll view zooms it.
    private let stack = UIView()
    private let pen: PenInput
    private var undoTaps: UndoTaps?
    private var slots: [Slot] = []
    private var views: [String: PageView] = [:]
    private var spare: [PageView] = []
    /// What pages other than the store's look like, as last loaded.
    private var cache: [String: PageView.Content] = [:]
    private var shownVersion = -1
    private var shownActive: String?
    private let gap: CGFloat = 36

    private let counter = HintPill()
    private var hideCounter: DispatchWorkItem?
    private let bottomHint = HintPill()
    private var armed = false
    private let addDistance: CGFloat = 110
    private var followsFit = true

    init(store: Store) {
        self.store = store
        pen = PenInput(store: store)
        super.init(frame: .zero)
        backgroundColor = Velvet.backdrop

        scroll.delegate = self
        scroll.delaysContentTouches = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.indicatorStyle = .white
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 120, right: 0)
        scroll.alwaysBounceVertical = true
        addSubview(scroll)
        scroll.addSubview(stack)
        addSubview(counter)
        addSubview(bottomHint)

        pen.zoom = { [weak self] in self?.scroll.zoomScale ?? 1 }
        pen.pencilSeen = { [weak self] in self?.configureGestures() }
        pen.activePage = { [weak self] in self.flatMap { $0.views[$0.store.pagePath ?? ""] } }
        undoTaps = UndoTaps(store: store, on: scroll)
        pen.willWrite = { [weak self] page in
            guard let self, let path = page.path else { return false }
            store.activate(path)
            return store.pagePath == path
        }
        addInteraction(UIPencilInteraction(delegate: self))
        store.inkChanged = { [weak self] area in self?.inkChanged(area) }
        configureGestures()
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

    /// Catches up with the store: new or moved pages, a page to show.
    func sync() {
        if store.layoutVersion != shownVersion || slots.isEmpty { reloadLayout() }
        if store.pagePath != shownActive { inkChanged(nil) }
        if let target = store.scrollTarget, target != takenTarget {
            takenTarget = target
            pendingTarget = target
            // Not during SwiftUI's update.
            DispatchQueue.main.async { [store] in if store.scrollTarget == target { store.scrollTarget = nil } }
        } else if store.scrollTarget == nil {
            takenTarget = nil
        }
        applyPendingTarget()
    }

    /// A page to scroll to once the canvas has its size and zoom.
    private var pendingTarget: String?
    private var takenTarget: String?

    private func applyPendingTarget() {
        guard let target = pendingTarget, bounds.width > 0, !slots.isEmpty else { return }
        pendingTarget = nil
        show(target, animated: false)
    }

    // ------------------------------------------------------------- layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = scroll.frame.size != bounds.size
        scroll.frame = bounds
        counter.center = CGPoint(x: bounds.midX, y: safeAreaInsets.top + 30)
        bottomHint.center = CGPoint(x: bounds.midX, y: bounds.maxY - safeAreaInsets.bottom - 110)
        if resized {
            fitZoom()
            updateVisible()
        }
        applyPendingTarget()
    }

    private func reloadLayout() {
        shownVersion = store.layoutVersion
        let layouts = store.pageLayouts()
        var y: CGFloat = 0
        var width: CGFloat = PDFBackground.standardSize.width
        let sized = layouts.map { ($0, store.size(of: $0)) }
        for (_, size) in sized { width = max(width, size.width) }
        slots = sized.map { layout, size in
            defer { y += size.height + gap }
            return Slot(layout: layout, frame: CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height))
        }
        let total = CGSize(width: width, height: max(y - gap, 1))

        // Another device may have changed any page: draw them afresh.
        cache.removeAll()
        for (_, view) in views { recycle(view) }
        views.removeAll()

        let zoom = scroll.zoomScale
        stack.bounds = CGRect(origin: .zero, size: total)
        stack.center = CGPoint(x: total.width * zoom / 2, y: total.height * zoom / 2)
        scroll.contentSize = CGSize(width: total.width * zoom, height: total.height * zoom)
        fitZoom()
        updateVisible()
    }

    private func fitZoom() {
        guard bounds.width > 0, stack.bounds.width > 0 else { return }
        let fit = (bounds.width - 24) / stack.bounds.width
        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = fit * 4
        if followsFit || scroll.zoomScale < fit { scroll.zoomScale = fit }
        centre()
    }

    private func centre() {
        let spare = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        scroll.contentInset.left = spare
        scroll.contentInset.right = spare
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { stack }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
        updateVisible()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        followsFit = scale <= scroll.minimumZoomScale * 1.01
        pen.wetScale = scale * traitCollection.displayScale
    }

    /// Scrolls so the page at `path` starts at the top of the screen.
    private func show(_ path: String, animated: Bool) {
        guard let slot = slots.first(where: { $0.layout.path == path }) else { return }
        let zoom = scroll.zoomScale
        let maxY = max(scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height, -scroll.contentInset.top)
        let y = min(slot.frame.minY * zoom - scroll.contentInset.top, maxY)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: animated)
        updateVisible()
    }

    // --------------------------------------------------------- page views

    /// Gives the pages on or near the screen a view, and drops the rest.
    private func updateVisible() {
        guard !slots.isEmpty, scroll.bounds.height > 0 else { return }
        let seen = scroll.convert(scroll.bounds, to: stack).insetBy(dx: 0, dy: -scroll.bounds.height / max(scroll.zoomScale, 0.1))
        var wanted = Set<String>()
        for slot in slots where slot.frame.intersects(seen) {
            wanted.insert(slot.layout.path)
            if views[slot.layout.path] == nil { place(slot) }
        }
        for (path, view) in views where !wanted.contains(path) {
            if let content = view.currentContent, path != store.pagePath { cache[path] = content }
            recycle(view)
            views[path] = nil
        }
    }

    private func place(_ slot: Slot) {
        let path = slot.layout.path
        let view = spare.popLast() ?? PageView()
        view.pen = pen
        view.path = path
        view.frame = slot.frame
        let content: PageView.Content?
        if path == store.pagePath {
            content = PageView.Content(store: store)
        } else if let cached = cache[path] {
            content = cached
        } else {
            content = store.content(of: path)
            cache[path] = content
        }
        view.update { $0 = content ?? PageView.Content() }
        view.setNeedsDisplay()
        stack.addSubview(view)
        views[path] = view
    }

    private func recycle(_ view: PageView) {
        view.removeFromSuperview()
        view.path = nil
        view.layer.contents = nil
        if spare.count < 4 { spare.append(view) }
    }

    /// Redraws part of the store's page after writing, or all of it when it
    /// changed hands or was reloaded.
    private func inkChanged(_ area: CGRect?) {
        redraw(area)
        pen.refreshSelection()
    }

    private func redraw(_ area: CGRect?) {
        guard let path = store.pagePath else { return }
        if !slots.contains(where: { $0.layout.path == path }) {
            reloadLayout()
        }
        shownActive = path
        guard let view = views[path] else { return }
        if let area {
            view.update { $0.ink = store.ink }
            view.setNeedsDisplay(area)
        } else {
            view.update { $0 = PageView.Content(store: store) }
            view.setNeedsDisplay()
        }
    }

    // ----------------------------------------------------- scrolling about

    /// The page under the middle of the screen.
    private var centrePath: (index: Int, path: String)? {
        guard !slots.isEmpty else { return nil }
        let y = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: stack).y
        let index = slots.firstIndex { y < $0.frame.maxY + gap / 2 } ?? slots.count - 1
        return (index, slots[index].layout.path)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisible()
        if scroll.isDragging || scroll.isDecelerating, let centre = centrePath, slots.count > 1 {
            counter.show("\(centre.index + 1) of \(slots.count)", progress: 1)
            counter.textColor = Velvet.text
            hideCounter?.cancel()
            let hide = DispatchWorkItem { [weak self] in
                UIView.animate(withDuration: 0.3) { self?.counter.alpha = 0 }
            }
            hideCounter = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hide)
        }

        // Past the end of the last page: offer a new one.
        guard scroll.isDragging else {
            bottomHint.show(nil, progress: 0)
            return
        }
        let maxY = scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height
        let past = scroll.contentOffset.y - max(maxY, -scroll.contentInset.top)
        let canAdd = store.canAddAfter(slots.map(\.layout))
        bottomHint.show(canAdd ? (past >= addDistance ? "Release for a new page" : "Pull for a new page") : nil, progress: past / addDistance)
        let nowArmed = canAdd && past >= addDistance
        if nowArmed && !armed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        armed = nowArmed
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        bottomHint.show(nil, progress: 0)
        guard armed else { return }
        armed = false
        DispatchQueue.main.async { [store] in store.newPage() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    /// Stopped on a page: make it the store's page.
    private func settle() {
        guard let centre = centrePath, centre.path != store.pagePath else { return }
        if let view = views[centre.path], let content = view.currentContent { cache[centre.path] = content }
        store.activate(centre.path)
    }

    /// Double-tap on the Pencil: swap between the eraser and the pen.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        store.tool = store.tool.isEraser ? .pen : .strokeEraser
    }
}
