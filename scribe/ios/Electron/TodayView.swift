import SwiftUI

/// Today, the home view (the desktop's TodayView.tsx), redesigned in Stratus's
/// pitch-black T3 style: `#000000` canvas, crisp SF Pro greeting & mono KPIs,
/// borderless `#0B0B0E` tonal cards, `#111114` input wells, and `#151519` pills.
struct TodayView: View {
    @Bindable var store: VaultStore

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TodayHeader(store: store)
                    if geo.size.width > 900 {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 22) {
                                TodayNoteCard(store: store)
                                TodayRecent(store: store)
                            }
                            VStack(spacing: 16) {
                                TodayWeekCard(store: store)
                                TodayTodoCard(store: store)
                                TodayTasksCard(store: store)
                            }
                            .frame(width: 320)
                        }
                    } else if geo.size.width < 560 {
                        TodayNoteCard(store: store, height: 280)
                        TodayWeekCard(store: store)
                        TodayTodoCard(store: store)
                        TodayTasksCard(store: store)
                        TodayRecent(store: store, stacked: true)
                    } else {
                        TodayNoteCard(store: store)
                        TodayWeekCard(store: store)
                        HStack(alignment: .top, spacing: 16) {
                            TodayTodoCard(store: store)
                            TodayTasksCard(store: store)
                        }
                        TodayRecent(store: store)
                    }
                }
                .padding(.horizontal, geo.size.width < 560 ? 16 : 28)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.evBg)
    }
}

