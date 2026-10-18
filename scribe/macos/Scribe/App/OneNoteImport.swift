import AppKit
import SwiftUI

// Importing OneNote notebooks straight from Microsoft, with a token copied
// from Microsoft's Graph Explorer (no app registration needed). The core
// turns each page into a Scribe canvas page (crates/scribe-core/src/
// onenote.rs); this file talks to Microsoft and drives the import.
//
// OneNote's notebooks become folders and its sections notebooks. A run that
// stops part way (the token lasts about an hour) carries on where it left
// off next time: pages already imported are skipped without being fetched.
// Microsoft limits how fast one person can read OneNote, so requests are
// spaced out and "slow down" answers are waited out rather than fatal.

/// Reads OneNote through Microsoft Graph with a borrowed token.
struct OneNoteClient {
    struct Section: Identifiable, Hashable {
        var id: String
        var name: String
        var notebook: String
        var group: String?
        /// The Scribe notebook name: the section, after its group if any.
        var scribeName: String { group.map { "\($0) – \(name)" } ?? name }
    }

    struct PageRef {
        var id: String
        var title: String
        var order: Int
    }

    enum Failure: LocalizedError {
        case tokenExpired
        case http(Int, String)
        /// Microsoft kept failing on one request (a 5xx, or no answer at
        /// all). Very large pages do this; the import skips them and goes on.
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .tokenExpired:
                "Microsoft no longer accepts the token (they last about an hour). Copy a fresh one from Graph Explorer and import again; it carries on where it stopped."
            case .http(let code, let message):
                "Microsoft answered \(code): \(message)"
            case .unavailable(let why):
                "Microsoft couldn't send it (\(why))."
            }
        }
    }

    static let graphExplorer = URL(string: "https://developer.microsoft.com/graph/graph-explorer")!
    private static let base = "https://graph.microsoft.com/v1.0/me/onenote"

    let token: String
    /// Why the import is waiting, and until when.
    struct Wait: Sendable {
        var until: Date
        var reason: String
    }

    /// Told when the import has to wait, and nil as soon as it tries again,
    /// so the popup says what's happening instead of looking stuck.
    var onWait: (@Sendable (Wait?) -> Void)?
    private let pacer = Pacer()

    /// Spaces requests out. OneNote allows each person only so many calls a
    /// minute and an hour; after a "slow down" the gap widens, so a long
    /// import settles at a pace Microsoft accepts instead of stopping.
    private actor Pacer {
        private var last = Date.distantPast
        private(set) var gap: TimeInterval = 0.6

        func turn() async {
            let wait = last.addingTimeInterval(gap).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            last = Date()
        }

        func slower() { gap = min(gap * 2, 10) }
    }

    /// The longest a single request waits out "slow down" answers in total.
    /// Graph Explorer tokens last about an hour, so waiting longer is moot.
    private static let patience: TimeInterval = 50 * 60
    /// The first wait after "slow down"; each next one doubles (tests shorten it).
    static var slowDownStep: TimeInterval = 15
    /// Tries at a request that Microsoft fails on (5xx) or doesn't answer.
    /// Huge pages time out on Microsoft's side every time, so a few tries
    /// is enough before the import skips them for a later run.
    static let serverTries = 3

    /// GETs `url`, waiting out Microsoft's rate limits.
    func get(_ url: String) async throws -> (Data, HTTPURLResponse) {
        guard let address = URL(string: url) else { throw Failure.http(0, "bad address") }
        var request = URLRequest(url: address)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90
        var waited: TimeInterval = 0
        var slowDowns = 0
        var failures = 0

        /// Waits `seconds`, telling the popup why, then clears the notice.
        func pause(_ seconds: TimeInterval, _ reason: String) async throws {
            onWait?(Wait(until: Date().addingTimeInterval(seconds), reason: reason))
            try await Task.sleep(for: .seconds(seconds))
            waited += seconds
            onWait?(nil)
        }

        /// A 5xx or no answer: retry soon, a few times, then give up on it.
        func serverTrouble(_ why: String) async throws {
            failures += 1
            guard failures < Self.serverTries else { throw Failure.unavailable(why) }
            try await pause(Self.slowDownStep / 5 * Double(failures), "Microsoft is struggling with this page (\(why)) · try \(failures + 1) of \(Self.serverTries)")
        }

        while true {
            await pacer.turn()
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
                try await serverTrouble(error.code == .timedOut ? "no answer" : "connection lost")
                continue
            }
            let http = response as? HTTPURLResponse ?? HTTPURLResponse()
            switch http.statusCode {
            case 200..<300:
                return (data, http)
            case 401, 403:
                throw Failure.tokenExpired
            case 429:
                slowDowns += 1
                let asked = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
                // 15 s, 30 s, 1 min, 2 min, 4 min, then 5 min at a time, or
                // longer if Microsoft says so.
                let wait = max(asked ?? 0, min(300, Self.slowDownStep * pow(2, Double(slowDowns - 1))))
                guard waited + wait <= Self.patience else {
                    throw Failure.http(429, "Microsoft kept asking to slow down for nearly an hour. Import again later; pages already imported are skipped.")
                }
                await pacer.slower()
                try await pause(wait, "Microsoft asked to slow down")
            case 500, 502, 503, 504:
                try await serverTrouble(http.statusCode == 504 ? "it timed out" : "error \(http.statusCode)")
            default:
                let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw Failure.http(http.statusCode, text)
            }
        }
    }

    private func json(_ url: String) async throws -> [String: Any] {
        let (data, _) = try await get(url)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Every list item, following Microsoft's paging.
    private func all(_ url: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var next: String? = url
        while let page = next {
            let body = try await json(page)
            items += body["value"] as? [[String: Any]] ?? []
            next = body["@odata.nextLink"] as? String
        }
        return items
    }

    func sections() async throws -> [Section] {
        let url = "\(Self.base)/sections?$select=id,displayName&$expand=parentNotebook($select=displayName),parentSectionGroup($select=displayName)&$top=100"
        return try await all(url).compactMap { item in
            guard let id = item["id"] as? String, let name = item["displayName"] as? String else { return nil }
            let notebook = (item["parentNotebook"] as? [String: Any])?["displayName"] as? String ?? "OneNote"
            let group = (item["parentSectionGroup"] as? [String: Any])?["displayName"] as? String
            return Section(id: id, name: name, notebook: notebook, group: group)
        }
        .sorted { ($0.notebook, $0.scribeName) < ($1.notebook, $1.scribeName) }
    }

    func pages(in section: Section) async throws -> [PageRef] {
        let url = "\(Self.base)/sections/\(section.id)/pages?pagelevel=true&$select=id,title,order&$top=100"
        return try await all(url).enumerated().compactMap { index, item in
            guard let id = item["id"] as? String else { return nil }
            return PageRef(id: id, title: item["title"] as? String ?? "", order: item["order"] as? Int ?? index)
        }
        .sorted { $0.order < $1.order }
    }

    /// The page as HTML plus its handwriting as InkML.
    func content(of page: PageRef) async throws -> (Data, String) {
        let id = page.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["!"])) ?? page.id
        let (data, response) = try await get("\(Self.base)/pages/\(id)/content?includeInkML=true")
        return (data, response.value(forHTTPHeaderField: "Content-Type") ?? "text/html")
    }
}

