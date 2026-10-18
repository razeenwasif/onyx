import SwiftUI

/// Every page of a notebook section as thumbnails, Goodnotes-style. Shared
/// by the Mac app (and Scribe inside Electron) and the iPad app; each passes
/// its own colours and handles the actions.
///
/// Tap a page to open it. Drag a page onto another to move it there (or onto
/// the + tile to send it to the end). The context menu stars, renames and
/// deletes. "Starred" filters to starred pages.
struct PageGrid: View {
    struct Style {
        var ground: Color
        var text: Color
        var muted: Color
        var accent: Color
        var control: Color
    }

    let pages: [PageInfo]
    let root: String
    let currentPath: String?
    let style: Style
    /// Narrowest a thumbnail may get; the grid fits as many columns as it can.
    var minWidth: CGFloat = 120
    /// What happens to deleted pages, for the confirmation.
    var deleteNote = "It moves to the Trash."
    let open: (PageInfo) -> Void
    let reorder: ([String]) -> Void
    let toggleStar: (PageInfo) -> Void
    let rename: (PageInfo) -> Void
    let delete: (PageInfo) -> Void
    let add: () -> Void

    @State private var starredOnly = false
    @State private var target: String?
    @State private var pendingDelete: PageInfo?

    private var shown: [PageInfo] { starredOnly ? pages.filter(\.isBookmarked) : pages }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Show", selection: $starredOnly) {
                Text("All pages · \(pages.count)").tag(false)
                Text("Starred · \(pages.filter(\.isBookmarked).count)").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.top, 12)

            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 18)], spacing: 22) {
                        ForEach(shown) { page in
                            tile(page, number: (pages.firstIndex(of: page) ?? 0) + 1)
                                .id(page.path)
                        }
                        if !starredOnly { addTile }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .onAppear {
                    if let currentPath { scroller.scrollTo(currentPath, anchor: .center) }
                }
            }
            .overlay {
                if starredOnly && shown.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star").font(.title)
                        Text("No starred pages")
                        Text("Star a page from its menu to find it here.").font(.callout)
                    }
                    .foregroundStyle(style.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.ground)
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { page in
            Button("Delete Page", role: .destructive) { delete(page) }
        } message: { _ in
            Text(deleteNote)
        }
    }

    private func tile(_ page: PageInfo, number: Int) -> some View {
        let current = page.path == currentPath
        let dropping = target == page.path
        return VStack(spacing: 6) {
            PageThumbnail(page: page, root: root)
                .overlay(alignment: .topTrailing) {
                    if page.isBookmarked {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(style.accent)
                            .padding(6)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(current ? style.accent : .white.opacity(0.07), lineWidth: current ? 2.5 : 1)
                }
                // Where a dragged page will land: just before this one.
                .overlay(alignment: .leading) {
                    if dropping {
                        Capsule().fill(style.accent).frame(width: 4).offset(x: -11)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            HStack(spacing: 4) {
                Text("\(number)").foregroundStyle(style.muted).monospacedDigit()
                Text(page.title).foregroundStyle(current ? style.accent : style.text).lineLimit(1)
            }
            .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(page) }
        .contextMenu {
            Button("Open", systemImage: "doc") { open(page) }
            Button(page.isBookmarked ? "Unstar" : "Star", systemImage: page.isBookmarked ? "star.slash" : "star") { toggleStar(page) }
            Button("Rename…", systemImage: "pencil") { rename(page) }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = page }
        }
        .draggable(page.path) {
            PageThumbnail(page: page, root: root).frame(width: 90)
        }
        .dropDestination(for: String.self) { paths, _ in
            guard !starredOnly, let moving = paths.first else { return false }
            move(moving, before: page.path)
            return true
        } isTargeted: { over in
            if over { target = page.path } else if target == page.path { target = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(number), \(page.title)\(page.isBookmarked ? ", starred" : "")")
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }

    private var addTile: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(target == "+" ? style.accent : style.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .aspectRatio(840 / 1188, contentMode: .fit)
                .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(style.muted))
            Text("New Page").font(.caption).foregroundStyle(style.muted)
        }
        .contentShape(Rectangle())
        .onTapGesture { add() }
        .dropDestination(for: String.self) { paths, _ in
            guard let moving = paths.first else { return false }
            move(moving, before: nil)
            return true
        } isTargeted: { over in
            if over { target = "+" } else if target == "+" { target = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Page")
        .accessibilityAddTraits(.isButton)
    }

    /// Moves `path` to just before `before` (nil: the end) and reports the order.
    private func move(_ path: String, before: String?) {
        target = nil
        guard path != before else { return }
        var order = pages.map(\.path)
        guard let from = order.firstIndex(of: path) else { return }
        order.remove(at: from)
        let to = before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(path, at: to)
        if order != pages.map(\.path) { reorder(order) }
    }
}

/// One page's thumbnail, drawn in the background and cached (Thumbnails).
struct PageThumbnail: View {
    let page: PageInfo
    let root: String
    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(red: 0x1C / 255, green: 0x19 / 255, blue: 0x20 / 255))
            .aspectRatio(840 / 1188, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: "\(page.path)@\(page.modified)@\(page.isBookmarked)") {
                image = await Thumbnails.shared.image(for: page, root: root)
            }
    }
}
