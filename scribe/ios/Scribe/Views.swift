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
        .overlay(alignment: .topLeading) { AppSwitchButton().padding(20) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.choose(url) }
        }
    }
}

/// The library, a folder's notebooks, then a notebook's pages, as one stack
/// with back buttons, the way Goodnotes-style apps move around.
struct LibraryView: View {
    @Bindable var store: Store
    @State private var prompt: NamePrompt?
    @State private var query = ""
    @State private var results: [PageInfo] = []
    /// The query the results are for, so "no results" waits for the search.
    @State private var searched = ""
    @State private var showingDeleted = false

    /// One file picker for both jobs (SwiftUI allows one per view). The
    /// job is kept apart from whether the picker shows: the picker closes
    /// before it hands over the files.
    private enum Picking { case library, pdfs(NotebookInfo?) }
    @State private var picking: Picking = .library
    @State private var picker = false

    static let style = PageGrid.Style(
        ground: .velvetBackdrop, text: Color(uiColor: Velvet.text), muted: .velvetMuted,
        accent: .velvetAccent, control: Color(uiColor: Velvet.control)
    )
    static let deleteNote = "It stays in Recently Deleted for 30 days."

    private func pick(_ job: Picking) {
        picking = job
        picker = true
    }

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
            delete: { store.delete($0) },
            folders: store.notebooks,
            move: { store.move($0, to: $1) }
        )
    }

    var body: some View {
        NavigationStack(path: $store.route) {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    LibraryHome(folders: store.notebooks, recents: store.recents, root: store.rootPath,
                                style: Self.style, actions: actions, deleteNote: Self.deleteNote)
                } else {
                    SearchResults(store: store, results: results, query: query, finished: searched == query)
                }
            }
                .navigationTitle("Library")
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes and handwriting")
                .task(id: query) {
                    // A short pause so typing doesn't search every letter.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    results = store.search(query)
                    searched = query
                }
                .safeAreaInset(edge: .bottom) {
                    if store.downloading > 0 {
                        Label("Downloading \(store.downloading) from iCloud…", systemImage: "icloud.and.arrow.down")
                            .font(.footnote)
                            .foregroundStyle(Color.velvetMuted)
                            .padding(10)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { AppSwitchButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New Folder…", systemImage: "folder.badge.plus") { prompt = NamePrompt(kind: .newFolder) }
                            Button("Import PDF or Goodnotes…", systemImage: "doc.badge.plus") { pick(.pdfs(nil)) }
                            Divider()
                            Button("Recently Deleted", systemImage: "trash") { showingDeleted = true }
                            Button("Sync Now", systemImage: "arrow.clockwise") { store.refreshInBackground() }
                            Button("Change Library Location…", systemImage: "externaldrive") { pick(.library) }
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
                                        Menu {
                                            Button("New Notebook…", systemImage: "book.closed") { prompt = NamePrompt(kind: .newNotebook(folder)) }
                                            Button("Import PDF or Goodnotes…", systemImage: "doc.badge.plus") { pick(.pdfs(folder)) }
                                        } label: {
                                            Image(systemName: "plus")
                                        }
                                        .accessibilityLabel("New")
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
        .fileImporter(
            isPresented: $picker,
            allowedContentTypes: { if case .pdfs = picking { [.pdf] } else { [.folder] } }(),
            allowsMultipleSelection: { if case .pdfs = picking { true } else { false } }()
        ) { result in
            switch result {
            case .failure(let error):
                store.problem = error.localizedDescription
                return
            case .success(let urls) where urls.isEmpty:
                return
            case .success:
                break
            }
            guard case .success(let urls) = result else { return }
            switch picking {
            case .library:
                if let url = urls.first {
                    store.forgetFolder()
                    store.choose(url)
                }
            case .pdfs(let folder):
                store.importPDFs(urls, into: folder)
            }
        }
        .sheet(isPresented: $showingDeleted) { RecentlyDeletedView(store: store) }
        .overlay {
            if let progress = store.importing {
                ImportPopup(progress: progress, accent: .velvetAccent, text: Color(uiColor: Velvet.text),
                            muted: .velvetMuted, card: Color(uiColor: Velvet.sidebar)) {
                    store.importing = nil
                }
            }
        }
    }
}

struct WritingView: View {
    @Bindable var store: Store
    @Binding var prompt: NamePrompt?
    /// A link was just copied: say so for a moment.
    @State private var linkCopied = false
    /// Copied writing is on the clipboard (checked without reading it, so
    /// iPadOS doesn't ask about pasting).
    @State private var canPaste = false

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
                Group {
                    if store.continuous {
                        NotebookCanvasView(store: store, layoutVersion: store.layoutVersion, scrollTarget: store.scrollTarget,
                                           pagePath: store.pagePath, fingerDraws: store.fingerDraws, reveal: store.revealVersion)
                    } else {
                        PageCanvas(store: store, pageID: store.doc?.id, fingerDraws: store.fingerDraws, reveal: store.revealVersion)
                    }
                }
                    .ignoresSafeArea(edges: .bottom)
                    // Writing near the screen's edges comes before the
                    // system's edge swipes.
                    .defersSystemGestures(on: .all)
                VStack(spacing: 10) {
                    if store.hasSelection {
                        HStack(spacing: 18) {
                            Button("Copy", systemImage: "doc.on.doc") {
                                store.copySelection()
                                canPaste = true
                            }
                            Button("Cut", systemImage: "scissors") {
                                store.cutSelection()
                                canPaste = true
                            }
                            Button("Link", systemImage: "link") {
                                store.copyLink()
                                linkCopied = true
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSelection() }
                            Button("Done") { store.clearSelection() }
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    } else if store.tool == .select, canPaste {
                        // Copied writing, ready to drop in the middle of the screen.
                        Button("Paste", systemImage: "doc.on.clipboard") { store.paste() }
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    ToolDock(store: store)
                }
                .padding(.bottom, 14)
                .animation(.spring(duration: 0.25), value: store.hasSelection)
            } else {
                ContentUnavailableView("No Page Open", systemImage: "pencil.and.scribble", description: Text("Open a notebook from the library."))
            }
        }
        .navigationTitle(store.showingGrid ? (store.section?.name ?? "All Pages") : (store.doc?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.tabs.count > 1 { NotebookTabs(store: store) }
        }
        .onChange(of: store.tool) { _, tool in
            if tool != .select { store.clearSelection() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(selection: Binding(get: { store.paperKind }, set: { store.setPaper(kind: $0) })) {
                        Text("Ruled").tag("ruled")
                        Text("Grid").tag("grid")
                        Text("Dots").tag("dots")
                        Text("Blank").tag("blank")
                    } label: {
                        Label("Paper", systemImage: "doc.plaintext")
                    }
                    .pickerStyle(.menu)
                    .disabled(store.pageIsPDF)
                    Picker(selection: Binding(get: { store.paperSpacing }, set: { store.setPaper(spacing: $0) })) {
                        Text("Narrow").tag(24.0)
                        Text("Medium").tag(32.0)
                        Text("Wide").tag(40.0)
                    } label: {
                        Label("Line Spacing", systemImage: "line.3.horizontal")
                    }
                    .pickerStyle(.menu)
                    .disabled(store.pageIsPDF || store.paperKind == "blank")
                    Divider()
                    Button("Copy Link to Page", systemImage: "link") {
                        store.copyLink(wholePage: true)
                        linkCopied = true
                    }
                    .disabled(store.doc == nil)
                    Divider()
                    Toggle(isOn: $store.continuous) {
                        Label("Scroll Through Pages", systemImage: "arrow.up.and.down.text.horizontal")
                    }
                    Toggle(isOn: $store.fingerDraws) {
                        Label("Draw with Finger", systemImage: "hand.draw")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Page options")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !store.showingGrid { LinkedNotesButton(store: store) }
            }
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
        .onAppear { canPaste = store.canPaste }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in canPaste = store.canPaste }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in canPaste = store.canPaste }
        .background {
            // With a keyboard: copy, cut and paste writing, as on the Mac.
            Group {
                Button("Copy") { store.copySelection(); canPaste = true }.keyboardShortcut("c")
                Button("Cut") { store.cutSelection(); canPaste = true }.keyboardShortcut("x")
                Button("Paste") { store.paste() }.keyboardShortcut("v")
            }
            .hidden()
            // Only with the lasso, so typing a title still copies and pastes text.
            .disabled(store.doc == nil || store.tool != .select)
        }
        .overlay(alignment: .top) {
            if linkCopied {
                Label("Link copied. Paste it into a note in Electron.", systemImage: "link")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(1.8))
                        linkCopied = false
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: linkCopied)
    }
}

/// Pages matching a search, newest first, with where they live.
struct SearchResults: View {
    let store: Store
    let results: [PageInfo]
    let query: String
    var finished = true

    var body: some View {
        List(results) { page in
            Button { store.openRecent(page) } label: {
                HStack(spacing: 14) {
                    PageThumbnail(page: page, root: store.rootPath).frame(width: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(page.title).font(.body.weight(.medium)).foregroundStyle(Color(uiColor: Velvet.text))
                        Text(store.notebook(at: page.sectionPath)?.name ?? "")
                            .font(.caption).foregroundStyle(Color.velvetMuted)
                        if !page.snippet.isEmpty {
                            Text(page.snippet).font(.callout).foregroundStyle(Color.velvetMuted).lineLimit(2)
                        }
                    }
                }
            }
            .listRowBackground(Color.velvetBackdrop)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.velvetBackdrop)
        .overlay {
            if results.isEmpty && finished {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

/// What was deleted on this iPad in the last 30 days, to put back.
struct RecentlyDeletedView: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Store.DeletedItem] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.body.weight(.medium))
                            Text("\(item.kind) · \(item.place.isEmpty ? "Library" : item.place) · \(item.deleted, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(Color.velvetMuted)
                        }
                        Spacer()
                        Button("Restore") {
                            store.restore(item)
                            items = store.recentlyDeleted()
                        }
                        .buttonStyle(.bordered)
                    }
                    .swipeActions {
                        Button("Delete Now", role: .destructive) {
                            store.deleteForever(item)
                            items = store.recentlyDeleted()
                        }
                    }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Nothing Deleted", systemImage: "trash", description: Text("Pages, notebooks and folders you delete here stay for 30 days."))
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { items = store.recentlyDeleted() }
        }
        .preferredColorScheme(.dark)
    }
}

