import CoreGraphics
import PDFKit

/// A page of a PDF used as a page's background: how imported PDFs and
/// Goodnotes exports appear. The PDF sits in the section's assets/ folder
/// (`background.asset`) and `background.pdfPage` picks the page (0-based).
///
/// The PDF page is scaled to the standard page width, so imported pages
/// line up with Scribe's own and the pen feels the same on both.
enum PDFBackground {
    /// The standard page (PageModel.defaultSize); kept here so the iPad app
    /// can share this file.
    static let standardSize = CGSize(width: 840, height: 1188)

    private static let cache = NSCache<NSString, PDFDocument>()

    /// The background's PDF page, if this background is one and the file is there.
    static func page(for background: BackgroundDTO, sectionPath: String) -> PDFPage? {
        guard background.kind.lowercased() == "pdf", let asset = background.asset, !asset.isEmpty else { return nil }
        let path = (sectionPath as NSString).appendingPathComponent(asset)
        let doc: PDFDocument
        if let cached = cache.object(forKey: path as NSString) {
            doc = cached
        } else {
            guard let loaded = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
            cache.setObject(loaded, forKey: path as NSString)
            doc = loaded
        }
        return doc.page(at: max(0, background.pdfPage ?? 0))
    }

    /// The page's size on the canvas: the standard page width, its own aspect.
    static func size(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0 else { return standardSize }
        let scale = standardSize.width / box.width
        return CGSize(width: standardSize.width, height: ceil(box.height * scale))
    }

    /// Draws `page` at the top-left of a flipped (top-down) context.
    static func draw(_ page: PDFPage, in ctx: CGContext) {
        let box = page.bounds(for: .mediaBox)
        let size = size(of: page)
        ctx.saveGState()
        // PDF space runs bottom-up; flip it into the page's top-down space.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / box.width, y: -size.height / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(box)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
    }

    /// A bitmap of the page, for reading the writing on it.
    static func image(of page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let size = size(of: page)
        let (w, h) = (Int(size.width * scale), Int(size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        // Top-down, like the page.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(page, in: ctx)
        return ctx.makeImage()
    }
}
