import SwiftUI

// The library: Scribe's home screen, shared by the Mac app (and so Scribe
// inside Electron) and the iPad. Scribe's notebooks appear as "folders" and
// its sections as "notebooks" with page covers, the way Goodnotes-style apps
// name them; the files on disk keep their own names (docs/FORMAT.md).

/// Something in the library a menu acts on.
enum LibraryItem {
    case folder(NotebookInfo)
    case notebook(SectionInfo)

    var name: String {
        switch self {
        case .folder(let f): f.name
        case .notebook(let n): n.name
        }
    }
}

/// What the library's taps and menus do; each app supplies its own.
struct LibraryActions {
    var openFolder: (NotebookInfo) -> Void
    var openNotebook: (SectionInfo) -> Void
    var openPage: (PageInfo) -> Void
    var newFolder: () -> Void
    var newNotebook: (NotebookInfo) -> Void
    var rename: (LibraryItem) -> Void
    var recolor: (LibraryItem, String) -> Void
    var setCover: (SectionInfo, String) -> Void
    var delete: (LibraryItem) -> Void
}

/// Cover colours, soft enough for dark velvet.
enum CoverColor {
    static let all: [(name: String, hex: String)] = [
        ("Lavender", "#C7B6F2"), ("Peach", "#F2B9A0"), ("Mint", "#A9D8C3"), ("Butter", "#F3DB95"),
        ("Sky", "#9CC4F0"), ("Rose", "#F0A8BF"), ("Sage", "#B8C9A3"), ("Slate", "#AEB4C2"),
    ]

    static func color(_ hex: String) -> Color {
        let v = Core.parseColor(hex, fallback: 0xC7B6_F2FF)
        return Color(.sRGB, red: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
                     blue: Double((v >> 8) & 0xFF) / 255, opacity: 1)
    }
}

/// The home screen: recent pages along the top, then every folder.
struct LibraryHome: View {
    let folders: [NotebookInfo]
    let recents: [PageInfo]
    let root: String
    let style: PageGrid.Style
    let actions: LibraryActions
    var deleteNote = "It moves to the Trash."

    @AppStorage("librarySort") private var sortByName = false
    @State private var pendingDelete: LibraryItem?

    private var sorted: [NotebookInfo] {
        sortByName
            ? folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : folders.sorted { ($0.modified ?? 0) > ($1.modified ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        heading("Recent")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(recents) { page in recentCard(page) }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        heading("Folders")
                        Spacer()
                        Menu {
                            Picker("Sort", selection: $sortByName) {
                                Text("Recently Edited").tag(false)
                                Text("Name").tag(true)
                            }
                        } label: {
                            Label(sortByName ? "Name" : "Recent", systemImage: "arrow.up.arrow.down")
                                .font(.callout)
                                .foregroundStyle(style.accent)
                        }
                        .fixedSize()
                        .padding(.trailing, 24)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 22)], spacing: 26) {
                        ForEach(sorted) { folder in folderTile(folder) }
                        newTile("New Folder") { actions.newFolder() }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 20)
        }
        .background(style.ground)
        .deleteConfirmation($pendingDelete, note: deleteNote, delete: actions.delete)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(style.muted)
            .padding(.horizontal, 24)
    }

    private func recentCard(_ page: PageInfo) -> some View {
        Button { actions.openPage(page) } label: {
            VStack(alignment: .leading, spacing: 6) {
                PageThumbnail(page: page, root: root)
                    .frame(width: 112)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                Text(page.title).font(.caption.weight(.medium)).foregroundStyle(style.text).lineLimit(1)
                Text(place(of: page)).font(.caption2).foregroundStyle(style.muted).lineLimit(1)
            }
            .frame(width: 112)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(page.title), in \(place(of: page))")
    }

    private func place(of page: PageInfo) -> String {
        folders.lazy.flatMap(\.sections).first { $0.path == page.sectionPath }?.name ?? ""
    }

    private func folderTile(_ folder: NotebookInfo) -> some View {
        Button { actions.openFolder(folder) } label: {
            VStack(alignment: .leading, spacing: 8) {
                FolderStack(name: folder.name, color: CoverColor.color(folder.color))
                Text(folder.sections.count == 1 ? "1 notebook" : "\(folder.sections.count) notebooks")
                    .font(.caption)
                    .foregroundStyle(style.muted)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { itemMenu(.folder(folder), color: folder.color) }
        .accessibilityLabel("Folder \(folder.name), \(folder.sections.count) notebooks")
    }

    @ViewBuilder
    private func itemMenu(_ item: LibraryItem, color: String) -> some View {
        LibraryItemMenu(item: item, color: color, actions: actions) { pendingDelete = item }
    }
}

/// A folder's notebooks, as covers.
struct FolderView: View {
    let folder: NotebookInfo
    let root: String
    let style: PageGrid.Style
    let actions: LibraryActions
    var deleteNote = "It moves to the Trash."

    @State private var pendingDelete: LibraryItem?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 22)], spacing: 26) {
                ForEach(folder.sections) { notebook in
                    Button { actions.openNotebook(notebook) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            NotebookCover(notebook: notebook, root: root)
                            Text(notebook.name).font(.callout.weight(.medium)).foregroundStyle(style.text).lineLimit(1)
                            Text(notebook.pageCount == 1 ? "1 page" : "\(notebook.pageCount) pages")
                                .font(.caption).foregroundStyle(style.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        LibraryItemMenu(item: .notebook(notebook), color: notebook.color, actions: actions) {
                            pendingDelete = .notebook(notebook)
                        }
                    }
                    .accessibilityLabel("Notebook \(notebook.name), \(notebook.pageCount) pages")
                }
                newTile("New Notebook", aspect: 840 / 1188) { actions.newNotebook(folder) }
            }
            .padding(24)
        }
        .background(style.ground)
        .deleteConfirmation($pendingDelete, note: deleteNote, delete: actions.delete)
    }
}

