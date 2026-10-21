import Foundation
import Observation

/// A file or folder in the vault, for the sidebar tree.
struct VaultNode: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case folder, note, pdf, image, other }

    var id: String { rel }
    /// Vault-relative POSIX path; "" is the vault itself.
    let rel: String
    let name: String
    let kind: Kind
    /// Nil for files, so `List(children:)` shows no disclosure arrow.
    var children: [VaultNode]?

    var isFolder: Bool { kind == .folder }

    /// The name without `.md`.
    var title: String { kind == .note ? (name as NSString).deletingPathExtension : name }

    static func kind(of name: String) -> Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdx": .note
        case "pdf": .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "svg", "avif": .image
        default: .other
        }
    }
}

/// What the index knows about one note.
struct NoteMeta: Sendable, Equatable {
    let rel: String
    let title: String
    let tags: [String]
    /// Raw link targets (`[[…]]` and local `[](…)`), unresolved.
    let targets: [String]
    let aliases: [String]
    let modified: Date

    /// `Folder/Note.md` → `Note`.
    var name: String { ((rel as NSString).lastPathComponent as NSString).deletingPathExtension }

    init(rel: String, text: String, modified: Date) {
        self.rel = rel
        self.modified = modified
        let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        title = NoteParse.firstHeading(text) ?? name
        var tags = NoteParse.frontmatterTags(text)
        for t in NoteParse.inlineTags(NoteParse.body(text)) where !tags.contains(t) { tags.append(t) }
        self.tags = tags
        targets = NoteParse.links(text).map(\.target) + NoteParse.mdLinks(text)
        aliases = NoteParse.aliases(text)
    }
}

/// One pass over the vault folder, made off the main thread.
struct VaultScan: Sendable {
    var tree: [VaultNode] = []
    /// Every file's modification date, notes and attachments.
    var files: [String: Date] = [:]
    var notes: [String: NoteMeta] = [:]
    var texts: [String: String] = [:]
    /// Files iCloud still has to download to this iPad.
    var pending = 0

    /// Folders the desktop never shows (desktop/src/main/vault.ts).
    static let ignored: Set<String> = [".git", ".obsidian", ".onyx", ".trash", "node_modules", ".svn", ".hg"]

