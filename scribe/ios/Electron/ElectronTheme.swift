import SwiftUI
import UIKit

/// Pitch-black Stratus / T3 Code-inspired design tokens for Electron iOS.
/// Zero borders, zero pane dividers, pure typographic hierarchy and subtle
/// tonal elevation (`#000000` / `#030304` / `#060608` / `#0B0B0E`).
enum EV {
    // MARK: - Surfaces
    static let chrome = UIColor(hex: "#000000")
    static let bg = UIColor(hex: "#000000")
    static let panel = UIColor(hex: "#030304")
    static let inspector = UIColor(hex: "#060608")
    static let sheet = UIColor(hex: "#050507")
    static let palette = UIColor(hex: "#0B0B0F")
    static let surfaceSubtle = UIColor(hex: "#0B0B0E")
    static let bgAlt = UIColor(hex: "#111114")
    static let bgSel = UIColor(hex: "#16161B")
    static let surfacePill = UIColor(hex: "#151519")

    // MARK: - Typography
    static let fg = UIColor(hex: "#F4F4F6")
    static let heading = UIColor(hex: "#F4F4F6")
    /// Note body text: slightly softer than headings on pure black.
    static let text = UIColor(hex: "#E2E2E8")
    static let fgDim = UIColor(hex: "#8E8E99")
    static let fgMuted = UIColor(hex: "#6E6E77")
    static let fgSubtle = UIColor(hex: "#585862")

    // MARK: - Accents
    static let accent = UIColor(hex: "#7A89FF")
    static let wikilink = UIColor(hex: "#7A89FF")
    static let link = UIColor(hex: "#4BC3F7")
    static let info = UIColor(hex: "#4BC3F7")
    static let tag = UIColor(hex: "#34D399")
    static let tagText = UIColor(hex: "#34D399")
    static let success = UIColor(hex: "#34D399")
    static let ink = UIColor(hex: "#E88255")
    static let accentAlt = UIColor(hex: "#E88255")
    static let code = UIColor(hex: "#E88255")
    static let warning = UIColor(hex: "#FBBF24")
    static let error = UIColor(hex: "#F87171")
    static let violet = UIColor(hex: "#A78BFA")

    static let border = UIColor(hex: "#16161B")
    static let codeBg = UIColor(hex: "#0B0B0E")
    static let highlight = UIColor(hex: "#FBBF24").withAlphaComponent(0.24)
}

extension Color {
    static let evBg = Color(uiColor: EV.bg)
    static let evChrome = Color(uiColor: EV.chrome)
    static let evPanel = Color(uiColor: EV.panel)
    static let evInspector = Color(uiColor: EV.inspector)
    static let evSheet = Color(uiColor: EV.sheet)
    static let evPalette = Color(uiColor: EV.palette)
    static let evSurfaceSubtle = Color(uiColor: EV.surfaceSubtle)
    static let evBgAlt = Color(uiColor: EV.bgAlt)
    static let evBgSel = Color(uiColor: EV.bgSel)
    static let evSurfacePill = Color(uiColor: EV.surfacePill)

    static let evFg = Color(uiColor: EV.fg)
    static let evText = Color(uiColor: EV.text)
    static let evDim = Color(uiColor: EV.fgDim)
    static let evMuted = Color(uiColor: EV.fgMuted)
    static let evSubtle = Color(uiColor: EV.fgSubtle)

    static let evAccent = Color(uiColor: EV.accent)
    static let evSky = Color(uiColor: EV.link)
    static let evMint = Color(uiColor: EV.success)
    static let evCoral = Color(uiColor: EV.ink)
    static let evAmber = Color(uiColor: EV.warning)
    static let evRose = Color(uiColor: EV.error)
    static let evViolet = Color(uiColor: EV.violet)
    static let evTag = Color(uiColor: EV.tag)
    static let evTagText = Color(uiColor: EV.tagText)
    static let evInk = Color(uiColor: EV.ink)
    static let evCode = Color(uiColor: EV.code)
    static let evBorder = Color(uiColor: EV.border)
}

/// Callout colours and icons, aligned with Stratus accents.
enum Callouts {
    static func color(_ type: String) -> UIColor {
        switch type {
        case "note", "abstract", "summary", "tldr", "info", "todo": EV.info
        case "tip", "hint", "important", "success", "check", "done": EV.success
        case "question", "help", "faq", "warning", "caution", "attention": EV.warning
        case "failure", "fail", "missing", "danger", "error", "bug": EV.error
        case "quote", "cite": EV.fgSubtle
        default: EV.accent
        }
    }

    static func icon(_ type: String) -> String {
        switch type {
        case "note": "pencil"
        case "abstract", "summary", "tldr": "list.bullet.clipboard"
        case "info": "info.circle"
        case "todo": "checkmark.circle"
        case "tip", "hint", "important": "flame"
        case "success", "check", "done": "checkmark"
        case "question", "help", "faq": "questionmark.circle"
        case "warning", "caution", "attention": "exclamationmark.triangle"
        case "failure", "fail", "missing": "xmark"
        case "danger", "error": "bolt"
        case "bug": "ladybug"
        case "example": "list.number"
        case "quote", "cite": "quote.opening"
        default: "pencil"
        }
    }
}
