import SwiftUI

/// Formatting for the text box being edited, floating just above it.
struct FormatPill: View {
    @Bindable var app: AppModel

    var body: some View {
        let f = app.textFormat
        HStack(spacing: 2) {
            Menu {
                ForEach(HeadingPreset.allCases) { preset in
                    Button(preset.label) { app.activeTextView?.applyHeading(preset) }
                }
            } label: { menuLabel(HeadingPreset(rawValue: f.heading)?.label ?? "Body") }
                .pillMenu()
                .help("Style")

            Menu {
                ForEach(ScribeFonts.choices) { choice in
                    Button(choice.label) { app.activeTextView?.format { $0.family = choice.name } }
                }
            } label: { menuLabel(ScribeFonts.label(for: f.family)) }
                .pillMenu()
                .help("Font")

            Menu {
                ForEach(ScribeFonts.sizes, id: \.self) { size in
                    Button("\(Int(size))") { app.activeTextView?.format { $0.size = size } }
                }
            } label: { menuLabel(String(format: "%g", f.size)) }
                .pillMenu()
                .help("Size")

            BarDivider()

            toggle(on: f.bold, label: "Bold (⌘B)") {
                Text("B").font(.system(size: 15, weight: .black))
            } change: { $0.bold.toggle() }
            toggle(on: f.italic, label: "Italic (⌘I)") {
                Text("I").font(Velvet.title(17).italic()).fontDesign(nil)
            } change: { $0.italic.toggle() }
            toggle(on: f.underline, label: "Underline (⌘U)") {
                Text("U").font(.system(size: 15, weight: .semibold)).underline()
            } change: { $0.underline.toggle() }
            toggle(on: f.strikethrough, label: "Strikethrough (⇧⌘X)") {
                Text("S").font(.system(size: 15, weight: .semibold)).strikethrough()
            } change: { $0.strikethrough.toggle() }

            BarDivider()

            Menu {
                ForEach(InkColor.inks) { ink in
                    Button(ink.name) { app.activeTextView?.format { $0.color = ink.hex } }
                }
            } label: {
                Circle()
                    .fill(InkPaint.swatch(f.color))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5).padding(-3.5))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .pillMenu()
            .help("Text colour")
            .accessibilityLabel("Text colour")
        }
        .padding(5)
        .velvetFloating()
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 13, weight: .bold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Velvet.muted)
        }
        .padding(.leading, 13)
        .padding(.trailing, 11)
        .frame(height: 36)
        .contentShape(Capsule())
    }

    private func toggle<L: View>(on: Bool, label: String, @ViewBuilder glyph: () -> L,
                                 change: @escaping (inout TextStyle) -> Void) -> some View {
        Button { app.activeTextView?.format(change) } label: { glyph() }
            .buttonStyle(RoundButtonStyle(size: 36, fill: on ? Velvet.accentSoft : .clear, foreground: on ? Velvet.accent : Velvet.text))
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Actions on a lasso selection, floating just above it.
struct SelectionPill: View {
    @Bindable var app: AppModel
    @Bindable var page: PageModel

    var body: some View {
        HStack(spacing: 2) {
            action("Copy", symbol: "doc.on.doc") { app.copySelection() }
            action("Duplicate", symbol: "plus.square.on.square") { app.duplicateSelection() }
            if !page.selectedStrokes.isEmpty {
                Menu {
                    ForEach(InkColor.inks) { ink in
                        Button(ink.name) { app.recolorSelection(ink.hex) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(AngularGradient(colors: InkColor.inks.prefix(4).map { InkPaint.swatch($0.hex) } + [InkPaint.swatch(InkColor.inks[0].hex)],
                                                  center: .center))
                            .frame(width: 14, height: 14)
                        Text("Recolour").font(.system(size: 13, weight: .bold))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .contentShape(Capsule())
                }
                .pillMenu()
            }
            BarDivider()
            Button { page.deleteSelection() } label: { Image(systemName: "trash") }
                .buttonStyle(RoundButtonStyle(size: 36, fill: .clear, foreground: Velvet.danger))
                .help("Delete (⌫)")
                .accessibilityLabel("Delete selection")
        }
        .padding(5)
        .velvetFloating()
        .fixedSize()
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Capsule())
        }
        .buttonStyle(RowButtonStyle(radius: 18))
    }
}

extension View {
    /// A menu whose label is drawn by us, inside a floating pill.
    func pillMenu() -> some View {
        self
            .menuStyle(.button)
            .buttonStyle(RowButtonStyle(radius: 18))
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
