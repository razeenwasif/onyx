import Foundation

/// What a note says about itself and where it points, read the same way as the
/// desktop (desktop/src/shared/parse.ts): `[[wikilinks]]`, `#tags` outside
/// code, frontmatter `tags:` and `aliases:`, and the first `# Heading`.
enum NoteParse {
    struct WikiLink: Equatable {
        var target: String
        var alias: String?
        var range: NSRange
        var embed: Bool
    }

    private static let wikiRE = try! NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]+?)\]\]"#)
    private static let tagRE = try! NSRegularExpression(pattern: #"(^|[^\w&])#([A-Za-z][\w/-]*)"#, options: [.anchorsMatchLines])
    private static let fenceRE = try! NSRegularExpression(pattern: #"^(?:```|~~~).*$"#, options: [.anchorsMatchLines])
    private static let mdLinkRE = try! NSRegularExpression(pattern: #"(!?)\[[^\]\n]*\]\(([^)\n]+)\)"#)

    // MARK: Code ranges

    /// UTF-16 ranges that link and tag scanning skip: fenced blocks and
    /// inline code spans.
    static func excludedRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        let fences = fenceRE.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var i = 0
        while i + 1 < fences.count {
            ranges.append(NSRange(location: fences[i].location, length: NSMaxRange(fences[i + 1]) - fences[i].location))
            i += 2
        }
        if fences.count % 2 == 1, let last = fences.last {
            ranges.append(NSRange(location: last.location, length: ns.length - last.location))
        }
        // Inline code: balanced backticks on one line.
        let tick: unichar = 96, newline: unichar = 10
        var pos = 0
        while pos < ns.length {
            if ns.character(at: pos) == tick, !inside(pos, ranges) {
                var end = pos + 1
                while end < ns.length, ns.character(at: end) != tick, ns.character(at: end) != newline { end += 1 }
                if end < ns.length, ns.character(at: end) == tick {
                    ranges.append(NSRange(location: pos, length: end - pos + 1))
                    pos = end + 1
                    continue
                }
            }
            pos += 1
        }
        return ranges.sorted { $0.location < $1.location }
    }

    static func inside(_ pos: Int, _ ranges: [NSRange]) -> Bool {
        for r in ranges {
            if pos >= r.location && pos < NSMaxRange(r) { return true }
            if r.location > pos { break }
        }
        return false
    }

    // MARK: Links and tags

    static func links(_ source: String) -> [WikiLink] {
        let ns = source as NSString
        let excluded = excludedRanges(ns)
        var out: [WikiLink] = []
        for m in wikiRE.matches(in: source, range: NSRange(location: 0, length: ns.length)) where !inside(m.range.location, excluded) {
            let inner = ns.substring(with: m.range(at: 2))
            let (target, alias) = splitAlias(inner)
            guard !target.isEmpty else { continue }
            out.append(WikiLink(target: target, alias: alias, range: m.range, embed: m.range(at: 1).length > 0))
        }
        return out
    }

    /// `Note|Shown` → ("Note", "Shown").
    static func splitAlias(_ inner: String) -> (String, String?) {
        guard let bar = inner.firstIndex(of: "|") else { return (inner.trimmingCharacters(in: .whitespaces), nil) }
        return (String(inner[..<bar]).trimmingCharacters(in: .whitespaces),
                String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Local `[text](Note.md)` links, as note targets.
    static func mdLinks(_ source: String) -> [String] {
        let ns = source as NSString
        let excluded = excludedRanges(ns)
        return mdLinkRE.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard !inside(m.range.location, excluded), m.range(at: 1).length == 0 else { return nil }
            return localTarget(ns.substring(with: m.range(at: 2)))
        }
    }

    /// A markdown link destination that points into the vault, as a target.
    static func localTarget(_ raw: String) -> String? {
        var dest = raw.trimmingCharacters(in: .whitespaces)
        if dest.hasPrefix("<"), dest.hasSuffix(">") { dest = String(dest.dropFirst().dropLast()) }
        else { dest = dest.split(separator: " ").first.map(String.init) ?? dest }
        if dest.isEmpty || dest.hasPrefix("#") || dest.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        dest = dest.removingPercentEncoding ?? dest
        if let hash = dest.firstIndex(of: "#") { dest = String(dest[..<hash]) }
        if dest.lowercased().hasSuffix(".md") { dest = String(dest.dropLast(3)) }
        if dest.hasPrefix("./") { dest = String(dest.dropFirst(2)) }
        return dest.isEmpty ? nil : dest
    }

    static func inlineTags(_ source: String) -> [String] {
        let ns = source as NSString
        let excluded = excludedRanges(ns)
        return tagRE.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let at = m.range(at: 1).location + m.range(at: 1).length
            return inside(at, excluded) ? nil : ns.substring(with: m.range(at: 2))
        }
    }

    /// The note name of a link target: no `#heading` or `^block`.
    static func noteName(_ target: String) -> String {
        guard let cut = target.firstIndex(where: { $0 == "#" || $0 == "^" }) else { return target }
        return String(target[..<cut])
    }

    /// The heading a target points at (`Note#Heading`), if any.
    static func heading(_ target: String) -> String? {
        guard let hash = target.firstIndex(of: "#") else { return nil }
        let rest = String(target[target.index(after: hash)...])
        return rest.hasPrefix("^") || rest.isEmpty ? nil : rest
    }

    // MARK: Frontmatter

    /// UTF-16 length of the leading `---` block including its fences, or 0.
    static func frontmatterLength(_ source: String) -> Int {
        let ns = source as NSString
        let bom = source.hasPrefix("\u{FEFF}") ? 1 : 0
        let body = ns.substring(from: bom) as NSString
        guard body.hasPrefix("---\n") || body.hasPrefix("---\r\n") else { return 0 }
        guard let re = try? NSRegularExpression(pattern: #"\r?\n(?:---|\.\.\.)[ \t]*(\r?\n|$)"#),
              let m = re.firstMatch(in: body as String, range: NSRange(location: 3, length: body.length - 3))
        else { return 0 }
        return bom + NSMaxRange(m.range)
    }

    /// The frontmatter's `key: value` pairs, lists flattened to their items.
    static func properties(_ source: String) -> [(key: String, values: [String])] {
        let length = frontmatterLength(source)
        guard length > 0 else { return [] }
        let block = (source as NSString).substring(to: length)
        var lines = block.components(separatedBy: .newlines)
        lines.removeFirst()
        var out: [(String, [String])] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { break }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var values: [String] = []
            if value.isEmpty {
                var j = i + 1
                while j < lines.count {
                    let item = lines[j].trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("-") else { break }
                    let v = scalar(String(item.dropFirst()))
                    if !v.isEmpty { values.append(v) }
                    j += 1
                }
                i = j
            } else {
                if value.hasPrefix("["), value.hasSuffix("]") {
                    values = value.dropFirst().dropLast().split(separator: ",").map { scalar(String($0)) }.filter { !$0.isEmpty }
                } else {
                    values = [scalar(value)]
                }
                i += 1
            }
            out.append((key, values))
        }
        return out
    }

    private static func scalar(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let a = t.first, let b = t.last, (a == "\"" && b == "\"") || (a == "'" && b == "'") {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func frontmatterTags(_ source: String) -> [String] {
        properties(source)
            .filter { ["tags", "tag"].contains($0.key.lowercased()) }
            .flatMap(\.values)
            .map { $0.replacingOccurrences(of: #"^#+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    static func aliases(_ source: String) -> [String] {
        properties(source).filter { ["aliases", "alias"].contains($0.key.lowercased()) }.flatMap(\.values)
    }

    static func body(_ source: String) -> String {
        let n = frontmatterLength(source)
        return n > 0 ? (source as NSString).substring(from: n) : source
    }

    static func firstHeading(_ source: String) -> String? {
        // Only the top of the note: splitting all of it is slow on long notes.
        var found: String?
        var seen = 0
        body(source).enumerateLines { line, stop in
            if line.hasPrefix("# ") {
                found = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                stop = true
            }
            seen += 1
            if seen >= 80 { stop = true }
        }
        return found
    }

    /// `## Some Heading` lines with their level, for the outline.
    static func headings(_ source: String) -> [(level: Int, text: String)] {
        var out: [(Int, String)] = []
        var fenced = false
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced, line.hasPrefix("#") else { continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard hashes <= 6, line.dropFirst(hashes).first == " " else { continue }
            out.append((hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }
}
