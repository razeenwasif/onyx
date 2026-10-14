import AppKit
import UniformTypeIdentifiers

/// Pasting and inserting: images, tables, text, and Scribe's own selections.
extension AppModel {
    static let fragmentType = NSPasteboard.PasteboardType("app.scribe.fragment")

    /// A copied selection, self-contained enough to paste into another page.
    struct Fragment: Codable {
        var sectionPath: String
        var strokes: [StrokeDTO]
        var textBoxes: [TextBoxDTO]
        var images: [ImageDTO]
        var latexBlocks: [LatexDTO]
        var tables: [TableDTO]
    }

    private var insertionPoint: CGPoint { canvas?.visiblePageCenter ?? CGPoint(x: 120, y: 120) }

    private func selectionFragment() -> Fragment? {
        guard let page, page.hasSelection else { return nil }
        let objects = page.selectedObjectList
        return Fragment(
            sectionPath: page.sectionPath,
            strokes: page.selectedStrokeList.map(\.dto),
            textBoxes: objects.compactMap { ($0 as? TextBoxItem)?.dto },
            images: objects.compactMap { ($0 as? ImageItem)?.dto },
            latexBlocks: objects.compactMap { ($0 as? LatexItem)?.dto },
            tables: objects.compactMap { ($0 as? TableItem)?.dto }
        )
    }

    /// Copies the selection and pastes it just beside itself, in one step.
    func duplicateSelection() {
        guard let page, let fragment = selectionFragment() else { return }
        paste(fragment, into: page)
    }

    func copySelection() {
        guard let fragment = selectionFragment() else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = try? JSONEncoder().encode(fragment) {
            pb.setData(data, forType: Self.fragmentType)
        }
        // Typed text also goes out as plain text, for pasting elsewhere.
        let text = fragment.textBoxes.map(\.text).joined(separator: "\n\n")
        if !text.isEmpty { pb.setString(text, forType: .string) }
    }

    /// Pastes whatever is most useful from the pasteboard onto the page:
    /// a Scribe selection, an image, a table, or text.
    func paste() {
        guard let page else { return }
        let pb = NSPasteboard.general
        let at = insertionPoint

        if let data = pb.data(forType: Self.fragmentType),
           let fragment = try? JSONDecoder().decode(Fragment.self, from: data) {
            paste(fragment, into: page)
            return
        }

        // Image files copied in Finder.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
            insertImage(fileURL: url, at: at)
            return
        }

