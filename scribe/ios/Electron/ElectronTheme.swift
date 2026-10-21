import SwiftUI
import UIKit

/// The desktop's "Electron Velvet" theme (desktop/src/renderer/src/themes.ts),
/// in the redesign's palette: a near-black plum backdrop, the Library a step
/// up, the note a step above that; lavender for Electron, green tags and
/// coral for Scribe's ink.
enum EV {
    static let chrome = UIColor(hex: "#120F17")
    static let panel = UIColor(hex: "#18141E")
    static let bg = UIColor(hex: "#1B1722")
    static let bgAlt = UIColor(hex: "#1F1A26")
    static let bgSel = UIColor(hex: "#2A2335")
    static let fg = UIColor(hex: "#ECE7F3")
    /// Note text: a shade softer than headings.
    static let text = UIColor(hex: "#DDD7E6")
    static let fgDim = UIColor(hex: "#B4ADC1")
    static let fgSubtle = UIColor(hex: "#948CA3")
    static let accent = UIColor(hex: "#B39DFB")
    static let accentAlt = UIColor(hex: "#E39072")
    static let link = UIColor(hex: "#C4B2FD")
    static let wikilink = UIColor(hex: "#C4B2FD")
    static let tag = UIColor(hex: "#5FD4A4")
    static let tagText = UIColor(hex: "#7FE0B8")
    static let ink = UIColor(hex: "#E39072")
    static let code = UIColor(hex: "#F0AD93")
    static let heading = UIColor(hex: "#F4F0F8")
    static let border = UIColor(hex: "#2C2537")
    static let success = UIColor(hex: "#5FD4A4")
    static let warning = UIColor(hex: "#F0C27A")
    static let error = UIColor(hex: "#F7768E")
    static let info = UIColor(hex: "#8FB7F0")
    static let codeBg = UIColor(hex: "#241F2D")
    static let highlight = UIColor(hex: "#F0C27A").withAlphaComponent(0.28)
}

extension Color {
    static let evBg = Color(uiColor: EV.bg)
    static let evBgAlt = Color(uiColor: EV.bgAlt)
    static let evBgSel = Color(uiColor: EV.bgSel)
    static let evChrome = Color(uiColor: EV.chrome)
    static let evPanel = Color(uiColor: EV.panel)
    static let evText = Color(uiColor: EV.text)
    static let evTagText = Color(uiColor: EV.tagText)
    static let evInk = Color(uiColor: EV.ink)
    static let evFg = Color(uiColor: EV.fg)
    static let evDim = Color(uiColor: EV.fgDim)
    static let evSubtle = Color(uiColor: EV.fgSubtle)
    static let evAccent = Color(uiColor: EV.accent)
    static let evBorder = Color(uiColor: EV.border)
    static let evTag = Color(uiColor: EV.tag)
    static let evCode = Color(uiColor: EV.code)
}

/// Callout colours and icons, as the desktop's renderer has them.
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