/// Borderless `#0B0B0E` tonal card matching Stratus's elevated surfaces.
private struct TodayCard<Content: View>: View {
    let title: String
    var height: CGFloat?
    var trailing: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.evFg)
                Spacer()
                trailing
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TodayHeader: View {
    let store: VaultStore

    private var openTodosCount: Int {
        store.loadTodos().filter { !$0.done }.count
    }

    private var todayEventCount: Int {
        store.agenda?.events(on: .now).count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.evSubtle)
                    Text(greeting)
                        .font(.system(size: 32, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(Color.evFg)
                }
                Spacer()
                if let last = store.recents.first(where: { store.notes[$0] != nil }) {
                    Button { store.show(last) } label: {
                        HStack(spacing: 6) {
                            Text("Continue \(store.notes[last]?.name ?? last)").lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold))
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.evFg)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.evSurfacePill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Stratus-style compact KPI strip
            HStack(spacing: 16) {
                StratusMetricStat(label: "Notes", value: "\(store.notes.count)", tint: .evFg)
                StratusMetricStat(label: "Open Tasks", value: "\(store.openTasks.count + openTodosCount)", tint: .evAccent)
                StratusMetricStat(label: "Events", value: "\(todayEventCount)", tint: .evCoral)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

/// Today's daily note, written in place, with a borderless capture well.
private struct TodayNoteCard: View {
    let store: VaultStore
    var height: CGFloat = 394
    @State private var text = ""
    @State private var loadedFor = ""
    @State private var capture = ""

    private var rel: String { VaultStore.dailyPath(.now) }

    var body: some View {
        TodayCard(title: "Today's note", height: height, trailing: AnyView(
            Button((rel as NSString).lastPathComponent) { store.openDaily() }
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.evAccent)
        )) {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .foregroundStyle(Color.evText)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write about today…")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.evSubtle)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.evSubtle)
                TextField("Capture a thought, or [] a task…", text: $capture)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.evFg)
                    .submitLabel(.done)
                    .onSubmit(add)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .onAppear(perform: load)
        .onChange(of: store.texts[rel]) { _, fresh in
            if let fresh, fresh != text { text = fresh }
        }
        .task(id: text) {
            guard loadedFor == rel, text != (store.texts[rel] ?? "") else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func load() {
        text = store.texts[rel] ?? ""
        loadedFor = rel
    }

    private func save() {
        if store.files[rel] == nil {
            _ = store.create(rel, text: text)
        } else {
            _ = store.write(rel, text)
        }
    }

    private func add() {
        var line = capture.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if line.hasPrefix("[]") { line = "- [ ] " + line.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        else if !line.hasPrefix("- ") { line = "- " + line }
        if text.isEmpty { text = "# \(VaultStore.dailyName(.now))\n\n" }
        text += (text.hasSuffix("\n") ? "" : "\n") + line + "\n"
        capture = ""
        save()
    }
}

/// The week, Monday first: an indigo dot for a daily note, coral for an event.
private struct TodayWeekCard: View {
    let store: VaultStore

    var body: some View {
        TodayCard(title: "This week", height: 178, trailing: AnyView(syncNote)) {
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    let today = Calendar.current.isDateInToday(day)
                    Button { store.openDaily(day) } label: {
                        VStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(today ? Color.evAccent : Color.evSubtle)
                            Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.evFg)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(store.files[VaultStore.dailyPath(day)] != nil ? Color.evAccent : Color.clear)
                                    .frame(width: 4.5, height: 4.5)
                                if store.agenda?.events(on: day).isEmpty == false {
                                    Circle().fill(Color.evInk).frame(width: 4.5, height: 4.5)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(today ? Color.evBgSel : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            let todays = store.agenda?.events(on: .now) ?? []
            if !todays.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(todays, id: \.self) { event in
                            HStack(spacing: 10) {
                                Text(event.allDay ? "ALL DAY" : event.timeLabel)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.evSubtle)
                                    .frame(width: 58, alignment: .leading)
                                Text(event.summary).font(.system(size: 12.5)).foregroundStyle(Color.evFg).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var syncNote: some View {
        if let when = store.agenda?.updatedDate {
            Text(when.formatted(.relative(presentation: .named)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.evSubtle)
                .lineLimit(1)
        }
    }

    private var days: [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

/// The desktop's to-do list (`.onyx/todos.md`).
private struct TodayTodoCard: View {
    let store: VaultStore
    @State private var items: [VaultStore.Todo] = []
    @State private var draft = ""

    var body: some View {
        TodayCard(title: "To do", height: 200) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11.5)).foregroundStyle(Color.evSubtle)
                TextField("Add a todo…", text: $draft)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evFg)
                    .submitLabel(.done)
                    .onSubmit(add)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text("Nothing to do. Enjoy it.").font(.footnote).foregroundStyle(Color.evSubtle)
                    }
                    ForEach($items) { $item in
                        Button {
                            item.done.toggle()
                            item.doneOn = item.done ? VaultStore.today() : nil
                            save()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(item.done ? Color.evMint : Color.evSubtle)
                                Text(item.text)
                                    .foregroundStyle(item.done ? Color.evSubtle : Color.evFg)
                                    .strikethrough(item.done)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 13.5))
                        }
                        .buttonStyle(.plain)
                    }
                    let google = (store.agenda?.tasks ?? []).filter { !store.tickedGoogle.contains($0.id) }
                    if !google.isEmpty {
                        StratusSectionHeader(title: "Google Tasks")
                            .padding(.top, 6)
                        ForEach(google) { task in
                            Button { store.completeGoogleTask(task) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "square").foregroundStyle(Color.evSubtle)
                                    Text(task.title).foregroundStyle(Color.evFg).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    if let due = task.due?.prefix(10), let date = VaultStore.dayFormatter.date(from: String(due)) {
                                        Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Color.evSubtle)
                                    }
                                }
                                .font(.system(size: 13.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { items = store.loadTodos() }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        items.insert(VaultStore.Todo(text: text, done: false), at: items.firstIndex(where: \.done) ?? items.count)
        draft = ""
        save()
    }

    private func save() {
        items = items.filter { !$0.done } + items.filter(\.done)
        store.saveTodos(items)
    }
}

/// Unchecked `- [ ]` items across the vault; ticking one ticks it in its note.
private struct TodayTasksCard: View {
    let store: VaultStore

    var body: some View {
        TodayCard(title: "Tasks across the vault", height: 200, trailing: AnyView(
            StratusTagPill(text: "\(store.openTasks.count) open", tint: .evDim, background: .evSurfacePill, monospaced: true)
        )) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if store.openTasks.isEmpty {
                        Text("Nothing open. Add one with [] above.").font(.footnote).foregroundStyle(Color.evSubtle)
                    }
                    ForEach(store.openTasks) { task in
                        HStack(spacing: 10) {
                            Button { store.complete(task) } label: {
                                Image(systemName: "square").foregroundStyle(Color.evSubtle)
                            }
                            .buttonStyle(.plain)
                            Text(Inline.plain(task.text)).foregroundStyle(Color.evFg).lineLimit(1)
                            Spacer(minLength: 6)
                            Button(store.notes[task.rel]?.name ?? task.rel) { store.show(task.rel) }
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.evSubtle)
                                .lineLimit(1)
                                .frame(maxWidth: 110, alignment: .trailing)
                        }
                        .font(.system(size: 13.5))
                    }
                }
            }
        }
    }
}

/// Notes edited and ink written lately, newest first.
private struct TodayRecent: View {
    let store: VaultStore
    var stacked = false
    @AppStorage("todayRecentFilter") private var filter = "all"

    private enum Item: Identifiable {
        case note(NoteMeta)
        case ink(LinkedPage)

        var id: String {
            switch self {
            case .note(let m): "n:" + m.rel
            case .ink(let p): "i:" + p.id
            }
        }

        var at: Date {
            switch self {
            case .note(let m): m.modified
            case .ink(let p): Date(timeIntervalSince1970: p.modified)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let header = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout())
            header {
                Text("Pick up where you left off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.evFg)
                if !stacked { Spacer() }
                HStack(spacing: 4) {
                    StratusFilterPill(title: "All", isSelected: filter == "all") { filter = "all" }
                    StratusFilterPill(title: "Notes", isSelected: filter == "notes") { filter = "notes" }
                    StratusFilterPill(title: "Ink", isSelected: filter == "ink") { filter = "ink" }
                }
                .padding(3)
                .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            if items.isEmpty {
                Text("Nothing here yet.").font(.footnote).foregroundStyle(Color.evSubtle)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(items) { item in tile(item) }
            }
        }
    }

    private var items: [Item] {
        let notes = filter == "ink" ? [] : store.notes.values.sorted { $0.modified > $1.modified }.prefix(8).map(Item.note)
        let ink = filter == "notes" ? [] : store.scribePages.values.sorted { $0.modified > $1.modified }.prefix(8).map(Item.ink)
        return Array((notes + ink).sorted { $0.at > $1.at }.prefix(8))
    }

    @ViewBuilder
    private func tile(_ item: Item) -> some View {
        Button {
            switch item {
            case .note(let m): store.show(m.rel)
            case .ink(let p): store.openScribe?(ScribeLink(pageId: p.id))
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind(item))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isInk(item) ? Color.evInk : Color.evAccent)
                    .lineLimit(1)
                Text(title(item))
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.evFg)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Text("\(isInk(item) ? "Written" : "Edited") \(item.at.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.evSubtle)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                if isInk(item) {
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                        .fill(Color.evInk)
                        .frame(width: 2.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func isInk(_ item: Item) -> Bool { if case .ink = item { true } else { false } }

    private func kind(_ item: Item) -> String {
        switch item {
        case .note(let m):
            let folder = m.rel.split(separator: "/").dropLast().first.map(String.init)
            return "Note" + (folder.map { " · \($0)" } ?? "")
        case .ink(let p): return "Ink · \(p.section)"
        }
    }

    private func title(_ item: Item) -> String {
        switch item {
        case .note(let m): m.name
        case .ink(let p): p.title
        }
    }
}