        // Image data: screenshots, images copied from a browser or Preview.
        // Checked before HTML, which browsers also put on the pasteboard.
        if pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb) {
            insertImage(image, at: at)
            return
        }

        let html = pb.string(forType: .html)
        let text = pb.string(forType: .string)

        if html != nil || text != nil {
            var args: [String: Any] = [:]
            if let html { args["html"] = html }
            if let text { args["text"] = text }
            if let table = (try? Core.call("parse_table", args, as: ParsedTable?.self)) ?? nil, !table.rows.isEmpty {
                page.addTable(TableDTO(x: at.x, y: at.y, rows: table.rows, hasHeader: table.hasHeader))
                return
            }
        }

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            page.addTextBox(at: at, text: text, width: 420, focus: false)
        }
    }

    private func paste(_ fragment: Fragment, into page: PageModel) {
        // Offset so a paste onto the same page does not land exactly on top.
        let offset: Double = 24
        let sameSection = fragment.sectionPath == page.sectionPath
        let fm = FileManager.default

        let strokes = fragment.strokes.map { s -> StrokeDTO in
            var s = s
            for i in stride(from: 0, to: s.points.count - 2, by: 3) {
                s.points[i] += offset
                s.points[i + 1] += offset
            }
            return s
        }
        let texts = fragment.textBoxes.map { t -> TextBoxItem in
            var t = t
            t.id = newID(); t.x += offset; t.y += offset
            return TextBoxItem(t)
        }
        let images = fragment.images.map { img -> ImageItem in
            var img = img
            img.id = newID(); img.x += offset; img.y += offset
            if !sameSection {
                // Images are stored per section; bring the file along.
                let src = URL(fileURLWithPath: fragment.sectionPath).appendingPathComponent(img.file)
                if let slot = try? Core.call("new_asset", ["section": page.sectionPath, "ext": src.pathExtension], as: AssetSlot.self),
                   (try? fm.copyItem(at: src, to: URL(fileURLWithPath: slot.path))) != nil {
                    img.file = slot.rel
                }
            }
            return ImageItem(img, sectionPath: page.sectionPath)
        }
        let latex = fragment.latexBlocks.map { l -> LatexItem in
            var l = l
            l.id = newID(); l.x += offset; l.y += offset
            return LatexItem(l)
        }
        let tables = fragment.tables.map { t -> TableItem in
            var t = t
            t.id = newID(); t.x += offset; t.y += offset
            return TableItem(t)
        }
        tool = .select
        page.insert(strokes: strokes, textBoxes: texts, images: images, latex: latex, tables: tables, name: "Paste")
    }

    // ---------------------------------------------------------------- images

    func chooseImage() {
        guard page != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Insert Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        var at = insertionPoint
        for url in panel.urls {
            insertImage(fileURL: url, at: at)
            at.y += 40
        }
    }

    func insertImage(fileURL url: URL, at point: CGPoint) {
        guard let page, let image = NSImage(contentsOf: url) else { return }
        do {
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let slot: AssetSlot = try Core.call("new_asset", ["section": page.sectionPath, "ext": ext])
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: slot.path))
            place(image, file: slot.rel, at: point)
        } catch {
            show(error, title: "Could not insert the image")
        }
    }

    func insertImage(_ image: NSImage, at point: CGPoint) {
        guard let page else { return }
        do {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw Core.Failure(message: "The image could not be converted to PNG.")
            }
            let slot: AssetSlot = try Core.call("new_asset", ["section": page.sectionPath, "ext": "png"])
            try png.write(to: URL(fileURLWithPath: slot.path), options: .atomic)
            place(image, file: slot.rel, at: point)
        } catch {
            show(error, title: "Could not paste the image")
        }
    }

    private func place(_ image: NSImage, file: String, at point: CGPoint) {
        guard let page else { return }
        var size = image.size
        if size.width < 1 || size.height < 1 { size = CGSize(width: 320, height: 240) }
        // Keep large images to a readable width; they can be resized after.
        let maxWidth: CGFloat = 640
        if size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        page.addImage(ImageDTO(x: point.x - size.width / 2, y: point.y, width: size.width, height: size.height, file: file))
        tool = .text
    }

    // ---------------------------------------------------- tables & equations

    func insertTable(rows: Int, columns: Int, header: Bool) {
        guard let page else { return }
        let at = insertionPoint
        let grid = Array(repeating: Array(repeating: "", count: max(columns, 1)), count: max(rows, 1))
        page.addTable(TableDTO(x: at.x - Double(columns) * 60, y: at.y, rows: grid, hasHeader: header))
        tool = .text
    }

    func insertLatex(_ latex: String, scale: Double) {
        guard let page else { return }
        let at = insertionPoint
        page.addLatex(LatexDTO(x: at.x - 80, y: at.y, latex: latex, scale: scale, color: "#1A1A1A"))
    }

    func copyTable(_ table: TableItem, as format: TableCopyFormat) {
        guard let out = try? Core.call("export_table", ["rows": table.dto.rows, "hasHeader": table.dto.hasHeader], as: ExportedTable.self)
        else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch format {
        case .rich:
            pb.setString(out.html, forType: .html)
            pb.setString(out.tsv, forType: .string)
        case .markdown:
            pb.setString(out.markdown, forType: .string)
        }
    }
}

enum TableCopyFormat {
    /// HTML plus tab-separated text: pastes as a table into Numbers, Pages,
    /// Excel and mail.
    case rich
    case markdown
}
