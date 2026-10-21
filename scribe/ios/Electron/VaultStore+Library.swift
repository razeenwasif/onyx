import Foundation

/// An unchecked task in a note, as the desktop finds them (main/search.ts
/// openTasks): `- [ ]` lines outside fenced code.
struct OpenTask: Identifiable, Hashable {
    var id: String { "\(rel):\(line)" }
    let rel: String
    let line: Int
    let text: String
    let modified: Date
}

/// What the Library needs beyond the files: pins, tasks and the scratch pad.
extension VaultStore {
    static let bookmarksPath = ".onyx/bookmarks.json"
    static let quicknotePath = ".onyx/quicknote.md"

    nonisolated static func findTasks(notes: [String: NoteMeta], texts: [String: String], limit: Int = 200) -> [OpenTask] {
        var out: [OpenTask] = []
        for meta in notes.values.sorted(by: { $0.modified > $1.modified }) {
            guard let text = texts[meta.rel], text.contains("[ ]") else { continue }
            var fenced = false
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
                if fenced { continue }
                guard let marker = trimmed.first, "-*+".contains(marker) else { continue }
                let rest = trimmed.dropFirst().drop(while: { $0 == " " })
                guard rest.hasPrefix("[ ] ") else { continue }
                let body = rest.dropFirst(4).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { continue }
                out.append(OpenTask(rel: meta.rel, line: i, text: body, modified: meta.modified))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    func loadBookmarks() {
        guard let url = url(for: Self.bookmarksPath), let raw = VaultScan.read(url),
              let list = try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
        else { if !bookmarks.isEmpty { bookmarks = [] }; return }
        if list != bookmarks { bookmarks = list }
    }

    func isBookmarked(_ rel: String) -> Bool { bookmarks.contains(rel) }

    func toggleBookmark(_ rel: String) {
        if let i = bookmarks.firstIndex(of: rel) { bookmarks.remove(at: i) } else { bookmarks.append(rel) }
        guard let url = url(for: Self.bookmarksPath),
              let data = try? JSONEncoder().encode(bookmarks) else { return }
        coordinatedWrite(url, data)
    }

    /// Ticks a task off in its note.
    func complete(_ task: OpenTask) {
        guard var lines = texts[task.rel]?.components(separatedBy: "\n"), task.line < lines.count,
              let box = lines[task.line].range(of: "[ ]") else { return }
        lines[task.line].replaceSubrange(box, with: "[x]")
        let content = lines.joined(separator: "\n")
        if task.rel == current { text = content }
        _ = write(task.rel, content)
    }

    func loadQuicknote() -> String {
        url(for: Self.quicknotePath).flatMap(VaultScan.read) ?? ""
    }

    func saveQuicknote(_ text: String) {
        guard let url = url(for: Self.quicknotePath) else { return }
        coordinatedWrite(url, Data(text.utf8))
    }

    private func coordinatedWrite(_ url: URL, _ data: Data) {
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }
}