/// The notebooks you have open, one tap apart.
struct NotebookTabs: View {
    let store: Store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.tabs, id: \.self) { path in
                    if let notebook = store.notebook(at: path) {
                        tab(notebook, current: path == store.pageSectionPath)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color.velvetBackdrop)
    }

    private func tab(_ notebook: SectionInfo, current: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(CoverColor.color(notebook.color)).frame(width: 7, height: 7)
            Text(notebook.name).font(.footnote.weight(current ? .semibold : .regular)).lineLimit(1)
            if current {
                Button {
                    store.closeTab(notebook.path)
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(notebook.name)")
            }
        }
        .foregroundStyle(current ? Color(uiColor: Velvet.text) : Color.velvetMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(current ? Color(uiColor: Velvet.control) : Color(uiColor: Velvet.sidebar), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { if !current { store.openNotebook(notebook) } }
        .contextMenu {
            Button("Close Tab", systemImage: "xmark") { store.closeTab(notebook.path) }
        }
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
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
        // With writing selected, a colour recolours it.
        if store.hasSelection { return store.recolorSelection(hex) }
        if store.tool == .highlighter { store.highlighter.color = hex } else { store.pen.color = hex }
    }

    private func dock(compact: Bool) -> some View {
        HStack(spacing: 4) {
            tool(.pen, "pencil.tip")
            tool(.highlighter, "highlighter")
            tool(.strokeEraser, "eraser")
            tool(.select, "lasso")
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
                    if store.tool.isEraser || (store.tool == .select && !store.hasSelection) { store.tool = .pen }
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
            if store.tool.isEraser || (store.tool == .select && !store.hasSelection) { store.tool = .pen }
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
