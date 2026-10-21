import SwiftUI
import UIKit

/// A note drawn natively, block by block, in the desktop's Velvet look.
struct NoteReader: View {
    let store: VaultStore
    let rel: String
    @State private var nodes: [MDNode] = []
    @State private var parsedFor = ""
    /// The block at the top of the screen.
    @State private var topID: Int?

    static let bodySize: CGFloat = 17

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(((rel as NSString).lastPathComponent as NSString).deletingPathExtension)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color(uiColor: EV.heading))
                        .padding(.bottom, 10)
                        .textSelection(.enabled)
                    Properties(store: store, source: store.text)
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(nodes) { node in
                            BlockView(block: node.block, line: node.line, store: store, depth: 0)
                                .id(node.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.top, 6)
                    Backlinks(store: store, rel: rel)
                        .padding(.top, 40)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $topID, anchor: .top)
            .background(Color.evBg)
            .onAppear {
                reparse()
                // Back from the editor: start where it was, once laid out.
                if store.anchorLine > 0, store.headingTarget == nil,
                   let id = nodes.last(where: { $0.line <= store.anchorLine })?.id {
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .onChange(of: topID) { _, id in
                if let id, nodes.indices.contains(id) { store.anchorLine = nodes[id].line }
            }
            .onChange(of: store.text) { _, _ in reparse() }
            .onChange(of: store.headingTarget) { _, _ in scrollToHeading(proxy) }
            .task(id: parsedFor) { scrollToHeading(proxy) }
        }
        .environment(\.openURL, OpenURLAction { url in open(url) })
    }

    private func reparse() {
        guard parsedFor != store.text || nodes.isEmpty else { return }
        nodes = Markdown.parse(store.text)
        parsedFor = store.text
    }

    private func scrollToHeading(_ proxy: ScrollViewProxy) {
        guard let target = store.headingTarget else { return }
        let want = Self.slug(target)
        if let hit = nodes.first(where: { if case .heading(_, let t) = $0.block { Self.slug(Inline.plain(t)) == want } else { false } }) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(hit.id, anchor: .top) }
        }
        store.headingTarget = nil
    }

    static func slug(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func open(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "electron" else { return .systemAction }
        let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        switch url.host {
        case "note": store.follow(t)
        case "tag": store.tagFilter = t
        default: break
        }
        return .handled
    }
}

/// The frontmatter as a small properties table; tags become chips.
private struct Properties: View {
    let store: VaultStore
    let source: String

    var body: some View {
        let props = NoteParse.properties(source)
        if !props.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(props.enumerated()), id: \.offset) { _, prop in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(prop.key)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.evSubtle)
                            .frame(width: 96, alignment: .leading)
                        if ["tags", "tag"].contains(prop.key.lowercased()) {
                            FlowTags(tags: prop.values) { store.tagFilter = $0 }
                        } else {
                            Text(prop.values.joined(separator: ", "))
                                .font(.system(size: 14))
                                .foregroundStyle(Color.evDim)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 10)
        }
    }
}

struct FlowTags: View {
    let tags: [String]
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button { tap(tag) } label: {
                    Text("#" + tag)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.evTagText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.evTag.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// One block, drawing its children the same way.
struct BlockView: View {
    let block: MDBlock
    let line: Int
    let store: VaultStore
    let depth: Int

    private var size: CGFloat { NoteReader.bodySize }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(source: text, size: Self.headingSize(level), weight: level <= 3 ? .bold : .semibold,
                       color: level == 6 ? Color.evDim : Color(uiColor: EV.heading))
                .padding(.top, level <= 2 ? 14 : 6)

        case .paragraph(let text):
            InlineText(source: text, size: size)

        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ListRow(item: item, store: store, depth: depth)
                }
            }

        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.evAccent.opacity(0.5)).frame(width: 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                        BlockView(block: b, line: line, store: store, depth: depth + 1)
                    }
                }
                .opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .callout(let type, let title, let folded, let blocks):
            CalloutView(type: type, title: title, folded: folded, blocks: blocks, line: line, store: store, depth: depth)

        case .code(let lang, let text):
            CodeBlock(lang: lang, code: text)

        case .math(let latex):
            MathBlock(latex: latex)

        case .table(let header, let align, let rows):
            TableBlock(header: header, align: align, rows: rows)

        case .rule:
            Rectangle().fill(Color.evBorder).frame(height: 1).padding(.vertical, 8)

        case .image(let alt, let source):
            NoteImage(source: source, alt: alt, store: store)

        case .embed(let target):
            EmbedView(target: target, store: store, depth: depth)
        }
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 27
        case 2: 23
        case 3: 20
        case 4: 18
        default: 17
        }
    }
}

