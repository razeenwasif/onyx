import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Importing PDFs, including notebooks exported from Goodnotes: each file
/// becomes a section named after it, with one page per PDF page. The PDF is
/// the page's background (see PDFBackground), so you can write on top, and
/// the writing already on it is read for search like handwriting.
extension AppModel {
    func chooseAndImportPDFs() {
        let panel = NSOpenPanel()
        panel.title = "Import PDF or Goodnotes Export"
        panel.message = "Each PDF becomes a notebook, one page per PDF page, ready to write on. "
            + "From Goodnotes, export a notebook as PDF (Share → Export → PDF)."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var last: String?
        for url in panel.urls {
            if let section = importPDF(at: url) { last = section }
        }
        if let last { selectSection(last) }
    }

    /// Imports the PDF at `url` as a new section in the current notebook (or
    /// the first one). Returns the new section's path.
    @discardableResult
    func importPDF(at url: URL) -> String? {
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
            alert = AlertInfo(title: "Import PDF", message: "\(url.lastPathComponent) isn't a PDF Scribe can open.")
            return nil
        }
        commitOpenPage()
        do {
            let notebookPath = try targetNotebook()
            let name = url.deletingPathExtension().lastPathComponent
            let section: String = try Core.call("create_section", ["notebook": notebookPath, "name": name])

            // One copy of the PDF for the whole section; every page points at it.
            let slot: AssetSlot = try Core.call("new_asset", ["section": section, "ext": "pdf"])
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: slot.path))

            let stamp = ISO8601DateFormatter().string(from: Date())
            for index in 0..<pdf.pageCount {
                let title = pdf.pageCount == 1 ? name : "Page \(index + 1)"
                let pagePath: String = try Core.call("create_page", ["section": section, "title": title])
                var doc: PageDoc = try Core.call("read_page", ["path": pagePath])
                doc.background = BackgroundDTO(kind: "pdf", spacing: 32, color: "#E8EEF5", asset: slot.rel, pdfPage: index)
                doc.source = SourceDTO(app: "pdf", id: url.lastPathComponent, importedAt: stamp)
                let _: WriteResult = try Core.call("write_page", ["path": pagePath, "page": try Core.json(doc)])
            }
            reloadTree()
            // Read the writing on the new pages in the background.
            inkReader.backfill(root: root)
            return section
        } catch {
            show(error, title: "Could not import \(url.lastPathComponent)")
            return nil
        }
    }

    /// The notebook imports go into: the selected section's, else the first,
    /// else a new "Imported" notebook.
    private func targetNotebook() throws -> String {
        if let sec = section(at: selectedSectionPath), let nb = notebook(containing: sec) { return nb.path }
        if let first = notebooks.first { return first.path }
        return try Core.call("create_notebook", ["root": root, "name": "Imported"])
    }
}
