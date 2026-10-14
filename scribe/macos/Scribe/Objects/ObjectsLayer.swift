import AppKit
import SwiftMath
import SwiftUI

/// Everything on the page that is not ink, laid out in page coordinates. It
/// sits under the ink view inside the magnified scroll view, so it zooms with
/// the page and stays crisp.
struct ObjectsLayer: View {
    let app: AppModel
    let page: PageModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(page.images, id: \.objectID) { ImageObjectView(app: app, page: page, item: $0) }
            ForEach(page.tables, id: \.objectID) { TableObjectView(app: app, page: page, item: $0) }
            ForEach(page.latexBlocks, id: \.objectID) { LatexObjectView(app: app, page: page, item: $0) }
            ForEach(page.textBoxes, id: \.objectID) { TextBoxView(app: app, page: page, item: $0) }
            // Pills live here, at page level, rather than in an overlay of the
            // object they serve: outside its bounds they would not get clicks.
            if let box = editingTextBox {
                FormatPill(app: app)
                    .fixedSize()
                    .offset(x: box.dto.x - 12, y: box.dto.y - (TextBoxItem.pillHeight + TextBoxItem.pillGap) - 9)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if app.tool == .select, let frame = page.selectionPillFrame {
                SelectionPill(app: app, page: page)
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.opacity)
            }
        }
        .frame(width: page.pageSize.width, height: page.pageSize.height, alignment: .topLeading)
        .coordinateSpace(name: ObjectChrome<EmptyView>.space)
        .environment(\.colorScheme, .dark)
        .fontDesign(.rounded)
        .foregroundStyle(Velvet.text)
        .tint(Velvet.accent)
        .animation(.easeOut(duration: 0.15), value: editingTextBox?.dto.id)
    }

    private var editingTextBox: TextBoxItem? {
        guard app.tool == .text, app.textFormat.active, let id = app.textFormat.itemID else { return nil }
        return page.textBoxes.first { $0.dto.id == id }
    }
}

/// Shared behaviour of on-page objects: a grip to move them while the Text
/// tool is active, a selection outline, and a context menu.
struct ObjectChrome<Content: View>: View {
    static var space: String { "page" }

    let app: AppModel
    let page: PageModel
    let object: PageObject
    var menu: () -> AnyView = { AnyView(EmptyView()) }
    @ViewBuilder let content: () -> Content

    @State private var hovering = false
    @State private var dragStart: CGPoint?

    private var selected: Bool { page.selectedObjects.contains(object.objectID) }

    var body: some View {
        content()
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Velvet.Radius.row, style: .continuous)
                        .strokeBorder(Velvet.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
                        .padding(-8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if hovering || dragStart != nil, app.tool == .text {
                    grip
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                menu()
                Divider()
                Button("Delete", role: .destructive) { page.removeObject(id: object.objectID) }
            }
            .offset(x: object.origin.x, y: object.origin.y)
    }

    private var grip: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Velvet.onAccent)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Velvet.accent).shadow(color: .black.opacity(0.5), radius: 6, y: 3))
            .offset(x: -26, y: -4)
            .help("Drag to move")
            .gesture(
                DragGesture(coordinateSpace: .named(Self.space))
                    .onChanged { g in
                        let start = dragStart ?? object.origin
                        if dragStart == nil { dragStart = start }
                        object.origin = CGPoint(x: max(0, start.x + g.translation.width), y: max(0, start.y + g.translation.height))
                        page.contentChanged()
                    }
                    .onEnded { _ in
                        if let start = dragStart { page.commitMove(of: object, from: start) }
                        dragStart = nil
                    }
            )
    }
}

// ------------------------------------------------------------------- text

struct TextBoxView: View {
    let app: AppModel
    let page: PageModel
    let item: TextBoxItem

    @State private var widthStart: Double?

    /// Its text view has the caret.
    private var editing: Bool {
        app.tool == .text && app.textFormat.active && app.textFormat.itemID == item.dto.id
    }

    var body: some View {
        ObjectChrome(app: app, page: page, object: item) {
            RichTextEditor(app: app, page: page, item: item, dark: app.dark, width: item.dto.width)
                .frame(width: item.dto.width, height: item.dto.height ?? item.measuredHeight)
                .background {
                    // A soft well while editing, never a hard box.
                    RoundedRectangle(cornerRadius: Velvet.Radius.card, style: .continuous)
                        .fill(Color.white.opacity(editing ? 0.025 : 0))
                        .overlay(RoundedRectangle(cornerRadius: Velvet.Radius.card, style: .continuous)
                            .strokeBorder(editing ? Velvet.accentRing : .clear, lineWidth: 1))
                        .padding(.horizontal, -12)
                        .padding(.vertical, -9)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .trailing) {
                    if app.tool == .text { widthHandle }
                }
                .animation(.easeOut(duration: 0.15), value: editing)
        }
        .onChange(of: editing, initial: true) { _, now in item.showsFormatPill = now }
    }