/// Inline Markdown as one wrapping Text, with any images below it.
struct InlineText: View {
    let source: String
    var size: CGFloat = NoteReader.bodySize
    var weight: Font.Weight = .regular
    var color: Color = .evFg

    var body: some View {
        let pieces = Inline.parse(source)
        let images = pieces.compactMap { p -> (String, String)? in
            if case .image(let alt, let src) = p { return (alt, src) } else { return nil }
        }
        VStack(alignment: .leading, spacing: 8) {
            if pieces.contains(where: { if case .image = $0 { false } else { true } }) {
                Text.pieces(pieces.filter { if case .image = $0 { false } else { true } }, size: size)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                    .lineSpacing(size * 0.28)
                    .tint(Color(uiColor: EV.wikilink))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                NoteImageLoader(source: img.1, alt: img.0)
            }
        }
    }
}

private struct ListRow: View {
    let item: MDListItem
    let store: VaultStore
    let depth: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let done = item.task {
                    Button {
                        store.toggleTask(line: item.line)
                    } label: {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 17))
                            .foregroundStyle(done ? Color.evAccent : Color.evDim)
                    }
                    .buttonStyle(.plain)
                } else if item.ordered {
                    Text(item.marker).font(.system(size: NoteReader.bodySize).monospacedDigit()).foregroundStyle(Color.evDim)
                } else {
                    Text(depth % 2 == 0 ? "•" : "◦").font(.system(size: NoteReader.bodySize, weight: .bold)).foregroundStyle(Color.evAccent)
                }
            }
            .frame(minWidth: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                InlineText(source: item.text, color: item.task == true ? .evDim : .evFg)
                    .strikethrough(item.task == true, color: .evSubtle)
                ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                    BlockView(block: child, line: item.line, store: store, depth: depth + 1)
                }
            }
        }
    }
}

private struct CalloutView: View {
    let type: String
    let title: String
    let folded: Bool?
    let blocks: [MDBlock]
    let line: Int
    let store: VaultStore
    let depth: Int
    @State private var open: Bool?

    var body: some View {
        let color = Color(uiColor: Callouts.color(type))
        let expanded = open ?? (folded != true)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard folded != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { open = !expanded }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Callouts.icon(type))
                    InlineText(source: title, size: 16, weight: .semibold, color: color)
                    Spacer(minLength: 0)
                    if folded != nil {
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                }
                .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    BlockView(block: b, line: line, store: store, depth: depth + 1)
                }
            }
        }
        .padding(14)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(color).frame(width: 3)
        }
    }
}

private struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.evSubtle)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.evDim)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.evFg.opacity(0.92))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
            }
        }
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.evBorder))
    }
}

private struct MathBlock: View {
    let latex: String

    var body: some View {
        if let r = MathRender.render(latex, size: NoteReader.bodySize * 1.12, display: true) {
            ViewThatFits(in: .horizontal) {
                Image(uiImage: r.image).frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: r.image).padding(.vertical, 2)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text(verbatim: "$$\(latex)$$")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.evCode)
                .textSelection(.enabled)
        }
    }
}

private struct TableBlock: View {
    let header: [String]
    let align: [MDAlign]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
                        cellView(cell, column: c, bold: true)
                    }
                }
                .background(Color.evBgAlt)
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            cellView(cell, column: c, bold: false)
                        }
                    }
                    .background(r % 2 == 1 ? Color.white.opacity(0.02) : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.evBorder))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cellView(_ text: String, column: Int, bold: Bool) -> some View {
        let a = column < align.count ? align[column] : .leading
        return InlineText(source: text, size: 15, weight: bold ? .semibold : .regular)
            .frame(minWidth: 60, maxWidth: 340, alignment: a == .center ? .center : a == .trailing ? .trailing : .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.evBorder).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.evBorder).frame(height: 1) }
    }
}

