import Foundation

// The page file format as the app sees it. Mirrors crates/scribe-core/src/
// model.rs; docs/FORMAT.md is the contract. Fields this app does not know are
// preserved by the core when a page is written, so these types only list the
// documented ones.

struct PageDoc: Codable {
    var schema: String = "scribe.page/1"
    var id: String = newID()
    var title: String = "Untitled page"
    var created: String?
    var modified: String?
    var background = BackgroundDTO()
    var strokes: [StrokeDTO] = []
    var textBoxes: [TextBoxDTO] = []
    var images: [ImageDTO] = []
    var latexBlocks: [LatexDTO] = []
    var tables: [TableDTO] = []
    var source: SourceDTO?
    /// "canvas" for a page without fixed paper (imported from OneNote): it
    /// grows as you write past an edge. Absent for ordinary pages.
    var layout: String?

    var isCanvas: Bool { layout == "canvas" }
}

struct BackgroundDTO: Codable, Equatable {
    /// blank, ruled, grid or dots.
    var kind: String = "ruled"
    var spacing: Double = 32
    /// Light-mode rule colour.
    var color: String = "#E8EEF5"
    /// kind "pdf": the PDF in the section's assets/ folder, and which of its
    /// pages (0-based) this page shows. See PDFBackground.
    var asset: String?
    var pdfPage: Int?
}

struct StrokeDTO: Codable, Equatable {
    var color: String = "#1A1A1A"
    var width: Double = 2.4
    var height: Double = 2.4
    var tip: String = "ellipse"
    var highlighter: Bool = false
    var fit: Bool = true
    var pressureSensitive: Bool = true
    /// Flat, stride 3: x, y, pressure.
    var points: [Double] = []

    init(color: String = "#1A1A1A", width: Double = 2.4, height: Double = 2.4, tip: String = "ellipse",
         highlighter: Bool = false, fit: Bool = true, pressureSensitive: Bool = true, points: [Double] = []) {
        self.color = color
        self.width = width
        self.height = height
        self.tip = tip
        self.highlighter = highlighter
        self.fit = fit
        self.pressureSensitive = pressureSensitive
        self.points = points
    }

    // Points cross to and from the core packed: base64 little-endian
    // Float32s in `pointsPacked` (crates/scribe-core/src/model.rs
    // pack_points). Decoding millions of JSON numbers was most of what
    // opening a big page cost. Plain `points` are read too.
    private enum Keys: String, CodingKey {
        case color, width, height, tip, highlighter, fit, pressureSensitive, points, pointsPacked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#1A1A1A"
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 2.4
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? width
        tip = try c.decodeIfPresent(String.self, forKey: .tip) ?? "ellipse"
        highlighter = try c.decodeIfPresent(Bool.self, forKey: .highlighter) ?? false
        fit = try c.decodeIfPresent(Bool.self, forKey: .fit) ?? true
        pressureSensitive = try c.decodeIfPresent(Bool.self, forKey: .pressureSensitive) ?? true
        if let packed = try c.decodeIfPresent(String.self, forKey: .pointsPacked), let data = Data(base64Encoded: packed) {
            points = data.withUnsafeBytes { raw in
                raw.bindMemory(to: Float32.self).map { Double(Float32(bitPattern: $0.bitPattern.littleEndian)) }
            }
        } else {
            points = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(tip, forKey: .tip)
        try c.encode(highlighter, forKey: .highlighter)
        try c.encode(fit, forKey: .fit)
        try c.encode(pressureSensitive, forKey: .pressureSensitive)
        var bytes = [UInt8]()
        bytes.reserveCapacity(points.count * 4)
        for v in points {
            withUnsafeBytes(of: Float32(v).bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        try c.encode(Data(bytes).base64EncodedString(), forKey: .pointsPacked)
    }
}

struct TextSpanDTO: Codable, Equatable {
    var start: Int
    var length: Int
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var fontSize: Double?
    var fontFamily: String?
    var color: String?
}

struct TextBoxDTO: Codable, Equatable {
    var id: String = newID()
    var x: Double = 0
    var y: Double = 0
    var width: Double = 320
    var height: Double?
    var text: String = ""
    var fontFamily: String = "Segoe UI"
    var fontSize: Double = 15
    var color: String = "#1A1A1A"
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var heading: String?
    var spans: [TextSpanDTO]?
    var xaml: String?
}

struct ImageDTO: Codable, Equatable {
    var id: String = newID()
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var file: String = ""
}

struct LatexDTO: Codable, Equatable {
    var id: String = newID()
    var x: Double = 0
    var y: Double = 0
    var latex: String = ""
    var scale: Double = 20
    var color: String = "#1A1A1A"
}

struct TableDTO: Codable, Equatable {
    var id: String = newID()
    var x: Double = 0
    var y: Double = 0
    var rows: [[String]] = []
    var columnWidths: [Double]?
    var hasHeader: Bool = true
}

struct SourceDTO: Codable, Equatable {
    var app: String = "onenote"
    var id: String?
    var importedAt: String?
}

// ------------------------------------------------------------- workspace

/// A Scribe notebook, shown in the library as a "folder" of notebooks.
struct NotebookInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var color: String
    var path: String
    var sections: [SectionInfo]
    /// When a page in it last changed (Unix seconds).
    var modified: Double?
}

/// A Scribe section, shown in the library as a "notebook" with a cover.
struct SectionInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var color: String
    var path: String
    var notebookPath: String
    var pageCount: Int
    /// When a page in it last changed (Unix seconds).
    var modified: Double?
    /// The page shown as its cover: the first, or the latest edited.
    var cover: PageInfo?
    /// "first" or "latest".
    var coverChoice: String?
}

struct PageInfo: Codable, Identifiable, Hashable {
    var title: String
    var path: String
    var sectionPath: String
    /// Unix seconds; 0 when unknown.
    var modified: Double
    /// The start of the page's typed text.
    var snippet: String
    /// The page's own id (the file's `id`), for caches such as thumbnails.
    var pageId: String?
    /// Starred in the page grid.
    var bookmarked: Bool?

