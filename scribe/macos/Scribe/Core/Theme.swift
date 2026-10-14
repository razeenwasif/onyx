import AppKit
import CoreText
import SwiftUI

/// Velvet dark: depth from layered surfaces and soft light, never outlines.
/// Every corner is rounded and every control is a pill or a circle, so the
/// chrome steps back and the page and the ink lead.
enum Velvet {
    // Surfaces, back to front.
    static let ground = Color(hex: 0x0E0C10)
    static let editor = Color(hex: 0x131116)
    static let list = Color(hex: 0x151217)
    static let sidebar = Color(hex: 0x17141A)
    static let page = Color(hex: 0x1C1920)
    static let field = Color(hex: 0x1F1B23)
    static let button = Color(hex: 0x1E1A22)
    static let raised = Color(hex: 0x221D27)
    static let control = Color(hex: 0x2C2732)
    /// Floating chrome (dock, pills, popovers) sits on a blur.
    static let floating = Color(red: 34 / 255, green: 30 / 255, blue: 39 / 255).opacity(0.88)
    static let popover = Color(red: 36 / 255, green: 31 / 255, blue: 41 / 255).opacity(0.96)

    // Type.
    static let text = Color(hex: 0xEEE8F0)
    static let secondary = Color(hex: 0xCFC6D3)
    static let muted = Color(hex: 0xA69DAB)
    static let faint = Color(hex: 0x8F8595)
    static let danger = Color(hex: 0xF0A3A3)
    /// Dark text on accent fills.
    static let onAccent = Color(hex: 0x1B1418)

    // Terracotta: sits beside ink without competing with it.
    static let accentHex: UInt32 = 0xE39072
    static let accent = Color(hex: accentHex)
    static let accentSoft = accent.opacity(0.14)
    static let accentRing = accent.opacity(0.35)
    static let accentText = Color(hex: 0xFBF1EE)

    /// The faint light along the top edge of every surface.
    static let sheen = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.06)

    enum Radius {
        static let popover: CGFloat = 26
        static let panel: CGFloat = 22
        static let page: CGFloat = 24
        static let card: CGFloat = 18
        static let row: CGFloat = 14
        static let chip: CGFloat = 11
    }

    // ----------------------------------------------------------------- fonts

    /// Registers the bundled Fraunces once, at launch.
    static func registerFonts() {
        guard let url = Bundle.module.url(forResource: "Fraunces", withExtension: "ttf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private static func axis(_ tag: String) -> Int {
        tag.unicodeScalars.reduce(0) { ($0 << 8) | Int($1.value) }
    }

    /// Fraunces at its softest: the serifs round off, which is what gives
    /// page titles their velvet feel.
    static func titleNSFont(_ size: CGFloat, weight: CGFloat = 520) -> NSFont {
        let base = NSFontDescriptor(name: "Fraunces-Regular", size: size)
        let variation: [Int: CGFloat] = [
            axis("SOFT"): 100,
            axis("WONK"): 0,
            axis("opsz"): min(144, max(9, size * 2)),
            axis("wght"): weight,
        ]
        let desc = base.addingAttributes([.variation: variation])
        guard let font = NSFont(descriptor: desc, size: size), font.familyName == "Fraunces" else {
            return NSFont(descriptor: NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.serif)
                ?? NSFont.systemFont(ofSize: size).fontDescriptor, size: size) ?? .systemFont(ofSize: size)
        }
        return font
    }

    static func title(_ size: CGFloat, weight: CGFloat = 520) -> Font {
        Font(titleNSFont(size, weight: weight) as CTFont)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    static let scribeAccent = Velvet.accent
}

extension View {
    /// Fraunces for titles. The window asks for SF Rounded everywhere, and
    /// that design would otherwise override the custom face, so it is reset
    /// here.
    func velvetTitle(_ size: CGFloat, weight: CGFloat = 520) -> some View {
        font(Velvet.title(size, weight: weight)).fontDesign(nil)
    }

    /// A resting velvet surface: a fill, a soft top-left light, a 1px top
    /// sheen and no border.
    func velvetPanel(_ fill: Color, radius: CGFloat = Velvet.Radius.panel, light: Double = 0.035) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(RadialGradient(colors: [Color.white.opacity(light), .clear],
                                             center: .topLeading, startRadius: 0, endRadius: 420))
                )
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Velvet.sheen, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)),
                                      lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
        }
    }

    /// Floating chrome: blurred, lifted, lit from above.
    func velvetFloating(radius: CGFloat = 999, popover: Bool = false) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(popover ? Velvet.popover : Velvet.floating))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center),
                                      lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.7), radius: popover ? 34 : 24, y: popover ? 22 : 16)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Colours for the AppKit page canvas.
struct Palette {
    let isDark: Bool
    let backdrop: NSColor
    let page: NSColor
    let pageBorder: NSColor
    let rule: NSColor
    let marginRule: NSColor
    let shadow: NSColor
    let shadowOpacity: Float
    let accent: NSColor
    let accentSoft: NSColor
    let selection: NSColor
    let mutedText: NSColor

    static let dark = Palette(
        isDark: true,
        backdrop: NSColor(hex: "#131116"),
        page: NSColor(hex: "#1C1920"),
        pageBorder: NSColor(white: 1, alpha: 0.05),
        rule: NSColor(white: 1, alpha: 0.045),
        marginRule: NSColor(hex: "#E39072").withAlphaComponent(0.35),
        shadow: .black,
        shadowOpacity: 0.85,
        accent: NSColor(hex: "#E39072"),
        accentSoft: NSColor(hex: "#E39072").withAlphaComponent(0.1),
        selection: NSColor(hex: "#E39072"),
        mutedText: NSColor(hex: "#A69DAB")
    )

    /// Kept for the ink self-test, which checks both themes.
    static let light = Palette(
        isDark: false,
        backdrop: NSColor(hex: "#EFEDE6"),
        page: .white,
        pageBorder: NSColor(hex: "#E4E0D6"),
        rule: NSColor(hex: "#E9E4D9"),
        marginRule: NSColor(hex: "#B85C3B").withAlphaComponent(0.35),
        shadow: NSColor(hex: "#4A4238"),
        shadowOpacity: 0.16,
        accent: NSColor(hex: "#B85C3B"),
        accentSoft: NSColor(hex: "#F6E8E1"),
        selection: NSColor(hex: "#B85C3B"),
        mutedText: NSColor(hex: "#6C665E")
    )

    static func of(dark: Bool) -> Palette { dark ? .dark : .light }
}

/// Ink colour as painted on the current theme. The stored colour never
/// changes; this only decides what is drawn.
enum InkPaint {
    static func color(hex: String, highlighter: Bool, dark: Bool) -> NSColor {
        var rgba = Core.adapt(Core.parseColor(hex), dark: dark)
        if highlighter {
            // A highlighter must let the ink underneath show through.
            rgba = (rgba & 0xFFFF_FF00) | UInt32(Core.highlighterAlpha(dark: dark))
        }
        return NSColor(rgba: rgba)
    }

    static func swatch(_ hex: String, dark: Bool = true) -> Color {
        Color(nsColor: color(hex: hex, highlighter: false, dark: dark))
    }
}