/// An image block: from the web, or a file in the vault.
struct NoteImage: View {
    let source: String
    let alt: String
    let store: VaultStore

    var body: some View {
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            NoteImageLoader(source: source, alt: alt)
        } else {
            let target = source.hasPrefix("vault:") ? String(source.dropFirst(6)) : (source.removingPercentEncoding ?? source)
            if let rel = store.resolve(target, from: store.current), let url = store.url(for: rel),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: min(image.size.width, 720))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label(alt.isEmpty ? target : alt, systemImage: "photo").foregroundStyle(Color.evSubtle)
            }
        }
    }
}

struct NoteImageLoader: View {
    let source: String
    let alt: String

    var body: some View {
        if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit().frame(maxWidth: 720).clipShape(RoundedRectangle(cornerRadius: 8))
                case .failure:
                    Link(destination: url) {
                        Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo.badge.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(Color.evSubtle)
                    }
                default:
                    RoundedRectangle(cornerRadius: 8).fill(Color.evBgAlt).frame(height: 120)
                        .overlay(ProgressView())
                }
            }
        } else {
            Label(alt.isEmpty ? source : alt, systemImage: "photo").foregroundStyle(Color.evSubtle)
        }
    }
}

/// `![[Note]]`, `![[image.png]]`, `![[file.pdf]]`.
private struct EmbedView: View {
    let target: String
    let store: VaultStore
    let depth: Int

    var body: some View {
        let rel = store.resolve(target, from: store.current)
        let kind = rel.map { VaultNode.kind(of: $0) } ?? VaultNode.kind(of: NoteParse.noteName(target))
        switch kind {
        case .image:
            NoteImage(source: "vault:" + target, alt: target, store: store)
        case .note where rel != nil && depth < 2:
            VStack(alignment: .leading, spacing: 10) {
                Button { store.follow(target) } label: {
                    Label(((rel! as NSString).lastPathComponent as NSString).deletingPathExtension, systemImage: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.evAccent)
                }
                .buttonStyle(.plain)
                ForEach(Markdown.parse(store.texts[rel!] ?? "").prefix(40)) { node in
                    BlockView(block: node.block, line: -1, store: store, depth: depth + 1)
                }
            }
            .padding(14)
            .overlay(alignment: .leading) { Rectangle().fill(Color.evAccent.opacity(0.6)).frame(width: 2) }
        default:
            if ScribeLink(target: target) != nil {
                // `![[scribe:…]]`: Scribe's page isn't drawn here; open it there.
                Button { store.follow(target) } label: {
                    Label(store.scribePage(target)?.title ?? "Scribe page", systemImage: "pencil.and.scribble")
                        .foregroundStyle(Color.velvetAccent)
                }
                .buttonStyle(.plain)
            } else {
                Button { store.follow(target) } label: {
                    Label(target, systemImage: kind == .pdf ? "doc.richtext" : "link")
                        .foregroundStyle(rel == nil ? Color.evSubtle : Color.evAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Notes that link here.
private struct Backlinks: View {
    let store: VaultStore
    let rel: String

    var body: some View {
        let refs = store.backlinks(of: rel)
        let pages = store.scribeBacklinks(of: rel)
        let count = refs.count + pages.count
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Color.evBorder).frame(height: 1).padding(.bottom, 8)
            Text(count == 0 ? "No linked mentions" : "Linked mentions · \(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.evSubtle)
            ForEach(refs, id: \.self) { ref in
                Button { store.show(ref) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.notes[ref]?.name ?? ref)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.evAccent)
                        let folder = (ref as NSString).deletingLastPathComponent
                        if !folder.isEmpty {
                            Text(folder).font(.system(size: 12)).foregroundStyle(Color.evSubtle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            // Scribe pages with [[this note]] typed on them.
            ForEach(pages) { page in
                Button { store.openScribe?(ScribeLink(pageId: page.id)) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(page.title, systemImage: "pencil.and.scribble")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.velvetAccent)
                        Text("Scribe · \(page.notebook) › \(page.section)").font(.system(size: 12)).foregroundStyle(Color.evSubtle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