    /// Drag the right edge to rewrap.
    private var widthHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 4)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(ObjectChrome<EmptyView>.space))
                    .onChanged { g in
                        let start = widthStart ?? item.dto.width
                        if widthStart == nil { widthStart = start }
                        item.dto.width = max(60, start + g.translation.width)
                        page.contentChanged()
                    }
                    .onEnded { _ in
                        if let start = widthStart {
                            let end = item.dto.width
                            page.commitEdit(item, name: "Resize Text", before: { $0.dto.width = start }, after: { $0.dto.width = end })
                        }
                        widthStart = nil
                    }
            )
    }
}

// ----------------------------------------------------------------- images

struct ImageObjectView: View {
    let app: AppModel
    let page: PageModel
    let item: ImageItem

    @State private var resizeStart: CGSize?

    var body: some View {
        ObjectChrome(app: app, page: page, object: item, menu: { AnyView(menu) }) {
            Group {
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Label("Missing image\n\(item.dto.file)", systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(width: item.size.width, height: item.size.height)
            .clipShape(RoundedRectangle(cornerRadius: Velvet.Radius.row, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if app.tool == .text { resizeHandle }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Original Size") {
            guard let img = item.image else { return }
            let before = item.dto
            item.dto.width = img.size.width
            item.dto.height = img.size.height
            let after = item.dto
            page.commitEdit(item, name: "Resize Image", before: { $0.dto = before }, after: { $0.dto = after })
        }
        Button("Show in Finder") {
            app.revealInFinder(URL(fileURLWithPath: page.sectionPath).appendingPathComponent(item.dto.file).path)
        }
    }

    /// Bottom-right corner; keeps the aspect ratio unless Shift is held.
    private var resizeHandle: some View {
        Circle()
            .fill(Velvet.accent)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Velvet.page, lineWidth: 3))
            .offset(x: 4, y: 4)
            .gesture(
                DragGesture(coordinateSpace: .named(ObjectChrome<EmptyView>.space))
                    .onChanged { g in
                        let start = resizeStart ?? CGSize(width: item.dto.width, height: item.dto.height)
                        if resizeStart == nil { resizeStart = start }
                        let w = max(16, start.width + g.translation.width)
                        if NSEvent.modifierFlags.contains(.shift) {
                            item.dto.width = w
                            item.dto.height = max(16, start.height + g.translation.height)
                        } else {
                            item.dto.width = w
                            item.dto.height = max(16, w * start.height / max(start.width, 1))
                        }
                        page.contentChanged()
                    }
                    .onEnded { _ in
                        if let start = resizeStart {
                            let end = CGSize(width: item.dto.width, height: item.dto.height)
                            page.commitEdit(item, name: "Resize Image",
                                            before: { $0.dto.width = start.width; $0.dto.height = start.height },
                                            after: { $0.dto.width = end.width; $0.dto.height = end.height })
                        }
                        resizeStart = nil
                    }
            )
    }
}

// --------------------------------------------------------------- equations

struct LatexObjectView: View {
    let app: AppModel
    let page: PageModel
    let item: LatexItem

    var body: some View {
        ObjectChrome(app: app, page: page, object: item, menu: { AnyView(menu) }) {
            MathView(latex: item.dto.latex, fontSize: item.dto.scale,
                     color: InkPaint.color(hex: item.dto.color, highlighter: false, dark: app.dark))
                .fixedSize()
                .padding(4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { app.sheet = .latex(item) }
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    guard item.measured != size else { return }
                    item.measured = size
                    page.recomputeSize()
                }
                .help("Double-click to edit")
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Edit Equation…") { app.sheet = .latex(item) }
        Button("Copy LaTeX") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.dto.latex, forType: .string)
        }
    }
}

/// Typeset LaTeX via SwiftMath.
struct MathView: NSViewRepresentable {
    var latex: String
    var fontSize: Double
    var color: NSColor

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = .display
        label.textAlignment = .left
        configure(label)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        if label.latex != latex { label.latex = latex }
        if label.fontSize != CGFloat(fontSize) { label.fontSize = CGFloat(fontSize) }
        label.textColor = color
        label.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        let s = nsView.intrinsicContentSize
        return CGSize(width: max(s.width, 12), height: max(s.height, 12))
    }
}

// ------------------------------------------------------------------ tables

struct TableObjectView: View {
    let app: AppModel
    let page: PageModel
    let item: TableItem

    @State private var columnDrag: (column: Int, start: Double)?