/// What the core reports for one imported page.
private struct ImportedPage: Decodable {
    struct Picture: Decodable {
        var src: String
        var ext: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var path: String
    var existing: Bool
    var pictures: [Picture]
    var skipped: [String]
}

extension AppModel {
    func startOneNoteImport() {
        guard importing == nil else { return }
        commitOpenPage()
        sheet = .oneNote
    }

    /// Imports the chosen OneNote sections, with the import popup.
    @MainActor
    func importOneNote(_ sections: [OneNoteClient.Section], client: OneNoteClient) {
        guard !sections.isEmpty, importing == nil else { return }
        let progress = ImportProgress()
        progress.unit = "notebook"
        progress.fileCount = sections.count
        importing = progress
        let root = self.root

        let client = {
            var waiting = client
            waiting.onWait = { wait in
                Task { @MainActor in progress.waiting = wait.map { (until: $0.until, reason: $0.reason) } }
            }
            return waiting
        }()
        // Pages an earlier run brought in are skipped without downloading
        // them again, so a stopped import resumes straight away and doesn't
        // spend Microsoft's request allowance on them.
        let done = Set((try? Core.call("onenote_imported_ids", ["root": root], as: [String].self)) ?? [])

        Task { @MainActor in
            var folders: [String: String] = [:]
            var lastSection: String?
            var skipped: [String] = []
            do {
                for (index, source) in sections.enumerated() {
                    progress.fileIndex = index
                    progress.file = source.scribeName
                    progress.phase = .reading
                    progress.page = 0
                    progress.pageCount = 0

                    let folder = try folders[source.notebook] ?? folder(named: source.notebook, root: root)
                    folders[source.notebook] = folder
                    let section = try notebook(named: source.scribeName, in: folder)
                    lastSection = section

                    let pages = try await client.pages(in: source)
                    progress.pageCount = pages.count
                    progress.phase = .pages
                    for (n, page) in pages.enumerated() {
                        progress.page = n + 1
                        if done.contains(page.id) {
                            progress.alreadyHere += 1
                            continue
                        }
                        progress.pageTitle = page.title
                        let imported: ImportedPage
                        do {
                            imported = try await importPage(page, into: section, root: root, client: client)
                        } catch OneNoteClient.Failure.unavailable {
                            // Left out of the record, so the next run tries it again.
                            progress.failedPages.append(page.title.isEmpty ? "Untitled page" : page.title)
                            continue
                        }
                        if !imported.existing { progress.pagesMade += 1 }
                        skipped += imported.skipped
                    }
                    progress.made.append(section)
                }
                progress.fileIndex = sections.count
                progress.phase = .done
            } catch {
                progress.phase = .failed(error.localizedDescription)
            }
            if !skipped.isEmpty {
                NSLog("Scribe: OneNote import skipped %d attachments", skipped.count)
            }
            reloadTree()
            if let lastSection, progress.phase == .done {
                showingHome = false
                showingPageGrid = false
                selectSection(lastSection)
            }
            inkReader.backfill(root: root)
        }
    }

