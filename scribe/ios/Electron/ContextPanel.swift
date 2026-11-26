import SwiftUI

/// The Context panel (the desktop's ContextPanel.tsx), styled after Stratus's
/// `#060608` inspector drawer: borderless filter pills, tonal `#0B0B0E` cards,
/// and zero dividers.
struct ContextPanel: View {
    let store: VaultStore
    @AppStorage("contextTab") private var tab = "linked"

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                StratusFilterPill(title: "Linked", isSelected: tab == "linked") { tab = "linked" }
                StratusFilterPill(title: "Outline", isSelected: tab == "outline") { tab = "outline" }
                StratusFilterPill(title: "Graph", isSelected: tab == "graph") { tab = "graph" }
                StratusFilterPill(title: "Month", isSelected: tab == "calendar") { tab = "calendar" }
            }
            .padding(3)
            .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 14)

            switch tab {
            case "outline":
                ScrollView { ContextOutline(store: store).padding(.horizontal, 14) }
            case "graph":
                if let rel = store.current, VaultNode.kind(of: rel) == .note {
                    GraphScreen(store: store, focus: rel, embedded: true)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding([.horizontal, .bottom], 14)
                } else {
                    hint("Open a note to see the notes around it.")
                }
            case "calendar":
                ScrollView { CalendarSheet(store: store, embedded: true).padding(.horizontal, 14) }
            default:
                ScrollView { ContextLinked(store: store).padding(.horizontal, 14) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.evInspector)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Color.evSubtle).padding(20).frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Notes and Scribe pages that link to the open note.
private struct ContextLinked: View {
    let store: VaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rel = store.current {
                let refs = store.backlinks(of: rel)
                let pages = store.scribeBacklinks(of: rel)
                StratusSectionHeader(title: "Linked from", trailing: "\(refs.count + pages.count)")
                if refs.isEmpty && pages.isEmpty {
                    Text("No notes link here yet.").font(.footnote).foregroundStyle(Color.evSubtle)
                }
                ForEach(refs, id: \.self) { ref in
                    Button { store.show(ref) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.notes[ref]?.name ?? ref)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evFg)
                            if let line = mention(of: rel, in: ref) {
                                Text(line).font(.system(size: 12.5)).foregroundStyle(Color.evDim).lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if !pages.isEmpty {
                    StratusSectionHeader(title: "Ink", trailing: "\(pages.count)")
                        .padding(.top, 8)
                    ForEach(pages) { page in
                        Button { store.openScribe?(ScribeLink(pageId: page.id)) } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.evInk).frame(width: 8, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.evFg)
                                    Text("\(page.notebook) · \(page.section)")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(Color.evSubtle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .leading) {
                                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                                    .fill(Color.evInk)
                                    .frame(width: 2.5)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Open a note to see what links to it.").font(.footnote).foregroundStyle(Color.evSubtle)
            }
        }
        .padding(.bottom, 20)
    }

    /// The line in `ref` that links to `rel`, as it reads.
    private func mention(of rel: String, in ref: String) -> String? {
        let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let line = store.texts[ref]?.components(separatedBy: "\n").first { $0.lowercased().contains("[[" + name) || $0.lowercased().contains("[[" + VaultStore.relKey(rel)) }
        return line.map { CommandBar.plain($0) }
    }
}

/// The open note's headings.
private struct ContextOutline: View {
    let store: VaultStore

    var body: some View {
        let headings = store.current == nil ? [] : NoteParse.headings(store.text)
        VStack(alignment: .leading, spacing: 4) {
            if headings.isEmpty {
                Text(store.current == nil ? "Open a note to see its outline." : "No headings").font(.footnote).foregroundStyle(Color.evSubtle)
            }
            ForEach(Array(headings.enumerated()), id: \.offset) { _, h in
                Button {
                    store.mode = .reading
                    store.headingTarget = Inline.plain(h.text)
                } label: {
                    Text(Inline.plain(h.text))
                        .font(.system(size: h.level <= 2 ? 14 : 13, weight: h.level == 1 ? .semibold : .regular))
                        .foregroundStyle(h.level <= 2 ? Color.evFg : Color.evDim)
                        .padding(.leading, CGFloat(h.level - 1) * 12)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 20)
    }
}
