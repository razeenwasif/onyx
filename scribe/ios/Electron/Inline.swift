import SwiftUI
import UIKit

/// A run of a paragraph: styled text, or a formula drawn as an image.
enum InlinePiece {
    case text(AttributedString)
    case math(String, display: Bool)
    case image(alt: String, source: String)
}

/// Inline Markdown → pieces: emphasis, `code`, links, `[[wikilinks]]`,
/// `#tags`, `==highlights==`, `~~strikes~~`, `$math$` and a little HTML.
enum Inline {
    /// Links inside the app: `electron://note?t=<target>` and `…/tag?t=`.
    static func noteURL(_ target: String) -> URL? {
        var c = URLComponents()
        c.scheme = "electron"; c.host = "note"
        c.queryItems = [URLQueryItem(name: "t", value: target)]
        return c.url
    }

    static func tagURL(_ tag: String) -> URL? {
        var c = URLComponents()
        c.scheme = "electron"; c.host = "tag"
        c.queryItems = [URLQueryItem(name: "t", value: tag)]
        return c.url
    }

    struct Style {
        var intents: InlinePresentationIntent = []
        var link: URL?
        var color: Color?
        var background: Color?
    }

    static func parse(_ source: String, style: Style = Style()) -> [InlinePiece] {
        var parser = Parser(chars: Array(source))
        return merge(parser.run(style))
    }

