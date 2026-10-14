import AppKit
import UniformTypeIdentifiers

/// The drawing surface: renders the page's ink and turns pointer input into
/// strokes, erasing, lasso selection and panning.
///
/// It sits above the object layer. With the Text tool it lets clicks on
/// objects fall through to them, so text boxes and tables are editable; with
/// every other tool it takes all input, so writing over an image or a table
/// annotates it instead of selecting it.
final class InkView: NSView {
    private weak var app: AppModel?
    private var page: PageModel?

    // Wet ink: the stroke under the nib, not yet committed.
    private var wetPoints: [Double] = []
    private var wetPath: CGPath?
    private var wetPen: Pen?

    private enum Gesture {
        case none
        case ink
        case erase(before: [InkStroke], partial: Bool)
        case lasso([CGPoint])
        case move(PageModel.GeometrySnapshot, start: CGPoint)
        case resize(PageModel.GeometrySnapshot, anchor: CGPoint, original: CGRect)
        case pan(start: CGPoint, origin: CGPoint)
    }

    private var gesture = Gesture.none

    /// The tablet pen is flipped to its eraser end.
    private var eraserEnd = false
    /// Space is held: pan temporarily, whatever the tool.
    private var spacePan = false
    private var hover: CGPoint?
    private var proximityMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The pen's eraser end erases regardless of the selected tool; that is
        // muscle memory from every real pen.
        proximityMonitor = NSEvent.addLocalMonitorForEvents(matching: .tabletProximity) { [weak self] event in
            self?.eraserEnd = event.isEnteringProximity && event.pointingDeviceType == .eraser
            return event
        }
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = proximityMonitor { NSEvent.removeMonitor(m) }
    }

    func attach(app: AppModel, page: PageModel) {
        self.app = app
        if self.page !== page {
            self.page = page
            page.onInkInvalidated = { [weak self] rect in
                guard let self else { return }
                if let rect { self.setNeedsDisplay(rect.insetBy(dx: -4, dy: -4)) } else { self.needsDisplay = true }
            }
            gesture = .none
            wetPath = nil
            needsDisplay = true
        }
    }

    func toolChanged() {
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var dark: Bool { app?.dark ?? true }
    private var tool: ToolKind { app?.tool ?? .pen }
    private var scale: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// The tool that actually applies to this event.
    private func effectiveTool(_ event: NSEvent) -> ToolKind {
        if spacePan { return .pan }
        if eraserEnd || event.pointingDeviceType == .eraser { return .strokeEraser }
        return tool
    }

    // -------------------------------------------------------------- hit test

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let page, !spacePan else { return super.hitTest(point) }
        let p = convert(point, from: superview)
        switch tool {
        case .text:
            // Over an object or its grip and pills: let it handle the click
            // so it can be edited.
            if page.allObjects.contains(where: { $0.hitFrame.contains(p) }) { return nil }
        case .select:
            // The selection's action pill lives in the object layer below.
            if let pill = page.selectionPillFrame, pill.contains(p) { return nil }
        default:
            break
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .pen, .highlighter: .crosshair
        case .text: .iBeam
        case .pan: .openHand
        case .strokeEraser, .pointEraser: .crosshair
        case .select: .arrow
        }
        addCursorRect(bounds, cursor: spacePan ? .openHand : cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool.isEraser else { return }
        let old = hover
        hover = convert(event.locationInWindow, from: nil)
        invalidateCursor(old)
        invalidateCursor(hover)
    }

    override func mouseExited(with event: NSEvent) {
        let old = hover
        hover = nil
        invalidateCursor(old)
    }

    private func invalidateCursor(_ p: CGPoint?) {
        guard let p else { return }
        let r = eraserRadius + 4
        setNeedsDisplay(CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    private var eraserRadius: Double {
        tool == .pointEraser ? max(app?.eraserWidth ?? 18, 4) / 2 : 4
    }

    // ---------------------------------------------------------------- input

    private func sample(_ event: NSEvent) -> (CGPoint, Double) {
        let p = convert(event.locationInWindow, from: nil)
        // Only a tablet reports meaningful pressure; a mouse or trackpad gets
        // the same mid value a pen-less Windows machine does.
        let pressure = event.subtype == .tabletPoint ? Double(event.pressure) : 0.5
        return (p, pressure)
    }

    override func mouseDown(with event: NSEvent) {
        guard let page, let app else { return }
        window?.makeFirstResponder(self)
        let (p, pressure) = sample(event)
        app.trayOpen = false
        app.insertOpen = false

        switch effectiveTool(event) {
        case .pen, .highlighter:
            page.clearSelection()
            wetPen = tool == .highlighter ? app.highlighter : app.pen
            wetPoints = [p.x, p.y, pressure]
            gesture = .ink
            rebuildWet()

        case .strokeEraser, .pointEraser:
            let partial = !eraserEnd && tool == .pointEraser
            gesture = .erase(before: page.strokes, partial: partial)
            erase(at: p, partial: partial)

        case .select:
            beginSelect(at: p, event: event)

        case .text:
            // Over empty paper (objects took the click otherwise): new text box.
            page.addTextBox(at: CGPoint(x: p.x, y: p.y - 12))
            app.tool = .text

        case .pan:
            startPan(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let page else { return }
        let (p, pressure) = sample(event)

        switch gesture {
        case .ink:
            wetPoints.append(contentsOf: [p.x, p.y, pressure])
            rebuildWet()

        case .erase(_, let partial):
            erase(at: p, partial: partial)
            let old = hover
            hover = p
            invalidateCursor(old)
            invalidateCursor(hover)

        case .lasso(var points):
            points.append(p)
            gesture = .lasso(points)
            needsDisplay = true

        case .move(let snap, let start):
            page.translateSelection(from: snap, dx: p.x - start.x, dy: p.y - start.y)

        case .resize(let snap, let anchor, let original):
            let sx = max(0.05, (p.x - anchor.x) / max(original.width, 1))
            let sy = max(0.05, (p.y - anchor.y) / max(original.height, 1))
            // Hold Shift to keep proportions.
            let uniform = event.modifierFlags.contains(.shift) ? max(sx, sy) : nil
            page.scaleSelection(from: snap, anchor: anchor, sx: uniform ?? sx, sy: uniform ?? sy)

        case .pan(let start, let origin):
            pan(event, start: start, origin: origin)

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let page else { return }

        switch gesture {
        case .ink:
            commitWet()

        case .erase(let before, _):
            if before.count != page.strokes.count || zip(before, page.strokes).contains(where: { $0 !== $1 }) {
                page.commitStrokes(from: before, to: page.strokes, name: "Erase")
            }

        case .lasso(let points):
            if points.count > 3 {
                page.select(lasso: points.flatMap { [$0.x, $0.y] })
            }

        case .move(let snap, let start):
            let p = convert(event.locationInWindow, from: nil)
            if hypot(p.x - start.x, p.y - start.y) > 0.5 {
                page.commitGeometry(from: snap, name: "Move")
            }

        case .resize(let snap, _, _):
            page.commitGeometry(from: snap, name: "Resize")

        case .pan:
            NSCursor.openHand.set()

        case .none:
            break
        }

        gesture = .none
        needsDisplay = true
    }

    // Middle-button drag pans with any tool.
    override func otherMouseDown(with event: NSEvent) { startPan(event) }
    override func otherMouseDragged(with event: NSEvent) {
        if case .pan(let start, let origin) = gesture { pan(event, start: start, origin: origin) }
    }
    override func otherMouseUp(with event: NSEvent) { gesture = .none }

    // Some tablets report the eraser end as the right button.
    override func rightMouseDown(with event: NSEvent) {
        if event.subtype == .tabletPoint {
            eraserEnd = true
            mouseDown(with: event)
        } else {
            super.rightMouseDown(with: event)
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        if event.subtype == .tabletPoint { mouseDragged(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if event.subtype == .tabletPoint {
            mouseUp(with: event)
            eraserEnd = false
        }
    }

    private func startPan(_ event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        gesture = .pan(start: event.locationInWindow, origin: clip.bounds.origin)
        NSCursor.closedHand.set()
    }

    private func pan(_ event: NSEvent, start: CGPoint, origin: CGPoint) {
        guard let scroll = enclosingScrollView else { return }
        let m = scroll.magnification
        let dx = (event.locationInWindow.x - start.x) / m
        let dy = (event.locationInWindow.y - start.y) / m
        scroll.contentView.scroll(to: CGPoint(x: origin.x - dx, y: origin.y + dy))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // ------------------------------------------------------------------ ink

    private func rebuildWet() {
        guard let pen = wetPen else { return }
        let old = wetPath?.boundingBoxOfPath
        // Wet ink is not tapered: tapering each partial stroke would pinch the
        // line wherever a frame happened to end.
        wetPath = Core.outlinePath(points: wetPoints, width: pen.width, pressureSensitive: pen.pressureSensitive, fit: true, taper: false)

        // Only the tail changes as points arrive, so repaint just that.
        let tail = Array(wetPoints.suffix(3 * 8))
        var dirty = Core.strokeBounds(points: tail, width: pen.width).insetBy(dx: -3, dy: -3)
        if wetPoints.count <= 3, let b = wetPath?.boundingBoxOfPath { dirty = dirty.union(b) }
        if let old, wetPoints.count <= 6 { dirty = dirty.union(old) }
        setNeedsDisplay(dirty)
    }

    private func commitWet() {
        guard let pen = wetPen, let page, !wetPoints.isEmpty else { return }
        let dto = StrokeDTO(
            color: pen.color,
            width: pen.width,
            height: pen.width,
            tip: "ellipse",
            highlighter: pen.highlighter,
            fit: true,
            pressureSensitive: pen.pressureSensitive,
            points: wetPoints
        )
        let bounds = Core.strokeBounds(points: wetPoints, width: pen.width)
        wetPoints = []
        wetPath = nil
        wetPen = nil
        page.addStroke(dto)
        setNeedsDisplay(bounds.insetBy(dx: -4, dy: -4))
    }

    private func erase(at p: CGPoint, partial: Bool) {
        guard let page else { return }
        let radius = eraserRadius
        var list = page.strokes
        var changed = false
        var dirty = CGRect.null

        var i = 0
        while i < list.count {
            let s = list[i]
            guard s.bounds.insetBy(dx: -radius, dy: -radius).contains(p) else {
                i += 1
                continue
            }

            if partial {
                if let pieces = Core.strokeErase(points: s.dto.points, width: s.nib, fit: s.dto.fit, at: p, radius: radius) {
                    dirty = dirty.union(s.bounds)
                    let replacements = pieces.map { piece -> InkStroke in
                        var d = s.dto
                        d.points = piece
                        return InkStroke(d)
                    }
                    list.replaceSubrange(i...i, with: replacements)
                    i += replacements.count
                    changed = true
                    continue
                }
            } else if Core.strokeHit(points: s.dto.points, width: s.nib, at: p, radius: radius) {
                dirty = dirty.union(s.bounds)
                list.remove(at: i)
                changed = true
                continue
            }
            i += 1
        }

        if changed {
            page.setStrokesLive(list)
            setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2))
        }
    }

    // ------------------------------------------------------------ selection

    private var handleSize: CGFloat { 16 / scale }

    /// Sits on the corner of the rounded selection outline.
    private func resizeHandle(for r: CGRect) -> CGRect {
        let inset = 10 - 20 * (1 - 1 / CGFloat(2).squareRoot())
        let corner = CGPoint(x: r.maxX + inset, y: r.maxY + inset)
        return CGRect(x: corner.x - handleSize / 2, y: corner.y - handleSize / 2, width: handleSize, height: handleSize)
    }

    private func beginSelect(at p: CGPoint, event: NSEvent) {
        guard let page else { return }

        if let r = page.selectionBounds {
            if resizeHandle(for: r).insetBy(dx: -4 / scale, dy: -4 / scale).contains(p) {
                gesture = .resize(page.captureSelectionGeometry(), anchor: r.origin, original: r)
                return
            }
            if r.insetBy(dx: -4, dy: -4).contains(p) {
                gesture = .move(page.captureSelectionGeometry(), start: p)
                return
            }
        }

        // A click on an object selects just that object, ready to move.
        if let obj = page.allObjects.last(where: { $0.frame.contains(p) }) {
            page.selectedStrokes = []
            page.selectedObjects = [obj.objectID]
            if event.clickCount == 2 {
                // Double-click edits it.
                app?.select(tool: .text)
                if let tb = obj as? TextBoxItem { page.focusRequest = tb.dto.id }
                if let lx = obj as? LatexItem { app?.sheet = .latex(lx) }
                page.clearSelection()
                return
            }
            gesture = .move(page.captureSelectionGeometry(), start: p)
            needsDisplay = true
            return
        }

        page.clearSelection()
        gesture = .lasso([p])
    }

    // ------------------------------------------------------------- keyboard

    override func keyDown(with event: NSEvent) {
        guard let page else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])

        if mods.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased() {
            // Tool letters are handled app-wide in AppDelegate.
            if chars == " " {
                if !spacePan {
                    spacePan = true
                    window?.invalidateCursorRects(for: self)
                }
                return
            }
        }

        switch event.keyCode {
        case 51, 117: // delete, forward delete
            page.deleteSelection()
        case 53: // escape
            page.clearSelection()
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", spacePan {
            spacePan = false
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyUp(with: event)
    }

    @objc func delete(_ sender: Any?) { page?.deleteSelection() }

    override func selectAll(_ sender: Any?) {
        guard let page else { return }
        app?.tool = .select
        page.selectedStrokes = Set(page.strokes.map(ObjectIdentifier.init))
        page.selectedObjects = Set(page.allObjects.map(\.objectID))
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) { app?.copySelection() }

    @objc func cut(_ sender: Any?) {
        app?.copySelection()
        page?.deleteSelection()
    }

    @objc func paste(_ sender: Any?) { app?.paste() }

    // Copy, cut and delete only make sense with something selected; this
    // keeps the Edit menu honest.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return page?.hasSelection ?? false
        default:
            return true
        }
    }

    // ------------------------------------------------------------ drag & drop

    private func droppedImageURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let pb = info.draggingPasteboard
        return !droppedImageURLs(info).isEmpty || pb.availableType(from: [.png, .tiff]) != nil ? .copy : []
    }

    /// Images dropped from Finder or another app land where they are dropped.
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard let app else { return false }
        var p = convert(info.draggingLocation, from: nil)
        let urls = droppedImageURLs(info)
        if !urls.isEmpty {
            for url in urls {
                app.insertImage(fileURL: url, at: p)
                p.y += 40
            }
            return true
        }
        if let image = NSImage(pasteboard: info.draggingPasteboard) {
            app.insertImage(image, at: p)
            return true
        }
        return false
    }

    // ---------------------------------------------------------------- draw

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = self.dark

        for s in page.strokes where s.bounds.intersects(dirtyRect) {
            ctx.addPath(s.path)
            ctx.setFillColor(s.paint(dark: dark).cgColor)
            ctx.fillPath(using: .winding)
        }

        if let wet = wetPath, let pen = wetPen {
            ctx.addPath(wet)
            ctx.setFillColor(InkPaint.color(hex: pen.color, highlighter: pen.highlighter, dark: dark).cgColor)
            ctx.fillPath(using: .winding)
        }

        let accent = Palette.of(dark: dark).selection
        drawSelection(ctx, page: page, accent: accent)

        if case .lasso(let points) = gesture, points.count > 1 {
            ctx.saveGState()
            ctx.addLines(between: points)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5 / scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: [5 / scale, 4 / scale])
            ctx.strokePath()
            ctx.restoreGState()
        }

        if tool.isEraser, let h = hover {
            let r = eraserRadius
            ctx.saveGState()
            ctx.setStrokeColor(Palette.of(dark: dark).mutedText.cgColor)
            ctx.setLineWidth(1 / scale)
            ctx.strokeEllipse(in: CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
    }

    private func drawSelection(_ ctx: CGContext, page: PageModel, accent: NSColor) {
        guard page.hasSelection, let bounds = page.selectionBounds else { return }

        ctx.saveGState()
        // A soft tint over selected ink makes it obvious what will move.
        ctx.setFillColor(accent.withAlphaComponent(0.35).cgColor)
        for s in page.selectedStrokeList {
            ctx.addPath(s.path)
            ctx.fillPath(using: .winding)
        }

        // Soft, rounded bounds: a faint wash and a dashed edge, no hard box.
        let r = bounds.insetBy(dx: -10, dy: -10)
        let shape = CGPath(roundedRect: r, cornerWidth: 20, cornerHeight: 20, transform: nil)
        ctx.addPath(shape)
        ctx.setFillColor(accent.withAlphaComponent(0.07).cgColor)
        ctx.fillPath()
        ctx.addPath(shape)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5 / scale)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [5 / scale, 4 / scale])
        ctx.strokePath()

        // A round resize handle, ringed in the page colour so it floats.
        ctx.setLineDash(phase: 0, lengths: [])
        let h = resizeHandle(for: bounds)
        ctx.setFillColor(Palette.of(dark: dark).page.cgColor)
        ctx.fillEllipse(in: h.insetBy(dx: -4 / scale, dy: -4 / scale))
        ctx.setFillColor(accent.cgColor)
        ctx.fillEllipse(in: h)
        ctx.restoreGState()
    }
}
