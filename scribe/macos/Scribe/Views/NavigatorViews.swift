import SwiftUI

/// Notebooks and their sections, with search at the top.
struct Sidebar: View {
    @Bindable var app: AppModel
    /// In the window, as opposed to the narrow-window popover: shows the
    /// panel controls beside the traffic lights.
    var docked = true

    @State private var collapsed: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if docked {
                // The traffic lights sit at the left of this row.
                HStack(spacing: 2) {
                    Color.clear.contentShape(Rectangle()).windowDraggable()
                    PanelToggle(symbol: "sidebar.squares.left", on: !app.pageListCollapsed,
                                help: app.pageListCollapsed ? "Show pages (⌃⌘P)" : "Hide pages (⌃⌘P)") {
                        app.pageListCollapsed.toggle()
                    }
                    PanelToggle(symbol: "sidebar.left", on: true, help: "Collapse sidebar (⌃⌘S)") {
                        app.sidebarCollapsed = true
                    }
                }
                .frame(height: 28)
                .padding(.trailing, -4)
            }

            searchField

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "Notebooks").padding(.horizontal, 10).padding(.bottom, 6)
                    ForEach(app.notebooks) { nb in
                        notebookRow(nb)
                        if !collapsed.contains(nb.id) {
                            VStack(spacing: 2) {
                                ForEach(nb.sections) { sectionRow(nb, $0) }
                            }
                            .padding(.leading, 22)
                            .padding(.bottom, 4)
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            Button {
                app.prompt = PromptInfo(title: "New Notebook", label: "Notebook name", text: "My Notebook", confirm: "Create") {
                    app.newNotebook(named: $0)
                }
            } label: {
                Label("New notebook", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(height: 44))

            Text("Saved as plain folders in\n\(storageLabel)")
                .font(.system(size: 12))
                .foregroundStyle(Velvet.faint)
                .lineSpacing(2)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .velvetPanel(Velvet.sidebar)
        .onChange(of: app.focusSearch) { _, now in
            if now {
                searchFocused = true
                app.focusSearch = false
            }
        }
    }

    private var storageLabel: String {
        let parts = URL(fileURLWithPath: app.root).pathComponents.suffix(2)
        return parts.joined(separator: " › ")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Velvet.muted)
            TextField("Search everything", text: $app.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .accessibilityLabel("Search all notebooks")
            if app.searchText.isEmpty {
                Text("⌘F").font(.system(size: 12, weight: .medium)).foregroundStyle(Velvet.faint)
            } else {
                Button { app.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Velvet.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(Velvet.field))
        .overlay(Capsule().strokeBorder(searchFocused ? Velvet.accentRing : Velvet.sheen, lineWidth: 1))
    }

    private func notebookRow(_ nb: NotebookInfo) -> some View {
        let open = !collapsed.contains(nb.id)
        return Button {
            withAnimation(.spring(duration: 0.3)) {
                if open { collapsed.insert(nb.id) } else { collapsed.remove(nb.id) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Velvet.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(InkPaint.swatch(nb.color))
                    .frame(width: 10, height: 10)
                Text(nb.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(open ? Velvet.text : Velvet.secondary)
            .padding(.horizontal, 10)
            .frame(height: 38)
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu { notebookMenu(nb) }
    }

    private func sectionRow(_ nb: NotebookInfo, _ sec: SectionInfo) -> some View {
        let selected = app.selectedSectionPath == sec.path && app.searchResults == nil
        return Button { app.selectSection(sec.path) } label: {
            HStack(spacing: 10) {
                Circle().fill(selected ? Velvet.accent : InkPaint.swatch(sec.color)).frame(width: 6, height: 6)
                Text(sec.name).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(sec.pageCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Velvet.accentText.opacity(0.75) : Velvet.faint)
            }
            .font(.system(size: 14, weight: selected ? .bold : .medium))
            .foregroundStyle(selected ? Velvet.accentText : Velvet.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .contextMenu { sectionMenu(nb, sec) }
    }

    @ViewBuilder private func notebookMenu(_ nb: NotebookInfo) -> some View {
        Button("New Section…") {
            app.prompt = PromptInfo(title: "New Section", label: "Section name", text: "New Section", confirm: "Create") {
                app.newSection(in: nb, named: $0)
            }
        }
        Button("Rename…") {
            app.prompt = PromptInfo(title: "Rename Notebook", label: "Notebook name", text: nb.name, confirm: "Rename") {
                app.rename(notebook: nb, to: $0)
            }
        }
        Button("Show in Finder") { app.revealInFinder(nb.path) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            app.confirm = ConfirmInfo(
                title: "Move “\(nb.name)” to the Trash?",
                message: "The notebook folder and everything in it go to the Trash, where you can still recover them.",
                action: "Move to Trash"
            ) { app.trash(notebook: nb) }
        }
    }

    @ViewBuilder private func sectionMenu(_ nb: NotebookInfo, _ sec: SectionInfo) -> some View {
        Button("New Page") {
            app.selectSection(sec.path, openFirst: false)
            app.newPage()
        }
        Button("New Section…") {
            app.prompt = PromptInfo(title: "New Section", label: "Section name", text: "New Section", confirm: "Create") {
                app.newSection(in: nb, named: $0)
            }
        }
        Button("Rename…") {
            app.prompt = PromptInfo(title: "Rename Section", label: "Section name", text: sec.name, confirm: "Rename") {
                app.rename(section: sec, to: $0)
            }
        }
        Button("Show in Finder") { app.revealInFinder(sec.path) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            app.confirm = ConfirmInfo(
                title: "Move “\(sec.name)” to the Trash?",
                message: "The section folder and its pages go to the Trash, where you can still recover them.",
                action: "Move to Trash"
            ) { app.trash(section: sec) }
        }
    }
}

/// Pages of the selected section, or search results across every notebook.
struct PageList: View {
    @Bindable var app: AppModel
    var width: CGFloat = 300
    var collapsible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)

            List {
                if let results = app.searchResults {
                    ForEach(results) { card($0, showSection: true) }
                } else {
                    ForEach(app.pages) { card($0, showSection: false) }
                        .onMove { app.movePages(from: $0, to: $1) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .environment(\.defaultMinListRowHeight, 1)
            .overlay { emptyState }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .velvetPanel(Velvet.list, light: 0.03)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .velvetTitle(24, weight: 560)
                    .foregroundStyle(Velvet.text)
                    .lineLimit(1)
                Text(countText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Velvet.faint)
            }
            Spacer(minLength: 0)
            if collapsible {
                PanelToggle(symbol: "chevron.left.2", on: false, help: "Hide pages (⌃⌘P)") {
                    app.pageListCollapsed = true
                }
            }
            Button { app.newPage() } label: { Image(systemName: "plus") }
                .buttonStyle(RoundButtonStyle(fill: Velvet.accentSoft, foreground: Velvet.accent))
                .overlay(Circle().strokeBorder(Velvet.accentRing, lineWidth: 1))
                .help("New page (⌘N)")
                .accessibilityLabel("New page")
        }
    }

    private var titleText: String {
        if app.searchResults != nil { return "Search" }
        return app.section(at: app.selectedSectionPath)?.name ?? "Pages"
    }

    private var countText: String {
        let n = app.searchResults?.count ?? app.pages.count
        if app.searchResults != nil { return n == 1 ? "1 match" : "\(n) matches" }
        return n == 1 ? "1 page" : "\(n) pages"
    }

    @ViewBuilder private var emptyState: some View {
        if app.searchResults?.isEmpty == true {
            Text("Nothing matches “\(app.searchText)”")
                .font(.system(size: 13))
                .foregroundStyle(Velvet.muted)
                .multilineTextAlignment(.center)
                .padding(24)
        } else if app.searchResults == nil, app.pages.isEmpty, app.selectedSectionPath != nil {
            VStack(spacing: 12) {
                Text("No pages yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(Velvet.muted)
                Button("New page") { app.newPage() }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }

    private func card(_ p: PageInfo, showSection: Bool) -> some View {
        PageCard(app: app, info: p, showSection: showSection, selected: app.selectedPagePath == p.path)
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .contextMenu { pageMenu(p) }
    }

    @ViewBuilder private func pageMenu(_ p: PageInfo) -> some View {
        Button("Rename…") {
            app.prompt = PromptInfo(title: "Rename Page", label: "Page title", text: p.title, confirm: "Rename") {
                app.renamePage(p, to: $0)
            }
        }
        Menu("Move To") {
            ForEach(app.notebooks) { nb in
                Section(nb.name) {
                    ForEach(nb.sections) { sec in
                        Button(sec.name) { app.movePage(p, to: sec) }
                            .disabled(sec.path == p.sectionPath)
                    }
                }
            }
        }
        Button("Show in Finder") { app.revealInFinder(p.path) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            app.confirm = ConfirmInfo(
                title: "Move “\(p.title)” to the Trash?",
                message: "You can still recover it from the Trash.",
                action: "Move to Trash"
            ) { app.trashPage(p) }
        }
    }
}

/// A page in the list: title, the start of its text, and when it changed.
/// A tap rather than a button, so the row can still be dragged to reorder.
struct PageCard: View {
    let app: AppModel
    let info: PageInfo
    let showSection: Bool
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Velvet.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            Text(info.title.isEmpty ? "Untitled page" : info.title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Velvet.text)
                .lineLimit(1)
            if !info.snippet.isEmpty {
                Text(info.snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color(hex: 0xB3AAB8) : Velvet.muted)
                    .lineLimit(2)
                    .lineSpacing(1.5)
            }
            HStack(spacing: 6) {
                Text(DateLabel.short(info.modifiedDate))
                    .foregroundStyle(selected ? Velvet.accent : Velvet.faint)
                if showSection {
                    Text(app.sectionName(for: info.sectionPath)).foregroundStyle(Velvet.faint).lineLimit(1)
                }
            }
            .font(.system(size: 12, weight: selected ? .bold : .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(selected ? Velvet.raised : Color.white.opacity(hover ? 0.035 : 0)))
        .overlay { if selected { shape.strokeBorder(Velvet.accentRing, lineWidth: 1) } }
        .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 14, y: 10)
        .contentShape(shape)
        .onTapGesture { app.openPage(info.path) }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { app.openPage(info.path) }
    }
}

/// The sidebar collapsed to icons: by choice, or because the window is
/// too narrow for the full panels.
struct Rail: View {
    @Bindable var app: AppModel
    /// The window is too narrow to expand into; the library opens in a popover.
    var narrow: Bool

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: 28).contentShape(Rectangle()).windowDraggable()
            Button {
                if narrow { app.showLibrary.toggle() } else { app.sidebarCollapsed = false }
            } label: { Image(systemName: narrow ? "books.vertical" : "sidebar.left") }
                .buttonStyle(RoundButtonStyle(size: 44, fill: Velvet.accentSoft, foreground: Velvet.accent))
                .help(narrow ? "Notebooks and pages" : "Expand sidebar (⌃⌘S)")
                .accessibilityLabel(narrow ? "Notebooks and pages" : "Expand sidebar")
                .popover(isPresented: $app.showLibrary, arrowEdge: .trailing) { LibraryPopover(app: app) }
            Button {
                if narrow { app.showLibrary = true } else { app.sidebarCollapsed = false }
                app.focusSearch = true
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(RoundButtonStyle(size: 44, fill: .clear))
                .help("Search (⌘F)")
                .accessibilityLabel("Search")
            if !narrow {
                Button { app.pageListCollapsed.toggle() } label: { Image(systemName: "sidebar.squares.left") }
                    .buttonStyle(RoundButtonStyle(size: 44, fill: app.pageListCollapsed ? .clear : Color.white.opacity(0.06)))
                    .help(app.pageListCollapsed ? "Show pages (⌃⌘P)" : "Hide pages (⌃⌘P)")
                    .accessibilityLabel(app.pageListCollapsed ? "Show pages" : "Hide pages")
            }
            Spacer()
            Button { app.newPage() } label: { Image(systemName: "plus") }
                .buttonStyle(RoundButtonStyle(size: 44, fill: Velvet.control))
                .help("New page (⌘N)")
                .accessibilityLabel("New page")
        }
        .padding(.vertical, 14)
        .frame(width: 68)
        .frame(maxHeight: .infinity)
        .velvetPanel(Velvet.sidebar)
    }
}

/// A small icon button for showing and hiding panels.
struct PanelToggle: View {
    var symbol: String
    var on: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(RoundButtonStyle(size: 30, fill: on ? Color.white.opacity(0.06) : .clear))
            .help(help)
            .accessibilityLabel(help)
    }
}

/// Notebooks and pages in a popover, from the rail.
struct LibraryPopover: View {
    @Bindable var app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Sidebar(app: app, docked: false)
            PageList(app: app, width: 290, collapsible: false)
        }
        .padding(8)
        .frame(height: 620)
        .background(Velvet.ground)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
        .onChange(of: app.selectedPagePath) { app.showLibrary = false }
    }
}

/// A one-field prompt.
struct PromptSheet: View {
    let info: PromptInfo
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(info.title).velvetTitle(22)
            TextField(info.label, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Capsule().fill(Velvet.field))
                .overlay(Capsule().strokeBorder(Velvet.accentRing, lineWidth: 1))
                .frame(width: 320)
                .onSubmit(commit)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(info.confirm, action: commit)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(26)
        .velvetSheet()
        .onAppear { text = info.text }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        dismiss()
        info.action(t)
    }
}

struct ConfirmInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var action: String
    var perform: () -> Void
}

extension View {
    /// Velvet styling for sheets.
    func velvetSheet() -> some View {
        self
            .fontDesign(.rounded)
            .foregroundStyle(Velvet.text)
            .presentationBackground(Velvet.raised)
            .environment(\.colorScheme, .dark)
            .tint(Velvet.accent)
    }
}
