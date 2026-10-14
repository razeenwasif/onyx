import SwiftUI

/// A list row: rounded, with a soft hover and an accent wash when selected.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = Velvet.Radius.row

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, selected: selected, radius: radius)
    }

    private struct Styled: View {
        let configuration: Configuration
        let selected: Bool
        let radius: CGFloat
        @State private var hover = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .contentShape(shape)
                .background(shape.fill(selected ? Velvet.accentSoft : Color.white.opacity(hover ? 0.045 : 0)))
                .overlay { if selected { shape.strokeBorder(Velvet.accentRing, lineWidth: 1) } }
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// A round icon button: 40pt by default, filled softly, accent when active.
struct RoundButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    var fill: Color = Velvet.button
    var active = false
    /// The glyph colour; defaults to the secondary text colour.
    var foreground: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, size: size, fill: fill, active: active, foreground: foreground)
    }

    private struct Styled: View {
        let configuration: Configuration
        let size: CGFloat
        let fill: Color
        let active: Bool
        let foreground: Color?
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(active ? Velvet.onAccent : (enabled ? (foreground ?? Velvet.secondary) : Velvet.faint.opacity(0.7)))
                .frame(width: size, height: size)
                .background(Circle().fill(active ? Velvet.accent : (hover && enabled ? Color.white.opacity(0.07) : fill)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
                .animation(.spring(duration: 0.25), value: active)
        }
    }
}

/// A capsule button. Prominent ones are filled with the accent.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, prominent: prominent, height: height)
    }

    private struct Styled: View {
        let configuration: Configuration
        let prominent: Bool
        let height: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(prominent ? Velvet.onAccent : Velvet.text)
                .padding(.horizontal, 18)
                .frame(height: height)
                .background(
                    Capsule().fill(prominent ? Velvet.accent : Velvet.control)
                        .overlay(Capsule().fill(Color.white.opacity(hover ? 0.06 : 0)))
                )
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// A colour swatch: a disc, ringed in the accent when chosen.
struct Swatch: View {
    var color: Color
    var selected: Bool
    var diameter: CGFloat = 20
    var marker = false

    var body: some View {
        ZStack {
            if marker {
                Capsule().fill(color).frame(width: diameter + 2, height: diameter * 0.62)
            } else {
                Circle().fill(color).frame(width: diameter, height: diameter)
            }
        }
        .frame(width: diameter + 14, height: diameter + 14)
        .overlay(Circle().strokeBorder(selected ? Velvet.accent : .clear, lineWidth: 2))
        .contentShape(Circle())
    }
}

/// A thin, rounded divider for floating bars.
struct BarDivider: View {
    var body: some View {
        Capsule().fill(Velvet.hairline).frame(width: 1, height: 22).padding(.horizontal, 5)
    }
}

/// Small caps section label.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(Velvet.faint)
    }
}

extension View {
    /// Lets the window be dragged by this area, now that the title bar is
    /// hidden and content runs to the top edge.
    func windowDraggable() -> some View {
        gesture(WindowDragGesture())
    }
}

enum DateLabel {
    /// "Today · 10:42", "Yesterday", "12 Oct", or "12 Oct 2025".
    static func short(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today · " + date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
