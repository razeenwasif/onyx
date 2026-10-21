import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Small pictures of pages, for the page grid. Shared by the Mac app (and so
/// Scribe inside Electron) and the iPad app, which draw them identically.
///
/// A thumbnail is the page as it looks on the dark velvet paper: rules or
/// PDF, pictures, typed text and ink. Thumbnails are cached on disk in the
/// workspace's `.scribe/thumbs.nosync/` folder, one PNG per page id. iCloud
/// Drive skips anything ending in `.nosync`, so each device keeps its own
/// cache and nothing extra syncs. A cached thumbnail is used while it is
/// newer than its page file; otherwise the page is drawn again.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()

    /// Width of a thumbnail in pixels: sharp in a grid cell at 2× without
    /// costing much to draw or keep.
    static let pixelWidth = 320

    private let work = OperationQueue()
    private let memory = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var waiting: [String: [(CGImage?) -> Void]] = [:]

    private init() {
        work.name = "Scribe thumbnails"
        // One at a time on the iPad: two big pages at once is a lot of
        // memory for it.
        #if os(iOS)
        work.maxConcurrentOperationCount = 1
        #else
        work.maxConcurrentOperationCount = 2
        #endif
        work.qualityOfService = .utility
        memory.countLimit = 400
    }

    /// The page's thumbnail, drawn or read from the cache off the main thread.
    func image(for page: PageInfo, root: String) async -> CGImage? {
        let key = Self.key(page)
        let memoryKey = "\(key)@\(page.modified)" as NSString
        if let hit = memory.object(forKey: memoryKey) { return hit }
        return await withCheckedContinuation { done in
            lock.lock()
            if waiting[memoryKey as String] != nil {
                waiting[memoryKey as String]?.append { done.resume(returning: $0) }
                lock.unlock()
                return
            }
            waiting[memoryKey as String] = [{ done.resume(returning: $0) }]
            lock.unlock()

            work.addOperation { [self] in
                let image = Self.cachedOrDrawn(page, key: key, root: root)
                if let image { memory.setObject(image, forKey: memoryKey) }
                lock.lock()
                let callbacks = waiting.removeValue(forKey: memoryKey as String) ?? []
                lock.unlock()
                callbacks.forEach { $0(image) }
            }
        }
    }

    private static func key(_ page: PageInfo) -> String {
        if let id = page.pageId, !id.isEmpty { return id }
        // A page without an id still gets a stable name from its path.
        return String(page.path.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }

    private static func cachedOrDrawn(_ page: PageInfo, key: String, root: String) -> CGImage? {
        let folder = URL(fileURLWithPath: root).appendingPathComponent(".scribe/thumbs.nosync", isDirectory: true)
        let file = folder.appendingPathComponent("\(key).png")
        let fm = FileManager.default
        let pageDate = (try? fm.attributesOfItem(atPath: page.path))?[.modificationDate] as? Date
        if let thumbDate = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           let pageDate, thumbDate >= pageDate,
           let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }

        guard let doc = try? Core.readPage(page.path),
              let image = render(doc, sectionPath: page.sectionPath)
        else { return nil }

        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let out = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(out, image, nil)
            CGImageDestinationFinalize(out)
        }
        return image
    }

    // ------------------------------------------------------------- drawing

    private static let paper = CGColor(srgbRed: 0x1C / 255, green: 0x19 / 255, blue: 0x20 / 255, alpha: 1)
    private static let rule = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)
    private static let margin = CGColor(srgbRed: 0xE3 / 255, green: 0x90 / 255, blue: 0x72 / 255, alpha: 0.35)
    private static let muted = CGColor(srgbRed: 0xA6 / 255, green: 0x9D / 255, blue: 0xAB / 255, alpha: 0.5)

    /// The page at thumbnail size: the standard page (or the PDF page's own
    /// shape), with anything beyond it cut off.
    static func render(_ doc: PageDoc, sectionPath: String) -> CGImage? {
        render(doc, sectionPath: sectionPath, crop: nil, width: pixelWidth)
    }

    /// `crop` (page units) draws just that part of the page, `width` pixels
    /// wide: the cards that show a page inside a note.
    static func render(_ doc: PageDoc, sectionPath: String, crop: CGRect?, width pixels: Int) -> CGImage? {
        let pdf = PDFBackground.page(for: doc.background, sectionPath: sectionPath)
        var size = pdf.map { PDFBackground.size(of: $0) } ?? PDFBackground.standardSize
        if doc.isCanvas {
            // A canvas page shows its whole width, page-shaped from the top,
            // so writing that runs off to the right isn't cropped away.
            let width = max(size.width, contentRight(doc) + 24)
            size = CGSize(width: width, height: width * size.height / size.width)
        }
        let bounds = CGRect(origin: .zero, size: size)
        let view = crop ?? bounds
        guard view.width > 0, view.height > 0 else { return nil }
        let scale = CGFloat(pixels) / view.width
        let height = max(1, Int((view.height * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: pixels, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Page coordinates run top-down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -view.minX, y: -view.minY)
        ctx.setFillColor(paper)
        ctx.fill(view)
        ctx.clip(to: view)

        if let pdf {
            PDFBackground.draw(pdf, in: ctx)
        } else {
            drawRules(doc.background, in: bounds, ctx)
        }

        let strokes = doc.strokes.filter { $0.points.count >= 3 }
        drawInk(strokes.filter(\.highlighter), ctx)
        for image in doc.images { drawImage(image, sectionPath: sectionPath, ctx) }
        for table in doc.tables { drawTable(table, ctx) }
        for box in doc.textBoxes { drawText(box, ctx) }
        for block in doc.latexBlocks {
            // Formulas show as a faint bar at thumbnail size.
            ctx.setFillColor(muted)
            let width = min(Double(block.latex.count) * block.scale * 0.45, 600)
            ctx.fill(CGRect(x: block.x, y: block.y, width: width, height: block.scale * 0.9))
        }
        drawInk(strokes.filter { !$0.highlighter }, ctx)
        return ctx.makeImage()
    }

    /// The part of the page a card shows: a linked area with a margin, or
    /// else everything on the page, from the top of what's written and no
    /// taller than a wide card (the rest is left for Scribe).
    static func cardCrop(_ doc: PageDoc, area: CGRect?) -> CGRect {
        let size = PDFBackground.standardSize
        if let area, area.width > 0, area.height > 0 {
            return area.insetBy(dx: -16, dy: -16)
        }
        var box = CGRect.null
        for s in doc.strokes {
            let pad = max(s.width, s.height) / 2
            for i in stride(from: 0, to: s.points.count - 2, by: 3) {
                box = box.union(CGRect(x: s.points[i] - pad, y: s.points[i + 1] - pad, width: pad * 2, height: pad * 2))
            }
        }
        for t in doc.textBoxes { box = box.union(CGRect(x: t.x, y: t.y, width: t.width, height: t.height ?? t.fontSize * 1.4)) }
        for i in doc.images { box = box.union(CGRect(x: i.x, y: i.y, width: i.width, height: i.height)) }
        if box.isNull {
            return CGRect(x: 0, y: 0, width: size.width, height: size.width * 0.3)
        }
        // Full width, so the page's left margin and rules read as a page.
        let left = min(0, box.minX - 24)
        let width = max(size.width, box.maxX + 24) - left
        let top = max(0, box.minY - 24)
        let height = min(box.maxY + 24 - top, width * 0.6)
        return CGRect(x: left, y: top, width: width, height: max(height, width * 0.18))
    }

    /// How far right the page's content reaches.
    private static func contentRight(_ doc: PageDoc) -> CGFloat {
        var right: CGFloat = 0
        for s in doc.strokes {
            let pad = max(s.width, s.height) / 2
            for i in stride(from: 0, to: s.points.count - 2, by: 3) { right = max(right, s.points[i] + pad) }
        }
        for t in doc.textBoxes { right = max(right, t.x + t.width) }
        for i in doc.images { right = max(right, i.x + i.width) }
        for t in doc.tables { right = max(right, t.x + CGFloat((t.columnWidths ?? []).reduce(0, +))) }
        return right
    }

    private static func drawRules(_ background: BackgroundDTO, in bounds: CGRect, _ ctx: CGContext) {
        let kind = background.kind.lowercased()
        guard kind != "blank" else { return }
        let spacing = max(background.spacing, 4)
        ctx.setStrokeColor(rule)
        ctx.setFillColor(rule)
        ctx.setLineWidth(1.6)
        var y = spacing
        while y < bounds.maxY {
            if kind == "dots" {
                var x = spacing
                while x < bounds.maxX {
                    ctx.fillEllipse(in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2))
                    x += spacing
                }
            } else {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
            y += spacing
        }
        if kind == "grid" {
            var x = spacing
            while x < bounds.maxX {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
                x += spacing
            }
        }
        ctx.strokePath()
        if kind == "ruled" {
            ctx.setStrokeColor(margin)
            ctx.move(to: CGPoint(x: spacing * 3, y: 0))
            ctx.addLine(to: CGPoint(x: spacing * 3, y: bounds.maxY))
            ctx.strokePath()
        }
    }

    private static func drawInk(_ strokes: [StrokeDTO], _ ctx: CGContext) {
        for s in strokes {
            let path = Core.outlinePath(
                points: s.points, width: max(s.width, s.height), pressureSensitive: s.pressureSensitive, fit: s.fit, taper: true
            )
            ctx.addPath(path)
            ctx.setFillColor(color(s.color, highlighter: s.highlighter))
            ctx.fillPath(using: .winding)
        }
    }

    /// Ink as it shows on the dark page (black ink becomes warm cream).
    static func color(_ hex: String, highlighter: Bool) -> CGColor {
        var rgba = Core.adapt(Core.parseColor(hex), dark: true)
        if highlighter { rgba = (rgba & 0xFFFF_FF00) | UInt32(Core.highlighterAlpha(dark: true)) }
        return CGColor(
            srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255
        )
    }

    private static func drawImage(_ dto: ImageDTO, sectionPath: String, _ ctx: CGContext) {
        let url = URL(fileURLWithPath: sectionPath).appendingPathComponent(dto.file)
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary
        guard dto.width > 0, dto.height > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return }
        ctx.saveGState()
        // Images draw bottom-up; flip back for this one.
        ctx.translateBy(x: dto.x, y: dto.y + dto.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dto.width, height: dto.height))
        ctx.restoreGState()
    }

    private static func drawText(_ box: TextBoxDTO, _ ctx: CGContext) {
        guard !box.text.isEmpty else { return }
        var font = CTFontCreateUIFontForLanguage(.system, box.fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, box.fontSize, nil)
        var traits: CTFontSymbolicTraits = []
        if box.bold || box.heading != nil { traits.insert(.traitBold) }
        if box.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, box.fontSize, nil, traits, traits) { font = styled }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(box.color, highlighter: false),
        ]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: box.text, attributes: attributes))
        let height = box.height ?? 4000
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: height), transform: nil), nil)
        ctx.saveGState()
        // CoreText lays out bottom-up; flip for the box.
        ctx.translateBy(x: box.x, y: box.y + height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    private static func drawTable(_ table: TableDTO, _ ctx: CGContext) {
        let columns = table.rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let widths = (0..<columns).map { i in table.columnWidths.flatMap { i < $0.count ? $0[i] : nil } ?? 140 }
        ctx.setStrokeColor(muted)
        ctx.setLineWidth(1.5)
        var y = table.y
        for _ in table.rows {
            var x = table.x
            for w in widths {
                ctx.stroke(CGRect(x: x, y: y, width: w, height: 30))
                x += w
            }
            y += 30
        }
    }
}

