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
}

struct BackgroundDTO: Codable, Equatable {
    /// blank, ruled, grid or dots.
    var kind: String = "ruled"
    var spacing: Double = 32
    /// Light-mode rule colour.
    var color: String = "#E8EEF5"
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

struct NotebookInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var color: String
    var path: String
    var sections: [SectionInfo]
}

struct SectionInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var color: String
    var path: String
    var notebookPath: String
    var pageCount: Int
}

struct PageInfo: Codable, Identifiable, Hashable {
    var title: String
    var path: String
    var sectionPath: String
    /// Unix seconds; 0 when unknown.
    var modified: Double
    /// The start of the page's typed text.
    var snippet: String

    var id: String { path }

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
