import Foundation

/// A note's body split into the blocks the reading view draws. Covers what
/// the vault uses: headings, paragraphs, nested and task lists, quotes and
/// `> [!callouts]`, fenced code, `$$ math $$`, tables, rules, images and
/// `![[embeds]]`. `line` is the block's first source line, for task ticks
/// and jumping to headings.
indirect enum MDBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MDListItem])
    case quote([MDBlock])
    case callout(type: String, title: String, folded: Bool?, body: [MDBlock])
    case code(lang: String, text: String)
    case math(String)
    case table(header: [String], align: [MDAlign], rows: [[String]])
    case rule
    case image(alt: String, source: String)
    case embed(String)
}

enum MDAlign: Hashable { case leading, center, trailing }

struct MDListItem: Hashable {
    /// "•" for bullets, "3." for numbers.
    var marker: String
    var ordered: Bool
    /// Nil when it isn't a task; else whether it's ticked.
    var task: Bool?
    var text: String
    /// Source line of the item, 0-based in the whole note.
    var line: Int
    var children: [MDBlock]
}

struct MDNode: Identifiable, Hashable {
    let id: Int
    let line: Int
    let block: MDBlock
}

enum Markdown {
    /// Parses `source` (a whole note, frontmatter skipped) into blocks.
    static func parse(_ source: String) -> [MDNode] {
        let skip = NoteParse.frontmatterLength(source)
        let body = skip > 0 ? (source as NSString).substring(from: skip) : source
        let skippedLines = skip > 0 ? (source as NSString).substring(to: skip).components(separatedBy: "\n").count - 1 : 0
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var nodes: [MDNode] = []
        for (i, b) in blocks(lines[...], base: skippedLines).enumerated() { nodes.append(MDNode(id: i, line: b.line, block: b.block)) }
        return nodes
    }

    private typealias Lines = ArraySlice<String>

    private static func blocks(_ lines: Lines, base: Int) -> [(line: Int, block: MDBlock)] {
        var out: [(Int, MDBlock)] = []
        var i = lines.startIndex
        var para: [String] = []
        var paraStart = 0
        func flush() {
            guard !para.isEmpty else { return }
            out.append(contentsOf: paragraphs(para, start: paraStart))
            para = []
        }
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNo = base + (i - lines.startIndex)

            if trimmed.isEmpty { flush(); i += 1; continue }

            // Fenced code.
            if let fence = fenceMarker(trimmed) {
                flush()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var j = i + 1
                var body: [String] = []
                let indent = line.prefix { $0 == " " }.count
                while j < lines.endIndex, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(String(lines[j].dropFirst(min(indent, lines[j].prefix { $0 == " " }.count))))
                    j += 1
                }
                out.append((lineNo, .code(lang: lang, text: body.joined(separator: "\n"))))
                i = min(j + 1, lines.endIndex)
                continue
            }