/// Cards for pages linked from notes (Electron shows them inline): the
/// linked area of a page, or what's written on it, as a cached PNG.
public enum PageCards {
    /// The card's PNG path for page `id`, drawing it if the cached one is
    /// older than the page; nil when the page can't be found or drawn.
    public static func image(id: String, area: CGRect?, pixels: Int, root: String) -> String? {
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit }),
              let page = (try? Core.call("page_with_id", ["root": root, "id": id], as: String?.self)) ?? nil
        else { return nil }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: root).appendingPathComponent(".scribe/thumbs.nosync", isDirectory: true)
        let part = area.map { a in [a.minX, a.minY, a.width, a.height].map { String(Int($0.rounded())) }.joined(separator: "_") } ?? "page"
        let file = folder.appendingPathComponent("\(id)-card-\(part)-\(pixels).png")
        let pageDate = (try? fm.attributesOfItem(atPath: page))?[.modificationDate] as? Date
        if let made = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           let pageDate, made >= pageDate {
            return file.path
        }
        let sectionPath = URL(fileURLWithPath: page).deletingLastPathComponent().path
        guard let doc = try? Core.readPage(page) else { return nil }
        // A page on a PDF (imported slides or notes) is its PDF: the card
        // shows the whole page rather than just the ink on it.
        var crop = Thumbnails.cardCrop(doc, area: area)
        if area == nil, let pdf = PDFBackground.page(for: doc.background, sectionPath: sectionPath) {
            crop = CGRect(origin: .zero, size: PDFBackground.size(of: pdf))
        }
        guard let image = Thumbnails.render(doc, sectionPath: sectionPath, crop: crop, width: pixels),
              (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let out = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out) ? file.path : nil
    }

}
