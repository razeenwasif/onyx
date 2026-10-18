import SwiftUI
import UIKit

/// Shared between the text view and SwiftUI: the `[[` being typed and a way
/// to finish it.
@MainActor
@Observable
final class EditorBridge {
    /// What follows an unclosed `[[` before the caret, or nil.
    var linkQuery: String?
    weak var textView: UITextView?

    /// Replaces the half-typed link with `[[name]]`.
    func complete(_ name: String) {
        guard let tv = textView, let query = linkQuery else { return }
        let caret = tv.selectedRange.location
        let start = caret - (query as NSString).length
        guard start >= 0 else { return }
        let ns = tv.text as NSString
        let closes = caret + 2 <= ns.length && ns.substring(with: NSRange(location: caret, length: 2)) == "]]"
        let range = NSRange(location: start, length: (query as NSString).length + (closes ? 2 : 0))
        if let r = tv.textRange(from: range) { tv.replace(r, withText: name + "]]") }
        linkQuery = nil
    }

    /// The source line at the top of the text view.
    static func topLine(of tv: UITextView) -> Int {
        let point = CGPoint(x: tv.textContainerInset.left + 4, y: tv.contentOffset.y + tv.adjustedContentInset.top + tv.textContainerInset.top + 4)
        guard let pos = tv.closestPosition(to: point) else { return 0 }
        let offset = tv.offset(from: tv.beginningOfDocument, to: pos)
        let ns = tv.text as NSString
        var line = 0, location = 0
        while location < min(offset, ns.length) {
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            if next > offset { break }
            location = next
            line += 1
        }
        return line
    }

    var topLine: Int? { textView.map(Self.topLine(of:)) }

    func wrap(_ before: String, _ after: String) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange
        let ns = tv.text as NSString
        let inner = sel.length > 0 ? ns.substring(with: sel) : ""
        guard let r = tv.textRange(from: sel) else { return }
        tv.replace(r, withText: before + inner + after)
        tv.selectedRange = NSRange(location: sel.location + (before as NSString).length, length: (inner as NSString).length)
    }

    /// Puts `prefix` at the start of the caret's line (or takes it off).
    func linePrefix(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: tv.selectedRange.location, length: 0))
        let line = ns.substring(with: lineRange)
        let caret = tv.selectedRange.location
        if line.hasPrefix(prefix) {
            if let r = tv.textRange(from: NSRange(location: lineRange.location, length: (prefix as NSString).length)) { tv.replace(r, withText: "") }
            tv.selectedRange = NSRange(location: max(lineRange.location, caret - (prefix as NSString).length), length: 0)
        } else {
            if let r = tv.textRange(from: NSRange(location: lineRange.location, length: 0)) { tv.replace(r, withText: prefix) }
            tv.selectedRange = NSRange(location: caret + (prefix as NSString).length, length: 0)
        }
    }
}

private extension UITextView {
    func textRange(from range: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length) else { return nil }
        return textRange(from: start, to: end)
    }
}

/// The Markdown source, styled as you type (headings sized, markers dimmed,
/// code, math, links and tags coloured), saving through the store.
struct MarkdownEditor: UIViewRepresentable {
    let store: VaultStore
    let bridge: EditorBridge

    func makeCoordinator() -> Coordinator { Coordinator(store: store, bridge: bridge) }

