import PDFKit
import SwiftUI

/// Electron's half of the app: Stratus-styled `#030304` Library sidebar on the
/// left, `#000000` canvas on the right, and zero borders or dividers.
struct ElectronRoot: View {
    @Bindable var store: VaultStore

    var body: some View {
        Group {
            if store.root == nil {
                VaultWelcome(store: store)
            } else {
                ElectronMain(store: store)
            }
        }
        .background(Color.evBg)
        .tint(.evAccent)
        .alert("Electron", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.problem ?? "")
        }
    }
}

/// First launch: point Electron at the vault in iCloud Drive.
private struct VaultWelcome: View {
    let store: VaultStore
    @State private var picking = false

    var body: some View {
        ZStack {
            Color.evBg.ignoresSafeArea()
            RadialGradient(
                colors: [Color.evAccent.opacity(0.18), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.evSurfaceSubtle)
                        .frame(width: 78, height: 78)
                    Image(systemName: "atom")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(Color.evAccent)
                }
                Text("Electron")
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.evFg)
                Text("Choose your vault to start. The Mac keeps it in iCloud Drive as **OnyxVault**, so pick that folder and your notes stay in sync both ways.")
                    .font(.system(size: 14.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evDim)
                    .frame(maxWidth: 400)
                Button {
                    picking = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Choose Vault")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Color.evAccent)
                    .padding(.horizontal, 22)
                    .frame(height: 42)
                    .background(Color.evAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(32)
        }
        .overlay(alignment: .topLeading) { AppSwitchButton().padding(20) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.choose(url) }
        }
    }
}

/// A name to type: a new folder, or a rename.
private struct NameAsk: Identifiable {
    enum Kind { case newFolder(parent: String), rename(rel: String) }
    let id = UUID()
    let kind: Kind
    var text: String