/// A notebook's cover: its cover page with a spine in the notebook's colour.
struct NotebookCover: View {
    let notebook: SectionInfo
    let root: String

    var body: some View {
        Group {
            if let page = notebook.cover {
                PageThumbnail(page: page, root: root)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0x1C / 255, green: 0x19 / 255, blue: 0x20 / 255))
                    .aspectRatio(840 / 1188, contentMode: .fit)
            }
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, style: .continuous)
                .fill(CoverColor.color(notebook.color))
                .frame(width: 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }
}

/// A folder: a little stack of covers in the folder's colour.
struct FolderStack: View {
    let name: String
    let color: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.35))
                .rotationEffect(.degrees(4)).offset(x: 6, y: -5)
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.6))
                .rotationEffect(.degrees(2)).offset(x: 3, y: -2)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .overlay(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .topLeading, endPoint: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            Text(name)
                .font(.system(.callout, design: .serif).weight(.semibold))
                .foregroundStyle(Color(red: 0.08, green: 0.06, blue: 0.1).opacity(0.85))
                .lineLimit(2)
                .padding(10)
        }
        .aspectRatio(1 / 1.05, contentMode: .fit)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

/// Rename, colour, cover and delete, for a folder or notebook.
private struct LibraryItemMenu: View {
    let item: LibraryItem
    let color: String
    let actions: LibraryActions
    let askDelete: () -> Void

    var body: some View {
        Button("Rename…", systemImage: "pencil") { actions.rename(item) }
        Picker(selection: Binding(get: { color.uppercased() }, set: { actions.recolor(item, $0) })) {
            ForEach(CoverColor.all, id: \.hex) { c in
                Text(c.name).tag(c.hex.uppercased())
            }
        } label: {
            Label("Colour", systemImage: "paintpalette")
        }
        .pickerStyle(.menu)
        if case .notebook(let notebook) = item {
            Picker(selection: Binding(get: { notebook.coverChoice ?? "first" }, set: { actions.setCover(notebook, $0) })) {
                Text("First Page").tag("first")
                Text("Latest Page").tag("latest")
            } label: {
                Label("Cover", systemImage: "book.closed")
            }
            .pickerStyle(.menu)
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: askDelete)
    }
}

/// The dashed "New …" tile at the end of a grid.
/// `aspect` matches the tiles beside it: folder stacks or page covers.
private func newTile(_ title: String, aspect: CGFloat = 1 / 1.05, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .aspectRatio(aspect, contentMode: .fit)
                .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(.secondary))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
}

private extension View {
    func deleteConfirmation(_ item: Binding<LibraryItem?>, note: String, delete: @escaping (LibraryItem) -> Void) -> some View {
        confirmationDialog(
            "Delete “\(item.wrappedValue?.name ?? "")”?",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { target in
            Button(target.isFolder ? "Delete Folder" : "Delete Notebook", role: .destructive) { delete(target) }
        } message: { target in
            Text(target.isFolder ? "Every notebook and page in it goes too. \(note)" : "Every page in it goes too. \(note)")
        }
    }
}

private extension LibraryItem {
    var isFolder: Bool {
        if case .folder = self { true } else { false }
    }
}