    func makeUIView(context: Context) -> MarkdownTextView {
        let tv = MarkdownTextView()
        tv.delegate = context.coordinator
        tv.bridge = bridge
        tv.backgroundColor = EV.bg
        tv.tintColor = EV.accent
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 24, bottom: 240, right: 24)
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.autocorrectionType = .default
        tv.spellCheckingType = .default
        tv.font = MarkdownStyle.body
        tv.textColor = EV.fg
        tv.typingAttributes = MarkdownStyle.base
        tv.installShortcuts()
        bridge.textView = tv
        context.coordinator.load(tv, text: store.text, rel: store.current)
        return tv
    }

    static func dismantleUIView(_ tv: MarkdownTextView, coordinator: Coordinator) {
        coordinator.recordAnchor(tv)
    }

    func updateUIView(_ tv: MarkdownTextView, context: Context) {
        let c = context.coordinator
        if c.rel != store.current || (tv.text != store.text && !c.editing) {
            c.load(tv, text: store.text, rel: store.current)
        }
        // Widen the margins on a wide screen, so lines stay readable.
        let side = max(24, (tv.bounds.width - 760) / 2)
        if abs(tv.textContainerInset.left - side) > 1 {
            tv.textContainerInset = UIEdgeInsets(top: 24, left: side, bottom: 240, right: side)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let store: VaultStore
        let bridge: EditorBridge
        var rel: String?
        var editing = false
        private var regions: [MarkdownStyle.Region] = []

        init(store: VaultStore, bridge: EditorBridge) {
            self.store = store
            self.bridge = bridge
        }

        func load(_ tv: UITextView, text: String, rel: String?) {
            let sameNote = rel == self.rel
            let selection = tv.selectedRange
            self.rel = rel
            tv.text = text
            regions = MarkdownStyle.regions(text as NSString)
            MarkdownStyle.apply(tv.textStorage, in: NSRange(location: 0, length: (text as NSString).length), regions: regions)
            if sameNote, NSMaxRange(selection) <= (text as NSString).length { tv.selectedRange = selection }
            else { tv.selectedRange = NSRange(location: 0, length: 0); tv.setContentOffset(.zero, animated: false) }
            bridge.linkQuery = nil
            if !sameNote, store.anchorLine > 0 {
                let line = store.anchorLine
                // Wait for the view to have its size, then start where the reader was.
                DispatchQueue.main.async { [weak tv] in
                    guard let tv else { return }
                    Self.scroll(tv, toLine: line)
                }
            }
        }

        /// Scrolls so source line `line` (0-based) is at the top.
        static func scroll(_ tv: UITextView, toLine line: Int) {
            let ns = tv.text as NSString
            var location = 0, n = 0
            while n < line, location < ns.length {
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
                n += 1
            }
            guard let start = tv.position(from: tv.beginningOfDocument, offset: min(location, ns.length)),
                  let range = tv.textRange(from: start, to: start) else { return }
            tv.layoutIfNeeded()
            let rect = tv.firstRect(for: range)
            guard rect.origin.y.isFinite else { return }
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            tv.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, rect.minY - tv.textContainerInset.top - tv.adjustedContentInset.top))), animated: false)
        }

        func recordAnchor(_ tv: UITextView) {
            store.anchorLine = EditorBridge.topLine(of: tv)
        }

        func textViewDidBeginEditing(_ textView: UITextView) { editing = true }
        func textViewDidEndEditing(_ textView: UITextView) {
            editing = false
            store.flush()
        }

        private var lastEdit = NSRange(location: 0, length: 0)

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Enter on a list line continues the list; on an empty item, ends it.
            if text == "\n", range.length == 0, let tv = textView as? MarkdownTextView, tv.continueList(at: range.location) {
                return false
            }
            lastEdit = NSRange(location: range.location, length: (text as NSString).length)
            return true
        }

        func textViewDidChange(_ tv: UITextView) {
            store.edited(tv.text)
            guard tv.markedTextRange == nil else { return }
            let ns = tv.text as NSString
            let fresh = MarkdownStyle.regions(ns)
            let all = NSRange(location: 0, length: ns.length)
            if fresh != regions {
                regions = fresh
                MarkdownStyle.apply(tv.textStorage, in: all, regions: regions)
            } else {
                let edit = NSIntersectionRange(NSRange(location: lastEdit.location, length: lastEdit.length), all)
                let para = ns.paragraphRange(for: NSRange(location: min(edit.location, max(0, ns.length - 1)), length: edit.length))
                MarkdownStyle.apply(tv.textStorage, in: para, regions: regions)
            }
            tv.typingAttributes = MarkdownStyle.base
            updateLinkQuery(tv)
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            updateLinkQuery(tv)
        }

        private func updateLinkQuery(_ tv: UITextView) {
            let ns = tv.text as NSString
            let caret = tv.selectedRange.location
            guard tv.selectedRange.length == 0, caret <= ns.length else { bridge.linkQuery = nil; return }
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            let before = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
            if let open = before.range(of: "[[", options: .backwards), !before[open.upperBound...].contains("]") {
                let query = String(before[open.upperBound...])
                bridge.linkQuery = query.contains("|") ? nil : query
            } else {
                bridge.linkQuery = nil
            }
        }
    }
}

