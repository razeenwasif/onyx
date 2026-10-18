import AppKit
import UniformTypeIdentifiers

/// Importing PDFs, including notebooks exported from Goodnotes: each file
/// becomes a notebook (section) named after it, with one page per PDF page
/// (PDFImportJob, shared with the iPad). The PDF is the page's background
/// (see PDFBackground), so you can write on top, and the writing already on
/// it is read for search like handwriting.
extension AppModel {
    @MainActor
    func chooseAndImportPDFs() {
        let panel = NSOpenPanel()
        panel.title = "Import PDF or Goodnotes Export"
        panel.message = "Each PDF becomes a notebook, one page per PDF page, ready to write on. "
            + "From Goodnotes, export a notebook as PDF (Share → Export → PDF)."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importPDFs(panel.urls)
    }

    /// Imports in the background with the import popup (ImportPopup), then
    /// opens the new notebook.
    @MainActor
    func importPDFs(_ urls: [URL]) {
        guard !urls.isEmpty, importing == nil else { return }
        commitOpenPage()
        let notebookPath: String
        do {
            notebookPath = try targetNotebook()
        } catch {
            show(error, title: "Could not import")
            return
        }
        let progress = ImportProgress()
        importing = progress
        Task { @MainActor in
            await PDFImportJob.run(urls, into: notebookPath, progress: progress)
            reloadTree()
            if let last = progress.made.last {
                showingHome = false
                showingPageGrid = false
                selectSection(last)
            }
            // Read the writing on the new pages in the background.
            inkReader.backfill(root: root)
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