            // Display math: `$$` … `$$`, possibly on one line.
            if trimmed.hasPrefix("$$") {
                flush()
                var rest = String(trimmed.dropFirst(2))
                if let end = rest.range(of: "$$") {
                    out.append((lineNo, .math(String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces))))
                    i += 1
                    continue
                }
                var body = rest.isEmpty ? [] : [rest]
                var j = i + 1
                while j < lines.endIndex {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if let end = t.range(of: "$$") {
                        rest = String(t[..<end.lowerBound])
                        if !rest.isEmpty { body.append(rest) }
                        break
                    }
                    body.append(lines[j])
                    j += 1
                }
                out.append((lineNo, .math(body.joined(separator: "\n"))))
                i = min(j + 1, lines.endIndex)
                continue
            }

            // Heading.
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes <= 6, trimmed.count == hashes || trimmed.dropFirst(hashes).first == " " {
                    flush()
                    var text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                    while text.hasSuffix("#") { text.removeLast() }
                    out.append((lineNo, .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))))
                    i += 1
                    continue
                }
            }

            // Thematic break.
            if isRule(trimmed) {
                flush()
                out.append((lineNo, .rule))
                i += 1
                continue
            }

            // Table: a row then a `---|---` separator.
            if trimmed.contains("|"), i + 1 < lines.endIndex, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                let align = cells(lines[i + 1]).map { c -> MDAlign in
                    let left = c.hasPrefix(":"), right = c.hasSuffix(":")
                    return left && right ? .center : right ? .trailing : .leading
                }
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.endIndex, lines[j].contains("|"), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[j])
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(max(header.count, 1))))
                    j += 1
                }
                out.append((lineNo, .table(header: header, align: align, rows: rows)))
                i = j
                continue
            }

            // Quote or callout.
            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                var j = i
                while j < lines.endIndex {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var s = String(t.dropFirst())
                    if s.hasPrefix(" ") { s.removeFirst() }
                    inner.append(s)
                    j += 1
                }
                if let first = inner.first, first.hasPrefix("[!"), let m = first.firstMatch(of: #/^\[!([A-Za-z-]+)\]([+-]?)\s*(.*)$/#) {
                    let type = String(m.1).lowercased()
                    let fold = String(m.2)
                    let title = String(m.3).trimmingCharacters(in: .whitespaces)
                    let body = blocks(Array(inner.dropFirst())[...], base: lineNo + 1).map(\.block)
                    out.append((lineNo, .callout(type: type, title: title.isEmpty ? type.prefix(1).uppercased() + type.dropFirst() : title,
                                                 folded: fold.isEmpty ? nil : fold == "-", body: body)))
                } else {
                    out.append((lineNo, .quote(blocks(inner[...], base: lineNo).map(\.block))))
                }
                i = j
                continue
            }

            // List.
            if listMarker(line) != nil {
                flush()
                let (items, next) = list(lines, from: i, base: base)
                out.append((lineNo, .list(items)))
                i = next
                continue
            }

            // Standalone embed.
            if trimmed.hasPrefix("![["), trimmed.hasSuffix("]]"), !trimmed.dropFirst(3).contains("[[") {
                flush()
                out.append((lineNo, .embed(String(trimmed.dropFirst(3).dropLast(2)))))
                i += 1
                continue
            }

            if para.isEmpty { paraStart = lineNo }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    /// Paragraph lines, with lines that are only an image split out.
    private static func paragraphs(_ lines: [String], start: Int) -> [(Int, MDBlock)] {
        var out: [(Int, MDBlock)] = []
        var text: [String] = []
        var textStart = start
        for (k, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("!["), t.hasSuffix(")"), let m = t.wholeMatch(of: #/!\[([^\]]*)\]\(<?([^)>]+)>?\)/#) {
                if !text.isEmpty { out.append((textStart, .paragraph(text.joined(separator: "\n")))); text = [] }
                out.append((start + k, .image(alt: String(m.1), source: String(m.2).trimmingCharacters(in: .whitespaces))))
                textStart = start + k + 1
            } else {
                if text.isEmpty { textStart = start + k }
                text.append(t)
            }
        }
        if !text.isEmpty { out.append((textStart, .paragraph(text.joined(separator: "\n")))) }
        return out
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return String(trimmed.prefix { $0 == "`" }) }
        if trimmed.hasPrefix("~~~") { return String(trimmed.prefix { $0 == "~" }) }
        return nil
    }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.contains("|") && t.allSatisfy { "|:- \t".contains($0) }
    }

    /// `| a | b |` → ["a", "b"], keeping `\|` and pipes inside code.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var code = false
        var prev: Character = " "
        for ch in t {
            if ch == "`" { code.toggle() }
            if ch == "|", !code, prev != "\\" {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                if ch == "|", prev == "\\" { cur.removeLast() }
                cur.append(ch)
            }
            prev = ch
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// The marker of a list line: indent, marker text, content offset.
    private static func listMarker(_ line: String) -> (indent: Int, marker: String, ordered: Bool, content: Int)? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " || rest.count == 1 {
            return (indent, "•", false, indent + 2)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " || after.count == 1 {
                return (indent, digits + ".", true, indent + digits.count + 2)
            }
        }
        return nil
    }

    /// A list starting at `start`: items at its indent, deeper lines as the
    /// previous item's children (nested lists, code, math).
    private static func list(_ lines: Lines, from start: Int, base: Int) -> ([MDListItem], Int) {
        guard let first = listMarker(lines[start]) else { return ([], start + 1) }
        var items: [MDListItem] = []
        var i = start
        var childLines: [String] = []
        var childStart = 0
        func closeChildren() {
            guard !items.isEmpty, !childLines.isEmpty else { childLines = []; return }
            items[items.count - 1].children = blocks(childLines[...], base: childStart).map(\.block)
            childLines = []
        }
        while i < lines.endIndex {
            let line = lines[i].replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            if trimmed.isEmpty {
                // A blank line ends the list unless more of it follows, indented.
                var j = i + 1
                while j < lines.endIndex, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.endIndex else { break }
                let nextIndent = lines[j].replacingOccurrences(of: "\t", with: "    ").prefix { $0 == " " }.count
                if nextIndent > first.indent || (nextIndent == first.indent && listMarker(lines[j]) != nil) {
                    if nextIndent > first.indent { childLines.append("") }
                    i += 1
                    continue
                }
                break
            }
            if indent <= first.indent, let m = listMarker(line), m.indent <= first.indent + 1 {
                closeChildren()
                var text = String(line.dropFirst(min(m.content, line.count)))
                var task: Bool?
                if text.hasPrefix("["), let tm = text.firstMatch(of: #/^\[([ xX])\](\s|$)/#) {
                    task = tm.1 != " "
                    text = String(text.dropFirst(tm.0.count))
                }
                items.append(MDListItem(marker: m.marker, ordered: m.ordered, task: task, text: text, line: base + (i - lines.startIndex), children: []))
                i += 1
                continue
            }
            if indent > first.indent {
                if childLines.isEmpty { childStart = base + (i - lines.startIndex) }
                // Children are re-parsed relative to the item's content column.
                let cut = min(indent, first.content)
                childLines.append(String(line.dropFirst(cut)))
                i += 1
                continue
            }
            // An unindented line straight after an item continues its text.
            if !items.isEmpty, childLines.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(">"), fenceMarker(trimmed) == nil, !trimmed.hasPrefix("$$") {
                items[items.count - 1].text += "\n" + trimmed
                i += 1
                continue
            }
            break
        }
        closeChildren()
        return (items, i)
    }
}
