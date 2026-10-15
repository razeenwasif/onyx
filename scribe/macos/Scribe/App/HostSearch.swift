import Foundation

/// Scribe's pages, for a host app's own search (the Electron app lists them
/// beside its notes). Notebook and section names come from the folder names,
/// which follow their titles.
struct HostSearchHit: Encodable {
    var title: String
    var path: String
    var notebook: String
    var section: String
    var modified: Double
    var snippet: String
}

extension AppModel {
    /// Pages matching `query` (titles, typed text, tables and handwriting),
    /// as a JSON array of HostSearchHit. Empty on any failure.
    public func searchJSON(_ query: String) -> String {
        let pages: [PageInfo] = (try? Core.call("search", ["root": root, "query": query])) ?? []
        let hits = pages.map { page in
            let section = URL(fileURLWithPath: page.sectionPath)
            return HostSearchHit(
                title: page.title,
                path: page.path,
                notebook: section.deletingLastPathComponent().lastPathComponent,
                section: section.lastPathComponent,
                modified: page.modified,
                snippet: page.snippet
            )
        }
        guard let data = try? JSONEncoder().encode(hits), let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Reads any handwriting not yet read (see InkReader), in the background.
    /// A host calls this when Scribe is loaded but not on screen, so its
    /// search finds handwriting even if Scribe is never opened.
    public func readHandwriting() {
        inkReader.backfill(root: root)
    }

    /// Opens the page at `path` in its section, leaving focus mode.
    public func showPage(at path: String) {
        focusMode = false
        let section = (path as NSString).deletingLastPathComponent
        if selectedSectionPath != section { selectSection(section, openFirst: false) }
        openPage(path)
    }
}