    var body: some View {
        ObjectChrome(app: app, page: page, object: item, menu: { AnyView(tableMenu) }) {
            grid
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    guard item.measured != size else { return }
                    item.measured = size
                    page.recomputeSize()
                }
        }
        .onChange(of: item.dto.rows) { page.contentChanged() }
    }

    private var lineColor: Color { Velvet.hairline }

    private var grid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(item.dto.rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(item.dto.rows[r].indices, id: \.self) { c in
                        cell(r, c)
                    }
                }
            }
        }
        // Cells stretch to their row's height; without this the whole table
        // would stretch to the page, grow the page, and stretch again.
        .fixedSize()
        .background(Color(hex: 0x211D26))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
    }

    private func cell(_ r: Int, _ c: Int) -> some View {
        let header = r == 0 && item.dto.hasHeader
        return TextField("", text: binding(r, c), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: header ? .heavy : .regular))
            .foregroundStyle(header ? Color(hex: 0xF6E9E4) : (c == 0 ? Color(hex: 0xEAE2EC) : Color(hex: 0xC9C0CD)))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(width: item.width(ofColumn: c), alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(header ? Velvet.accentSoft : .clear)
            .overlay(alignment: .trailing) {
                Color.clear.frame(width: 1)
                    .overlay {
                        if app.tool == .text && r == 0 { columnHandle(c) }
                    }
            }
            .overlay(alignment: .bottom) {
                if r < item.dto.rows.count - 1 { Rectangle().fill(lineColor).frame(height: 1) }
            }
            .contextMenu { cellMenu(r, c) }
    }

    private func binding(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(
            get: { r < item.dto.rows.count && c < item.dto.rows[r].count ? item.dto.rows[r][c] : "" },
            set: { v in
                // Text fields write back during layout; an unchanged write
                // would still count as a mutation and re-render forever.
                guard r < item.dto.rows.count, c < item.dto.rows[r].count, item.dto.rows[r][c] != v else { return }
                item.dto.rows[r][c] = v
            }
        )
    }

    /// Drag the line right of a header cell to resize that column.
    private func columnHandle(_ c: Int) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(ObjectChrome<EmptyView>.space))
                    .onChanged { g in
                        let start = columnDrag?.start ?? item.width(ofColumn: c)
                        if columnDrag == nil { columnDrag = (c, start) }
                        item.setWidth(start + g.translation.width, ofColumn: c)
                        page.contentChanged()
                    }
                    .onEnded { _ in
                        if let drag = columnDrag {
                            let end = item.width(ofColumn: c)
                            page.commitEdit(item, name: "Resize Column",
                                            before: { $0.setWidth(drag.start, ofColumn: c) },
                                            after: { $0.setWidth(end, ofColumn: c) })
                        }
                        columnDrag = nil
                    }
            )
    }

    private func edit(_ name: String, _ change: (inout TableDTO) -> Void) {
        let before = item.dto
        change(&item.dto)
        if item.dto.rows.isEmpty || item.columnCount == 0 {
            item.dto = before
            page.removeObject(id: item.objectID)
            return
        }
        let after = item.dto
        page.commitEdit(item, name: name, before: { $0.dto = before }, after: { $0.dto = after })
    }

    @ViewBuilder private func cellMenu(_ r: Int, _ c: Int) -> some View {
        Button("Insert Row Above") { edit("Insert Row") { $0.rows.insert(blankRow, at: r) } }
        Button("Insert Row Below") { edit("Insert Row") { $0.rows.insert(blankRow, at: r + 1) } }
        Button("Delete Row") { edit("Delete Row") { $0.rows.remove(at: r) } }
        Divider()
        Button("Insert Column Left") { edit("Insert Column") { insertColumn(&$0, at: c) } }
        Button("Insert Column Right") { edit("Insert Column") { insertColumn(&$0, at: c + 1) } }
        Button("Delete Column") { edit("Delete Column") { deleteColumn(&$0, at: c) } }
        Divider()
        tableMenu
    }

    @ViewBuilder private var tableMenu: some View {
        Toggle("Header Row", isOn: Binding(
            get: { item.dto.hasHeader },
            set: { v in edit("Header Row") { $0.hasHeader = v } }
        ))
        Button("Copy Table") { app.copyTable(item, as: .rich) }
        Button("Copy as Markdown") { app.copyTable(item, as: .markdown) }
    }

    private var blankRow: [String] { Array(repeating: "", count: item.columnCount) }

    private func insertColumn(_ t: inout TableDTO, at c: Int) {
        for i in t.rows.indices { t.rows[i].insert("", at: min(c, t.rows[i].count)) }
        if var w = t.columnWidths {
            w.insert(TableItem.defaultColumnWidth, at: min(c, w.count))
            t.columnWidths = w
        }
    }

    private func deleteColumn(_ t: inout TableDTO, at c: Int) {
        for i in t.rows.indices where c < t.rows[i].count { t.rows[i].remove(at: c) }
        if var w = t.columnWidths, c < w.count {
            w.remove(at: c)
            t.columnWidths = w
        }
        if t.rows.first?.isEmpty ?? true { t.rows = [] }
    }
}
