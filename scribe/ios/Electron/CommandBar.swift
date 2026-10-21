import SwiftUI

/// Something the command bar can run (the desktop's command registry).
struct PaletteCommand: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    var shortcut: String?
    let run: () -> Void
}

/// The command bar (⌘K), as on the desktop (CommandBar.tsx): one search
/// across notes, the text in them, handwriting in Scribe, commands and
/// tags. `>` at the start lists commands only, `#` tags only. Return opens
/// the first result.
struct CommandBar: View {
    let store: VaultStore
    let commands: [PaletteCommand]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var notes: [VaultStore.Hit] = []
    @State private var ink: [PageInfo] = []
    @FocusState private var focused: Bool

    enum Filter: String, CaseIterable {
        case all = "Everything", notes = "Notes", ink = "Handwriting", commands = "Commands", tags = "Tags"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.evAccent)
                TextField("Search notes and handwriting, run a command…", text: $query)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.evFg)
                    .focused($focused)
                    .submitLabel(.go)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(runFirst)
                Button("esc") { dismiss() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.evSubtle)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            Divider().overlay(Color.evBorder)
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            List {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.rows) { row in
                            Button { run(row) } label: { label(row) }
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        if !group.title.isEmpty {
                            Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.evSubtle)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color(uiColor: UIColor(hex: "#1D1824")))
        .presentationBackground(Color(uiColor: UIColor(hex: "#1D1824")))
        .onAppear { focused = true }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let q = text
            notes = q.isEmpty ? [] : await store.search(q)
            ink = q.isEmpty || store.searchInk == nil ? [] : (await store.searchInk?(q) ?? [])
        }
    }

    // ------------------------------------------------------------ results

    private enum Row: Identifiable {
        case note(rel: String, title: String, folder: String, snippet: String?)
        case create(String)
        case ink(PageInfo)
        case command(PaletteCommand)
        case tag(String, Int)

        var id: String {
            switch self {
            case .note(let rel, _, _, _): "n:" + rel
            case .create(let t): "c:" + t
            case .ink(let p): "i:" + p.path
            case .command(let c): "x:" + c.name
            case .tag(let t, _): "t:" + t
            }
        }
    }

    private struct Group {
        let title: String
        let rows: [Row]
    }

    /// The query without its `>` or `#`.
    private var text: String {
        var q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(">") || q.hasPrefix("#") { q = String(q.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return q
    }

    private var effective: Filter {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(">") { return .commands }
        if q.hasPrefix("#"), filter == .all { return .tags }
        return filter
    }

    private func want(_ f: Filter) -> Bool { effective == .all || effective == f }

    private var groups: [Group] {
        let q = text.lowercased()
        var out: [Group] = []
        if q.isEmpty {
            if want(.notes) {
                let recent = store.recents.filter { store.notes[$0] != nil }.prefix(6).map(noteRow)
                if !recent.isEmpty { out.append(Group(title: "Recent", rows: recent)) }
            }
            if want(.commands) { out.append(Group(title: "Commands", rows: commands.prefix(effective == .commands ? 40 : 6).map(Row.command))) }
            if effective == .tags { out.append(Group(title: "Tags", rows: store.tagCounts.prefix(40).map { .tag($0.tag, $0.count) })) }
            return out.filter { !$0.rows.isEmpty }
        }
        if want(.notes) {
            var rows = notes.prefix(8).map { hit in
                Row.note(rel: hit.rel, title: store.notes[hit.rel]?.name ?? hit.title,
                         folder: (hit.rel as NSString).deletingLastPathComponent, snippet: hit.snippet)
            }
            if !store.notes.values.contains(where: { $0.name.lowercased() == q }) { rows.append(.create(text)) }
            out.append(Group(title: "Notes", rows: rows))
        }
        if want(.ink), !ink.isEmpty { out.append(Group(title: "Handwriting", rows: ink.prefix(effective == .ink ? 20 : 4).map(Row.ink))) }
        if want(.commands) {
            let rows = commands.filter { $0.name.lowercased().contains(q) }.prefix(effective == .commands ? 40 : 5).map(Row.command)
            if !rows.isEmpty { out.append(Group(title: "Commands", rows: rows)) }
        }
        if want(.tags) {
            let rows = store.tagCounts.filter { $0.tag.lowercased().contains(q) }.prefix(effective == .tags ? 40 : 4).map { Row.tag($0.tag, $0.count) }
            if !rows.isEmpty { out.append(Group(title: "Tags", rows: rows)) }
        }
        return out.filter { !$0.rows.isEmpty }
    }

    private func noteRow(_ rel: String) -> Row {
        .note(rel: rel, title: store.notes[rel]?.name ?? rel, folder: (rel as NSString).deletingLastPathComponent, snippet: nil)
    }

    @ViewBuilder
    private func label(_ row: Row) -> some View {
        switch row {
        case .note(_, let title, let folder, let snippet):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(Color.evSubtle).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).foregroundStyle(Color.evFg)
                        if !folder.isEmpty { Text(folder).font(.footnote).foregroundStyle(Color.evSubtle).lineLimit(1) }
                    }
                    if let snippet { Text(Self.plain(snippet)).font(.footnote).foregroundStyle(Color.evDim).lineLimit(1) }
                }
            }
        case .create(let title):
            Label("Create “\(title)”", systemImage: "plus").foregroundStyle(Color.evAccent)
        case .ink(let page):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Color.evInk).frame(width: 9, height: 12).padding(.top, 4).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).foregroundStyle(Color.evFg)
                    if !page.snippet.isEmpty { Text(page.snippet).font(.footnote).foregroundStyle(Color.evDim).lineLimit(1) }
                }
                Spacer()
                Text("opens in Scribe").font(.footnote).foregroundStyle(Color.evSubtle)
            }
        case .command(let c):
            HStack(spacing: 12) {
                Image(systemName: c.icon).foregroundStyle(Color.evSubtle).frame(width: 20)
                Text(c.name).foregroundStyle(Color.evFg)
                Spacer()
                if let s = c.shortcut {
                    Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.evDim)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.evBgSel, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        case .tag(let tag, let count):
            HStack {
                Text("#" + tag).foregroundStyle(Color.evTagText)
                Spacer()
                Text("\(count)").font(.footnote).foregroundStyle(Color.evSubtle).monospacedDigit()
            }
        }
    }

    /// A line of Markdown as it reads: links by their text, no heading marks.
    static func plain(_ line: String) -> String {
        Inline.plain(line.replacingOccurrences(of: #"(^|\s)#{1,6}\s"#, with: "$1", options: .regularExpression))
            .trimmingCharacters(in: .whitespaces)
    }

    private func runFirst() {
        if let first = groups.first?.rows.first { run(first) }
    }

    private func run(_ row: Row) {
        dismiss()
        switch row {
        case .note(let rel, _, _, _):
            store.show(rel)
        case .create(let title):
            let rel = title.replacingOccurrences(of: "/", with: "-") + ".md"
            if store.files[rel] != nil { store.show(rel) } else if store.create(rel, text: "") { store.show(rel); store.mode = .editing }
        case .ink(let page):
            if let id = page.pageId, !id.isEmpty { store.openScribe?(ScribeLink(pageId: id)) }
        case .command(let c):
            // Let the sheet go before a command opens another.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { c.run() }
        case .tag(let tag, _):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.tagFilter = tag }
        }
    }
}