    var title: String {
        switch kind {
        case .newFolder: "New Folder"
        case .rename(let rel): VaultNode.kind(of: rel) == .folder ? "Rename Folder" : "Rename"
        }
    }
}

private struct ElectronMain: View {
    @Bindable var store: VaultStore
    @State private var columns: NavigationSplitViewVisibility = .automatic
    /// On a phone, one column at a time: Today or the note first, the Library behind Back.
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var commandBar = false
    @State private var ask: NameAsk?
    @State private var deleting: String?
    @State private var showingTodos = false
    @State private var showingTags = false
    @State private var showingCalendar = false
    @State private var graphFocus: GraphFocus?
    @State private var picking = false
    /// Which Library sections are folded, remembered across launches.
    @AppStorage("libraryFolded") private var folded = "scratch"

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            sidebar
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.evPanel, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { AppSwitchButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New Note", systemImage: "square.and.pencil") { store.newNote(in: folderForNew) }
                            Button("New Folder…", systemImage: "folder.badge.plus") { ask = NameAsk(kind: .newFolder(parent: ""), text: "") }
                            Divider()
                            Button("Today", systemImage: "calendar") { store.showToday() }
                            Button("Today's Note", systemImage: "sun.max") { store.openDaily() }
                            Button("Daily Notes…", systemImage: "calendar") { showingCalendar = true }
                            Button("Graph", systemImage: "point.3.connected.trianglepath.dotted") { graphFocus = GraphFocus(rel: nil) }
                            Divider()
                            Button("Todos", systemImage: "checklist") { showingTodos = true }
                            Button("Tags", systemImage: "number") { showingTags = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { store.newNote(in: folderForNew) } label: { Image(systemName: "square.and.pencil") }
                            .keyboardShortcut("n", modifiers: .command)
                    }
                }
        } detail: {
            NoteDetail(store: store, ask: { ask = $0 }, delete: { deleting = $0 }, graph: { graphFocus = GraphFocus(rel: $0) },
                       search: { commandBar = true }, agent: { AgentLink.shared.showing = true })
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.shown) { _, _ in compactColumn = .detail }
        .onChange(of: store.openTodosTrigger) { _, open in
            if open {
                store.openTodosTrigger = false
                showingTodos = true
            }
        }
        .onChange(of: store.openSearchTrigger) { _, open in
            if open {
                store.openSearchTrigger = false
                commandBar = true
            }
        }
        .sheet(isPresented: $commandBar) { CommandBar(store: store, commands: commands) }
        .sheet(isPresented: Binding(get: { AgentLink.shared.showing }, set: { AgentLink.shared.showing = $0 })) {
            AgentSheet(store: store, link: AgentLink.shared)
        }
        .alert(ask?.title ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
            TextField("Name", text: Binding(get: { ask?.text ?? "" }, set: { ask?.text = $0 }))
            Button("Cancel", role: .cancel) { ask = nil }
            Button("OK") {
                guard let ask else { return }
                switch ask.kind {
                case .newFolder(let parent): store.newFolder(in: parent, named: ask.text)
                case .rename(let rel): store.rename(rel, to: ask.text)
                }
                self.ask = nil
            }
        }
        .confirmationDialog("Move “\(((deleting ?? "") as NSString).lastPathComponent)” to the vault's trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let deleting { store.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("It goes to the .trash folder in the vault, where the desktop can restore it.")
        }
        .sheet(isPresented: $showingTodos) { TodoSheet(store: store) }
        .sheet(isPresented: $showingCalendar) { CalendarSheet(store: store) }
        .fullScreenCover(item: $graphFocus) { focus in GraphScreen(store: store, focus: focus.rel) }
        .background {
            Button("Today") { store.showToday() }.keyboardShortcut("d", modifiers: [.command, .shift]).hidden()
            Button("Graph") { graphFocus = GraphFocus(rel: nil) }.keyboardShortcut("g", modifiers: .command).hidden()
            Button("Command Bar") { commandBar = true }.keyboardShortcut("k", modifiers: .command).hidden()
        }
        .sheet(isPresented: $showingTags) { TagSheet(store: store, start: nil) }
        .sheet(item: Binding(get: { store.tagFilter.map(TagPick.init) }, set: { store.tagFilter = $0?.tag })) { pick in
            TagSheet(store: store, start: pick.tag)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.choose(url) }
        }
    }

    private struct GraphFocus: Identifiable {
        let rel: String?
        var id: String { rel ?? "" }
    }

    private struct TagPick: Identifiable {
        let tag: String
        var id: String { tag }
    }

    /// New notes go next to the open one.
    private var folderForNew: String {
        store.current.map { ($0 as NSString).deletingLastPathComponent } ?? ""
    }

    private var sidebar: some View {
        List {
            Button { commandBar = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.evSubtle)
                    Text("Jump to note...")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.evSubtle)
                        .lineLimit(1)
                    Spacer()
                    StratusTagPill(text: "⌘K", tint: .evSubtle, background: .evSurfacePill, monospaced: true)
                }
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))

            if !store.loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.evAccent)
                    Text("Reading the vault…").font(.footnote).foregroundStyle(Color.evDim)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            LibraryTodayRow(store: store, active: store.current == nil) {
                store.showToday()
                hideSidebarIfNarrow()
            }
            .listRowSeparator(.hidden)

            Section(isExpanded: isOpen("pinned")) {
                LibraryPinned(store: store) { open($0) }
            } header: {
                StratusSectionHeader(title: "Pinned")
            }
            .listRowSeparator(.hidden)

            Section(isExpanded: isOpen("notes")) {
                OutlineGroup(store.tree, children: \.children) { node in
                    row(node, icon: nil)
                }
            } header: {
                HStack {
                    StratusSectionHeader(title: "Notes", trailing: "\(store.notes.count)")
                    Button { store.newNote(in: folderForNew) } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 12)).foregroundStyle(Color.evDim)
                    }
                    Button { ask = NameAsk(kind: .newFolder(parent: ""), text: "") } label: {
                        Image(systemName: "folder.badge.plus").font(.system(size: 12)).foregroundStyle(Color.evDim)
                    }
                }
                .buttonStyle(.borderless)
            }
            .listRowSeparator(.hidden)

            if !store.scribePages.isEmpty {
                Section(isExpanded: isOpen("ink")) {
                    LibraryInk(store: store)
                } header: {
                    StratusSectionHeader(title: "Ink", trailing: "Scribe")
                }
                .listRowSeparator(.hidden)
            }

            Section(isExpanded: isOpen("scratch")) {
                LibraryScratchPad(store: store)
            } header: {
                StratusSectionHeader(title: "Scratch pad")
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.evPanel)
        .refreshable { store.refresh() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryFoot(store: store) { picking = true }
        }
    }

    /// What the command bar can run.
    private var commands: [PaletteCommand] {
        var list = [
            PaletteCommand(name: "Today", icon: "calendar", shortcut: "⇧⌘D") { store.showToday() },
            PaletteCommand(name: "Create new note", icon: "square.and.pencil", shortcut: "⌘N") { store.newNote(in: folderForNew) },
            PaletteCommand(name: "Open today's note", icon: "sun.max") { store.openDaily() },
            PaletteCommand(name: "Open graph view", icon: "point.3.connected.trianglepath.dotted", shortcut: "⌘G") { graphFocus = GraphFocus(rel: nil) },
            PaletteCommand(name: "Daily notes calendar", icon: "calendar.badge.clock") { showingCalendar = true },
            PaletteCommand(name: "Show to-do list", icon: "checklist") { showingTodos = true },
            PaletteCommand(name: "Browse tags", icon: "number") { showingTags = true },
            PaletteCommand(name: "New folder", icon: "folder.badge.plus") { ask = NameAsk(kind: .newFolder(parent: ""), text: "") },
            PaletteCommand(name: "Toggle Library", icon: "sidebar.left") {
                columns = columns == .detailOnly ? .all : .detailOnly
            },
            PaletteCommand(name: "Sync now", icon: "arrow.clockwise") { store.refresh() },
            PaletteCommand(name: "Open another vault", icon: "externaldrive") { picking = true },
        ]
        if let rel = store.current, VaultNode.kind(of: rel) == .note {
            list.insert(contentsOf: [
                PaletteCommand(name: store.mode == .reading ? "Edit this note" : "Read this note", icon: store.mode == .reading ? "pencil" : "book", shortcut: "⌘E") {
                    store.flush()
                    store.mode = store.mode == .reading ? .editing : .reading
                },
                PaletteCommand(name: store.isBookmarked(rel) ? "Unpin this note" : "Pin this note", icon: "star") { store.toggleBookmark(rel) },
                PaletteCommand(name: "Show local graph", icon: "point.3.connected.trianglepath.dotted") { graphFocus = GraphFocus(rel: rel) },
                PaletteCommand(name: "Rename this note", icon: "pencil.line") {
                    ask = NameAsk(kind: .rename(rel: rel), text: ((rel as NSString).lastPathComponent as NSString).deletingPathExtension)
                },
            ], at: 1)
        }
        return list
    }

    private func isOpen(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !folded.split(separator: ",").contains(Substring(key)) },
            set: { open in
                var keys = Set(folded.split(separator: ",").map(String.init))
                if open { keys.remove(key) } else { keys.insert(key) }
                folded = keys.sorted().joined(separator: ",")
            }
        )
    }

    private func open(_ rel: String) {
        store.show(rel)
        hideSidebarIfNarrow()
    }

    private func hideSidebarIfNarrow() {
        if UIDevice.current.orientation.isPortrait || UIScreen.main.bounds.width < 900 { columns = .detailOnly }
    }

    @ViewBuilder
    private func row(_ node: VaultNode, icon: String?) -> some View {
        if node.isFolder {
            Label {
                Text(node.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.evFg)
            } icon: {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Color.evDim)
            }
            .listRowBackground(Color.clear)
            .contextMenu {
                Button("New Note Here", systemImage: "square.and.pencil") { store.newNote(in: node.rel) }
                Button("New Folder…", systemImage: "folder.badge.plus") { ask = NameAsk(kind: .newFolder(parent: node.rel), text: "") }
                Button("Rename…", systemImage: "pencil") { ask = NameAsk(kind: .rename(rel: node.rel), text: node.name) }
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) { deleting = node.rel }
            }
        } else {
            let isSelected = node.rel == store.current
            Button { open(node.rel) } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon ?? Self.icon(node.kind))
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.evAccent : (node.kind == .note ? Color.evSubtle : Color.evSky))
                        .frame(width: 16)
                    Text(node.title)
                        .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.evFg : Color.evDim)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isSelected {
                        Circle().fill(Color.evAccent).frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(isSelected ? Color.evBgSel : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 10))
            .contextMenu {
                if node.kind == .note {
                    Button(store.isBookmarked(node.rel) ? "Unpin" : "Pin", systemImage: store.isBookmarked(node.rel) ? "star.slash" : "star") {
                        store.toggleBookmark(node.rel)
                    }
                }
                Button("Rename…", systemImage: "pencil") { ask = NameAsk(kind: .rename(rel: node.rel), text: node.title) }
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) { deleting = node.rel }
            }
        }
    }

    static func icon(_ kind: VaultNode.Kind) -> String {
        switch kind {
        case .folder: "folder"
        case .note: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .other: "doc"
        }
    }
}

