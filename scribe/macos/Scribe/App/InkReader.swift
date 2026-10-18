import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Reads handwriting into text so search can find written words, using the
/// system's own text recognition (Vision). Shared by the Mac and the iPad. The core keeps the results in the
/// workspace's ink-text index (crates/scribe-core/src/ink.rs); page files are
/// never touched.
///
/// A page is read a moment after it's saved, and on start a background pass
/// works through older pages whose ink has never been read or has changed
/// since. Rendering goes through the core (main thread); recognition runs on a
/// background queue.
final class InkReader {
    /// Everything happens here, off the main thread: reading a big page,
    /// building its outlines and rendering it took seconds, and on the main
    /// thread that froze the app after saves and through a backfill.
    private let queue = DispatchQueue(label: "app.scribe.ink-reader", qos: .utility)
    /// Debounced reads after saves, by page id (touched on the main thread).
    private var scheduled: [String: DispatchWorkItem] = [:]
    /// Bumped when a backfill is replaced (another start, a new workspace).
    private let generation = Generation()

    private final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        func isCurrent(_ v: Int) -> Bool { lock.withLock { value == v } }
    }

    /// After a save: read the page's ink once editing pauses.
    func pageSaved(_ doc: PageDoc, modified: Double, root: String, sectionPath: String) {
        scheduled[doc.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Self.read(doc, sectionPath: sectionPath, modified: modified, root: root)
            DispatchQueue.main.async { self?.scheduled[doc.id] = nil }
        }
        scheduled[doc.id] = work
        queue.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Works through every page whose ink hasn't been read since it changed,
    /// most recently edited first, one page at a time in the background.
    func backfill(root: String) {
        let mine = generation.next()
        queue.async { [generation] in
            guard let pending: [PendingInk] = try? Core.call("ink_pending", ["root": root]) else { return }
            for item in pending {
                guard generation.isCurrent(mine) else { return }
                autoreleasepool {
                    guard let doc = try? Core.readPage(item.path) else { return }
                    Self.read(doc, sectionPath: (item.path as NSString).deletingLastPathComponent, modified: item.modified, root: root)
                }
                // Leave the machine room between pages.
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    private static func read(_ doc: PageDoc, sectionPath: String, modified: Double, root: String) {
        // No ink left (all erased) still records an empty result, which
        // clears any text kept from before.
        let image = render(doc)
        // An imported PDF page: its own text layer, plus the writing drawn
        // on it (Goodnotes exports handwriting as shapes, not text).
        let pdf = PDFBackground.page(for: doc.background, sectionPath: sectionPath)
        let pdfText = pdf?.string ?? ""
        let pdfImage = pdf.flatMap { PDFBackground.image(of: $0) }
        let parts = [image.map(recognize), pdfImage.map(recognize), pdfText]
        let text = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        _ = try? Core.call("set_ink_text", ["root": root, "id": doc.id, "text": text, "modified": modified], as: String?.self)
    }

    /// The page's ink, black on white, cropped to the writing. Highlighter
    /// strokes are left out: they cover words rather than form them.
    static func render(_ doc: PageDoc) -> CGImage? {
        let strokes = doc.strokes.filter { !$0.highlighter && !$0.points.isEmpty }.map {
            Core.outlinePath(points: $0.points, width: max($0.width, $0.height), pressureSensitive: $0.pressureSensitive, fit: $0.fit, taper: true)
        }
        guard !strokes.isEmpty else { return nil }
        let bounds = strokes
            .map { $0.boundingBoxOfPath }
            .reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -24, dy: -24)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Twice page resolution reads best; very large pages scale down to
        // keep the bitmap reasonable.
        let scale = min(2, 6000 / max(bounds.width, bounds.height))
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Page coordinates run top-down; flip so the writing comes out upright.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        ctx.setFillColor(gray: 0, alpha: 1)
        for stroke in strokes {
            ctx.addPath(stroke)
            ctx.fillPath(using: .winding)
        }
        return ctx.makeImage()
    }

    /// The text Vision reads in `image`, one line per line of writing, top to
    /// bottom.
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return ""
        }
        // Vision's boxes are normalised with the origin at the bottom left.
        let lines = (request.results ?? []).sorted { a, b in
            let (ya, yb) = (a.boundingBox.midY, b.boundingBox.midY)
            return abs(ya - yb) > 0.01 ? ya > yb : a.boundingBox.minX < b.boundingBox.minX
        }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// A page the core says needs its ink read.
struct PendingInk: Decodable {
    var id: String
    var path: String
    var modified: Double
}
