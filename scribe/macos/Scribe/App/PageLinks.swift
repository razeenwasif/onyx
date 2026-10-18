import AppKit

/// Links between pages and the Electron vault's notes (see ScribeLink and
/// scribe-core links.rs): copying a link to paste into a note, opening the
/// page or area a link names, and the notes that link to the open page.
extension AppModel {
    /// Copies a link to the lassoed area, or to the whole page when nothing
    /// is selected (or `wholePage`), ready to paste into a note.
    func copyLink(wholePage: Bool = false) {
        guard let page else { return }
        let area = (wholePage ? nil : page.selectionBounds).map { $0.insetBy(dx: -16, dy: -16).intersection(CGRect(origin: .zero, size: page.pageSize)) }
        let link = ScribeLink(pageId: page.pageId, area: area.flatMap { $0.isNull ? nil : $0 })
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(link.markdown(title: page.title), forType: .string)
        status = area == nil ? "Link to page copied" : "Link to selection copied"
    }

    /// Opens the page with `id` and, given an area, zooms to it and flashes
    /// it. The page is looked up off the main thread: the first lookup after
    /// an update reads every page once.
    public func showLinkedPage(id: String, area: CGRect?) {
        if let page, page.pageId == id {
            focusMode = false
            if let area { canvas?.reveal(area) }
            return
        }
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let path = (try? Core.call("page_with_id", ["root": root, "id": id], as: String?.self)) ?? nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let path else {
                    self.alert = AlertInfo(title: "Page not found",
                                           message: "The linked page isn't in your library any more. It may have been deleted.")
                    return
                }
                if let area { self.pendingReveal = (path, area) }
                self.showingHome = false
                self.showingPageGrid = false
                self.showPage(at: path)
            }
        }
    }

    /// Finds the vault's notes that link to the open page, in the background.
    public func loadLinkedNotes() {
        guard let vault = vaultRoot, let page else {
            linkedNotes = []
            return
        }
        let id = page.pageId
        let path = page.path
        DispatchQueue.global(qos: .utility).async {
            let notes = (try? Core.call("notes_linking_to", ["vault": vault, "pageId": id], as: [LinkingNote].self)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.page?.path == path, self.linkedNotes != notes else { return }
                self.linkedNotes = notes
            }
        }
    }

    /// Opens a vault note in the host (Electron).
    func openNote(_ path: String) {
        commitOpenPage()
        openNoteHandler?(path)
    }

    /// Every page with its id and the links typed on it, as JSON for a host
    /// (scribe-core link_index). Slow the first time; call it off the main
    /// thread.
    public static func linkIndexJSON(root: String) -> String {
        let pages = (try? Core.call("link_index", ["root": root], as: [LinkedPage].self)) ?? []
        // Sorted keys: the host is told of a change only when this text
        // differs, and the encoder's key order otherwise may not hold.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(pages), let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// The library folder, for a host that reads the link index itself.
    public var libraryRoot: String { root }
}