    /// Walks `root`, reusing `previous` for files that haven't changed.
    static func run(root: URL, previous: VaultScan?) -> VaultScan {
        var scan = VaultScan()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return scan
        }
        let base = root.standardizedFileURL.path
        var folders: Set<String> = []
        var fileList: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if name.hasPrefix(".") || ignored.contains(name) { walker.skipDescendants(); continue }
                folders.insert(rel(url, base))
                continue
            }
            // Old-style iCloud placeholders: `.Note.md.icloud`.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                scan.pending += 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            if name.hasPrefix(".") { continue }
            let path = rel(url, base)
            let modified = values?.contentModificationDate ?? .distantPast
            if let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                scan.pending += 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                // Keep showing what was read before; a placeholder has no text yet.
                if let old = previous?.texts[path], let meta = previous?.notes[path] {
                    scan.texts[path] = old
                    scan.notes[path] = meta
                    scan.files[path] = meta.modified
                    fileList.append(path)
                }
                continue
            }
            scan.files[path] = modified
            fileList.append(path)
            guard VaultNode.kind(of: name) == .note else { continue }
            if let old = previous?.notes[path], old.modified == modified, let text = previous?.texts[path] {
                scan.notes[path] = old
                scan.texts[path] = text
            } else if let text = read(url) {
                scan.notes[path] = NoteMeta(rel: path, text: text, modified: modified)
                scan.texts[path] = text
            }
        }
        scan.tree = buildTree(folders: folders, files: fileList)
        return scan
    }

    static func rel(_ url: URL, _ base: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func read(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func buildTree(folders: Set<String>, files: [String]) -> [VaultNode] {
        var kids: [String: [VaultNode]] = [:]
        for f in files {
            let parent = (f as NSString).deletingLastPathComponent
            kids[parent, default: []].append(VaultNode(rel: f, name: (f as NSString).lastPathComponent, kind: VaultNode.kind(of: f)))
        }
        func folder(_ rel: String) -> [VaultNode] {
            let subfolders = folders.filter { ($0 as NSString).deletingLastPathComponent == rel && !$0.isEmpty }
            var nodes = subfolders.map { sub in
                VaultNode(rel: sub, name: (sub as NSString).lastPathComponent, kind: .folder, children: folder(sub))
            }
            nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let files = (kids[rel] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return nodes + files
        }
        return folder("")
    }
}

/// Electron on the iPad: the vault, its index, and the open note. Reads and
/// writes the same folder the desktop app uses, through iCloud Drive.
@MainActor
@Observable
final class VaultStore {
    static let bookmarkKey = "electronVaultBookmark"

    enum Mode: String { case reading, editing }

    private(set) var root: URL?
    private(set) var tree: [VaultNode] = []
    private(set) var notes: [String: NoteMeta] = [:]
    private(set) var files: [String: Date] = [:]
    private(set) var texts: [String: String] = [:]
    private(set) var pending = 0
    private(set) var loaded = false
    var problem: String?

    // The open file.
    private(set) var current: String?
    var text = ""
    private(set) var dirty = false
    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "electronMode") ?? "") ?? .reading {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "electronMode") }
    }
    /// The source line at the top of the screen, so switching between
    /// reading and editing keeps your place.
    var anchorLine = 0
    /// A tag picked in a note, to list its notes.
    var tagFilter: String?
    /// A heading to scroll to once the note shows (`[[Note#Heading]]`).
    var headingTarget: String?
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "electronRecents") ?? []

    // Index built from `notes`.
    private var byRelKey: [String: String] = [:]
    private var byBase: [String: [String]] = [:]
    private var byAlias: [String: String] = [:]
    private var byFileName: [String: String] = [:]
    private(set) var backlinkMap: [String: Set<String>] = [:]
    private(set) var tagCounts: [(tag: String, count: Int)] = []
    /// Unchecked `- [ ]` items across the vault, newest note first (the
    /// Library's count, and Today's list).
    private(set) var openTasks: [OpenTask] = []
    /// Pinned notes, shared with the desktop (`.onyx/bookmarks.json`).
    var bookmarks: [String] = []

    /// Scribe's pages by id, for `[[scribe:…]]` links: Scribe's link index,
    /// handed over by AppHost whenever Scribe reads it.
    var scribePages: [String: LinkedPage] = [:]
    /// Opens a Scribe page, or an area of one, and shows Scribe (AppHost).
    @ObservationIgnored var openScribe: ((ScribeLink) -> Void)?

    private var lastScan: VaultScan?
    private var scanning = false
    private var poll: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var openedStamp: Date?

    init() {
        #if targetEnvironment(simulator)
        // For trying Electron on a copy of the vault on the Mac:
        //   xcrun simctl launch booted app.scribe.ipad -ElectronTestVault /path
        if let path = UserDefaults.standard.string(forKey: "ElectronTestVault") {
            open(URL(fileURLWithPath: path))
            return
        }
        #endif
        if let url = Library.restore(key: Self.bookmarkKey) { open(url) }
    }

    // MARK: Vault

    func choose(_ url: URL) {
        do { open(try Library.choose(url, key: Self.bookmarkKey)) } catch { problem = error.localizedDescription }
    }

    func forgetVault() {
        flush()
        poll?.cancel()
        Library.forget(key: Self.bookmarkKey)
        root = nil
        tree = []; notes = [:]; texts = [:]; files = [:]
        current = nil; text = ""; loaded = false
    }

    var vaultName: String { root?.lastPathComponent ?? "Vault" }

    private func open(_ url: URL) {
        root = url
        loaded = false
        lastScan = nil
        refresh()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
            }
        }
    }

    /// Rescans the vault (in the background) and picks up edits made on the Mac.
    func refresh() {
        guard let root, !scanning else { return }
        scanning = true
        let previous = lastScan
        Task.detached(priority: .userInitiated) {
            let scan = VaultScan.run(root: root, previous: previous)
            await MainActor.run { self.apply(scan) }
        }
    }

    private func apply(_ scan: VaultScan) {
        scanning = false
        lastScan = scan
        if scan.tree != tree { tree = scan.tree }
        pending = scan.pending
        files = scan.files
        texts = scan.texts
        if scan.notes != notes {
            notes = scan.notes
            reindex()
        }
        loaded = true
        loadBookmarks()
        // The open note changed on another device: show the new text unless
        // there are edits here that haven't been saved.
        // A scan that started before a save here still has the old stamp, so
        // only a newer file counts.
        if let current, !dirty, let stamp = files[current], stamp > (openedStamp ?? .distantPast), let fresh = texts[current] {
            text = fresh
            openedStamp = stamp
        }
    }

    private func reindex() {
        byRelKey = [:]; byBase = [:]; byAlias = [:]; byFileName = [:]
        for rel in notes.keys {
            let key = Self.relKey(rel)
            byRelKey[key] = rel
            byBase[(key as NSString).lastPathComponent, default: []].append(rel)
        }
        for list in byBase.keys { byBase[list]?.sort { $0.split(separator: "/").count < $1.split(separator: "/").count } }
        for (rel, meta) in notes { for a in meta.aliases { byAlias[a.lowercased()] = rel } }
        for rel in files.keys where VaultNode.kind(of: rel) != .note {
            byFileName[(rel as NSString).lastPathComponent.lowercased()] = rel
            byFileName[rel.lowercased()] = rel
        }
        var links: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for (rel, meta) in notes {
            for target in meta.targets where ScribeLink(target: target) == nil {
                if let hit = resolve(target, from: rel), hit != rel { links[hit, default: []].insert(rel) }
            }
            for tag in meta.tags { counts[tag, default: 0] += 1 }
        }
        backlinkMap = links
        openTasks = Self.findTasks(notes: notes, texts: texts)
        tagCounts = counts.map { ($0.key, $0.value) }.sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    /// `Folder/Note.md` → `folder/note`.
    static func relKey(_ rel: String) -> String {
        let ext = (rel as NSString).pathExtension.lowercased()
        let stem = ["md", "markdown", "mdx"].contains(ext) ? (rel as NSString).deletingPathExtension : rel
        return stem.lowercased()
    }

    /// Resolves a link target Obsidian-style: a path-qualified target by its
    /// path, a bare name to the nearest note (own folder first, then the
    /// shallowest), then aliases, then attachments.
    func resolve(_ target: String, from: String?) -> String? {
        var name = NoteParse.noteName(target).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("./") { name.removeFirst(2) }
        if name.isEmpty { return from }
        var key = name.lowercased()
        if key.hasSuffix(".md") { key.removeLast(3) }
        if key.contains("/") {
            if let hit = byRelKey[key] { return hit }
            if let from {
                let folder = (from as NSString).deletingLastPathComponent
                let joined = ((folder as NSString).appendingPathComponent(key) as NSString).standardizingPath.lowercased()
                if let hit = byRelKey[joined] { return hit }
            }
        }
        if let candidates = byBase[(key as NSString).lastPathComponent], !candidates.isEmpty {
            let matching = key.contains("/") ? candidates.filter { Self.relKey($0).hasSuffix(key) } : candidates
            let pool = matching.isEmpty ? candidates : matching
            if let from {
                let folder = (from as NSString).deletingLastPathComponent.lowercased()
                if let near = pool.first(where: { ($0 as NSString).deletingLastPathComponent.lowercased() == folder }) { return near }
            }
            return pool.first
        }
        if let hit = byAlias[key] { return hit }
        return byFileName[name.lowercased()]
    }

    func backlinks(of rel: String) -> [String] {
        (backlinkMap[rel] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The Scribe page a `scribe:` link target names, if Scribe has it.
    func scribePage(_ target: String) -> LinkedPage? {
        ScribeLink(target: target).flatMap { scribePages[$0.pageId] }
    }

    /// The notes linking to the Scribe page with `pageId`, for its "Linked
    /// from" list in Scribe.
    func notesLinking(toPage pageId: String) -> [LinkingNote] {
        notes.values
            .filter { meta in meta.targets.contains { ScribeLink(target: $0)?.pageId == pageId } }
            .map { LinkingNote(path: $0.rel, title: $0.name) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Scribe pages with `[[…]]` typed on them that leads to `rel`.
    func scribeBacklinks(of rel: String) -> [LinkedPage] {
        scribePages.values
            .filter { page in page.links.contains { ScribeLink(target: $0) == nil && resolve($0, from: nil) == rel } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func url(for rel: String) -> URL? {
        root?.appendingPathComponent(rel)
    }

    func notes(tagged tag: String) -> [String] {
        notes.values.filter { meta in meta.tags.contains { $0 == tag || $0.hasPrefix(tag + "/") } }
            .map(\.rel).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Opening

    /// Opens a file, keeping the page you were on for Back.
    func show(_ rel: String, heading: String? = nil, remember: Bool = true) {
        if rel == current {
            headingTarget = heading
            return
        }
        flush()
        if remember, let current { back.append(current); forward = [] }
        load(rel)
        headingTarget = heading
    }

    private func load(_ rel: String) {
        current = rel
        dirty = false
        anchorLine = 0
        openedStamp = files[rel]
        if VaultNode.kind(of: rel) == .note {
            if let url = url(for: rel), let fresh = VaultScan.read(url) {
                text = fresh
            } else {
                text = texts[rel] ?? ""
            }
        } else {
            text = ""
        }
        recents.removeAll { $0 == rel }
        recents.insert(rel, at: 0)
        if recents.count > 15 { recents.removeLast(recents.count - 15) }
        UserDefaults.standard.set(recents, forKey: "electronRecents")
    }

    /// Follows a link from the open note.
    func follow(_ target: String) {
        if let link = ScribeLink(target: target) {
            flush()
            openScribe?(link)
            return
        }
        if let hit = resolve(target, from: current) {
            show(hit, heading: NoteParse.heading(target))
        } else {
            // Obsidian makes a missing note on click; do the same, next to this one.
            let name = NoteParse.noteName(target).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let folder = current.map { ($0 as NSString).deletingLastPathComponent } ?? ""
            let rel = name.contains("/") ? name + ".md" : (folder as NSString).appendingPathComponent(name + ".md")
            if create(rel, text: "") { show(rel); mode = .editing }
        }
    }

    func goBack() {
        guard let last = back.popLast() else { return }
        flush()
        if let current { forward.append(current) }
        load(last)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        flush()
        if let current { back.append(current) }
        load(next)
    }

    func close() {
        flush()
        current = nil
        text = ""
    }

    /// Today, the home view: no note open. Back returns to the note left.
    func showToday() {
        guard current != nil else { return }
        flush()
        if let current { back.append(current); forward = [] }
        current = nil
        text = ""
    }

    // MARK: Editing

    /// Called on every edit; saves a second after typing stops.
    func edited(_ new: String) {
        guard new != text else { return }
        text = new
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard dirty, let current else { return }
        if write(current, text) {
            dirty = false
            openedStamp = files[current]
        }
    }

    /// Ticks or unticks the task on `line` (0-based) of the open note.
    func toggleTask(line: Int) {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        let l = lines[line]
        if let r = l.range(of: #"\[[ ]\]"#, options: .regularExpression) {
            lines[line] = l.replacingCharacters(in: r, with: "[x]")
        } else if let r = l.range(of: #"\[[xX]\]"#, options: .regularExpression) {
            lines[line] = l.replacingCharacters(in: r, with: "[ ]")
        } else { return }
        edited(lines.joined(separator: "\n"))
        flush()
    }

    @discardableResult
    func write(_ rel: String, _ content: String) -> Bool {
        guard let url = url(for: rel) else { return false }
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, atomically: true, encoding: .utf8)
            } catch { failure = error }
        }
        if let error = failure ?? coordError {
            problem = "Couldn't save \(rel): \(error.localizedDescription)"
            return false
        }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        files[rel] = stamp
        texts[rel] = content
        if VaultNode.kind(of: rel) == .note {
            notes[rel] = NoteMeta(rel: rel, text: content, modified: stamp)
            reindex()
        }
        lastScan?.files[rel] = stamp
        lastScan?.texts[rel] = content
        lastScan?.notes[rel] = notes[rel]
        return true
    }

    // MARK: Files

    /// A free `Untitled.md` (or `Untitled 2.md`…) in `folder`.
    func newNote(in folder: String) {
        var n = 1
        var rel: String
        repeat {
            let name = n == 1 ? "Untitled.md" : "Untitled \(n).md"
            rel = (folder as NSString).appendingPathComponent(name)
            n += 1
        } while files[rel] != nil
        if create(rel, text: "") {
            show(rel)
            mode = .editing
        }
    }

    @discardableResult
    func create(_ rel: String, text: String) -> Bool {
        guard files[rel] == nil else { problem = "“\(rel)” already exists."; return false }
        guard write(rel, text) else { return false }
        refresh()
        return true
    }

    func newFolder(in parent: String, named name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, let root else { return }
        let url = root.appendingPathComponent((parent as NSString).appendingPathComponent(clean))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch { problem = error.localizedDescription }
        refresh()
    }

    /// Renames a note, attachment or folder; links to a renamed note are
    /// rewritten the way the desktop does it.
    func rename(_ rel: String, to newName: String) {
        guard let root else { return }
        var clean = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        let isNote = VaultNode.kind(of: rel) == .note
        if isNote, (clean as NSString).pathExtension.isEmpty { clean += ".md" }
        let parent = (rel as NSString).deletingLastPathComponent
        let to = (parent as NSString).appendingPathComponent(clean)
        guard to != rel else { return }
        flush()
        let referrers = isNote ? backlinks(of: rel) : []
        var coordError: NSError?
        var failure: Error?
        let from = root.appendingPathComponent(rel), dest = root.appendingPathComponent(to)
        NSFileCoordinator().coordinate(writingItemAt: from, options: .forMoving, writingItemAt: dest, options: .forReplacing, error: &coordError) { a, b in
            do { try FileManager.default.moveItem(at: a, to: b) } catch { failure = error }
        }
        if let error = failure ?? coordError { problem = error.localizedDescription; return }

        if isNote {
            let oldKey = Self.relKey(rel), oldName = (oldKey as NSString).lastPathComponent
            let newRel = (to as NSString).deletingPathExtension, newBase = (newRel as NSString).lastPathComponent
            for ref in referrers {
                guard let refURL = url(for: ref == rel ? to : ref), let source = VaultScan.read(refURL) else { continue }
                let updated = Self.rewriteLinks(source) { target in
                    let name = NoteParse.noteName(target)
                    let rest = String(target.dropFirst(name.count))
                    switch name.lowercased() {
                    case oldKey: return newRel + rest
                    case oldName: return newBase + rest
                    default: return nil
                    }
                }
                if updated != source { write(ref, updated) }
            }
        }
        // Keep what's open pointing at the right file.
        func moved(_ path: String) -> String {
            if path == rel { return to }
            if path.hasPrefix(rel + "/") { return to + path.dropFirst(rel.count) }
            return path
        }
        if let current { self.current = moved(current); openedStamp = nil }
        back = back.map(moved); forward = forward.map(moved)
        recents = recents.map(moved)
        UserDefaults.standard.set(recents, forKey: "electronRecents")
        lastScan = nil
        refresh()
    }

    /// `[[target]]` / `[[target|alias]]` rewritten by `change` (nil keeps it).
    static func rewriteLinks(_ source: String, _ change: (String) -> String?) -> String {
        let ns = NSMutableString(string: source)
        for link in NoteParse.links(source).reversed() {
            guard let next = change(link.target) else { continue }
            let inner = next + (link.alias.map { "|" + $0 } ?? "")
            ns.replaceCharacters(in: link.range, with: (link.embed ? "!" : "") + "[[" + inner + "]]")
        }
        return ns as String
    }

    /// Moves a file or folder into the vault's `.trash` folder, as Obsidian does.
    func delete(_ rel: String) {
        guard let root else { return }
        if current == rel || current?.hasPrefix(rel + "/") == true {
            saveTask?.cancel()
            dirty = false
            current = nil
            text = ""
        }
        let trash = root.appendingPathComponent(".trash")
        var dest = trash.appendingPathComponent((rel as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = (rel as NSString).lastPathComponent
            dest = trash.appendingPathComponent("\((name as NSString).deletingPathExtension) \(stamp)" + ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension))
        }
        let source = root.appendingPathComponent(rel)
        var coordError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forMoving, writingItemAt: dest, options: .forReplacing, error: &coordError) { a, b in
            do {
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: a, to: b)
            } catch { failure = error }
        }
        if let error = failure ?? coordError { problem = error.localizedDescription }
        recents.removeAll { $0 == rel || $0.hasPrefix(rel + "/") }
        UserDefaults.standard.set(recents, forKey: "electronRecents")
        lastScan = nil
        refresh()
    }

    // MARK: Daily notes

    /// Where daily notes go and how they're named, as the desktop's defaults
    /// (Settings → Daily notes: folder "Daily", "YYYY-MM-DD").
    static let dailyFolder = "Daily"

    static func dailyName(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func dailyPath(_ date: Date) -> String {
        (dailyFolder as NSString).appendingPathComponent(dailyName(date) + ".md")
    }

    /// Opens the day's note, making it (as the desktop does) if it's new.
    func openDaily(_ date: Date = Date()) {
        let rel = Self.dailyPath(date)
        if files[rel] == nil {
            guard create(rel, text: "# \(Self.dailyName(date))\n\n") else { return }
            mode = .editing
        }
        show(rel)
    }

    // MARK: Search

    struct Hit: Identifiable, Sendable {
        var id: String { rel }
        let rel: String
        let title: String
        let snippet: String?
        let score: Int
    }

    /// Notes whose name, title, tags or text contain every word of `query`.
    func search(_ query: String) async -> [Hit] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let texts = self.texts, notes = self.notes
        return await Task.detached(priority: .userInitiated) {
            var hits: [Hit] = []
            for (rel, meta) in notes {
                let text = texts[rel] ?? ""
                let lower = text.lowercased()
                let name = meta.name.lowercased(), title = meta.title.lowercased()
                var score = 0
                var all = true
                for w in words {
                    if name.contains(w) || title.contains(w) { score += 10 }
                    else if meta.tags.contains(where: { $0.lowercased().contains(w) }) { score += 4 }
                    else if lower.contains(w) { score += 1 }
                    else { all = false; break }
                }
                guard all else { continue }
                if name == query.lowercased() { score += 50 }
                // Quote the note's body, not its frontmatter.
                let body = NoteParse.body(text)
                let snippet = Self.snippet(body, lower: body.lowercased(), word: words[0]) ?? Self.snippet(text, lower: lower, word: words[0])
                hits.append(Hit(rel: rel, title: meta.title, snippet: snippet, score: score))
            }
            return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.rel < $1.rel }.prefix(150).map { $0 }
        }.value
    }

    nonisolated private static func snippet(_ text: String, lower: String, word: String) -> String? {
        guard let r = lower.range(of: word) else { return nil }
        let offset = lower.distance(from: lower.startIndex, to: r.lowerBound)
        guard let start = text.index(text.startIndex, offsetBy: max(0, offset - 50), limitedBy: text.endIndex),
              let end = text.index(text.startIndex, offsetBy: min(text.count, offset + 90), limitedBy: text.endIndex)
        else { return nil }
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }

    // MARK: Todos

    struct Todo: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var done: Bool
        var doneOn: String?

        static func == (a: Todo, b: Todo) -> Bool { a.text == b.text && a.done == b.done && a.doneOn == b.doneOn }
    }

    static let todoPath = ".onyx/todos.md"

    /// The desktop's checklist (`.onyx/todos.md`, desktop/src/shared/todo.ts).
    func loadTodos() -> [Todo] {
        guard let url = url(for: Self.todoPath), let text = VaultScan.read(url) else { return [] }
        let today = Self.today()
        var out: [Todo] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ["), line.count >= 6 else { continue }
            let mark = line[line.index(line.startIndex, offsetBy: 3)]
            guard line[line.index(line.startIndex, offsetBy: 4)] == "]" else { continue }
            var body = String(line.dropFirst(6))
            let done = mark != " "
            var doneOn: String?
            if done {
                if let r = body.range(of: #"<!--done:(\d{4}-\d{2}-\d{2})-->\s*$"#, options: .regularExpression) {
                    doneOn = String(body[r].dropFirst(9).prefix(10))
                    body = String(body[..<r.lowerBound])
                } else { doneOn = today }
            }
            out.append(Todo(text: body.trimmingCharacters(in: .whitespaces), done: done, doneOn: doneOn))
        }
        // Finished more than a week ago: gone, as on the desktop.
        return out.filter { !$0.done || ($0.doneOn.map { Self.days(from: $0, to: today) < 7 } ?? true) }
    }

    func saveTodos(_ items: [Todo]) {
        let today = Self.today()
        let lines = items.filter { !$0.done }.map { "- [ ] \($0.text)" }
            + items.filter(\.done).map { "- [x] \($0.text) <!--done:\($0.doneOn ?? today)-->" }
        guard let url = url(for: Self.todoPath) else { return }
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
        }
    }

    static func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func days(from a: String, to b: String) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let da = f.date(from: a), let db = f.date(from: b) else { return 0 }
        return Int((db.timeIntervalSince(da) / 86400).rounded())
    }
}
