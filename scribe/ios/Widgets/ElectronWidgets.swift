import SwiftUI
import WidgetKit

@main
struct ElectronWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ElectronTodayWidget()
        ElectronTasksWidget()
        ElectronNotesWidget()
    }
}

// MARK: - Stratus Widget Tokens

private enum W {
    static let bg = Color(hex: 0x000000)
    static let bgDeep = Color(hex: 0x06070C)
    static let card = Color(hex: 0x0B0B0E)
    static let pill = Color(hex: 0x151519)
    static let active = Color(hex: 0x16161B)
    static let fg = Color(hex: 0xF4F4F6)
    static let dim = Color(hex: 0x8E8E99)
    static let subtle = Color(hex: 0x585862)
    static let indigo = Color(hex: 0x7A89FF)
    static let sky = Color(hex: 0x4BC3F7)
    static let mint = Color(hex: 0x34D399)
    static let coral = Color(hex: 0xE88255)
    static let amber = Color(hex: 0xFBBF24)
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

private struct ObsidianWidgetBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [W.bgDeep, W.bg],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [W.indigo.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 2,
                endRadius: 185
            )
            RadialGradient(
                colors: [W.sky.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 4,
                endRadius: 170
            )
        }
    }
}

// MARK: - Timeline Provider

struct ElectronWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ElectronWidgetSnapshot
    let isPlaceholder: Bool
}