    private func importPage(_ page: OneNoteClient.PageRef, into section: String, root: String, client: OneNoteClient) async throws -> ImportedPage {
        let (body, contentType) = try await client.content(of: page)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-onenote-\(newID()).txt")
        try body.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let imported: ImportedPage = try Core.call("onenote_import_page", [
            "root": root, "section": section, "bodyPath": file.path, "contentType": contentType, "pageId": page.id,
        ])
        guard !imported.existing, !imported.pictures.isEmpty else { return imported }

        // Pictures come down separately and go into the notebook's assets.
        var doc: PageDoc = try Core.readPage(imported.path)
        for picture in imported.pictures {
            guard let (data, _) = try? await client.get(picture.src) else { continue }
            let slot: AssetSlot = try Core.call("new_asset", ["section": section, "ext": picture.ext])
            try data.write(to: URL(fileURLWithPath: slot.path))
            doc.images.append(ImageDTO(x: picture.x, y: picture.y, width: picture.width, height: picture.height, file: slot.rel))
        }
        let _: WriteResult = try Core.writePage(imported.path, doc)
        return imported
    }

    /// The Scribe notebook (folder) for a OneNote notebook: an existing one
    /// of that name, so a second run fills in the same place.
    func folder(named name: String, root: String) throws -> String {
        if let existing = notebooks.first(where: { $0.name == name }) { return existing.path }
        let path: String = try Core.call("create_notebook", ["root": root, "name": name])
        reloadTree()
        return path
    }

    func notebook(named name: String, in folder: String) throws -> String {
        let tree: [NotebookInfo] = (try? Core.call("tree", ["root": root])) ?? notebooks
        if let existing = tree.first(where: { $0.path == folder })?.sections.first(where: { $0.name == name }) {
            return existing.path
        }
        return try Core.call("create_section", ["notebook": folder, "name": name])
    }
}

/// Signing in with a borrowed token, then choosing what to import.
struct OneNoteImportSheet: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var client: OneNoteClient?
    @State private var sections: [OneNoteClient.Section] = []
    @State private var chosen: Set<String> = []
    @State private var checking = false
    @State private var problem: String?

    private var notebooks: [(String, [OneNoteClient.Section])] {
        Dictionary(grouping: sections, by: \.notebook).sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from OneNote").font(.title3.weight(.semibold))
            if client == nil { signIn } else { picker }
        }
        .padding(24)
        .frame(width: 480)
        .frame(minHeight: 300)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scribe reads your notebooks from Microsoft with a temporary key you copy from Microsoft’s Graph Explorer. Nothing is stored, and the key only lasts about an hour.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Open Graph Explorer and sign in with your Microsoft account.", systemImage: "1.circle")
                Label("Run any OneNote query once so it asks for Notes.Read, and allow it.", systemImage: "2.circle")
                Label("Open the Access token tab and click Copy.", systemImage: "3.circle")
                Label("Come back here and click Continue.", systemImage: "4.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open Graph Explorer") { NSWorkspace.shared.open(OneNoteClient.graphExplorer) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(checking ? "Checking…" : "Continue") { Task { await useClipboard() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking)
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose what to import. Each OneNote notebook becomes a folder, and each section a notebook. Wide pages keep their full width.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(notebooks, id: \.0) { notebook, items in
                    Section(notebook) {
                        ForEach(items) { section in
                            Toggle(section.scribeName, isOn: Binding(
                                get: { chosen.contains(section.id) },
                                set: { if $0 { chosen.insert(section.id) } else { chosen.remove(section.id) } }
                            ))
                        }
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Button(chosen.count == sections.count ? "Select None" : "Select All") {
                    chosen = chosen.count == sections.count ? [] : Set(sections.map(\.id))
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import \(chosen.count) \(chosen.count == 1 ? "Section" : "Sections")") {
                    guard let client else { return }
                    let picked = sections.filter { chosen.contains($0.id) }
                    dismiss()
                    app.importOneNote(picked, client: client)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
    }

    /// Takes the token from the clipboard, clears it, and checks it works.
    private func useClipboard() async {
        let pasteboard = NSPasteboard.general
        guard var token = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            problem = "The clipboard is empty. Copy the token from Graph Explorer’s Access token tab first."
            return
        }
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)) }
        guard !token.contains(" "), token.count > 100 else {
            problem = "That doesn’t look like a token. In Graph Explorer, open the Access token tab and use its Copy button."
            return
        }
        pasteboard.clearContents()
        checking = true
        problem = nil
        defer { checking = false }
        let candidate = OneNoteClient(token: token)
        do {
            sections = try await candidate.sections()
            chosen = Set(sections.map(\.id))
            client = candidate
        } catch {
            problem = (error as? OneNoteClient.Failure).map { _ in
                "Microsoft didn’t accept that token. Copy a fresh one from Graph Explorer (and make sure Notes.Read is allowed), then click Continue."
            } ?? error.localizedDescription
        }
    }
}
