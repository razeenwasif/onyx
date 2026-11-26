import SwiftUI

/// Something the command bar can run (the desktop's command registry).
struct PaletteCommand: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    var shortcut: String?
    let run: () -> Void
}

/// The command bar (⌘K), styled after Stratus `CommandPaletteView`:
/// `#0B0B0F` background, borderless `#111114` search bar, borderless
/// `StratusFilterPill` switcher, and mono badge chips.
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
        case all = "Everything", notes = "Notes", ink = "Ink", commands = "Commands", tags = "Tags"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.evAccent)
                TextField("Search notes, handwriting, commands…", text: $query)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.evFg)
                    .focused($focused)
                    .submitLabel(.go)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(runFirst)
                Button { dismiss() } label: {
                    StratusTagPill(text: "ESC", tint: .evSubtle, background: .evSurfacePill, monospaced: true)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Filter.allCases, id: \.self) { f in
                        StratusFilterPill(title: f.rawValue, isSelected: filter == f) {
                            filter = f
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            List {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.rows) { row in
                            Button { run(row) } label: { label(row) }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
                        }
                    } header: {
                        if !group.title.isEmpty {
                            StratusSectionHeader(title: group.title)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color.evPalette)
        .presentationBackground(Color.evPalette)
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
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evAccent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.evFg)
                    if let snippet {
                        Text(Self.plain(snippet)).font(.system(size: 12)).foregroundStyle(Color.evDim).lineLimit(1)
                    } else if !folder.isEmpty {
                        Text(folder).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.evSubtle).lineLimit(1)
                    }
                }
                Spacer()
                StratusTagPill(text: "Note", tint: .evSubtle, background: .evSurfacePill)
            }
            .padding(.vertical, 4)
        case .create(let title):
            HStack(spacing: 12) {
                Image(systemName: "plus").foregroundStyle(Color.evAccent).frame(width: 20)
                Text("Create “\(title)”").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.evAccent)
                Spacer()
                StratusTagPill(text: "New", tint: .evAccent, background: .evAccent.opacity(0.14))
            }
            .padding(.vertical, 4)
        case .ink(let page):
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Color.evInk).frame(width: 9, height: 12).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.evFg)
                    if !page.snippet.isEmpty { Text(page.snippet).font(.system(size: 12)).foregroundStyle(Color.evDim).lineLimit(1) }
                }
                Spacer()
                StratusTagPill(text: "Scribe", tint: .evInk, background: .evInk.opacity(0.14))
            }
            .padding(.vertical, 4)
        case .command(let c):
            HStack(spacing: 12) {
                Image(systemName: c.icon).font(.system(size: 13)).foregroundStyle(Color.evDim).frame(width: 20)
                Text(c.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.evFg)
                Spacer()
                if let s = c.shortcut {
                    StratusTagPill(text: s, tint: .evDim, background: .evBgSel, monospaced: true)
                }
            }
            .padding(.vertical, 4)
        case .tag(let tag, let count):
            HStack {
                Text("#" + tag).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(Color.evTagText)
                Spacer()
                StratusTagPill(text: "\(count)", tint: .evSubtle, background: .evSurfacePill, monospaced: true)
            }
            .padding(.vertical, 4)
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
