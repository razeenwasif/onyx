import AppKit
import SwiftUI

/// The page viewport: an `NSScrollView` whose magnification gives pinch and
/// ⌘-scroll zoom with correct event coordinates for everything on the page,
/// including the text views inside the SwiftUI object layer.
final class PageScrollView: NSScrollView {
    static let pageMargin: CGFloat = 36

    let surface: PageSurfaceView
    let pageShadow = PageShadowView()
    let inkView: InkView
    let objectsHost: ZoomAwareHostingView<ObjectsLayer>

    private(set) weak var app: AppModel?
    private(set) var page: PageModel

    init(app: AppModel, page: PageModel) {
        self.app = app
        self.page = page
        surface = PageSurfaceView(frame: CGRect(origin: .zero, size: page.pageSize))
        inkView = InkView(frame: CGRect(origin: .zero, size: page.pageSize))
        objectsHost = ZoomAwareHostingView(rootView: ObjectsLayer(app: app, page: page))
        super.init(frame: .zero)

        contentView = CenteringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.15
        maxMagnification = 6
        drawsBackground = true
        usesPredominantAxisScrolling = false

        let doc = FlippedView(frame: CGRect(
            x: 0, y: 0,
            width: page.pageSize.width + Self.pageMargin * 2,
            height: page.pageSize.height + Self.pageMargin * 2))
        documentView = doc
        doc.addSubview(pageShadow)
        doc.addSubview(surface)

        objectsHost.sizingOptions = []
        objectsHost.autoresizingMask = [.width, .height]
        objectsHost.frame = surface.bounds
        surface.addSubview(objectsHost)

        inkView.autoresizingMask = [.width, .height]
        inkView.frame = surface.bounds
        surface.addSubview(inkView)

        inkView.attach(app: app, page: page)
        apply(app: app, page: page)

        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Pushes model state into the AppKit views. Called from SwiftUI updates.
    func apply(app: AppModel, page newPage: PageModel) {
        self.app = app
        if newPage !== page {
            page = newPage
            objectsHost.rootView = ObjectsLayer(app: app, page: newPage)
            inkView.attach(app: app, page: newPage)
            autoFit = true
            scrollToTop()
            takeFocus()
        }

        let palette = Palette.of(dark: app.dark)
        backgroundColor = palette.backdrop
        surface.palette = palette
        surface.background = page.background

        let size = page.pageSize
        if surface.frame.size != size {
            surface.frame = CGRect(origin: CGPoint(x: Self.pageMargin, y: Self.pageMargin), size: size)
            documentView?.setFrameSize(CGSize(width: size.width + Self.pageMargin * 2, height: size.height + Self.pageMargin * 2))
            reconstrain()
        } else if surface.frame.origin.x != Self.pageMargin {
            surface.setFrameOrigin(CGPoint(x: Self.pageMargin, y: Self.pageMargin))
        }
        if pageShadow.frame != surface.frame { pageShadow.frame = surface.frame }
        applyFit()

        inkView.toolChanged()
        surface.needsDisplay = true
        inkView.needsDisplay = true
    }

    func scrollToTop() {
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: .zero, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }

    /// The clip view only re-centres when it scrolls, so nudge it after the
    /// page changes size.
    private func reconstrain() {
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
    }

    /// Puts the keyboard on the page, so tool keys work straight away
    /// rather than typing into whatever field the window focused first.
    func takeFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if !(window.firstResponder is ScribeTextView) { window.makeFirstResponder(self.inkView) }
        }
    }

    // ----------------------------------------------------------------- zoom

    /// The page follows the pane: shown whole and centred, zoomed out only as
    /// far as it must be to fit beside open panels, and never past 100%. Any
    /// manual zoom turns this off until Fit Page Width or another page.
    private(set) var autoFit = true

    override func tile() {
        super.tile()
        applyFit()
    }

    private func applyFit() {
        guard autoFit, contentView.frame.width > 80 else { return }
        let docWidth = page.pageSize.width + Self.pageMargin * 2
        let target = min(1, contentView.frame.width / docWidth).clamped(minMagnification, maxMagnification)
        guard abs(target - magnification) > 0.002 else { return }
        let top = contentView.bounds.minY
        magnification = target
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(x: 0, y: top, width: contentView.bounds.width,
                                                                      height: contentView.bounds.height)).origin)
        reflectScrolledClipView(contentView)
        magnificationChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘ or ⌃ with the wheel zooms about the pointer, as in most editors.
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            let target = (magnification * (1 + delta)).clamped(minMagnification, maxMagnification)
            let center = contentView.convert(event.locationInWindow, from: nil)
            autoFit = false
            setMagnification(target, centeredAt: center)
            magnificationChanged()
            return
        }
        super.scrollWheel(with: event)
    }

    func zoom(by factor: CGFloat) {
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        autoFit = false
        setMagnification((magnification * factor).clamped(minMagnification, maxMagnification), centeredAt: center)
        magnificationChanged()
    }

    func zoomToActualSize() {
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        autoFit = false
        setMagnification(1, centeredAt: center)
        magnificationChanged()
    }

    /// Back to following the pane: the whole page width, centred.
    func zoomToFit() {
        autoFit = true
        applyFit()
        reconstrain()
    }

    @objc private func liveMagnifyEnded() {
        autoFit = false
        magnificationChanged()
    }

    @objc private func magnificationChanged() {
        app?.zoom = magnification
        inkView.needsDisplay = true
    }

    /// Centre of the visible part of the page, in page coordinates.
    var visiblePageCenter: CGPoint {
        let visible = surface.convert(contentView.bounds, from: contentView)
        let r = visible.intersection(surface.bounds)
        guard !r.isNull else { return CGPoint(x: 120, y: 120) }
        return CGPoint(x: r.midX, y: max(r.minY + 40, r.midY - 120))
    }
}

