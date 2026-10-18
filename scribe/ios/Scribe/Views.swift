import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var store: Store

    var body: some View {
        Group {
            if store.root == nil {
                WelcomeView(store: store)
            } else {
                LibraryView(store: store)
            }
        }
        .alert("Scribe", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.problem ?? "")
        }
    }
}

/// First launch: point Scribe at the notebook folder the Mac uses.
struct WelcomeView: View {
    let store: Store
    @State private var picking = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.velvetAccent)
            Text("Scribe").font(.largeTitle.weight(.semibold))
            Text("Choose your notebook folder to start. On the Mac it lives in iCloud Drive as **Scribe Notebooks**, so pick that folder and your notebooks stay in sync both ways.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.velvetMuted)
                .frame(maxWidth: 420)
            Button {
                picking = true
            } label: {
                Label("Choose Folder", systemImage: "folder")
                    .padding(.horizontal, 22)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.velvetBackdrop)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.choose(url) }
        }
    }
}

/// The library, a folder's notebooks, then a notebook's pages, as one stack
/// with back buttons, the way Goodnotes-style apps move around.
struct LibraryView: View {
    @Bindable var store: Store
    @State private var picking = false
    @State private var prompt: NamePrompt?

    static let style = PageGrid.Style(
        ground: .velvetBackdrop, text: Color(uiColor: Velvet.text), muted: .velvetMuted,
        accent: .velvetAccent, control: Color(uiColor: Velvet.control)
    )
    static let deleteNote = "It moves to Recently Deleted, so you can get it back."

    private var actions: LibraryActions {
        LibraryActions(
            openFolder: { store.openFolder($0) },
            openNotebook: { store.openNotebook($0) },
            openPage: { store.openRecent($0) },
            newFolder: { prompt = NamePrompt(kind: .newFolder) },
            newNotebook: { prompt = NamePrompt(kind: .newNotebook($0)) },
            rename: { prompt = NamePrompt(kind: .rename($0), initial: $0.name) },
            recolor: { store.recolor($0, $1) },
            setCover: { store.setCover($0, $1) },
            delete: { store.delete($0) }
        )
    }

    var body: some View {
        NavigationStack(path: $store.route) {
            LibraryHome(folders: store.notebooks, recents: store.recents, root: store.rootPath,
                        style: Self.style, actions: actions, deleteNote: Self.deleteNote)
                .navigationTitle("Library")
                .safeAreaInset(edge: .bottom) {
                    if store.downloading > 0 {
                        Label("Downloading \(store.downloading) from iCloud…", systemImage: "icloud.and.arrow.down")
                            .font(.footnote)
                            .foregroundStyle(Color.velvetMuted)
                            .padding(10)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New Folder…", systemImage: "folder.badge.plus") { prompt = NamePrompt(kind: .newFolder) }
                            Divider()
                            Button("Sync Now", systemImage: "arrow.clockwise") { store.refresh() }
                            Button("Change Library Location…", systemImage: "externaldrive") { picking = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .navigationDestination(for: Store.Route.self) { route in
                    switch route {
                    case .folder(let path):
                        if let folder = store.folder(at: path) {
                            FolderView(folder: folder, root: store.rootPath, style: Self.style, actions: actions, deleteNote: Self.deleteNote)
                                .navigationTitle(folder.name)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("New Notebook", systemImage: "plus") { prompt = NamePrompt(kind: .newNotebook(folder)) }
                                    }
                                }
                        } else {
                            ContentUnavailableView("Folder Not Found", systemImage: "folder", description: Text("It may have been moved or deleted on another device."))
                        }
                    case .notebook:
                        WritingView(store: store, prompt: $prompt)
                    }
                }
        }
        .onChange(of: store.route) { old, now in
            let inNotebook = { (r: [Store.Route]) in r.contains { if case .notebook = $0 { true } else { false } } }
            if inNotebook(old) && !inNotebook(now) { store.leftNotebook() }
        }
        .namePrompt($prompt, store: store)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.forgetFolder()
                store.choose(url)
            }
        }
    }
}

