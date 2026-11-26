import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared App Group snapshot store read by `ElectronWidgets` and written by `VaultStore`.
struct ElectronWidgetSnapshot: Codable, Sendable {
    struct WidgetTodo: Codable, Sendable, Identifiable {
        let id: String
        let text: String
        let done: Bool
    }

    struct WidgetTask: Codable, Sendable, Identifiable {
        let id: String
        let rel: String
        let noteName: String
        let text: String
    }

    struct WidgetNote: Codable, Sendable, Identifiable {
        let id: String
        let rel: String
        let title: String
        let folder: String
        let modified: Date
        let tags: [String]
    }

    struct WidgetEvent: Codable, Sendable, Identifiable {
        let id: String
        let timeLabel: String
        let summary: String
        let allDay: Bool
    }

    var vaultName: String
    var updatedAt: Date
    var noteCount: Int
    var openTodoCount: Int
    var openVaultTaskCount: Int
    var todayNoteExists: Bool
    var todayNotePath: String
    var todayNoteExcerpt: String
    var todos: [WidgetTodo]
    var vaultTasks: [WidgetTask]
    var recentNotes: [WidgetNote]
    var pinnedNotes: [WidgetNote]
    var todayEvents: [WidgetEvent]

    var totalOpenTasks: Int { openTodoCount + openVaultTaskCount }

    static let placeholder = ElectronWidgetSnapshot(
        vaultName: "OnyxVault",
        updatedAt: Date(),
        noteCount: 142,
        openTodoCount: 3,
        openVaultTaskCount: 4,
        todayNoteExists: true,
        todayNotePath: "Daily/2026-11-26.md",
        todayNoteExcerpt: "Finish Stratus redesign for Electron and ship the iOS widgets.",
        todos: [
            WidgetTodo(id: "t1", text: "Review architecture notes", done: false),
            WidgetTodo(id: "t2", text: "Sync iCloud vault on iPad", done: false),
            WidgetTodo(id: "t3", text: "Test WidgetKit timeline refresh", done: false),
        ],
        vaultTasks: [
            WidgetTask(id: "vt1", rel: "Projects/Electron.md", noteName: "Electron", text: "Verify deep links from Home Screen"),
            WidgetTask(id: "vt2", rel: "Research/Notes.md", noteName: "Notes", text: "Summarize weekly reading"),
        ],
        recentNotes: [
            WidgetNote(id: "n1", rel: "Projects/Electron.md", title: "Electron", folder: "Projects", modified: Date(), tags: ["app", "swiftui"]),
            WidgetNote(id: "n2", rel: "Daily/2026-11-26.md", title: "2026-11-26", folder: "Daily", modified: Date().addingTimeInterval(-1800), tags: ["daily"]),
            WidgetNote(id: "n3", rel: "Systems/Architecture.md", title: "Architecture", folder: "Systems", modified: Date().addingTimeInterval(-7200), tags: ["systems"]),
        ],
        pinnedNotes: [
            WidgetNote(id: "p1", rel: "Projects/Electron.md", title: "Electron", folder: "Projects", modified: Date(), tags: ["app"]),
            WidgetNote(id: "p2", rel: "Inbox.md", title: "Inbox", folder: "", modified: Date().addingTimeInterval(-3600), tags: []),
        ],
        todayEvents: [
            WidgetEvent(id: "e1", timeLabel: "10:00", summary: "Design review", allDay: false),
            WidgetEvent(id: "e2", timeLabel: "14:30", summary: "Systems sync", allDay: false),
        ]
    )
}

enum ElectronWidgetStore {
    static let appGroup = "group.app.electron.shared"
    private static let fileName = "electron-widget-snapshot.json"

    private static var fileURL: URL? {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return groupURL.appendingPathComponent(fileName)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    static func save(_ snapshot: ElectronWidgetSnapshot) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> ElectronWidgetSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(ElectronWidgetSnapshot.self, from: data) else {
            return nil
        }
        return snap
    }

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
