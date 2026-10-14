import SwiftUI

/// The open page: a header, the canvas, and the floating dock.
struct EditorView: View {
    @Bindable var app: AppModel
    /// Narrow window: the rail holds the window's traffic lights.
    var reserveLights = false

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let page = app.page {
                VStack(spacing: 0) {
                    if app.focusMode {
                        SlimHeader(app: app, page: page, undoManager: undoManager)
                    } else {
                        PageHeader(app: app, page: page, undoManager: undoManager)
                    }
                    ZStack(alignment: .bottom) {
                        PageCanvas(app: app, page: page)
                            .id(ObjectIdentifier(page))

                        // The dock stays centred; the zoom pill keeps to the
                        // right and steps aside when the pane is too narrow
                        // for both.
                        ViewThatFits(in: .horizontal) {
                            bottomBar(page, zoom: true)
                            bottomBar(page, zoom: false)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 22)
                        .animation(.spring(duration: 0.3, bounce: 0.15), value: app.trayOpen)
                        .animation(.spring(duration: 0.3, bounce: 0.15), value: app.insertOpen)
                    }
                }
                .onAppear { page.undoManager = undoManager }
                .onChange(of: ObjectIdentifier(page)) { page.undoManager = undoManager }
            } else {
                emptyEditor
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .velvetPanel(Velvet.editor, light: 0.03)
        .clipShape(RoundedRectangle(cornerRadius: Velvet.Radius.panel, style: .continuous))
    }

    private func bottomBar(_ page: PageModel, zoom: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            if zoom { Color.clear.frame(width: Self.zoomWidth, height: 1) }
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                if app.trayOpen && app.tool.isInk {
                    PenTray(app: app)
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }
                if app.insertOpen {
                    InsertMenu(app: app, page: page)
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }
                Dock(app: app)
            }
            .fixedSize()
            Spacer(minLength: 0)
            if zoom {
                ZoomPill(app: app)
                    .fixedSize()
                    .frame(width: Self.zoomWidth, alignment: .trailing)
                    .padding(.bottom, 8)
            }
        }
    }

    private static let zoomWidth: CGFloat = 132

    private var emptyEditor: some View {
        VStack(spacing: 14) {
            Color.clear.frame(height: 30).contentShape(Rectangle()).windowDraggable()
            Spacer()
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Velvet.faint)
            Text("No page open").velvetTitle(26)
            Text("Pick a page, or start a new one.").foregroundStyle(Velvet.muted)
            Button("New page") { app.newPage() }
                .buttonStyle(PillButtonStyle(prominent: true))
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Title, breadcrumb and page actions.
struct PageHeader: View {
    @Bindable var app: AppModel
    @Bindable var page: PageModel
    var undoManager: UndoManager?

    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(breadcrumb)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Velvet.faint)
                    .lineLimit(1)
                TitleField(app: app, page: page, size: 34, focused: $titleFocused)
            }
            Spacer(minLength: 12)
            PageActions(app: app, page: page, undoManager: undoManager, showFocusToggle: true)
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .windowDraggable()
        .onChange(of: app.focusTitle) { _, now in
            if now {
                titleFocused = true
                app.focusTitle = false
            }
        }
        .onAppear {
            if app.focusTitle {
                titleFocused = true
                app.focusTitle = false
            }
        }
    }

    private var breadcrumb: String {
        let place = app.sectionName(for: page.sectionPath)
        let status = app.status.isEmpty ? "" : " · \(app.status)"
        return place + status
    }
}

/// Focus mode's header: room for the traffic lights, the title centred.
struct SlimHeader: View {
    @Bindable var app: AppModel
    @Bindable var page: PageModel
    var undoManager: UndoManager?

    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 62, height: 1)
            Button {
                withAnimation(.spring(duration: 0.35)) { app.focusMode = false }
            } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(RoundButtonStyle(size: 36))
                .help("Show notebooks (⌘\\)")
                .accessibilityLabel("Show notebooks")
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TitleField(app: app, page: page, size: 19, focused: $titleFocused)
                    .fixedSize()
                Text(app.section(at: page.sectionPath)?.name ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Velvet.faint)
            }
            Spacer(minLength: 8)
            PageActions(app: app, page: page, undoManager: undoManager, showFocusToggle: false, size: 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .windowDraggable()
    }
}