struct WritingView: View {
    @Bindable var store: Store
    @Binding var prompt: NamePrompt?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.velvetBackdrop.ignoresSafeArea()
            if store.showingGrid {
                PageGrid(
                    pages: store.pages,
                    root: store.rootPath,
                    currentPath: store.pagePath,
                    style: .init(ground: .velvetBackdrop, text: Color(uiColor: Velvet.text), muted: .velvetMuted, accent: .velvetAccent, control: Color(uiColor: Velvet.control)),
                    minWidth: 150,
                    deleteNote: "It moves to Recently Deleted, so you can get it back.",
                    open: { store.openFromGrid($0) },
                    reorder: { store.setPageOrder($0) },
                    toggleStar: { store.toggleStar($0) },
                    rename: { prompt = NamePrompt(kind: .page($0.path), initial: $0.title) },
                    delete: { store.deletePage($0) },
                    add: {
                        store.showingGrid = false
                        store.newPage()
                    }
                )
            } else if store.doc != nil {
                PageCanvas(store: store, pageID: store.doc?.id, fingerDraws: store.fingerDraws)
                    .ignoresSafeArea(edges: .bottom)
                    // Writing near the screen's edges comes before the
                    // system's edge swipes.
                    .defersSystemGestures(on: .all)
                ToolDock(store: store)
                    .padding(.bottom, 14)
            } else {
                ContentUnavailableView("No Page Open", systemImage: "pencil.and.scribble", description: Text("Open a notebook from the library."))
            }
        }
        .navigationTitle(store.showingGrid ? (store.section?.name ?? "All Pages") : (store.doc?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.spring(duration: 0.3)) { store.toggleGrid() }
                } label: {
                    Image(systemName: store.showingGrid ? "square.grid.2x2.fill" : "square.grid.2x2")
                }
                .accessibilityLabel(store.showingGrid ? "Back to the page" : "All pages")
                .disabled(store.pagePath == nil && store.sectionPath == nil)
            }
        }
        .modifier(RenameTitleMenu(store: store, prompt: $prompt))
    }
}

/// Tapping the open page's title offers Rename. Left off while the grid
/// shows, where the title names the section instead.
private struct RenameTitleMenu: ViewModifier {
    let store: Store
    @Binding var prompt: NamePrompt?

    func body(content: Content) -> some View {
        if let path = store.pagePath, !store.showingGrid {
            content.toolbarTitleMenu {
                Button("Rename…", systemImage: "pencil") {
                    prompt = NamePrompt(kind: .page(path), initial: store.doc?.title ?? "")
                }
            }
        } else {
            content
        }
    }
}

/// Asking for a name: a new folder or notebook, or a new name for one.
struct NamePrompt {
    enum Kind {
        case newFolder
        case newNotebook(NotebookInfo)
        case rename(LibraryItem)
        case page(String)
    }

    var kind: Kind
    var initial = ""

    var title: String {
        switch kind {
        case .newFolder: "New Folder"
        case .newNotebook(let folder): "New Notebook in \(folder.name)"
        case .rename(.folder): "Rename Folder"
        case .rename(.notebook): "Rename Notebook"
        case .page: "Rename Page"
        }
    }

    var action: String {
        switch kind {
        case .rename, .page: "Rename"
        default: "Create"
        }
    }
}

private struct NamePromptModifier: ViewModifier {
    @Binding var prompt: NamePrompt?
    let store: Store
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                TextField("Name", text: $text)
                Button("Cancel", role: .cancel) {}
                Button(prompt?.action ?? "OK") { commit() }
            }
            .onChange(of: prompt?.title) { text = prompt?.initial ?? "" }
    }

    private func commit() {
        guard let prompt else { return }
        switch prompt.kind {
        case .newFolder: store.newFolder(named: text)
        case .newNotebook(let folder): store.newNotebook(in: folder, named: text)
        case .rename(let item): store.rename(item, to: text)
        case .page(let path): store.renamePage(path, to: text)
        }
    }
}

extension View {
    func namePrompt(_ prompt: Binding<NamePrompt?>, store: Store) -> some View {
        modifier(NamePromptModifier(prompt: prompt, store: store))
    }
}

/// Pen, highlighter, eraser, colours, nib size, undo.
struct ToolDock: View {
    @Bindable var store: Store