    var id: String { path }
    var isBookmarked: Bool { bookmarked ?? false }

    var modifiedDate: Date? { modified > 0 ? Date(timeIntervalSince1970: modified) : nil }
}

struct Settings: Codable, Equatable {
    var workspaceRoot: String?
    var lastPageFile: String?
    var darkMode: Bool = true
    var penWidths: [String: Double] = [:]
    var sidebarCollapsed: Bool = false
    var pageListCollapsed: Bool = false
}

struct ParsedTable: Codable {
    var rows: [[String]]
    var hasHeader: Bool
}

struct ExportedTable: Codable {
    var tsv: String
    var html: String
    var markdown: String
}

struct WriteResult: Codable {
    var modified: String
    var modifiedUnix: Double
}

struct AssetSlot: Codable {
    /// Absolute path to write the file to.
    var path: String
    /// Section-relative path to store in the page.
    var rel: String
}

/// 32 lowercase hex digits, the same shape the core and the Windows app use.
func newID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

// ------------------------------------------------------------------- links

/// A link from a Markdown note to a Scribe page, or to an area of one:
/// `[[scribe:<id>|Title]]` or `[[scribe:<id>#x,y,w,h|Title]]`, the area in
/// page units. Pages are named by id so the link survives a rename or move
/// (see scribe-core links.rs).
struct ScribeLink: Hashable {
    static let scheme = "scribe:"

    var pageId: String
    var area: CGRect?

    init(pageId: String, area: CGRect? = nil) {
        self.pageId = pageId
        self.area = area
    }

    /// Parses a wikilink target (the part before any `|`), or nil if it
    /// doesn't name a Scribe page.
    init?(target: String) {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix(Self.scheme) else { return nil }
        let rest = t.dropFirst(Self.scheme.count)
        let parts = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let id = parts[0].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        pageId = id
        if parts.count > 1 {
            let n = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if n.count == 4, n[2] > 0, n[3] > 0 { area = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        }
    }

    /// The target, without the `[[ ]]` or alias.
    var target: String {
        guard let a = area?.integral else { return Self.scheme + pageId }
        return Self.scheme + pageId + "#\(Int(a.minX)),\(Int(a.minY)),\(Int(a.width)),\(Int(a.height))"
    }

    /// The whole wikilink, shown as `title` where the note is read.
    func markdown(title: String) -> String {
        // `|` and brackets would end the link early.
        let shown = title.replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespaces)
        return "[[\(target)|\(shown.isEmpty ? "Untitled" : shown)]]"
    }
}

/// A page as links see it (scribe-core link_index).
struct LinkedPage: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var path: String
    var notebook: String
    var section: String
    var modified: Double
    /// `[[…]]` targets typed on the page: note names, or `scribe:` pages.
    var links: [String]
}

/// A vault note linking to a page (scribe-core notes_linking_to).
struct LinkingNote: Codable, Hashable, Identifiable {
    /// Vault-relative.
    var path: String
    var title: String
    var id: String { path }
}
