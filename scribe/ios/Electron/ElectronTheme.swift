import SwiftUI
import UIKit

/// The desktop's "Electron Velvet" theme (desktop/src/renderer/src/themes.ts),
/// so notes look the same on the iPad as on the Mac.
enum EV {
    static let chrome = UIColor(hex: "#0F0D13")
    static let bg = UIColor(hex: "#16131C")
    static let bgAlt = UIColor(hex: "#1C1823")
    static let bgSel = UIColor(hex: "#2A2433")
    static let fg = UIColor(hex: "#EBE6F2")
    static let fgDim = UIColor(hex: "#A49EB2")
    static let fgSubtle = UIColor(hex: "#6C657C")
    static let accent = UIColor(hex: "#A78BFA")
    static let accentAlt = UIColor(hex: "#F59E0B")
    static let link = UIColor(hex: "#7AA2F7")
    static let wikilink = UIColor(hex: "#A78BFA")
    static let tag = UIColor(hex: "#34D399")
    static let code = UIColor(hex: "#F9A3B3")
    static let heading = UIColor(hex: "#F3EEF9")
    static let border = UIColor(hex: "#322B3D")
    static let success = UIColor(hex: "#34D399")
    static let warning = UIColor(hex: "#F59E0B")
    static let error = UIColor(hex: "#F7768E")
    static let info = UIColor(hex: "#7AA2F7")
    static let codeBg = UIColor(white: 0, alpha: 0.24)
    static let highlight = UIColor(hex: "#F59E0B").withAlphaComponent(0.28)
}

extension Color {
    static let evBg = Color(uiColor: EV.bg)
    static let evBgAlt = Color(uiColor: EV.bgAlt)
    static let evBgSel = Color(uiColor: EV.bgSel)
    static let evChrome = Color(uiColor: EV.chrome)
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
