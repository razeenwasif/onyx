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

/// The Google agenda the Mac shares through the vault (desktop main/agenda.ts):
/// events from a week back to three weeks ahead, and open Google Tasks.
struct Agenda: Codable, Equatable {
    struct Event: Codable, Equatable, Hashable {
        var date: String
        var timeLabel: String
        var allDay: Bool
        var summary: String
    }

    struct Task: Codable, Equatable, Identifiable {
        var id: String
        var listId: String
        var listTitle: String
        var title: String
        var due: String?
    }

    var updated: String
    var events: [Event]
    var tasks: [Task]

    var updatedDate: Date? { ISO8601DateFormatter.agenda.date(from: updated) }

    func events(on day: Date) -> [Event] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return events.filter { $0.date == key }
    }
}

extension ISO8601DateFormatter {
    /// The Mac's stamps, with fractional seconds (JavaScript's toISOString).
    static let agenda: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
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

    /// `yyyy-MM-dd`, for due dates.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let agendaPath = ".onyx/agenda.json"
    static let agendaActionsPath = ".onyx/agenda-actions.json"

    func loadAgenda() {
        guard let url = url(for: Self.agendaPath) else { return }
        // Outside what the vault scan looks at, so iCloud may not have
        // fetched it yet: ask, and read it next time if not.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let raw = VaultScan.read(url),
              let fresh = try? JSONDecoder().decode(Agenda.self, from: Data(raw.utf8))
        else { return }
        // Ticks still queued for the Mac stay hidden, even after a relaunch;
        // one the Mac has carried out has left the agenda already.
        var queued: Set<String> = []
        if let aURL = self.url(for: Self.agendaActionsPath), let rawQueue = VaultScan.read(aURL), let data = rawQueue.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            queued = Set(list.compactMap { $0["taskId"] })
        }
        let hidden = tickedGoogle.union(queued).intersection(fresh.tasks.map(\.id))
        if hidden != tickedGoogle { tickedGoogle = hidden }
        if fresh != agenda { agenda = fresh }
    }

    /// Ticks a Google task: queued for the Mac, which marks it done in Google
    /// Tasks on its next sync.
    func completeGoogleTask(_ task: Agenda.Task) {
        guard let url = url(for: Self.agendaActionsPath) else { return }
        var queue: [[String: String]] = []
        if let raw = VaultScan.read(url), let data = raw.data(using: .utf8),
           let old = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            queue = old
        }
        queue.append(["op": "complete", "listId": task.listId, "taskId": task.id])
        guard let data = try? JSONSerialization.data(withJSONObject: queue, options: [.prettyPrinted]) else { return }
        coordinatedWrite(url, data)
        tickedGoogle.insert(task.id)
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
