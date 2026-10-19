import PhotosUI
import SwiftUI
import UIKit

/// The things on a page besides ink: text boxes, pictures, equations and
/// tables. The iPad inserts them from the toolbar's Insert menu, edits one
/// tapped with the lasso, and moves, copies and deletes them with the
/// lasso alongside ink.
struct PageObjects: Equatable {
    var textBoxes: [TextBoxDTO] = []
    var images: [ImageDTO] = []
    var latex: [LatexDTO] = []
    var tables: [TableDTO] = []

    init() {}

    init(doc: PageDoc?) {
        textBoxes = doc?.textBoxes ?? []
        images = doc?.images ?? []
        latex = doc?.latexBlocks ?? []
        tables = doc?.tables ?? []
    }

    func apply(to doc: inout PageDoc) {
        doc.textBoxes = textBoxes
        doc.images = images
        doc.latexBlocks = latex
        doc.tables = tables
    }

    var isEmpty: Bool { textBoxes.isEmpty && images.isEmpty && latex.isEmpty && tables.isEmpty }

    /// Just the objects whose ids are in `ids`.
    func only(_ ids: Set<String>) -> PageObjects {
        var out = PageObjects()
        out.textBoxes = textBoxes.filter { ids.contains($0.id) }
        out.images = images.filter { ids.contains($0.id) }
        out.latex = latex.filter { ids.contains($0.id) }
        out.tables = tables.filter { ids.contains($0.id) }
        return out
    }

    /// Everything but the objects whose ids are in `ids`.
    func without(_ ids: Set<String>) -> PageObjects {
        var out = self
        out.textBoxes.removeAll { ids.contains($0.id) }
        out.images.removeAll { ids.contains($0.id) }
        out.latex.removeAll { ids.contains($0.id) }
        out.tables.removeAll { ids.contains($0.id) }
        return out
    }

    /// Moved by (dx, dy), the ones in `ids` (or all of them).
    func translated(_ ids: Set<String>? = nil, dx: Double, dy: Double) -> PageObjects {
        var out = self
        for i in out.textBoxes.indices where ids?.contains(out.textBoxes[i].id) ?? true {
            out.textBoxes[i].x += dx; out.textBoxes[i].y += dy
        }
        for i in out.images.indices where ids?.contains(out.images[i].id) ?? true {
            out.images[i].x += dx; out.images[i].y += dy
        }
        for i in out.latex.indices where ids?.contains(out.latex[i].id) ?? true {
            out.latex[i].x += dx; out.latex[i].y += dy
        }
        for i in out.tables.indices where ids?.contains(out.tables[i].id) ?? true {
            out.tables[i].x += dx; out.tables[i].y += dy
        }
        return out
    }

    /// The same objects with new ids, for a paste.
    func withNewIDs() -> PageObjects {
        var out = self
        for i in out.textBoxes.indices { out.textBoxes[i].id = newID() }
        for i in out.images.indices { out.images[i].id = newID() }
        for i in out.latex.indices { out.latex[i].id = newID() }
        for i in out.tables.indices { out.tables[i].id = newID() }
        return out
    }

    var ids: [String] {
        textBoxes.map(\.id) + images.map(\.id) + latex.map(\.id) + tables.map(\.id)
    }

    /// Each object's id and where it sits, in page units.
    @MainActor
    var frames: [(id: String, frame: CGRect)] {
        textBoxes.map { ($0.id, ObjectGeometry.frame(of: $0)) }
            + images.map { ($0.id, ObjectGeometry.frame(of: $0)) }
            + latex.map { ($0.id, ObjectGeometry.frame(of: $0, size: ObjectGeometry.latexSize($0))) }
            + tables.map { ($0.id, ObjectGeometry.frame(of: $0)) }
    }
}

