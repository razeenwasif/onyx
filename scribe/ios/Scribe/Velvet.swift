import SwiftUI
import UIKit

/// The Mac app's dark velvet palette (Theme.swift), for UIKit and SwiftUI.
enum Velvet {
    static let backdrop = UIColor(hex: "#131116")
    static let page = UIColor(hex: "#1C1920")
    static let rule = UIColor(white: 1, alpha: 0.05)
    static let marginRule = UIColor(hex: "#E39072").withAlphaComponent(0.35)
    static let tableRule = UIColor(white: 1, alpha: 0.12)
    static let accent = UIColor(hex: "#E39072")
    static let text = UIColor(hex: "#EEE8F0")
    static let muted = UIColor(hex: "#A69DAB")
    static let control = UIColor(hex: "#2C2732")
    static let sidebar = UIColor(hex: "#17141A")
}

extension Color {
    static let velvetAccent = Color(uiColor: Velvet.accent)
    static let velvetMuted = Color(uiColor: Velvet.muted)
    static let velvetText = Color(uiColor: Velvet.text)
    static let velvetBackdrop = Color(uiColor: Velvet.backdrop)
    static let velvetSidebar = Color(uiColor: Velvet.sidebar)

    /// How an ink colour looks on the dark page.
    static func ink(_ hex: String) -> Color {
        Color(cgColor: InkPaint.color(hex: hex, highlighter: false))
    }
}