/// The page title, editable in place, in Fraunces at its softest.
struct TitleField: View {
    @Bindable var app: AppModel
    @Bindable var page: PageModel
    var size: CGFloat
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField("Untitled page", text: $page.title)
            .textFieldStyle(.plain)
            .velvetTitle(size, weight: size > 24 ? 520 : 540)
            .foregroundStyle(Velvet.text)
            .focused(focused)
            .onChange(of: page.title) { app.titleEdited() }
            .onSubmit { app.commitOpenPage() }
    }
}

/// Undo, redo and the page menu.
struct PageActions: View {
    @Bindable var app: AppModel
    @Bindable var page: PageModel
    var undoManager: UndoManager?
    var showFocusToggle: Bool
    var size: CGFloat = 40

    /// Bumped whenever the undo stack changes, which SwiftUI cannot observe.
    @State private var historyTick = 0

    var body: some View {
        HStack(spacing: 6) {
            Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(RoundButtonStyle(size: size))
                .disabled(historyTick < 0 || !(undoManager?.canUndo ?? false))
                .help("Undo (⌘Z)")
                .accessibilityLabel("Undo")
            Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(RoundButtonStyle(size: size))
                .disabled(historyTick < 0 || !(undoManager?.canRedo ?? false))
                .help("Redo (⇧⌘Z)")
                .accessibilityLabel("Redo")
            if showFocusToggle {
                Button {
                    withAnimation(.spring(duration: 0.35)) { app.focusMode = true }
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(RoundButtonStyle(size: size))
                    .help("Focus on the page (⌘\\)")
                    .accessibilityLabel("Focus mode")
            }
            Menu {
                Picker("Paper", selection: paperBinding) {
                    Text("Ruled").tag("ruled")
                    Text("Grid").tag("grid")
                    Text("Dots").tag("dots")
                    Text("Blank").tag("blank")
                }
                Divider()
                Button("Fit Page Width") { app.canvas?.zoomToFit() }
                Button("Show in Finder") { app.revealInFinder(page.path) }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    guard let info = app.pages.first(where: { $0.path == page.path }) else { return }
                    app.confirm = ConfirmInfo(
                        title: "Move “\(info.title)” to the Trash?",
                        message: "You can still recover it from the Trash.",
                        action: "Move to Trash"
                    ) { app.trashPage(info) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(RoundButtonStyle(size: size))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Page options")
            .accessibilityLabel("Page options")
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in historyTick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in historyTick += 1 }
        .onChange(of: app.status) { historyTick += 1 }
    }

    private var paperBinding: Binding<String> {
        Binding(
            get: { page.background.kind },
            set: { app.setPaper($0) }
        )
    }
}

// ---------------------------------------------------------------- the dock

/// One soft bar of tools, floating over the bottom of the page.
struct Dock: View {
    @Bindable var app: AppModel

    var body: some View {
        HStack(spacing: 4) {
            tool(.pen, symbol: "pencil", help: "Pen (P). Click again for colours and width")
            tool(.highlighter, symbol: "highlighter", help: "Highlighter (H). Click again for colours and width")
            tool(.strokeEraser, symbol: app.tool == .pointEraser ? "eraser.line.dashed" : "eraser",
                 help: app.tool == .pointEraser ? "Partial eraser. Click again for whole strokes" : "Eraser (E). Click again for a partial eraser")
            tool(.select, symbol: "lasso", help: "Lasso (S)")
            tool(.text, symbol: "character.cursor.ibeam", help: "Text (T). Click anywhere to type")

            BarDivider()

            ForEach(InkColor.inks.prefix(4)) { ink in
                Button { app.chooseInk(ink.hex) } label: {
                    Swatch(color: InkPaint.swatch(ink.hex), selected: app.tool == .pen && app.pen.color == ink.hex)
                }
                .buttonStyle(.plain)
                .help(ink.name)
                .accessibilityLabel("\(ink.name) ink")
            }
            Button { app.chooseHighlight(app.highlighter.color) } label: {
                Swatch(color: InkPaint.swatch(app.highlighter.color), selected: app.tool == .highlighter, marker: true)
            }
            .buttonStyle(.plain)
            .help("Highlighter")
            .accessibilityLabel("Highlighter colour")

            BarDivider()

            Button {
                app.trayOpen = false
                app.insertOpen.toggle()
            } label: {
                Image(systemName: "plus").rotationEffect(.degrees(app.insertOpen ? 45 : 0))
            }
            .buttonStyle(RoundButtonStyle(size: 44, fill: app.insertOpen ? Velvet.text : Velvet.control, foreground: app.insertOpen ? Velvet.onAccent : Velvet.text))
            .help("Insert a table, equation or image")
            .accessibilityLabel("Insert")
            .animation(.spring(duration: 0.25), value: app.insertOpen)
        }
        .padding(6)
        .velvetFloating()
    }

    private func tool(_ kind: ToolKind, symbol: String, help: String) -> some View {
        let active = app.tool == kind || (kind == .strokeEraser && app.tool == .pointEraser)
        return Button { app.select(tool: kind) } label: { Image(systemName: symbol) }
            .buttonStyle(RoundButtonStyle(size: 44, fill: .clear, active: active))
            .help(help)
            .accessibilityLabel(kind.title)
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Colours, nib width and pressure for the pen or the highlighter.
struct PenTray: View {
    @Bindable var app: AppModel

    var body: some View {
        let pen = app.trayPen
        let colours = pen.highlighter ? InkColor.highlights : InkColor.inks
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(pen.highlighter ? "Highlighter" : "Fountain pen").font(.system(size: 15, weight: .heavy))
                Spacer()
                Text(String(format: "%.1f pt", pen.width))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Velvet.muted)
                    .monospacedDigit()
            }

            StrokePreview(pen: pen)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Velvet.Radius.card, style: .continuous).fill(Color(hex: 0x1A171E)))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 6) {
                ForEach(colours) { c in
                    Button {
                        if pen.highlighter { app.chooseHighlight(c.hex) } else { app.chooseInk(c.hex) }
                    } label: {
                        Swatch(color: InkPaint.swatch(c.hex), selected: pen.color == c.hex, diameter: 22, marker: pen.highlighter)
                    }
                    .buttonStyle(.plain)
                    .help(c.name)
                    .accessibilityLabel(c.name)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nib width").font(.system(size: 12, weight: .bold)).foregroundStyle(Velvet.muted)
                Slider(value: Binding(get: { app.trayPen.width }, set: { app.setWidth($0) }), in: pen.widthRange)
                    .tint(Velvet.accent)
                    .accessibilityLabel("Nib width")
            }

            if !pen.highlighter {
                Toggle(isOn: Binding(get: { app.pen.pressureSensitive }, set: { app.setPressure($0) })) {
                    Text("Pressure shapes the line").font(.system(size: 14, weight: .bold))
                }
                .toggleStyle(.switch)
                .tint(Velvet.accent)
            }
        }
        .padding(18)
        .frame(width: 340)
        .velvetFloating(radius: Velvet.Radius.popover, popover: true)
    }
}

