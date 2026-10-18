import AppKit
import UniformTypeIdentifiers

// Importing OneNote's own files: a notebook downloaded from OneDrive (the
// zip, or the folder unzipped), or single .one section files. The core
// reads them (crates/scribe-core/src/onenote_file.rs), so nothing goes
// through Microsoft: no token, no rate limits, and pages of any size.
// OneNote notebooks become folders and sections notebooks, the same places
// the web import uses, and pages either import brought in are skipped.

/// A section file the core found in what was chosen.
private struct FileSection: Decodable {
    var path: String
    var notebook: String
    var groups: [String]
    var name: String
    /// In OneNote's recycle bin.
    var deleted: Bool

    var scribeName: String { groups.isEmpty ? name : (groups + [name]).joined(separator: " – ") }
}

private struct SectionImport: Decodable {
    var made: Int
    var existing: Int
    var skipped: [String]
}

extension AppModel {
    @MainActor
    func chooseAndImportOneNoteFiles() {
        let panel = NSOpenPanel()
        panel.title = "Import OneNote Files"
        panel.message = "Choose the zip OneDrive downloaded (or the folder inside it), or .one section files. "
            + "On onedrive.live.com, select your notebook in Documents and click Download."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .folder] + ["one", "onetoc2"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        importOneNoteFiles(panel.urls)
    }

    /// Unzips if need be, then imports section by section with the popup.
    @MainActor
    func importOneNoteFiles(_ urls: [URL]) {
        guard !urls.isEmpty, importing == nil else { return }
        commitOpenPage()
        let progress = ImportProgress()
        progress.unit = "section"
        progress.file = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "OneNote files"
        importing = progress
        let root = self.root

        Task { @MainActor in
            var lastSection: String?
            var unpacked: [URL] = []
            do {
                var sections: [FileSection] = []
                for url in urls {
                    var source = url
                    if url.pathExtension.lowercased() == "zip" {
                        source = try await Self.unzip(url)
                        unpacked.append(source)
                    }
                    sections += try Core.call("onenote_file_sections", ["path": source.path])
                }
                // Sections deleted in OneNote come along only if you say so.
                let deleted = sections.filter(\.deleted)
                if !deleted.isEmpty, !Self.askAboutDeleted(deleted.map(\.name)) {
                    sections.removeAll(where: \.deleted)
                }
                guard !sections.isEmpty else {
                    throw Core.Failure(message: "There are no OneNote sections (.one files) in what you chose.")
                }
                progress.fileCount = sections.count
                var folders: [String: String] = [:]
                for (index, source) in sections.enumerated() {
                    progress.fileIndex = index
                    progress.file = source.scribeName
                    let folder = try folders[source.notebook] ?? folder(named: source.notebook, root: root)
                    folders[source.notebook] = folder
                    let tree: [NotebookInfo] = (try? Core.call("tree", ["root": root])) ?? notebooks
                    let existed = tree.first { $0.path == folder }?.sections.contains { $0.name == source.scribeName } ?? false
                    let section = try notebook(named: source.scribeName, in: folder)
                    // Parsing a big section takes a moment; keep the UI moving.
                    let result: SectionImport = try await Task.detached {
                        try Core.call("onenote_file_import_section", ["root": root, "section": section, "file": source.path])
                    }.value
                    progress.pagesMade += result.made
                    progress.alreadyHere += result.existing
                    // A section with no pages leaves no empty notebook behind.
                    if !existed, result.made == 0, result.existing == 0 {
                        try? FileManager.default.removeItem(atPath: section)
                    }
                    if result.made > 0 { progress.made.append(section); lastSection = section }
                    if !result.skipped.isEmpty {
                        NSLog("Scribe: OneNote file import left out %@", result.skipped.joined(separator: ", "))
                    }
                }
                progress.fileIndex = sections.count
                progress.phase = .done
            } catch {
                progress.phase = .failed(error.localizedDescription)
            }
            for dir in unpacked { try? FileManager.default.removeItem(at: dir) }
            reloadTree()
            if let lastSection, progress.phase == .done {
                showingHome = false
                showingPageGrid = false
                selectSection(lastSection)
            }
            inkReader.backfill(root: root)
        }
    }

    /// Asks whether to import sections that are in OneNote's recycle bin.
    @MainActor
    private static func askAboutDeleted(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? "Also import a section from OneNote's recycle bin?"
            : "Also import \(names.count) sections from OneNote's recycle bin?"
        let shown = names.prefix(8).joined(separator: ", ") + (names.count > 8 ? ", and \(names.count - 8) more" : "")
        alert.informativeText = "These were deleted in OneNote but are still in the download: \(shown). "
            + "They go into the same folder as the rest of the notebook."
        alert.addButton(withTitle: "Import Them Too")
        alert.addButton(withTitle: "Skip Them")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Unzips a OneDrive download into a temporary folder.
    private static func unzip(_ zip: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-onenote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let status: Int32 = try await Task.detached {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, dest.path]
            try ditto.run()
            ditto.waitUntilExit()
            return ditto.terminationStatus
        }.value
        guard status == 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw Core.Failure(message: "Couldn't unzip “\(zip.lastPathComponent)”.")
        }
        return dest
    }
}