/// Where objects sit on the page, shared by drawing, hit testing and the
/// lasso.
enum ObjectGeometry {
    /// Generous bounds for a text box: its height if known, else enough for
    /// its lines, wrapped at its width.
    static func frame(of box: TextBoxDTO) -> CGRect {
        let width: Double = max(box.width, 40)
        let perLine: Double = box.fontSize * 0.6 / width
        var lines: Double = 0
        for line in box.text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, ceil(Double(line.count) * perLine))
        }
        let height: Double = box.height ?? (lines * box.fontSize * 1.5)
        return CGRect(x: box.x - 8, y: box.y - 8, width: width + 16, height: max(height, lines * box.fontSize * 1.5) + 16)
    }

    static func frame(of table: TableDTO) -> CGRect {
        let columns = table.rows.map(\.count).max() ?? 0
        var width: Double = 0
        for i in 0..<columns {
            if let widths = table.columnWidths, i < widths.count { width += widths[i] } else { width += 140 }
        }
        return CGRect(x: table.x - 4, y: table.y - 4, width: width + 8, height: Double(table.rows.count) * 30 + 8)
    }

    static func frame(of image: ImageDTO) -> CGRect {
        CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
    }

    /// An equation's box: its typeset size when known, else a guess from
    /// its length.
    static func frame(of block: LatexDTO, size: CGSize?) -> CGRect {
        let s = size ?? CGSize(width: max(40, Double(block.latex.count) * block.scale * 0.5), height: block.scale * 1.6)
        return CGRect(x: block.x - 4, y: block.y - 4, width: s.width + 8, height: s.height + 8)
    }

    /// An equation typeset as it's drawn on the page.
    @MainActor
    static func latexImage(_ block: LatexDTO) -> UIImage? {
        let color = UIColor(cgColor: InkPaint.color(hex: block.color, highlighter: false))
        return MathRender.render(block.latex, size: block.scale, display: false, color: color)?.image
    }

    @MainActor
    static func latexSize(_ block: LatexDTO) -> CGSize? { latexImage(block)?.size }
}

// ------------------------------------------------------------- editing

/// What the object editor sheet is working on.
enum ObjectEditing: Identifiable {
    case text(TextBoxDTO, isNew: Bool)
    case table(TableDTO, isNew: Bool)
    case equation(LatexDTO, isNew: Bool)

    var id: String {
        switch self {
        case .text(let t, _): t.id
        case .table(let t, _): t.id
        case .equation(let l, _): l.id
        }
    }
}

/// Writes or edits a text box, table or equation, then places it on the
/// page (in the middle of the screen when new) or saves the change.
struct ObjectEditor: View {
    let store: Store
    let editing: ObjectEditing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch editing {
                case .text(let box, let isNew): TextBoxEditor(store: store, box: box, isNew: isNew)
                case .table(let table, let isNew): TableEditor(store: store, table: table, isNew: isNew)
                case .equation(let block, let isNew): EquationEditor(store: store, block: block, isNew: isNew)
                }
            }
            .background(Color.velvetBackdrop)
        }
    }
}

/// Cancel, Delete (for an existing object) and Add/Done, shared by the editors.
private struct EditorToolbar: ToolbarContent {
    let isNew: Bool
    let canSave: Bool
    let delete: () -> Void
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        if !isNew {
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) {
                    delete()
                    dismiss()
                }
                .tint(.red)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(isNew ? "Add" : "Done") {
                save()
                dismiss()
            }
            .disabled(!canSave)
        }
    }
}

private struct TextBoxEditor: View {
    let store: Store
    @State var box: TextBoxDTO
    let isNew: Bool
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextEditor(text: $box.text)
                    .frame(minHeight: 160)
                    .focused($focused)
            }
            Section {
                Picker("Size", selection: $box.fontSize) {
                    Text("Small").tag(15.0)
                    Text("Medium").tag(20.0)
                    Text("Large").tag(28.0)
                    Text("Heading").tag(36.0)
                }
                .pickerStyle(.segmented)
                Toggle("Bold", isOn: $box.bold)
            }
        }
        .navigationTitle(isNew ? "New Text" : "Text")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditorToolbar(isNew: isNew, canSave: !box.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          delete: { store.deleteObject(id: box.id) },
                          save: { isNew ? store.insert(textBox: box) : store.update(textBox: box) })
        }
        .onAppear { focused = true }
    }
}

private struct TableEditor: View {
    let store: Store
    @State var table: TableDTO
    let isNew: Bool