/// A sample stroke drawn by the real ink engine, so the tray shows exactly
/// what the pen will put down.
struct StrokePreview: View {
    var pen: Pen

    var body: some View {
        Canvas { ctx, size in
            let w = Double(size.width) - 60
            var pts: [Double] = []
            let n = 70
            for i in 0..<n {
                let t = Double(i) / Double(n - 1)
                let x = 30 + t * w
                let y = Double(size.height) / 2 + sin(t * .pi * 3) * (pen.highlighter ? 4 : 12)
                pts += [x, y, max(0.05, sin(.pi * t))]
            }
            let path = Core.outlinePath(points: pts, width: min(pen.width * (pen.highlighter ? 1 : 1.6), 34),
                                        pressureSensitive: pen.pressureSensitive, fit: true, taper: true)
            ctx.fill(Path(path), with: .color(Color(nsColor: InkPaint.color(hex: pen.color, highlighter: pen.highlighter, dark: true))))
        }
        .accessibilityHidden(true)
    }
}

/// Tables, equations, images, pasting, and the paper.
struct InsertMenu: View {
    @Bindable var app: AppModel
    @Bindable var page: PageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Table", shortcut: "⌥⌘T", highlighted: true) {
                Image(systemName: "tablecells")
            } action: { app.sheet = .table }
            row("Equation", shortcut: "⌥⌘E") {
                Text("fx").font(Velvet.title(16).italic()).fontDesign(nil)
            } action: { app.sheet = .latex(nil) }
            row("Image", shortcut: "⌥⌘I") {
                Image(systemName: "photo")
            } action: { app.chooseImage() }
            row("Paste onto page", shortcut: "⌥⌘V") {
                Image(systemName: "doc.on.clipboard")
            } action: { app.paste() }

            Capsule().fill(Velvet.hairline).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 6)
            SectionLabel(text: "Paper").padding(.horizontal, 12).padding(.bottom, 4)
            HStack(spacing: 6) {
                ForEach(["ruled", "grid", "dots", "blank"], id: \.self) { kind in
                    Button { app.setPaper(kind) } label: { PaperTile(kind: kind, selected: page.background.kind == kind) }
                        .buttonStyle(.plain)
                        .help(kind.capitalized)
                        .accessibilityLabel("\(kind.capitalized) paper")
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .padding(8)
        .frame(width: 300)
        .velvetFloating(radius: Velvet.Radius.popover, popover: true)
    }

    private func row<Icon: View>(_ title: String, shortcut: String, highlighted: Bool = false,
                                 @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button {
            app.insertOpen = false
            action()
        } label: {
            HStack(spacing: 12) {
                icon()
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(highlighted ? Velvet.accent : Velvet.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: Velvet.Radius.chip, style: .continuous)
                        .fill(highlighted ? Velvet.accentSoft : Color(hex: 0x2A2530)))
                Text(title).font(.system(size: 14, weight: .bold))
                Spacer()
                Text(shortcut).font(.system(size: 12)).foregroundStyle(Velvet.faint)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
        }
        .buttonStyle(RowButtonStyle(radius: 16))
    }
}

