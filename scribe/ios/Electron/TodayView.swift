import SwiftUI

/// Today, the home view (the desktop's TodayView.tsx): shown when no note
/// is open. A greeting, today's note to write in, the week, the to-do list,
/// tasks across the vault, and what to pick up again. The cards keep the
/// redesign's heights and scroll inside.
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
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.evChrome)
    }
}

/// A card on Today: the redesign's #1b1722 on the dark backdrop.
private struct TodayCard<Content: View>: View {
    let title: String
    var height: CGFloat?
    var trailing: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.evFg)
                Spacer()
                trailing
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(Color.evBg, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TodayHeader: View {
    let store: VaultStore

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.evSubtle)
                Text(greeting)
                    .font(.system(size: 42, weight: .medium, design: .serif))
                    .foregroundStyle(Color(uiColor: EV.heading))
            }
            Spacer()
            if let last = store.recents.first(where: { store.notes[$0] != nil }) {
                Button { store.show(last) } label: {
                    HStack(spacing: 8) {
                        Text("Continue \(store.notes[last]?.name ?? last)").lineLimit(1)
                        Image(systemName: "chevron.right").font(.footnote)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.evFg)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Color.evBg, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
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

/// Today's daily note, written in place, with a box to capture into it.
private struct TodayNoteCard: View {
    let store: VaultStore
    @State private var text = ""
    @State private var loadedFor = ""
    @State private var capture = ""

    private var rel: String { VaultStore.dailyPath(.now) }

    var body: some View {
        TodayCard(title: "Today's note", height: 394, trailing: AnyView(
            Button((rel as NSString).lastPathComponent) { store.openDaily() }
                .font(.footnote)
                .foregroundStyle(Color.evAccent)
        )) {
            TextEditor(text: $text)
                .font(.system(size: 18, design: .serif))
                .foregroundStyle(Color.evText)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write about today…")
                            .font(.system(size: 18, design: .serif))
                            .foregroundStyle(Color.evSubtle)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 10) {
                Image(systemName: "plus").foregroundStyle(Color.evSubtle)
                TextField("Capture a thought, or [] a task…", text: $capture)
                    .foregroundStyle(Color.evFg)
                    .submitLabel(.done)
                    .onSubmit(add)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Color.evChrome, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.evBorder))
        }
        .onAppear(perform: load)
        .onChange(of: store.texts[rel]) { _, fresh in
            // Written elsewhere (another device, the note itself): take it.
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

/// The week, Monday first: a lavender dot where there's a daily note, a
/// coral one where there's an event; under it, today's events from Google
/// Calendar, as the Mac last shared them.
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
                                .font(.system(size: 11))
                                .foregroundStyle(today ? Color(uiColor: EV.link) : Color.evSubtle)
                            Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.evFg)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(store.files[VaultStore.dailyPath(day)] != nil ? Color.evAccent : Color.clear)
                                    .frame(width: 5, height: 5)
                                if store.agenda?.events(on: day).isEmpty == false {
                                    Circle().fill(Color.evInk).frame(width: 5, height: 5)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(today ? Color.evBgSel : Color.clear, in: RoundedRectangle(cornerRadius: 10))
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
                                Text(event.allDay ? "All day" : event.timeLabel)
                                    .font(.system(size: 13).monospacedDigit())
                                    .foregroundStyle(Color.evSubtle)
                                    .frame(width: 56, alignment: .leading)
                                Text(event.summary).font(.system(size: 13)).foregroundStyle(Color.evFg).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// How fresh the Mac's agenda is, or nothing before it has shared one.
    @ViewBuilder
    private var syncNote: some View {
        if let when = store.agenda?.updatedDate {
            Text("Mac synced \(when.formatted(.relative(presentation: .named)))")
                .font(.footnote)
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
                Image(systemName: "plus").foregroundStyle(Color.evSubtle)
                TextField("Add a todo…", text: $draft)
                    .foregroundStyle(Color.evFg)
                    .submitLabel(.done)
                    .onSubmit(add)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.evChrome, in: RoundedRectangle(cornerRadius: 10))
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
                                    .foregroundStyle(item.done ? Color.evAccent : Color.evDim)
                                Text(item.text)
                                    .foregroundStyle(item.done ? Color.evSubtle : Color.evFg)
                                    .strikethrough(item.done)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                    }
                    let google = (store.agenda?.tasks ?? []).filter { !store.tickedGoogle.contains($0.id) }
                    if !google.isEmpty {
                        Text("Google Tasks")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.evSubtle)
                            .padding(.top, 6)
                        ForEach(google) { task in
                            Button { store.completeGoogleTask(task) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "square").foregroundStyle(Color.evDim)
                                    Text(task.title).foregroundStyle(Color.evFg).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    if let due = task.due?.prefix(10), let date = VaultStore.dayFormatter.date(from: String(due)) {
                                        Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                            .font(.footnote)
                                            .foregroundStyle(Color.evSubtle)
                                    }
                                }
                                .font(.system(size: 15))
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
            Text("\(store.openTasks.count) open").font(.footnote).foregroundStyle(Color.evSubtle)
        )) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.openTasks.isEmpty {
                        Text("Nothing open. Add one with [] above.").font(.footnote).foregroundStyle(Color.evSubtle)
                    }
                    ForEach(store.openTasks) { task in
                        HStack(spacing: 10) {
                            Button { store.complete(task) } label: {
                                Image(systemName: "square").foregroundStyle(Color.evDim)
                            }
                            .buttonStyle(.plain)
                            Text(Inline.plain(task.text)).foregroundStyle(Color.evFg).lineLimit(1)
                            Spacer(minLength: 6)
                            Button(store.notes[task.rel]?.name ?? task.rel) { store.show(task.rel) }
                                .font(.footnote)
                                .foregroundStyle(Color.evSubtle)
                                .lineLimit(1)
                                .frame(maxWidth: 120, alignment: .trailing)
                        }
                        .font(.system(size: 15))
                    }
                }
            }
        }
    }
}

/// Notes edited and ink written lately, newest first.
private struct TodayRecent: View {
    let store: VaultStore
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
            HStack {
                Text("Pick up where you left off").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.evFg)
                Spacer()
                Picker("Show", selection: $filter) {
                    Text("All").tag("all")
                    Text("Notes").tag("notes")
                    Text("Ink").tag("ink")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
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
                Text(kind(item)).font(.system(size: 12)).foregroundStyle(isInk(item) ? Color.evInk : Color.evAccent).lineLimit(1)
                Text(title(item))
                    .font(.system(size: 19, design: .serif))
                    .foregroundStyle(Color.evFg)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Text("\(isInk(item) ? "Written" : "Edited") \(item.at.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.evSubtle)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(Color.evBg, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                if isInk(item) { RoundedRectangle(cornerRadius: 16).stroke(Color.evInk.opacity(0.28)) }
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
