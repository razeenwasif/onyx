import SwiftUI

/// The Context panel (the desktop's ContextPanel.tsx), as an inspector on
/// the right: one panel with four views of the open note.
///
///   Linked    notes and Scribe pages that link here
///   Outline   the note's headings; picking one scrolls there
///   Graph     the notes around this one
///   Month     the month of daily notes
struct ContextPanel: View {
    let store: VaultStore
    @AppStorage("contextTab") private var tab = "linked"

    var body: some View {
        VStack(spacing: 14) {
            Picker("View", selection: $tab) {
                Text("Linked").tag("linked")
                Text("Outline").tag("outline")
                Text("Graph").tag("graph")
                Text("Month").tag("calendar")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 14)

            switch tab {
            case "outline":
                ScrollView { ContextOutline(store: store).padding(.horizontal, 14) }
            case "graph":
                if let rel = store.current, VaultNode.kind(of: rel) == .note {
                    GraphScreen(store: store, focus: rel, embedded: true)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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
        .background(Color.evPanel)
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
                HStack {
                    Text("Linked from").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.evDim)
                    Spacer()
                    Text("\(refs.count + pages.count)").font(.footnote).foregroundStyle(Color.evSubtle)
                }
                if refs.isEmpty && pages.isEmpty {
                    Text("No notes link here yet.").font(.footnote).foregroundStyle(Color.evSubtle)
                }
                ForEach(refs, id: \.self) { ref in
                    Button { store.show(ref) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.notes[ref]?.name ?? ref).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.evFg)
                            if let line = mention(of: rel, in: ref) {
                                Text(line).font(.system(size: 13)).foregroundStyle(Color.evDim).lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                if !pages.isEmpty {
                    Text("Ink").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.evDim).padding(.top, 6)
                    ForEach(pages) { page in
                        Button { store.openScribe?(ScribeLink(pageId: page.id)) } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.evInk).frame(width: 9, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.evFg)
                                    Text("\(page.notebook) · \(page.section)").font(.system(size: 12)).foregroundStyle(Color.evSubtle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.evInk.opacity(0.28)))
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
                        .font(.system(size: h.level <= 2 ? 15 : 14, weight: h.level == 1 ? .semibold : .regular))
                        .foregroundStyle(h.level <= 2 ? Color.evFg : Color.evDim)
                        .padding(.leading, CGFloat(h.level - 1) * 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 20)
    }
}
