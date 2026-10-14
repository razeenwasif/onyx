import Foundation

enum ToolKind: String, CaseIterable, Identifiable {
    case pen
    case highlighter
    /// Removes whole strokes on contact.
    case strokeEraser
    /// Rubs away only the part of a stroke under the tip.
    case pointEraser
    /// Lasso selection of ink and objects.
    case select
    /// Click anywhere to place a text box; objects become editable.
    case text
    /// Drag to move the page.
    case pan

    var id: String { rawValue }

    var isInk: Bool { self == .pen || self == .highlighter }
    var isEraser: Bool { self == .strokeEraser || self == .pointEraser }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .strokeEraser: "Eraser"
        case .pointEraser: "Partial Eraser"
        case .select: "Lasso Select"
        case .text: "Text"
        case .pan: "Pan"
        }
    }

    var shortcut: Character? {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .strokeEraser: "e"
        case .select: "s"
        case .text: "t"
        case .pointEraser, .pan: nil
        }
    }
}

/// A named ink colour. `hex` is what is stored in the page; the app paints
/// it adapted for the dark page (black ink shows as warm cream).
struct InkColor: Identifiable, Equatable {
    var name: String
    var hex: String
    var id: String { hex }

    /// Distinguishable on the dark page and for the common forms of colour
    /// blindness (no red/green-only pairing).
    static let inks: [InkColor] = [
        InkColor(name: "Black", hex: "#1A1A1A"),
        InkColor(name: "Blue", hex: "#1D4ED8"),
        InkColor(name: "Rose", hex: "#C02848"),
        InkColor(name: "Sage", hex: "#157F3C"),
        InkColor(name: "Lavender", hex: "#6D3FD1"),
        InkColor(name: "Amber", hex: "#B7791F"),
        InkColor(name: "Clay", hex: "#B85C3B"),
    ]

    static let highlights: [InkColor] = [
        InkColor(name: "Yellow", hex: "#FFE03D"),
        InkColor(name: "Green", hex: "#8CE99B"),
        InkColor(name: "Pink", hex: "#FF9EC7"),
        InkColor(name: "Sky", hex: "#8FD3FF"),
    ]
}

/// The pen or the highlighter as currently set up.
struct Pen: Equatable {
    var color: String
    /// Nib width at full pressure, in page units.
    var width: Double
    var pressureSensitive: Bool
    var highlighter: Bool

    static let defaultPen = Pen(color: "#1A1A1A", width: 2.4, pressureSensitive: true, highlighter: false)
    static let defaultHighlighter = Pen(color: "#FFE03D", width: 16, pressureSensitive: false, highlighter: true)

    var widthRange: ClosedRange<Double> { highlighter ? 4...40 : 0.5...12 }
}
