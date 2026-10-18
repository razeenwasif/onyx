import Foundation
import Observation
import PDFKit

/// How an import is going, for the import popup (ImportPopup). Updated on
/// the main thread.
@MainActor
@Observable
final class ImportProgress {
    enum Phase: Equatable {
        case reading
        case pages
        case done
        case failed(String)
    }

    var phase: Phase = .reading
    /// The file (or OneNote section) being imported.
    var file = ""
    /// What the steps are called: a "file", or a "notebook" from OneNote.
    var unit = "file"
    /// Which file of how many.
    var fileIndex = 0
    var fileCount = 0
    var page = 0
    var pageCount = 0
    /// OneNote pages skipped because an earlier run imported them.
    var alreadyHere = 0
    /// While the import has to wait: until when, and why.
    var waiting: (until: Date, reason: String)?
    /// The OneNote page being fetched.
    var pageTitle = ""
    /// OneNote pages Microsoft wouldn't send; a later run tries them again.
    var failedPages: [String] = []
    /// Notebooks made so far, by section path.
    var made: [String] = []
    var pagesMade = 0

    var fraction: Double {
        guard fileCount > 0 else { return 0 }
        let perFile = pageCount > 0 ? Double(page) / Double(pageCount) : 0
        return min(1, (Double(fileIndex) + perFile) / Double(fileCount))
    }
}

/// Imports PDFs, including Goodnotes exports, as notebooks: one notebook
/// (Scribe section) per file in `folder`, one page per PDF page, with the
/// PDF as the page's background so you can write on it. Shared by the Mac
/// and the iPad. The work runs off the main thread; `progress` follows it.
enum PDFImportJob {
    @MainActor
    static func run(_ urls: [URL], into folder: String, progress: ImportProgress) async {
        progress.fileCount = urls.count
        for (index, url) in urls.enumerated() {
            progress.fileIndex = index
            progress.file = url.deletingPathExtension().lastPathComponent
            progress.phase = .reading
            progress.page = 0
            progress.pageCount = 0
            do {
                let section = try await importOne(url, into: folder) { page, count in
                    await MainActor.run {
                        progress.phase = .pages
                        progress.page = page
                        progress.pageCount = count
                    }
                }
                progress.made.append(section.path)
                progress.pagesMade += section.pages
            } catch {
                progress.phase = .failed("\(url.lastPathComponent): \(error.localizedDescription)")
                return
            }
        }
        progress.fileIndex = urls.count
        progress.phase = .done
    }

    private static func importOne(
        _ url: URL, into folder: String, onPage: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> (path: String, pages: Int) {
        try await Task.detached(priority: .userInitiated) {
            // A file picked from iCloud Drive may only be a placeholder until
            // read through a coordinator, which downloads it; copy it out so
            // the rest works on a whole local file.
            let local = try readableCopy(of: url)
            defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }

            guard let pdf = PDFDocument(url: local), pdf.pageCount > 0 else {
                throw Core.Failure(message: "It isn't a PDF Scribe can open.")
            }
            let name = url.deletingPathExtension().lastPathComponent
            let section: String = try Core.call("create_section", ["notebook": folder, "name": name])

            // One copy of the PDF for the notebook; every page points at it.
            let slot: AssetSlot = try Core.call("new_asset", ["section": section, "ext": "pdf"])
            try FileManager.default.copyItem(at: local, to: URL(fileURLWithPath: slot.path))

            let stamp = ISO8601DateFormatter().string(from: Date())
            let count = pdf.pageCount
            for index in 0..<count {
                try Task.checkCancellation()
                let title = count == 1 ? name : "Page \(index + 1)"
                let pagePath: String = try Core.call("create_page", ["section": section, "title": title])
                var doc: PageDoc = try Core.readPage(pagePath)
                doc.background = BackgroundDTO(kind: "pdf", spacing: 32, color: "#E8EEF5", asset: slot.rel, pdfPage: index)
                doc.source = SourceDTO(app: "pdf", id: url.lastPathComponent, importedAt: stamp)
                let _: WriteResult = try Core.writePage(pagePath, doc)
                await onPage(index + 1, count)
            }
            return (section, count)
        }.value
    }

    /// Reads `url` (security-scoped on the iPad) through a file coordinator
    /// into a temporary copy.
    private static func readableCopy(of url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-import-\(newID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: copy)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw Core.Failure(message: "Could not read it: \(error.localizedDescription)")
        }
        return copy
    }
}
