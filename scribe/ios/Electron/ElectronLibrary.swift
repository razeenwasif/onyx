import SwiftUI

/// The pieces of the Library sidebar (the desktop's LibraryPanel.tsx) in
/// Stratus's pitch-black #030304 sidebar style: borderless tonal rows,
/// active pill (#16161B) with a 5pt electric-indigo indicator dot, and a
/// Stratus-style vault footer card.
struct LibraryTodayRow: View {
    let store: VaultStore
    var active = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.evAccent : Color.evDim)
                    .frame(width: 18)
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)))
                    .font(.system(size: 13.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.evFg : Color.evDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if !store.openTasks.isEmpty {
                    Text("\(store.openTasks.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.evSubtle)
                        .monospacedDigit()
                }
                if active {
                    Circle().fill(Color.evAccent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(active ? Color.evBgSel : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
    }
}

struct LibraryPinned: View {
    let store: VaultStore
    let open: (String) -> Void

    var body: some View {
        let pins = store.bookmarks.filter { store.files[$0] != nil }
        if pins.isEmpty {
            Text("Pin a note from its ⋯ menu.")
                .font(.system(size: 12))
                .foregroundStyle(Color.evSubtle)
                .listRowBackground(Color.clear)
        }
        ForEach(pins, id: \.self) { rel in
            let isSelected = rel == store.current
            Button { open(rel) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.evAmber : Color.evAmber.opacity(0.75))
                        .frame(width: 18)
                    Text(store.notes[rel]?.name ?? ((rel as NSString).lastPathComponent as NSString).deletingPathExtension)
                        .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.evFg : Color.evDim)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isSelected {
                        Circle().fill(Color.evAccent).frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isSelected ? Color.evBgSel : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
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
                            RoundedRectangle(cornerRadius: 2).fill(Color.evInk).frame(width: 8, height: 11)
                            Text(book.name)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.evDim)
                                .lineLimit(1)
                            Spacer()
                            Text("\(book.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.evSubtle)
                                .monospacedDigit()
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } label: {
                Text(folder.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.evFg)
            }
            .listRowBackground(Color.clear)
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
            .font(.system(size: 14))
            .foregroundStyle(Color.evText)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 132)
            .padding(8)
            .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

/// Stratus-style account/vault footer pill at the foot of the Library.
struct LibraryFoot: View {
    let store: VaultStore
    let changeVault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.pending > 0 {
                Label("Downloading \(store.pending) from iCloud…", systemImage: "icloud.and.arrow.down")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.evDim)
            }
            Menu {
                Button("Sync Now", systemImage: "arrow.clockwise") { store.refresh() }
                Button("Change Vault…", systemImage: "externaldrive") { changeVault() }
            } label: {
                HStack(spacing: 9) {
                    StratusStatusDot(
                        color: store.pending > 0 ? .evAccent : .evMint,
                        size: 6,
                        pulse: store.pending == 0
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.vaultName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.evFg)
                            .lineLimit(1)
                        Text("\(store.notes.count) notes · iCloud")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.evSubtle)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.evSubtle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.evPanel)
    }
}