    static let penSizes: [(String, Double)] = [("Fine", 2.4), ("Medium", 3.4), ("Bold", 5)]
    private static let highlighterSizes: [(String, Double)] = [("Thin", 10), ("Medium", 16), ("Wide", 26)]

    var body: some View {
        // Every colour when there's room; one colour button when the page
        // column is narrow (sidebar open, or Split View).
        ViewThatFits(in: .horizontal) {
            dock(compact: false)
            dock(compact: true)
        }
    }

    private var colors: [InkColor] { store.tool == .highlighter ? InkColor.highlights : InkColor.inks }
    private var currentColor: String { store.tool == .highlighter ? store.highlighter.color : store.pen.color }

    private func setColor(_ hex: String) {
        if store.tool == .highlighter { store.highlighter.color = hex } else { store.pen.color = hex }
    }

    private func dock(compact: Bool) -> some View {
        HStack(spacing: 4) {
            tool(.pen, "pencil.tip")
            tool(.highlighter, "highlighter")
            tool(.strokeEraser, "eraser")
            divider
            if compact {
                colorMenu
            } else {
                ForEach(colors) { swatch($0, current: currentColor, set: setColor) }
            }
            sizeMenu
            divider
            iconButton("arrow.uturn.backward", enabled: store.canUndo) { store.undo() }
            iconButton("arrow.uturn.forward", enabled: store.canRedo) { store.redo() }
            divider
            Button {
                store.fingerDraws.toggle()
            } label: {
                Image(systemName: store.fingerDraws ? "hand.draw.fill" : "hand.draw")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(store.fingerDraws ? Color.velvetAccent : Color.velvetMuted)
            }
            .accessibilityLabel(store.fingerDraws ? "Finger drawing on" : "Finger drawing off")
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.06)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private var colorMenu: some View {
        Menu {
            ForEach(colors) { color in
                Button {
                    setColor(color.hex)
                    if store.tool.isEraser { store.tool = .pen }
                } label: {
                    if color.hex.caseInsensitiveCompare(currentColor) == .orderedSame {
                        Label(color.name, systemImage: "checkmark")
                    } else {
                        Text(color.name)
                    }
                }
            }
        } label: {
            Circle()
                .fill(Color.ink(currentColor))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.velvetAccent, lineWidth: 2))
                .frame(width: 30, height: 34)
        }
        .accessibilityLabel("Colour")
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func tool(_ kind: ToolKind, _ icon: String) -> some View {
        Button {
            store.tool = kind
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 34)
                .foregroundStyle(store.tool == kind ? Color.velvetAccent : Color.velvetMuted)
                .background(store.tool == kind ? Color.velvetAccent.opacity(0.14) : .clear, in: Capsule())
        }
        .accessibilityLabel(kind.title)
    }

    private func swatch(_ color: InkColor, current: String, set: @escaping (String) -> Void) -> some View {
        let selected = color.hex.caseInsensitiveCompare(current) == .orderedSame
        return Button {
            set(color.hex)
            if store.tool.isEraser { store.tool = .pen }
        } label: {
            Circle()
                .fill(Color.ink(color.hex))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.velvetAccent : .clear, lineWidth: 2))
                .frame(width: 30, height: 34)
        }
        .accessibilityLabel(color.name)
    }

    private var sizeMenu: some View {
        let highlighting = store.tool == .highlighter
        let sizes = highlighting ? Self.highlighterSizes : Self.penSizes
        let current = highlighting ? store.highlighter.width : store.pen.width
        return Menu {
            ForEach(sizes, id: \.1) { name, width in
                Button {
                    if highlighting { store.highlighter.width = width } else { store.pen.width = width }
                } label: {
                    if width == current { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            Image(systemName: "lineweight")
                .frame(width: 34, height: 34)
                .foregroundStyle(Color.velvetMuted)
        }
        .accessibilityLabel("Nib size")
    }

    private func iconButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 34, height: 34)
                .foregroundStyle(enabled ? Color.white.opacity(0.85) : Color.velvetMuted.opacity(0.4))
        }
        .disabled(!enabled)
    }
}
