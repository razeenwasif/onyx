import AppKit
import CScribeCore

/// Swift face of the Rust core (crates/scribe-core).
///
/// Storage, search, tables and settings go through `call`, a JSON request /
/// response channel. Ink geometry is on the per-sample path while writing, so
/// it uses the raw buffer entry points instead.
enum Core {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let result: Result<T, Failure>

        private enum Key: String, CodingKey { case ok, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            if let error = try c.decodeIfPresent(String.self, forKey: .error) {
                result = .failure(Failure(message: error))
            } else {
                // Decoding `ok` as T directly lets an Optional T accept null.
                result = .success(try c.decode(T.self, forKey: .ok))
            }
        }
    }

    /// Runs one core operation. `args` must be JSON-serialisable; `Encodable`
    /// values are encoded first.
    static func call<T: Decodable>(_ op: String, _ args: [String: Any] = [:], as: T.Type = T.self) throws -> T {
        var request = args
        request["op"] = op

        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "bad request") }

        guard let raw = scribe_call(text) else { throw Failure(message: "core returned nothing") }
        defer { scribe_string_free(raw) }

        let reply = Data(bytes: raw, count: strlen(raw))
        return try JSONDecoder().decode(Envelope<T>.self, from: reply).result.get()
    }

    /// For operations whose result does not matter.
    static func run(_ op: String, _ args: [String: Any] = [:]) throws {
        _ = try call(op, args, as: JSONAny?.self)
    }

    /// Accepts any JSON value and keeps nothing.
    private struct JSONAny: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// Converts an `Encodable` into the `Any` tree `JSONSerialization` wants.
    static func json<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // ------------------------------------------------------------- geometry

    private static func withFloats<R>(_ values: [Double], _ body: (UnsafePointer<Double>?, Int) -> R) -> R {
        values.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
    }

    private static func take(_ f: ScribeFloats) -> [Double] {
        defer { scribe_floats_free(f) }
        guard let ptr = f.ptr, f.len > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: f.len))
    }

    /// Filled outline of a pressure-varying stroke (non-zero fill rule).
    static func outlinePath(points: [Double], width: Double, pressureSensitive: Bool, fit: Bool, taper: Bool) -> CGPath {
        let poly = withFloats(points) { take(scribe_stroke_outline($0, $1, width, pressureSensitive, fit, taper)) }
        return polygonPath(poly)
    }

    static func polygonPath(_ poly: [Double]) -> CGPath {
        let path = CGMutablePath()
        guard poly.count >= 6 else { return path }
        path.move(to: CGPoint(x: poly[0], y: poly[1]))
        var i = 2
        while i + 1 < poly.count {
            path.addLine(to: CGPoint(x: poly[i], y: poly[i + 1]))
            i += 2
        }
        path.closeSubpath()
        return path
    }

    static func strokeBounds(points: [Double], width: Double) -> CGRect {
        var out = [Double](repeating: 0, count: 4)
        withFloats(points) { ptr, n in
            out.withUnsafeMutableBufferPointer { scribe_stroke_bounds(ptr, n, width, $0.baseAddress) }
        }
        return CGRect(x: out[0], y: out[1], width: out[2], height: out[3])
    }

    static func strokeHit(points: [Double], width: Double, at p: CGPoint, radius: Double) -> Bool {
        withFloats(points) { scribe_stroke_hit($0, $1, width, p.x, p.y, radius) }
    }

    /// `nil` when the eraser missed. Otherwise the surviving pieces, possibly
    /// none.
    static func strokeErase(points: [Double], width: Double, fit: Bool, at p: CGPoint, radius: Double) -> [[Double]]? {
        let buf = withFloats(points) { take(scribe_stroke_erase($0, $1, width, fit, p.x, p.y, radius)) }
        guard let count = buf.first else { return nil }

        var pieces: [[Double]] = []
        var i = 1
        for _ in 0..<Int(count) {
            guard i < buf.count else { break }
            let n = Int(buf[i])
            pieces.append(Array(buf[(i + 1)..<(i + 1 + n)]))
            i += 1 + n
        }
        return pieces
    }

    static func lassoFraction(lasso: [Double], points: [Double]) -> Double {
        lasso.withUnsafeBufferPointer { l in
            withFloats(points) { scribe_lasso_fraction(l.baseAddress, l.count, $0, $1) }
        }
    }

    static func pointInPolygon(_ poly: [Double], _ p: CGPoint) -> Bool {
        withFloats(poly) { scribe_point_in_polygon($0, $1, p.x, p.y) }
    }

    // ---------------------------------------------------------------- colour

    /// Packed 0xRRGGBBAA.
    static func parseColor(_ hex: String, fallback: UInt32 = 0x1A1A_1AFF) -> UInt32 {
        scribe_parse_color(hex, fallback)
    }

    static func adapt(_ rgba: UInt32, dark: Bool) -> UInt32 {
        scribe_adapt_color(rgba, dark)
    }

    static func highlighterAlpha(dark: Bool) -> UInt8 {
        scribe_highlighter_alpha(dark)
    }
}

extension NSColor {
    convenience init(rgba: UInt32) {
        self.init(
            srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }

    convenience init(hex: String, fallback: UInt32 = 0x1A1A_1AFF) {
        self.init(rgba: Core.parseColor(hex, fallback: fallback))
    }

    /// `#RRGGBB`, or `#AARRGGBB` when translucent, as the format stores it.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 255).rounded())
        return a == 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }
}