/// A hosting view that still gets clicks right when the page is zoomed.
///
/// Inside the magnified scroll view, AppKit draws SwiftUI content at the
/// zoomed size, but SwiftUI places its controls as if at 100%, measured from
/// the view's top-left corner. Left alone, a click on a pill or a table cell
/// lands on whatever SwiftUI thinks is there at unzoomed scale. Mouse events
/// and hit tests for SwiftUI content are re-expressed in those terms; native
/// AppKit subviews (the text boxes) keep the real coordinates.
final class ZoomAwareHostingView<Content: View>: NSHostingView<Content> {
    /// The window point SwiftUI expects for a point in this view.
    private func swiftUIWindowPoint(forLocal local: NSPoint) -> NSPoint {
        let topLeft = convert(NSPoint.zero, to: nil)
        return isFlipped
            ? NSPoint(x: topLeft.x + local.x, y: topLeft.y - local.y)
            : NSPoint(x: topLeft.x + local.x, y: topLeft.y + local.y)
    }

    private var zoomed: Bool {
        abs(convert(NSSize(width: 1, height: 1), to: nil).width - 1) > 0.001
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard zoomed, let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Native views first, in true coordinates.
        for sub in subviews.reversed() where !sub.isHidden {
            if let hit = sub.hitTest(local) { return hit }
        }
        let window = swiftUIWindowPoint(forLocal: local)
        return super.hitTest(superview.convert(window, from: nil))
    }

    private func remapped(_ e: NSEvent) -> NSEvent {
        guard zoomed else { return e }
        let local = convert(e.locationInWindow, from: nil)
        return NSEvent.mouseEvent(
            with: e.type, location: swiftUIWindowPoint(forLocal: local), modifierFlags: e.modifierFlags,
            timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
            eventNumber: e.eventNumber, clickCount: e.clickCount, pressure: e.pressure
        ) ?? e
    }

    override func mouseDown(with e: NSEvent) { super.mouseDown(with: remapped(e)) }
    override func mouseDragged(with e: NSEvent) { super.mouseDragged(with: remapped(e)) }
    override func mouseUp(with e: NSEvent) { super.mouseUp(with: remapped(e)) }
    override func mouseMoved(with e: NSEvent) { super.mouseMoved(with: remapped(e)) }
    override func rightMouseDown(with e: NSEvent) { super.rightMouseDown(with: remapped(e)) }
    override func rightMouseDragged(with e: NSEvent) { super.rightMouseDragged(with: remapped(e)) }
    override func rightMouseUp(with e: NSEvent) { super.rightMouseUp(with: remapped(e)) }
    override func otherMouseDown(with e: NSEvent) { super.otherMouseDown(with: remapped(e)) }
    override func otherMouseDragged(with e: NSEvent) { super.otherMouseDragged(with: remapped(e)) }
    override func otherMouseUp(with e: NSEvent) { super.otherMouseUp(with: remapped(e)) }
    override func menu(for event: NSEvent) -> NSMenu? { super.menu(for: remapped(event)) }
}