struct ElectronWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ElectronWidgetEntry {
        ElectronWidgetEntry(date: .now, snapshot: .placeholder, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ElectronWidgetEntry) -> Void) {
        let loaded = ElectronWidgetStore.load()
        completion(ElectronWidgetEntry(
            date: .now,
            snapshot: loaded ?? .placeholder,
            isPlaceholder: context.isPreview && loaded == nil
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ElectronWidgetEntry>) -> Void) {
        let loaded = ElectronWidgetStore.load()
        let entry = ElectronWidgetEntry(date: .now, snapshot: loaded ?? .placeholder, isPlaceholder: false)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? Date(timeIntervalSinceNow: 900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Deep Link Helpers

private func noteURL(_ rel: String) -> URL {
    var comps = URLComponents()
    comps.scheme = "electron"
    comps.host = "note"
    comps.queryItems = [URLQueryItem(name: "path", value: rel)]
    return comps.url ?? URL(string: "electron://today")!
}

private enum DeepLink {
    static let today = URL(string: "electron://today")!
    static let daily = URL(string: "electron://daily")!
    static let newNote = URL(string: "electron://new")!
    static let search = URL(string: "electron://search")!
    static let todos = URL(string: "electron://todos")!
}

// MARK: - 1. Today Widget

struct ElectronTodayWidget: Widget {
    let kind = "app.electron.widget.today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ElectronWidgetProvider()) { entry in
            TodayWidgetRoot(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's daily note, open tasks, and upcoming events in Stratus obsidian style.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct TodayWidgetRoot: View {
    @Environment(\.widgetFamily) private var family
    let entry: ElectronWidgetEntry

    var body: some View {
        let snap = entry.snapshot
        Group {
            switch family {
            case .systemSmall:
                TodaySmallView(snap: snap)
            case .systemMedium:
                TodayMediumView(snap: snap)
            case .systemLarge:
                TodayLargeView(snap: snap)
            case .accessoryCircular:
                LockCircularView(snap: snap)
            case .accessoryRectangular:
                LockRectangularView(snap: snap)
            case .accessoryInline:
                LockInlineView(snap: snap)
            default:
                TodaySmallView(snap: snap)
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryCircular || family == .accessoryRectangular || family == .accessoryInline {
                Color.clear
            } else {
                ObsidianWidgetBackground()
            }
        }
    }
}

private struct TodaySmallView: View {
    let snap: ElectronWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(W.subtle)
                Spacer()
                Circle().fill(W.mint).frame(width: 5, height: 5)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("\(snap.totalOpenTasks)")
                    .font(.system(size: 32, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(W.fg)
                Text(snap.totalOpenTasks == 1 ? "OPEN TASK" : "OPEN TASKS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(W.dim)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                if let ev = snap.todayEvents.first {
                    HStack(spacing: 5) {
                        Circle().fill(W.coral).frame(width: 4, height: 4)
                        Text(ev.allDay ? "All day" : ev.timeLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(W.subtle)
                        Text(ev.summary)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(W.fg)
                            .lineLimit(1)
                    }
                } else if let todo = snap.todos.first(where: { !$0.done }) {
                    HStack(spacing: 5) {
                        Circle().fill(W.indigo).frame(width: 4, height: 4)
                        Text(todo.text)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(W.fg)
                            .lineLimit(1)
                    }
                } else {
                    Text(snap.vaultName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(W.dim)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLink.today)
    }
}

private struct TodayMediumView: View {
    let snap: ElectronWidgetSnapshot

    var body: some View {
        HStack(spacing: 14) {
            // Left: KPI + quick actions
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "atom")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(W.indigo)
                    Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(W.subtle)
                }

                Text("\(snap.totalOpenTasks)")
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(W.fg)
                Text("\(snap.noteCount) notes · \(snap.vaultName)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(W.dim)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Link(destination: DeepLink.newNote) {
                        Label("New", systemImage: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(W.indigo)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(W.indigo.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Link(destination: DeepLink.search) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(W.dim)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(W.pill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: 140, alignment: .leading)

            // Right: Upcoming events & open tasks
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snap.todayEvents.prefix(2)) { ev in
                    HStack(spacing: 6) {
                        Circle().fill(W.coral).frame(width: 4.5, height: 4.5)
                        Text(ev.allDay ? "DAY" : ev.timeLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(W.subtle)
                        Text(ev.summary)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(W.fg)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(W.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                let openTodos = snap.todos.filter { !$0.done }.prefix(snap.todayEvents.isEmpty ? 3 : 2)
                ForEach(openTodos) { todo in
                    Link(destination: DeepLink.todos) {
                        HStack(spacing: 6) {
                            Image(systemName: "square")
                                .font(.system(size: 10))
                                .foregroundStyle(W.subtle)
                            Text(todo.text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(W.fg)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(W.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }

                if snap.todayEvents.isEmpty && snap.todos.filter({ !$0.done }).isEmpty {
                    Text(snap.todayNoteExcerpt.isEmpty ? "Open Today's note" : snap.todayNoteExcerpt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(W.dim)
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(W.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .widgetURL(DeepLink.today)
    }
}

private struct TodayLargeView: View {
    let snap: ElectronWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(W.subtle)
                    Text(snap.vaultName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(W.fg)
                }
                Spacer()
                Link(destination: DeepLink.newNote) {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(W.indigo)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(W.indigo.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }

            // KPI row
            HStack(spacing: 10) {
                kpi("NOTES", "\(snap.noteCount)", W.fg)
                kpi("TASKS", "\(snap.totalOpenTasks)", W.indigo)
                kpi("EVENTS", "\(snap.todayEvents.count)", W.coral)
            }

            // Daily note preview
            Link(destination: DeepLink.daily) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("TODAY'S NOTE")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(W.subtle)
                        Spacer()
                        Text((snap.todayNotePath as NSString).lastPathComponent)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(W.indigo)
                    }
                    Text(snap.todayNoteExcerpt.isEmpty ? "Tap to start today's note…" : snap.todayNoteExcerpt)
                        .font(.system(size: 12.5))
                        .foregroundStyle(snap.todayNoteExcerpt.isEmpty ? W.subtle : W.fg)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(W.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            // Open tasks & todos
            VStack(alignment: .leading, spacing: 5) {
                Text("UP NEXT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(W.subtle)

                ForEach(snap.todayEvents.prefix(2)) { ev in
                    HStack(spacing: 7) {
                        Circle().fill(W.coral).frame(width: 5, height: 5)
                        Text(ev.allDay ? "ALL DAY" : ev.timeLabel)
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(W.subtle)
                        Text(ev.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(W.fg)
                            .lineLimit(1)
                    }
                }

                ForEach(snap.todos.filter { !$0.done }.prefix(3)) { todo in
                    Link(destination: DeepLink.todos) {
                        HStack(spacing: 7) {
                            Image(systemName: "square")
                                .font(.system(size: 10.5))
                                .foregroundStyle(W.subtle)
                            Text(todo.text)
                                .font(.system(size: 12))
                                .foregroundStyle(W.fg)
                                .lineLimit(1)
                        }
                    }
                }

                ForEach(snap.vaultTasks.prefix(2)) { task in
                    Link(destination: noteURL(task.rel)) {
                        HStack(spacing: 7) {
                            Image(systemName: "square")
                                .font(.system(size: 10.5))
                                .foregroundStyle(W.indigo)
                            Text(task.text)
                                .font(.system(size: 12))
                                .foregroundStyle(W.fg)
                                .lineLimit(1)
                            Spacer()
                            Text(task.noteName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(W.subtle)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .widgetURL(DeepLink.today)
    }

    private func kpi(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(W.subtle)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(W.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Lock Screen Accessories

private struct LockCircularView: View {
    let snap: ElectronWidgetSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "atom")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(snap.totalOpenTasks)")
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
            }
        }
        .widgetURL(DeepLink.today)
    }
}

private struct LockRectangularView: View {
    let snap: ElectronWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "atom").font(.system(size: 10, weight: .semibold))
                Text(snap.vaultName).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(snap.totalOpenTasks) open")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
            }
            if let first = snap.todos.first(where: { !$0.done }) {
                Text("• \(first.text)").font(.system(size: 11)).lineLimit(1)
            } else if let task = snap.vaultTasks.first {
                Text("• \(task.text)").font(.system(size: 11)).lineLimit(1)
            } else {
                Text("\(snap.noteCount) notes").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .widgetURL(DeepLink.today)
    }
}

private struct LockInlineView: View {
    let snap: ElectronWidgetSnapshot

    var body: some View {
        Label("Electron · \(snap.totalOpenTasks) tasks", systemImage: "atom")
            .widgetURL(DeepLink.today)
    }
}

// MARK: - 2. Tasks & Todos Widget

struct ElectronTasksWidget: Widget {
    let kind = "app.electron.widget.tasks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ElectronWidgetProvider()) { entry in
            TasksWidgetRoot(entry: entry)
        }
        .configurationDisplayName("Tasks & Todos")
        .description("Open checklist items and vault tasks across your notes.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct TasksWidgetRoot: View {
    @Environment(\.widgetFamily) private var family
    let entry: ElectronWidgetEntry

    var body: some View {
        let snap = entry.snapshot
        let openTodos = snap.todos.filter { !$0.done }
        let limit = family == .systemLarge ? 8 : (family == .systemMedium ? 4 : 3)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(W.mint).frame(width: 5, height: 5)
                    Text("TASKS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(W.subtle)
                }
                Spacer()
                Text("\(snap.totalOpenTasks)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(W.fg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(W.pill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            if openTodos.isEmpty && snap.vaultTasks.isEmpty {
                Spacer(minLength: 0)
                Text("All clear")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(W.dim)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(openTodos.prefix(limit)) { todo in
                        Link(destination: DeepLink.todos) {
                            HStack(spacing: 7) {
                                Image(systemName: "square")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(W.mint)
                                Text(todo.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(W.fg)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(W.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }

                    let remaining = max(0, limit - openTodos.prefix(limit).count)
                    ForEach(snap.vaultTasks.prefix(remaining)) { task in
                        Link(destination: noteURL(task.rel)) {
                            HStack(spacing: 7) {
                                Image(systemName: "square")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(W.indigo)
                                Text(task.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(W.fg)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if family != .systemSmall {
                                    Text(task.noteName)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(W.subtle)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(W.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLink.todos)
        .containerBackground(for: .widget) {
            ObsidianWidgetBackground()
        }
    }
}

// MARK: - 3. Recent & Pinned Notes Widget

struct ElectronNotesWidget: Widget {
    let kind = "app.electron.widget.notes"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ElectronWidgetProvider()) { entry in
            NotesWidgetRoot(entry: entry)
        }
        .configurationDisplayName("Recent & Pinned")
        .description("Jump straight back into pinned or recently edited notes.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct NotesWidgetRoot: View {
    @Environment(\.widgetFamily) private var family
    let entry: ElectronWidgetEntry

    var body: some View {
        let snap = entry.snapshot
        let combined = mergedNotes(snap)
        let limit = family == .systemLarge ? 6 : (family == .systemMedium ? 3 : 3)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NOTES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(W.subtle)
                Spacer()
                Link(destination: DeepLink.newNote) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 9.5, weight: .bold))
                        Text("New").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(W.indigo)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(W.indigo.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }

            if combined.isEmpty {
                Spacer(minLength: 0)
                Text("No notes yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(W.dim)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(combined.prefix(limit)) { item in
                        Link(destination: noteURL(item.note.rel)) {
                            HStack(spacing: 7) {
                                Image(systemName: item.pinned ? "star.fill" : "doc.text")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(item.pinned ? W.amber : W.indigo)
                                Text(item.note.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(W.fg)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if family != .systemSmall && !item.note.folder.isEmpty {
                                    Text(item.note.folder)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(W.subtle)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(W.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLink.today)
        .containerBackground(for: .widget) {
            ObsidianWidgetBackground()
        }
    }

    private struct EntryNote: Identifiable {
        var id: String { note.rel }
        let note: ElectronWidgetSnapshot.WidgetNote
        let pinned: Bool
    }

    private func mergedNotes(_ snap: ElectronWidgetSnapshot) -> [EntryNote] {
        var seen = Set<String>()
        var out: [EntryNote] = []
        for n in snap.pinnedNotes {
            if seen.insert(n.rel).inserted { out.append(EntryNote(note: n, pinned: true)) }
        }
        for n in snap.recentNotes {
            if seen.insert(n.rel).inserted { out.append(EntryNote(note: n, pinned: false)) }
        }
        return out
    }
}