    private var columns: Int { table.rows.map(\.count).max() ?? 0 }

    var body: some View {
        Form {
            Section {
                Stepper("Rows: \(table.rows.count)", value: rowCount, in: 1...30)
                Stepper("Columns: \(columns)", value: columnCount, in: 1...8)
                Toggle("Header row", isOn: $table.hasHeader)
            }
            Section("Cells") {
                ScrollView(.horizontal) {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(table.rows.indices, id: \.self) { r in
                            GridRow {
                                ForEach(0..<columns, id: \.self) { c in
                                    TextField(r == 0 && table.hasHeader ? "Heading" : "", text: cell(r, c))
                                        .textFieldStyle(.roundedBorder)
                                        .fontWeight(r == 0 && table.hasHeader ? .semibold : .regular)
                                        .frame(width: 140)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(isNew ? "New Table" : "Table")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditorToolbar(isNew: isNew, canSave: true,
                          delete: { store.deleteObject(id: table.id) },
                          save: { isNew ? store.insert(table: table) : store.update(table: table) })
        }
    }

    private func cell(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(
            get: { r < table.rows.count && c < table.rows[r].count ? table.rows[r][c] : "" },
            set: { value in
                while table.rows[r].count <= c { table.rows[r].append("") }
                table.rows[r][c] = value
            }
        )
    }

    private var rowCount: Binding<Int> {
        Binding(get: { table.rows.count }, set: { n in
            let width = max(columns, 1)
            while table.rows.count < n { table.rows.append(Array(repeating: "", count: width)) }
            if table.rows.count > n { table.rows.removeLast(table.rows.count - n) }
        })
    }

    private var columnCount: Binding<Int> {
        Binding(get: { columns }, set: { n in
            for r in table.rows.indices {
                while table.rows[r].count < n { table.rows[r].append("") }
                if table.rows[r].count > n { table.rows[r].removeLast(table.rows[r].count - n) }
            }
            if var widths = table.columnWidths {
                while widths.count < n { widths.append(140) }
                table.columnWidths = Array(widths.prefix(n))
            }
        })
    }
}

private struct EquationEditor: View {
    let store: Store
    @State var block: LatexDTO
    let isNew: Bool
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section("LaTeX") {
                TextField(#"e.g. \int_0^1 x^2\,dx = \frac{1}{3}"#, text: $block.latex, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...8)
                    .focused($focused)
            }
            Section("Preview") {
                let preview = MathRender.render(block.latex, size: 26, display: true, color: .white)
                Group {
                    if block.latex.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Type a formula above").foregroundStyle(.secondary)
                    } else if let preview {
                        Image(uiImage: preview.image)
                    } else {
                        Text("Can't typeset this yet").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            Section {
                Picker("Size", selection: $block.scale) {
                    Text("Small").tag(16.0)
                    Text("Medium").tag(22.0)
                    Text("Large").tag(30.0)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(isNew ? "New Equation" : "Equation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditorToolbar(isNew: isNew, canSave: !block.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          delete: { store.deleteObject(id: block.id) },
                          save: { isNew ? store.insert(latex: block) : store.update(latex: block) })
        }
        .onAppear { focused = true }
    }
}

/// The toolbar's Insert menu: text, a table, an equation or a photo.
struct InsertObjectMenu: View {
    let store: Store
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Menu {
            Button("Text", systemImage: "textformat") {
                store.editing = .text(TextBoxDTO(width: 360, fontSize: 20, color: "#1A1A1A"), isNew: true)
            }
            Button("Table", systemImage: "tablecells") {
                store.editing = .table(TableDTO(rows: Array(repeating: Array(repeating: "", count: 3), count: 3)), isNew: true)
            }
            Button("Equation", systemImage: "function") {
                store.editing = .equation(LatexDTO(scale: 22), isNew: true)
            }
            Button("Photo", systemImage: "photo") { pickingPhoto = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(Color.velvetText)
        }
        .accessibilityLabel("Insert")
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    store.insert(image: image)
                }
            }
        }
        .disabled(store.doc == nil)
    }
}