/// The text view, with list continuation and formatting shortcuts.
final class MarkdownTextView: UITextView {
    weak var bridge: EditorBridge?

    func installShortcuts() {
        let item = inputAssistantItem
        func button(_ symbol: String, _ action: @escaping () -> Void) -> UIBarButtonItem {
            UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
        }
        item.leadingBarButtonGroups += [UIBarButtonItemGroup(barButtonItems: [
            button("number") { [weak self] in self?.bridge?.linePrefix("## ") },
            button("bold") { [weak self] in self?.bridge?.wrap("**", "**") },
            button("italic") { [weak self] in self?.bridge?.wrap("*", "*") },
            button("checklist") { [weak self] in self?.bridge?.linePrefix("- [ ] ") },
        ], representativeItem: nil)]
        item.trailingBarButtonGroups += [UIBarButtonItemGroup(barButtonItems: [
            button("link") { [weak self] in self?.bridge?.wrap("[[", "]]") },
            button("chevron.left.forwardslash.chevron.right") { [weak self] in self?.bridge?.wrap("`", "`") },
            button("function") { [weak self] in self?.bridge?.wrap("$", "$") },
        ], representativeItem: nil)]
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Bold", action: #selector(boldKey), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italic", action: #selector(italicKey), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Link", action: #selector(linkKey), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "Toggle Checkbox", action: #selector(taskKey), input: "l", modifierFlags: .command),
        ]
    }

    @objc private func boldKey() { bridge?.wrap("**", "**") }
    @objc private func italicKey() { bridge?.wrap("*", "*") }
    @objc private func linkKey() { bridge?.wrap("[[", "]]") }
    @objc private func taskKey() { bridge?.linePrefix("- [ ] ") }

    /// Enter after `- item` starts `- `; after an empty `- `, clears it.
    func continueList(at location: Int) -> Bool {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let lineEnd = min(location, NSMaxRange(lineRange))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
        guard let m = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])( \[[ xX]\])? /#) else { return false }
        let marker: String
        if let n = Int(m.2.dropLast()) { marker = "\(n + 1)\(m.2.last!)" } else { marker = String(m.2) }
        let rest = line.dropFirst(m.0.count)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: end the list.
            if let r = textRange(from: NSRange(location: lineRange.location, length: lineEnd - lineRange.location)) { replace(r, withText: "") }
            return true
        }
        let next = "\n" + m.1 + marker + (m.3 != nil ? " [ ]" : "") + " "
        if let r = textRange(from: NSRange(location: location, length: 0)) { replace(r, withText: next) }
        return true
    }
}