/// The open file, read or edited.
private struct NoteDetail: View {
    @Bindable var store: VaultStore
    let ask: (NameAsk) -> Void
    let delete: (String) -> Void
    let graph: (String) -> Void
    let search: () -> Void
    let agent: () -> Void
    @State private var bridge = EditorBridge()
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var phone: Bool { sizeClass == .compact }
    @AppStorage("contextOpen") private var contextOpen = false
    @State private var phoneContext = false

    var body: some View {
        Group {
            if let rel = store.current {
                switch VaultNode.kind(of: rel) {
                case .note:
                    if store.mode == .editing {
                        MarkdownEditor(store: store, bridge: bridge)
                            .ignoresSafeArea(.container, edges: .bottom)
                            .overlay(alignment: .bottom) { LinkSuggestions(store: store, bridge: bridge) }
                    } else {
                        NoteReader(store: store, rel: rel)
                    }
                case .pdf:
                    if let url = store.url(for: rel) { PDFFileView(url: url).ignoresSafeArea(.container, edges: .bottom) }
                case .image:
                    if let url = store.url(for: rel), let image = UIImage(contentsOfFile: url.path) {
                        ScrollView([.horizontal, .vertical]) { Image(uiImage: image) }
                    }
                default:
                    ContentUnavailableView("Can't show this file", systemImage: "doc", description: Text(rel))
                }
            } else {
                TodayView(store: store)
            }
        }
        .background(Color.evBg)
        .navigationTitle(phone ? "" : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.evBg, for: .navigationBar)
        .inspector(isPresented: phone ? $phoneContext : $contextOpen) {
            ContextPanel(store: store)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .toolbar {
            if !phone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { contextOpen.toggle() } label: { Image(systemName: "sidebar.right") }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .accessibilityLabel("Context")
                }
            }
            ToolbarItemGroup(placement: .topBarLeading) {
                if !phone {
                    Button { store.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(store.back.isEmpty)
                        .keyboardShortcut("[", modifiers: .command)
                    Button { store.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(store.forward.isEmpty)
                        .keyboardShortcut("]", modifiers: .command)
                }
                Button(action: search) { Image(systemName: "magnifyingglass") }
                Button(action: agent) { Image(systemName: "sparkles") }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .accessibilityLabel("Agent")
            }
            if let rel = store.current {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if VaultNode.kind(of: rel) == .note {
                        Button {
                            store.flush()
                            if store.mode == .editing, let line = bridge.topLine { store.anchorLine = line }
                            store.mode = store.mode == .reading ? .editing : .reading
                        } label: {
                            Image(systemName: store.mode == .reading ? "pencil" : "book")
                        }
                        .keyboardShortcut("e", modifiers: .command)
                    }
                    Menu {
                        if phone {
                            Button("Context", systemImage: "sidebar.right") { phoneContext = true }
                            Divider()
                        }
                        if VaultNode.kind(of: rel) == .note {
                            Button(store.isBookmarked(rel) ? "Unpin" : "Pin", systemImage: store.isBookmarked(rel) ? "star.slash" : "star") {
                                store.toggleBookmark(rel)
                            }
                            Button("Local Graph", systemImage: "point.3.connected.trianglepath.dotted") { graph(rel) }
                        }
                        Button("Rename…", systemImage: "pencil") {
                            ask(NameAsk(kind: .rename(rel: rel), text: (((rel as NSString).lastPathComponent) as NSString).deletingPathExtension))
                        }
                        if let url = store.url(for: rel) {
                            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        }
                        Divider()
                        Button("Move to Trash", systemImage: "trash", role: .destructive) { delete(rel) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var title: String {
        guard let rel = store.current else { return "Today" }
        return VaultNode.kind(of: rel) == .note ? ((rel as NSString).lastPathComponent as NSString).deletingPathExtension : (rel as NSString).lastPathComponent
    }
}

private struct PDFFileView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = EV.bg
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// The desktop's Todo checklist, styled on pitch-black `#000000` + `#0B0B0E`.
private struct TodoSheet: View {
    let store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [VaultStore.Todo] = []
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").foregroundStyle(Color.evAccent)
                        TextField("Add a todo…", text: $draft)
                            .foregroundStyle(Color.evFg)
                            .focused($typing)
                            .submitLabel(.done)
                            .onSubmit(add)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.evBgAlt)
                }
                Section {
                    ForEach($items) { $item in
                        HStack(spacing: 12) {
                            Button {
                                item.done.toggle()
                                item.doneOn = item.done ? VaultStore.today() : nil
                                save()
                            } label: {
                                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17))
                                    .foregroundStyle(item.done ? Color.evMint : Color.evSubtle)
                            }
                            .buttonStyle(.plain)
                            Text(item.text)
                                .foregroundStyle(item.done ? Color.evSubtle : Color.evFg)
                                .strikethrough(item.done)
                        }
                        .listRowBackground(Color.evSurfaceSubtle)
                    }
                    .onDelete { items.remove(atOffsets: $0); save() }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1); save() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.evBg)
            .navigationTitle("Todos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.evSheet, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { items = store.loadTodos() }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let firstDone = items.firstIndex(where: \.done) ?? items.count
        items.insert(VaultStore.Todo(text: text, done: false), at: firstDone)
        draft = ""
        typing = true
        save()
    }

    private func save() {
        items = items.filter { !$0.done } + items.filter(\.done)
        store.saveTodos(items)
    }
}

/// Every tag, or the notes with one, styled on pitch-black `#000000` + `#0B0B0E`.
private struct TagSheet: View {
    let store: VaultStore
    let start: String?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(store.tagCounts, id: \.tag) { item in
                NavigationLink(value: item.tag) {
                    HStack {
                        Text("#" + item.tag)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.evTagText)
                        Spacer()
                        StratusTagPill(text: "\(item.count)", tint: .evSubtle, background: .evSurfacePill, monospaced: true)
                    }
                }
                .listRowBackground(Color.evSurfaceSubtle)
            }
            .scrollContentBackground(.hidden)
            .background(Color.evBg)
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.evSheet, for: .navigationBar)
            .navigationDestination(for: String.self) { tag in
                List(store.notes(tagged: tag), id: \.self) { rel in
                    Button {
                        store.show(rel)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.notes[rel]?.name ?? rel).foregroundStyle(Color.evFg)
                            Text((rel as NSString).deletingLastPathComponent)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.evSubtle)
                        }
                    }
                    .listRowBackground(Color.evSurfaceSubtle)
                }
                .scrollContentBackground(.hidden)
                .background(Color.evBg)
                .navigationTitle("#" + tag)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { if let start { path = [start] } }
    }
}
