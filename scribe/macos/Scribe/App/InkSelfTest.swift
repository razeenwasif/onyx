import AppKit

/// Draws sample strokes through the same code path the pen uses, to a PNG.
///
/// Ink cannot be exercised by UI automation (synthetic mouse events carry no
/// pressure), so this sheet is how the engine is checked: pressure response,
/// tapering, smoothing, the highlighter, dots, and a stroke round-tripped
/// through the JSON page format.
enum InkSelfTest {
    static let width = 900
    static let band = 620

    static func render(to url: URL) throws {
        let height = band * 2
        guard let ctx = CGContext(
            data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Core.Failure(message: "no bitmap context") }

        // Retina scale, with a top-left origin like the page.
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        try drawBand(ctx, top: 0, dark: true)
        try drawBand(ctx, top: CGFloat(band), dark: false)

        guard let image = ctx.makeImage() else { throw Core.Failure(message: "no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Core.Failure(message: "png encode") }
        try png.write(to: url)
    }

    private static func drawBand(_ ctx: CGContext, top: CGFloat, dark: Bool) throws {
        let palette = Palette.of(dark: dark)
        ctx.setFillColor(palette.page.cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: CGFloat(width), height: CGFloat(band)))

        ctx.setStrokeColor(palette.rule.cgColor)
        ctx.setLineWidth(1)
        var y = top + 32
        while y < top + CGFloat(band) {
            ctx.move(to: CGPoint(x: 0, y: y + 0.5))
            ctx.addLine(to: CGPoint(x: CGFloat(width), y: y + 0.5))
            y += 32
        }
        ctx.strokePath()

        let label = palette.mutedText
        text(dark ? "Dark page" : "Light page", at: CGPoint(x: 24, y: top + 12), size: 15, color: label, bold: true)

        let black = "#1A1A1A", blue = "#1D4ED8", red = "#C02828", yellow = "#FFE03D"
        var y0 = top + 52

        text("Pressure 0 → 1 → 0", at: CGPoint(x: 24, y: y0), size: 11, color: label)
        draw(ctx, wave(x: 60, y: y0 + 46, length: 700), color: black, width: 3.2, dark: dark)
        y0 += 86

        text("Same stroke, pressure off (even width)", at: CGPoint(x: 24, y: y0), size: 11, color: label)
        draw(ctx, wave(x: 60, y: y0 + 46, length: 700), color: black, width: 3.2, dark: dark, pressure: false)
        y0 += 86

        text("Handwriting, 2.4pt nib", at: CGPoint(x: 24, y: y0), size: 11, color: label)
        draw(ctx, cursive(x: 60, y: y0 + 46, length: 760), color: black, width: 2.4, dark: dark)
        y0 += 86

        text("Fine nib 1.2pt, and colour", at: CGPoint(x: 24, y: y0), size: 11, color: label)
        draw(ctx, cursive(x: 60, y: y0 + 40, length: 360), color: blue, width: 1.2, dark: dark)
        draw(ctx, cursive(x: 440, y: y0 + 40, length: 360), color: red, width: 2.0, dark: dark)
        y0 += 80

        text("Highlighter over ink", at: CGPoint(x: 24, y: y0), size: 11, color: label)
        draw(ctx, cursive(x: 60, y: y0 + 44, length: 500), color: black, width: 2.4, dark: dark)
        draw(ctx, [(60, y0 + 44, 0.5), (560, y0 + 44, 0.5)], color: yellow, width: 17, dark: dark, pressure: false, highlighter: true)
        y0 += 80

        text("Single taps (dots), pressure 0.8 and 0.3", at: CGPoint(x: 24, y: y0), size: 11, color: label)
        draw(ctx, [(70, y0 + 30, 0.8)], color: black, width: 4, dark: dark)
        draw(ctx, [(100, y0 + 30, 0.3)], color: black, width: 4, dark: dark)

        text("Round-tripped through the JSON page format", at: CGPoint(x: 330, y: y0), size: 11, color: label)
        let roundTripped = try roundTrip(wave(x: 330, y: y0 + 40, length: 480).flatMap { [$0.0, $0.1, $0.2] })
        draw(ctx, stride(from: 0, to: roundTripped.count - 2, by: 3).map { (roundTripped[$0], roundTripped[$0 + 1], roundTripped[$0 + 2]) },
             color: black, width: 3.2, dark: dark)
    }

    /// Writes a stroke into a page file and reads it back through the core.
    private static func roundTrip(_ points: [Double]) throws -> [Double] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-selftest-\(newID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("page.json").path
        var doc = PageDoc()
        doc.strokes = [StrokeDTO(points: points)]
        let _: WriteResult = try Core.call("write_page", ["path": file, "page": try Core.json(doc)])
        let back: PageDoc = try Core.call("read_page", ["path": file])
        guard let s = back.strokes.first else { throw Core.Failure(message: "stroke lost in round trip") }
        return s.points
    }

    private static func draw(_ ctx: CGContext, _ samples: [(Double, Double, Double)], color: String, width: Double,
                             dark: Bool, pressure: Bool = true, highlighter: Bool = false) {
        let stroke = InkStroke(StrokeDTO(
            color: color, width: width, height: width, highlighter: highlighter, fit: true,
            pressureSensitive: pressure, points: samples.flatMap { [$0.0, $0.1, $0.2] }
        ))
        ctx.addPath(stroke.path)
        ctx.setFillColor(stroke.paint(dark: dark).cgColor)
        ctx.fillPath(using: .winding)
    }

    private static func wave(x: Double, y: Double, length: Double) -> [(Double, Double, Double)] {
        let n = 90
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            let pressure = max(0.02, sin(.pi * t))
            return (x + t * length, y + sin(t * .pi * 4) * 14, pressure)
        }
    }

    /// A looping cursive line, sampled unevenly the way a fast hand is.
    private static func cursive(x: Double, y: Double, length: Double) -> [(Double, Double, Double)] {
        let loops = max(3, Int(length / 46))
        let n = loops * 22
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            let phase = t * Double(loops) * 2 * .pi
            let px = x + t * length + cos(phase) * 9
            let py = y - (sin(phase) * 13 + 4)
            let pressure = 0.35 + 0.5 * max(0, sin(phase + .pi / 3))
            return (px, py, min(1, max(0.02, pressure)))
        }
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, bold: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: color,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }
}
