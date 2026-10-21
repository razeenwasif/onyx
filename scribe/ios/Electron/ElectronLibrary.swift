import SwiftUI

/// The pieces of the Library sidebar (the desktop's LibraryPanel.tsx) that
/// aren't the file tree:
///
///   Today        the date, with how many tasks are open
///   Pinned       bookmarked notes, shared with the desktop
///   Ink          Scribe's notebooks, by folder; one opens its latest page
///   Scratch pad  the quick note (`.onyx/quicknote.md`), folded away
///
/// and the vault's name at the foot.

struct LibraryTodayRow: View {
    let store: VaultStore
    var active = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "calendar").foregroundStyle(Color.evAccent)
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)))
                    .foregroundStyle(Color.evFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                if !store.openTasks.isEmpty {
                    Text("\(store.openTasks.count) open").font(.footnote).foregroundStyle(Color.evSubtle)
                }
            }
            .font(.body.weight(.medium))
        }
        .listRowBackground(active ? Color.evBgSel : Color.clear)
    }
}

struct LibraryPinned: View {
    let store: VaultStore
    let open: (String) -> Void

    var body: some View {
        let pins = store.bookmarks.filter { store.files[$0] != nil }
        if pins.isEmpty {
            Text("Pin a note from its ⋯ menu.").font(.footnote).foregroundStyle(Color.evSubtle)
        }
        ForEach(pins, id: \.self) { rel in
            Button { open(rel) } label: {
                Label {
                    Text(store.notes[rel]?.name ?? ((rel as NSString).lastPathComponent as NSString).deletingPathExtension).lineLimit(1)
                } icon: {
                    Image(systemName: "star").foregroundStyle(Color.evAccent)
                }
                .foregroundStyle(rel == store.current ? Color.evAccent : Color.evFg)
            }
            .listRowBackground(rel == store.current ? Color.evBgSel : Color.clear)
            .contextMenu {
                Button("Unpin", systemImage: "star.slash") { store.toggleBookmark(rel) }
            }
        }
    }
}

/// Scribe's notebooks under their folders, each opening its latest page.
struct LibraryInk: View {
    let store: VaultStore

    private struct Book: Identifiable {
        var id: String { "\(folder)/\(name)" }
        let folder: String
        let name: String
        var count: Int
        var latest: LinkedPage
    }

    var body: some View {
        ForEach(folders, id: \.name) { folder in
            DisclosureGroup {
                ForEach(folder.books) { book in
                    Button {
                        store.openScribe?(ScribeLink(pageId: book.latest.id))
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.evInk).frame(width: 9, height: 12)
                            Text(book.name).foregroundStyle(Color.evFg).lineLimit(1)
                            Spacer()
                            Text("\(book.count)").font(.footnote).foregroundStyle(Color.evSubtle).monospacedDigit()
                        }
                    }
                }
            } label: {
                Text(folder.name).foregroundStyle(Color.evFg)
            }
        }
    }

    private var folders: [(name: String, books: [Book])] {
        var byFolder: [String: [String: Book]] = [:]
        for page in store.scribePages.values {
            if var book = byFolder[page.notebook]?[page.section] {
                book.count += 1
                if page.modified > book.latest.modified { book.latest = page }
                byFolder[page.notebook]?[page.section] = book
            } else {
                byFolder[page.notebook, default: [:]][page.section] = Book(folder: page.notebook, name: page.section, count: 1, latest: page)
            }
        }
        return byFolder
            .map { (name: $0.key, books: $0.value.values.sorted { $0.latest.modified > $1.latest.modified }) }
            .sorted { ($0.books.first?.latest.modified ?? 0) > ($1.books.first?.latest.modified ?? 0) }
    }
}

/// The desktop's quick note, saved as you pause.
struct LibraryScratchPad: View {
    let store: VaultStore
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15))
            .foregroundStyle(Color.evText)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 140)
            .padding(6)
            .background(Color.evChrome, in: RoundedRectangle(cornerRadius: 10))
            .listRowBackground(Color.clear)
            .onAppear {
                text = store.loadQuicknote()
                loaded = true
            }
            .task(id: text) {
                guard loaded else { return }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                store.saveQuicknote(text)
            }
    }
}

/// The vault's name at the foot of the Library, with what to do with it.
struct LibraryFoot: View {
    let store: VaultStore
    let changeVault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.pending > 0 {
                Label("Downloading \(store.pending) from iCloud…", systemImage: "icloud.and.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(Color.evDim)
            }
            Menu {
                Button("Sync Now", systemImage: "arrow.clockwise") { store.refresh() }
                Button("Change Vault…", systemImage: "externaldrive") { changeVault() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "archivebox").foregroundStyle(Color.evDim)
                    Text(store.vaultName).foregroundStyle(Color.evFg).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Color.evSubtle)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.evPanel)
    }
}