struct PaperTile: View {
    var kind: String
    var selected: Bool

    var body: some View {
        Canvas { ctx, size in
            let c = Color(hex: 0x8F8595)
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            switch kind {
            case "ruled":
                for dy in [-6.0, 0, 6] {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: mid.x - 13, y: mid.y + dy)); $0.addLine(to: CGPoint(x: mid.x + 13, y: mid.y + dy)) },
                               with: .color(c.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            case "grid":
                for d in [-6.0, 0, 6] {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: mid.x - 13, y: mid.y + d)); $0.addLine(to: CGPoint(x: mid.x + 13, y: mid.y + d)) },
                               with: .color(c.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    ctx.stroke(Path { $0.move(to: CGPoint(x: mid.x + d * 1.4, y: mid.y - 10)); $0.addLine(to: CGPoint(x: mid.x + d * 1.4, y: mid.y + 10)) },
                               with: .color(c.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            case "dots":
                for dx in [-8.0, 0, 8] {
                    for dy in [-7.0, 0, 7] {
                        ctx.fill(Path(ellipseIn: CGRect(x: mid.x + dx - 1.4, y: mid.y + dy - 1.4, width: 2.8, height: 2.8)), with: .color(c))
                    }
                }
            default:
                break
            }
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Velvet.Radius.row, style: .continuous).fill(Velvet.page))
        .overlay(RoundedRectangle(cornerRadius: Velvet.Radius.row, style: .continuous)
            .strokeBorder(selected ? Velvet.accent : Color.white.opacity(0.05), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: Velvet.Radius.row, style: .continuous))
    }
}

/// − 100% +
struct ZoomPill: View {
    @Bindable var app: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Button { app.canvas?.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus") }
                .buttonStyle(RoundButtonStyle(size: 32, fill: .clear))
                .help("Zoom out (⌘−)")
                .accessibilityLabel("Zoom out")
            Button { app.canvas?.zoomToFit() } label: {
                Text("\(Int((app.zoom * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Velvet.secondary)
                    .frame(minWidth: 46)
            }
            .buttonStyle(.plain)
            .help("Fit and centre the page (⌘9)")
            Button { app.canvas?.zoom(by: 1.25) } label: { Image(systemName: "plus") }
                .buttonStyle(RoundButtonStyle(size: 32, fill: .clear))
                .help("Zoom in (⌘=)")
                .accessibilityLabel("Zoom in")
        }
        .padding(4)
        .velvetFloating()
    }
}