/// How the editor styles Markdown source.
@MainActor
enum MarkdownStyle {
    static let body = UIFont.systemFont(ofSize: 17)
    static let mono = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 4
        return p
    }

    static var base: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: EV.fg, .paragraphStyle: paragraph]
    }

    /// Multi-line spans styled as a whole: frontmatter, code fences, `$$`.
    struct Region: Equatable {
        enum Kind { case frontmatter, code, math }
        let kind: Kind
        let range: NSRange
    }

    static func regions(_ ns: NSString) -> [Region] {
        var out: [Region] = []
        let fm = NoteParse.frontmatterLength(ns as String)
        if fm > 0 { out.append(Region(kind: .frontmatter, range: NSRange(location: 0, length: fm))) }
        var pos = fm
        var open: (Region.Kind, Int, String)?
        while pos < ns.length {
            let line = ns.lineRange(for: NSRange(location: pos, length: 0))
            let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let (kind, start, marker) = open {
                let closes = kind == .code ? text.hasPrefix(marker) : text.hasSuffix("$$")
                if closes {
                    out.append(Region(kind: kind, range: NSRange(location: start, length: NSMaxRange(line) - start)))
                    open = nil
                }
            } else if text.hasPrefix("```") || text.hasPrefix("~~~") {
                open = (.code, line.location, String(text.prefix(3)))
            } else if text.hasPrefix("$$") {
                let rest = text.dropFirst(2)
                if rest.contains("$$") {
                    out.append(Region(kind: .math, range: line))
                } else {
                    open = (.math, line.location, "$$")
                }
            }
            pos = NSMaxRange(line)
        }
        if let (kind, start, _) = open { out.append(Region(kind: kind, range: NSRange(location: start, length: ns.length - start))) }
        return out
    }

    private static let rules: [(NSRegularExpression, (NSTextCheckingResult, NSTextStorage) -> Void)] = {
        func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        func color(_ c: UIColor, _ g: Int = 0) -> (NSTextCheckingResult, NSTextStorage) -> Void {
            { m, s in s.addAttribute(.foregroundColor, value: c, range: m.range(at: g)) }
        }
        let dim = EV.fgSubtle
        return [
            // Bold and italic: the text styled, the markers dimmed.
            (re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), { m, s in
                s.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: m.range(at: 2))
                s.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location, length: 2))
                s.addAttribute(.foregroundColor, value: dim, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2))
            }),
            (re(#"(?<![*\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*\w])"#), { m, s in
                s.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 17), range: m.range(at: 2))
                s.addAttribute(.foregroundColor, value: dim, range: m.range(at: 1))
                s.addAttribute(.foregroundColor, value: dim, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            }),
            (re(#"~~(.+?)~~"#), { m, s in
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
                s.addAttribute(.foregroundColor, value: dim, range: m.range)
            }),
            (re(#"==(.+?)=="#), { m, s in s.addAttribute(.backgroundColor, value: EV.highlight, range: m.range(at: 1)) }),
            // Links.
            (re(#"!?\[\[[^\[\]\n]+\]\]"#), { m, s in
                s.addAttribute(.foregroundColor, value: EV.wikilink, range: m.range)
            }),
            (re(#"!?\[([^\]\n]*)\]\(([^)\n]+)\)"#), { m, s in
                s.addAttribute(.foregroundColor, value: dim, range: m.range)
                s.addAttribute(.foregroundColor, value: EV.link, range: m.range(at: 1))
            }),
            (re(#"(?<![\w(<])https?://[^\s)>]+"#), color(EV.link)),
            (re(#"(?:^|(?<=[^\w&]))#[A-Za-z][\w/-]*"#), color(EV.tag)),
            // Line starts: lists, tasks, quotes, callouts, rules.
            (re(#"^\s*(?:[-*+]|\d+[.)])(?= )"#), color(EV.accent)),
            (re(#"^\s*[-*+] (\[[ xX]\])"#), color(EV.accent, 1)),
            (re(#"^\s*>+"#), color(EV.accent)),
            (re(#"^\s*>\s*\[!([A-Za-z-]+)\][+-]?.*$"#), { m, s in
                let ns = s.string as NSString
                let type = ns.substring(with: m.range(at: 1)).lowercased()
                s.addAttribute(.foregroundColor, value: Callouts.color(type), range: m.range)
                s.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: m.range)
            }),
            (re(#"^\s*([-*_])(\s*\1){2,}\s*$"#), color(dim)),
            // Inline math and code last, so nothing inside them is styled.
            (re(#"(?<![\\$])\$(?=[^\s$])[^$\n]+?(?<=\S)\$(?!\d)"#), { m, s in
                s.addAttribute(.foregroundColor, value: EV.code, range: m.range)
                s.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: m.range)
            }),
            (re(#"`[^`\n]+`"#), { m, s in
                s.addAttribute(.foregroundColor, value: EV.code, range: m.range)
                s.addAttribute(.font, value: mono, range: m.range)
                s.addAttribute(.backgroundColor, value: EV.codeBg, range: m.range)
            }),
        ]
    }()

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+.*$"#, options: [.anchorsMatchLines])

    /// Restyles `range` (whole paragraphs) of `storage`.
    static func apply(_ storage: NSTextStorage, in range: NSRange, regions: [Region]) {
        let ns = storage.string as NSString
        let range = NSIntersectionRange(ns.paragraphRange(for: range), NSRange(location: 0, length: ns.length))
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(base, range: range)
        let string = storage.string

        heading.enumerateMatches(in: string, range: range) { m, _, _ in
            guard let m else { return }
            let level = m.range(at: 1).length
            let size = BlockView.headingSize(level)
            storage.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: level <= 3 ? .bold : .semibold), range: m.range)
            storage.addAttribute(.foregroundColor, value: EV.heading, range: m.range)
            storage.addAttribute(.foregroundColor, value: EV.fgSubtle, range: m.range(at: 1))
        }
        for (re, style) in rules {
            re.enumerateMatches(in: string, range: range) { m, _, _ in if let m { style(m, storage) } }
        }
        // Whole regions override what the line rules did inside them.
        for region in regions {
            let r = NSIntersectionRange(region.range, range)
            guard r.length > 0 else { continue }
            switch region.kind {
            case .frontmatter:
                storage.setAttributes([.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                       .foregroundColor: EV.fgDim, .paragraphStyle: paragraph], range: r)
            case .code:
                storage.setAttributes([.font: mono, .foregroundColor: EV.fg.withAlphaComponent(0.88),
                                       .backgroundColor: EV.codeBg, .paragraphStyle: paragraph], range: r)
            case .math:
                storage.setAttributes([.font: mono, .foregroundColor: EV.code, .paragraphStyle: paragraph], range: r)
            }
        }
        storage.endEditing()
    }
}

/// Note names for a half-typed `[[`, shown above the keyboard.
struct LinkSuggestions: View {
    let store: VaultStore
    let bridge: EditorBridge

    var body: some View {
        if let query = bridge.linkQuery {
            let q = query.lowercased()
            // A steady order (saving changes dates), and never the note itself.
            let matches = store.notes.values
                .filter { $0.rel != store.current }
                .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.aliases.contains { $0.lowercased().contains(q) } }
                .sorted { a, b in
                    let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
                    if ap != bp { return ap }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                .prefix(8)
            // Scribe's pages too, linked by id (see ScribeLink).
            let pages = q.isEmpty ? [] : store.scribePages.values
                .filter { $0.title.lowercased().contains(q) }
                .sorted { $0.modified > $1.modified }
                .prefix(4)
            if !matches.isEmpty || !pages.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pages)) { page in
                        Button {
                            bridge.complete(String(ScribeLink(pageId: page.id).markdown(title: page.title).dropFirst(2).dropLast(2)))
                        } label: {
                            HStack {
                                Image(systemName: "pencil.and.scribble").foregroundStyle(Color.velvetAccent)
                                Text(page.title).foregroundStyle(Color.evFg)
                                Spacer()
                                Text("Scribe · \(page.notebook) › \(page.section)")
                                    .font(.caption).foregroundStyle(Color.evSubtle).lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(matches), id: \.rel) { meta in
                        Button { bridge.complete(meta.name) } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(Color.evSubtle)
                                Text(meta.name).foregroundStyle(Color.evFg)
                                Spacer()
                                Text((meta.rel as NSString).deletingLastPathComponent)
                                    .font(.caption).foregroundStyle(Color.evSubtle).lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 520)
                .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.evBorder))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                .padding(12)
            }
        }
    }
}