    /// Joins neighbouring text pieces so Text concatenation stays shallow.
    private static func merge(_ pieces: [InlinePiece]) -> [InlinePiece] {
        var out: [InlinePiece] = []
        for p in pieces {
            if case .text(let t) = p, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + t)
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// Plain text of inline Markdown, for titles and outlines.
    static func plain(_ source: String) -> String {
        parse(source).map {
            switch $0 {
            case .text(let t): String(t.characters)
            case .math(let m, _): m
            case .image(let alt, _): alt
            }
        }.joined()
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(chars: [Character]) { self.chars = chars }

        mutating func run(_ style: Style) -> [InlinePiece] {
            parseUntil(nil, style)
        }

        private func at(_ k: Int) -> Character? { k < chars.count && k >= 0 ? chars[k] : nil }

        private func starts(_ s: String, at k: Int) -> Bool {
            var j = k
            for c in s { guard at(j) == c else { return false }; j += 1 }
            return true
        }

        /// Index of `s` at or after `from`, not past a closing `]` boundary.
        private func find(_ s: String, from: Int, sameLine: Bool = false) -> Int? {
            var j = from
            while j < chars.count {
                if sameLine, chars[j] == "\n" { return nil }
                if chars[j] == "\\" { j += 2; continue }
                if starts(s, at: j) { return j }
                j += 1
            }
            return nil
        }

        private func text(_ s: String, _ style: Style) -> InlinePiece {
            var a = AttributedString(s)
            if !style.intents.isEmpty { a.inlinePresentationIntent = style.intents }
            if let link = style.link { a.link = link }
            if let color = style.color { a.foregroundColor = color }
            if let bg = style.background { a.backgroundColor = bg }
            return .text(a)
        }

        private static func isWord(_ c: Character?) -> Bool {
            guard let c else { return false }
            return c.isLetter || c.isNumber || c == "_"
        }

        /// Parses until `close` (consumed) or the end.
        mutating func parseUntil(_ close: String?, _ style: Style) -> [InlinePiece] {
            var out: [InlinePiece] = []
            var buf = ""
            func flush() {
                if !buf.isEmpty { out.append(text(buf, style)); buf = "" }
            }
            while i < chars.count {
                if let close, starts(close, at: i) {
                    i += close.count
                    flush()
                    return out
                }
                let c = chars[i]
                switch c {
                case "\\":
                    if let n = at(i + 1), n.isPunctuation || n.isSymbol {
                        buf.append(n); i += 2
                    } else { buf.append(c); i += 1 }

                case "`":
                    let run = chars[i...].prefix { $0 == "`" }.count
                    let fence = String(repeating: "`", count: run)
                    if let end = find(fence, from: i + run) {
                        flush()
                        let code = String(chars[(i + run)..<end]).trimmingCharacters(in: .whitespaces)
                        var s = style
                        s.intents.insert(.code)
                        s.color = .evCode
                        s.background = Color(uiColor: EV.codeBg)
                        out.append(text(code, s))
                        i = end + run
                    } else { buf += fence; i += run }

                case "$":
                    if at(i + 1) == "$", let end = find("$$", from: i + 2) {
                        flush()
                        out.append(.math(String(chars[(i + 2)..<end]), display: true))
                        i = end + 2
                    } else if let n = at(i + 1), n != " ", n != "$",
                              let end = closingDollar(from: i + 1) {
                        flush()
                        out.append(.math(String(chars[(i + 1)..<end]), display: false))
                        i = end + 1
                    } else { buf.append(c); i += 1 }

                case "!" where at(i + 1) == "[":
                    if at(i + 2) == "[", let end = find("]]", from: i + 3, sameLine: true) {
                        flush()
                        let (target, alias) = NoteParse.splitAlias(String(chars[(i + 3)..<end]))
                        if VaultNode.kind(of: NoteParse.noteName(target)) == .image {
                            out.append(.image(alt: alias ?? target, source: "vault:" + target))
                        } else {
                            var s = style
                            s.link = noteURL(target)
                            out.append(text(alias ?? target, s))
                        }
                        i = end + 2
                    } else if let (alt, dest, next) = linkParts(from: i + 1) {
                        flush()
                        out.append(.image(alt: alt, source: dest))
                        i = next
                    } else { buf.append(c); i += 1 }

                case "[":
                    if at(i + 1) == "[", let end = find("]]", from: i + 2, sameLine: true) {
                        flush()
                        let (target, alias) = NoteParse.splitAlias(String(chars[(i + 2)..<end]))
                        var s = style
                        s.link = noteURL(target)
                        if ScribeLink(target: target) != nil {
                            // A Scribe page: in Scribe's colour, never its id.
                            s.color = .velvetAccent
                            out.append(text(alias ?? "Scribe page", s))
                        } else {
                            out.append(text(alias ?? Self.shown(target), s))
                        }
                        i = end + 2
                    } else if let (label, dest, next) = linkParts(from: i) {
                        flush()
                        var s = style
                        if let local = NoteParse.localTarget(dest) { s.link = noteURL(local) }
                        else { s.link = URL(string: dest) ?? URL(string: dest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") }
                        var sub = Parser(chars: Array(label))
                        out.append(contentsOf: sub.run(s))
                        i = next
                    } else { buf.append(c); i += 1 }

                case "*", "_":
                    let double = at(i + 1) == c
                    let marker = double ? String([c, c]) : String(c)
                    // `_` inside words (snake_case) isn't emphasis.
                    let opens = at(i + marker.count).map { !$0.isWhitespace } ?? false
                        && (c == "*" || !Self.isWord(at(i - 1)))
                    if opens, let end = closer(marker, from: i + marker.count) {
                        flush()
                        var s = style
                        s.intents.insert(double ? .stronglyEmphasized : .emphasized)
                        var sub = Parser(chars: Array(chars[(i + marker.count)..<end]))
                        out.append(contentsOf: sub.run(s))
                        i = end + marker.count
                    } else { buf += marker; i += marker.count }

                case "~" where at(i + 1) == "~":
                    if let end = find("~~", from: i + 2) {
                        flush()
                        var s = style
                        s.intents.insert(.strikethrough)
                        var sub = Parser(chars: Array(chars[(i + 2)..<end]))
                        out.append(contentsOf: sub.run(s))
                        i = end + 2
                    } else { buf += "~~"; i += 2 }

                case "=" where at(i + 1) == "=":
                    if let end = find("==", from: i + 2), end > i + 2 {
                        flush()
                        var s = style
                        s.background = Color(uiColor: EV.highlight)
                        var sub = Parser(chars: Array(chars[(i + 2)..<end]))
                        out.append(contentsOf: sub.run(s))
                        i = end + 2
                    } else { buf += "=="; i += 2 }

                case "#":
                    let prev = at(i - 1)
                    if (prev == nil || !(Self.isWord(prev) || prev == "&")), let n = at(i + 1), n.isLetter, n.isASCII {
                        var j = i + 1
                        while let ch = at(j), Self.isWord(ch) || ch == "/" || ch == "-" { j += 1 }
                        flush()
                        let tag = String(chars[(i + 1)..<j])
                        var s = style
                        s.color = .evTagText
                        s.link = tagURL(tag)
                        out.append(text("#" + tag, s))
                        i = j
                    } else { buf.append(c); i += 1 }

                case "<":
                    if let end = find(">", from: i + 1, sameLine: true) {
                        let inner = String(chars[(i + 1)..<end])
                        if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                            flush()
                            var s = style
                            s.link = URL(string: inner)
                            out.append(text(inner, s))
                            i = end + 1
                        } else if inner.range(of: #"^/?[A-Za-z][A-Za-z0-9]*(\s[^>]*)?/?$"#, options: .regularExpression) != nil {
                            // HTML: line breaks kept, other tags dropped.
                            if inner.lowercased().hasPrefix("br") { buf.append("\n") }
                            i = end + 1
                        } else { buf.append(c); i += 1 }
                    } else { buf.append(c); i += 1 }

                case "h" where starts("https://", at: i) || starts("http://", at: i):
                    guard !Self.isWord(at(i - 1)) else { buf.append(c); i += 1; break }
                    var j = i
                    while let ch = at(j), !ch.isWhitespace, ch != ">", ch != "<" { j += 1 }
                    while let ch = at(j - 1), ".,;:!?)".contains(ch) { j -= 1 }
                    flush()
                    let url = String(chars[i..<j])
                    var s = style
                    s.link = URL(string: url)
                    out.append(text(url, s))
                    i = j

                case "&":
                    if let end = find(";", from: i + 1, sameLine: true), end - i < 10,
                       let entity = Self.entities[String(chars[(i + 1)..<end])] {
                        buf.append(entity); i = end + 1
                    } else { buf.append(c); i += 1 }

                default:
                    buf.append(c); i += 1
                }
            }
            flush()
            return out
        }

        private static let entities: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "nbsp": "\u{00A0}", "#39": "'", "apos": "'",
        ]

        /// `[[Folder/Note#Heading]]` shows as `Note > Heading`.
        static func shown(_ target: String) -> String {
            var name = NoteParse.noteName(target)
            name = (name as NSString).lastPathComponent
            if let h = NoteParse.heading(target) { return name.isEmpty ? h : "\(name) > \(h)" }
            return name
        }

        /// A closing `$` for inline math: not after a space, not before a digit.
        private func closingDollar(from start: Int) -> Int? {
            var j = start
            while j < chars.count {
                let ch = chars[j]
                if ch == "\n", at(j + 1) == "\n" { return nil }
                if ch == "\\" { j += 2; continue }
                if ch == "$" {
                    if let p = at(j - 1), p.isWhitespace { return nil }
                    if let n = at(j + 1), n.isNumber { return nil }
                    return j
                }
                j += 1
            }
            return nil
        }

        /// The end of an emphasis run: `marker` not preceded by a space.
        private func closer(_ marker: String, from start: Int) -> Int? {
            var j = start
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "`", let end = find("`", from: j + 1) { j = end + 1; continue }
                if starts(marker, at: j), j > start, let p = at(j - 1), !p.isWhitespace {
                    // `**` must not be the start of a longer run for single `*`.
                    if marker.count == 1, at(j + 1) == marker.first {
                        j += 2
                        continue
                    }
                    if marker == "_", Self.isWord(at(j + 1)) { j += 1; continue }
                    return j
                }
                j += 1
            }
            return nil
        }

        /// `[label](dest "title")` starting at the `[`.
        private func linkParts(from k: Int) -> (String, String, Int)? {
            guard at(k) == "[" else { return nil }
            var depth = 0
            var j = k
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "[" { depth += 1 }
                if chars[j] == "]" { depth -= 1; if depth == 0 { break } }
                if chars[j] == "\n", at(j + 1) == "\n" { return nil }
                j += 1
            }
            guard j < chars.count, at(j + 1) == "(" else { return nil }
            let label = String(chars[(k + 1)..<j])
            var e = j + 2
            var paren = 1
            var angle = at(e) == "<"
            while e < chars.count {
                let ch = chars[e]
                if angle, ch == ">" { angle = false }
                else if !angle, ch == "(" { paren += 1 }
                else if !angle, ch == ")" { paren -= 1; if paren == 0 { break } }
                else if ch == "\n" { return nil }
                e += 1
            }
            guard e < chars.count else { return nil }
            var dest = String(chars[(j + 2)..<e]).trimmingCharacters(in: .whitespaces)
            if dest.hasPrefix("<"), let close = dest.firstIndex(of: ">") {
                dest = String(dest[dest.index(after: dest.startIndex)..<close])
            } else if let space = dest.firstIndex(of: " ") {
                dest = String(dest[..<space])
            }
            return (label, dest, e + 1)
        }
    }
}

extension Text {
    /// Pieces as one Text, with formulas drawn inline on the baseline.
    @MainActor
    static func pieces(_ pieces: [InlinePiece], size: CGFloat) -> Text {
        var result = Text(verbatim: "")
        for piece in pieces {
            let next: Text
            switch piece {
            case .text(let a):
                next = Text(a)
            case .math(let latex, let display):
                if let r = MathRender.render(latex, size: size * 1.08, display: display) {
                    next = Text(Image(uiImage: r.image)).baselineOffset(-r.descent)
                } else {
                    next = Text(verbatim: "$\(latex)$").font(.system(size: size * 0.9, design: .monospaced)).foregroundColor(.evCode)
                }
            case .image(let alt, _):
                next = Text(verbatim: alt.isEmpty ? "" : "[\(alt)]").foregroundColor(.evDim)
            }
            result = Text("\(result)\(next)")
        }
        return result
    }
}