/// Keeps the page centred left to right when it is narrower than the pane,
/// and pinned to the top, as paper on a desk would be.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if rect.height > doc.frame.height {
            rect.origin.y = 0
        }
        return rect
    }

    override var isFlipped: Bool { true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The soft shadow under the page, kept apart from the page itself so the
/// page can clip its corners while the shadow spills out around them.
final class PageShadowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.75
        layer?.shadowRadius = 38
        layer?.shadowOffset = CGSize(width: 0, height: -22)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // An explicit path spares the compositor from deriving the shadow
        // from pixels on every frame.
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 18, dy: 10), cornerWidth: Velvet.Radius.page,
                                   cornerHeight: Velvet.Radius.page, transform: nil)
    }
}

/// The sheet of paper: a rounded velvet surface with its rules.
///
/// Rules are drawn in page coordinates rather than tiled, so the spacing
/// stays locked to the page at every zoom and handwriting keeps sitting on
/// the same line.
final class PageSurfaceView: NSView {
    var palette = Palette.dark {
        didSet { needsDisplay = true }
    }

    var background = BackgroundDTO() {
        didSet { if background != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // No sharp corners, on the page or on anything that reaches its edge.
        layer?.cornerRadius = Velvet.Radius.page
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        palette.page.setFill()
        dirtyRect.fill()

        // The faint light along the top edge that every velvet surface has.
        if dirtyRect.minY < 2 {
            palette.pageBorder.setFill()
            CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }

        let kind = background.kind.lowercased()
        guard kind != "blank" else { return }

        let spacing = max(background.spacing, 4)
        // Dark mode supplies its own rule colour so the lines do not glare;
        // the stored light-mode colour is left untouched.
        let rule = palette.isDark ? palette.rule : NSColor(hex: background.color, fallback: 0xE8EE_F5FF)
        rule.set()

        let first = Int(floor(dirtyRect.minY / spacing))
        let last = Int(ceil(dirtyRect.maxY / spacing))

        if kind == "dots" {
            let firstX = Int(floor(dirtyRect.minX / spacing))
            let lastX = Int(ceil(dirtyRect.maxX / spacing))
            let dots = NSBezierPath()
            for j in max(first, 1)...max(last, 1) {
                for i in max(firstX, 1)...max(lastX, 1) {
                    dots.appendOval(in: CGRect(x: Double(i) * spacing - 1.1, y: Double(j) * spacing - 1.1, width: 2.2, height: 2.2))
                }
            }
            dots.fill()
            return
        }

        let lines = NSBezierPath()
        lines.lineWidth = 1
        for j in max(first, 1)...max(last, 1) {
            let y = Double(j) * spacing
            lines.move(to: CGPoint(x: dirtyRect.minX, y: y))
            lines.line(to: CGPoint(x: dirtyRect.maxX, y: y))
        }

        if kind == "grid" {
            let firstX = Int(floor(dirtyRect.minX / spacing))
            let lastX = Int(ceil(dirtyRect.maxX / spacing))
            for i in max(firstX, 1)...max(lastX, 1) {
                let x = Double(i) * spacing
                lines.move(to: CGPoint(x: x, y: dirtyRect.minY))
                lines.line(to: CGPoint(x: x, y: dirtyRect.maxY))
            }
        }
        lines.stroke()

        if kind == "ruled" {
            // The margin rule, as on paper, in a soft accent.
            let x = spacing * 3
            let margin = NSBezierPath()
            margin.lineWidth = 1
            margin.move(to: CGPoint(x: x, y: dirtyRect.minY))
            margin.line(to: CGPoint(x: x, y: dirtyRect.maxY))
            palette.marginRule.setStroke()
            margin.stroke()
        }
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

/// SwiftUI wrapper for the canvas.
struct PageCanvas: NSViewRepresentable {
    let app: AppModel
    let page: PageModel

    func makeNSView(context: Context) -> PageScrollView {
        let view = PageScrollView(app: app, page: page)
        app.canvas = view
        view.takeFocus()
        return view
    }

    func updateNSView(_ view: PageScrollView, context: Context) {
        // Reading these registers them for observation, so the canvas is
        // refreshed when any of them change.
        _ = (app.dark, app.tool, page.pageSize, page.background, page.selectedObjects)
        app.canvas = view
        view.apply(app: app, page: page)
    }
}
