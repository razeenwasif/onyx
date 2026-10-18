import SwiftMath
import UIKit

/// LaTeX drawn natively with SwiftMath, cached by formula and size. Notes
/// are written for KaTeX/MathJax, so a few commands SwiftMath lacks are
/// rewritten first.
@MainActor
enum MathRender {
    struct Rendered {
        let image: UIImage
        /// Points below the baseline, to line inline math up with text.
        let descent: CGFloat
    }

    private static var cache: [String: Rendered] = [:]
    private static var failures: Set<String> = []

    static func render(_ latex: String, size: CGFloat, display: Bool, color: UIColor = EV.fg) -> Rendered? {
        let key = "\(display ? "D" : "I")\(size)|\(latex)"
        if let hit = cache[key] { return hit }
        if failures.contains(key) { return nil }
        func draw(_ loose: Bool) -> (UIImage, MathImage.LayoutInfo)? {
            var math = MathImage(latex: prepare(latex, display: display, loose: loose), fontSize: size, textColor: color,
                                 labelMode: display ? .display : .text, textAlignment: display ? .center : .left)
            math.font = .latinModernFont
            let (error, image, info) = math.asImage()
            guard error == nil, let image, let info, image.size.width > 0 else { return nil }
            return (image, info)
        }
        guard let (image, info) = draw(false) ?? draw(true) else {
            failures.insert(key)
            return nil
        }
        let rendered = Rendered(image: image, descent: info.descent)
        if cache.count > 600 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }

    /// Rewrites what KaTeX accepts and SwiftMath doesn't. `loose` is the
    /// second try: alignment marks dropped, so over-wide `aligned` and
    /// `cases` blocks still draw.
    static func prepare(_ latex: String, display: Bool, loose: Bool = false) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        // KaTeX's built-in macros and the commands SwiftMath lacks.
        let swaps: [(String, String)] = [
            (#"(\\[A-Za-z]+)(?=[^\x00-\x7F])"#, "$1 "),
            (#"\\(boldsymbol|bold|bm|textbf)(?![A-Za-z])"#, #"\\mathbf"#), (#"\\textit(?![A-Za-z])"#, #"\\mathit"#),
            (#"\\[dt]frac(?![A-Za-z])"#, #"\\frac"#),
            (#"\\(displaystyle|textstyle|scriptstyle|large|Large|LARGE|huge|Huge|small|normalsize|nonumber|notag|boxed|underbrace|overbrace|limits|nolimits)(?![A-Za-z])"#, ""),
            (#"\\(big|Big|bigg|Bigg)[lrm]?(?![A-Za-z])"#, ""),
            (#"\\(tag\*?|label|hspace\*?|vspace\*?)\{[^}]*\}"#, " "), (#"\\hspace\d+\w*"#, " "),
            (#"\\operatorname\*?\{([^}]*)\}"#, #"\\mathrm{$1}"#), (#"\\mathrm\{d\}"#, "d"),
            (#"\\begin\{(equation\*?|displaymath)\}|\\end\{(equation\*?|displaymath)\}"#, ""),
            (#"\\begin\{(align\*?|alignat\*?|flalign\*?|split|multline\*?)\}(\{[^}]*\})*"#, #"\\begin{aligned}"#),
            (#"\\end\{(align\*?|alignat\*?|flalign\*?|split|multline\*?)\}(\{[^}]*\})*"#, #"\\end{aligned}"#),
            (#"\\begin\{gather\*\}"#, #"\\begin{gather}"#), (#"\\end\{gather\*\}"#, #"\\end{gather}"#),
            (#"\\R(?![A-Za-z])"#, #"\\mathbb{R}"#), (#"\\N(?![A-Za-z])"#, #"\\mathbb{N}"#), (#"\\Z(?![A-Za-z])"#, #"\\mathbb{Z}"#),
            (#"\\Q(?![A-Za-z])"#, #"\\mathbb{Q}"#), (#"\\C(?![A-Za-z])"#, #"\\mathbb{C}"#),
            (#"\\implies(?![A-Za-z])"#, #"\\Rightarrow"#), (#"\\impliedby(?![A-Za-z])"#, #"\\Leftarrow"#), (#"\\iff(?![A-Za-z])"#, #"\\Leftrightarrow"#),
            (#"\\dots[bcimo]?(?![A-Za-z])"#, #"\\ldots"#), (#"\\sube(?![A-Za-z])"#, #"\\subseteq"#), (#"\\supe(?![A-Za-z])"#, #"\\supseteq"#),
            (#"\\sub(?![A-Za-z])"#, #"\\subset"#),
            (#"\\therefore(?![A-Za-z])"#, "∴"), (#"\\because(?![A-Za-z])"#, "∵"), (#"\\blacksquare(?![A-Za-z])"#, "■"), (#"\\square(?![A-Za-z])"#, "□"),
            (#"\\succeq(?![A-Za-z])"#, "⪰"), (#"\\preceq(?![A-Za-z])"#, "⪯"), (#"\\succ(?![A-Za-z])"#, "≻"), (#"\\prec(?![A-Za-z])"#, "≺"),
            (#"\\gt(?![A-Za-z])"#, ">"), (#"\\lt(?![A-Za-z])"#, "<"), (#"\\space(?![A-Za-z])"#, "~"), (#"\\newline(?![A-Za-z])"#, #"\\\\"#),
            (#"\\lVert\b|\\rVert(?![A-Za-z])"#, #"\\|"#), (#"\\lvert\b|\\rvert(?![A-Za-z])"#, "|"),
            (#"\\coloneqq(?![A-Za-z])"#, ":="), (#"\\eqqcolon(?![A-Za-z])"#, "=:"),
            (#"\\(it|rm|bf|footnotesize|scriptsize|tiny)(?![A-Za-z])"#, ""), (#"\\emph(?![A-Za-z])"#, #"\\mathit"#),
            (#"\\empty(?![A-Za-z])"#, #"\\emptyset"#), (#"\\infin(?![A-Za-z])"#, #"\\infty"#), (#"\\exist(?![A-Za-z])"#, #"\\exists"#),
            (#"\\and(?![A-Za-z])"#, #"\\land"#), (#"\\mod(?![A-Za-z])"#, #"~\\mathrm{mod}~"#), (#"\\pmod\{([^}]*)\}"#, #"~(\\mathrm{mod}~$1)"#),
            (#"\\x(right|left)arrow(\[[^\]]*\])?"#, #"\\$1arrow"#), (#"\\not\s*="#, #"\\neq"#), (#"\\not(?![A-Za-z])"#, ""),
            (#"\\nleq(?![A-Za-z])"#, "≰"), (#"\\ngeq(?![A-Za-z])"#, "≱"), (#"\\lll(?![A-Za-z])"#, "⋘"), (#"\\ggg(?![A-Za-z])"#, "⋙"),
            (#"\\rightsquigarrow(?![A-Za-z])"#, "⇝"),
            (#"\\begin\{array\}\{[^}]*\}"#, #"\\begin{matrix}"#), (#"\\end\{array\}"#, #"\\end{matrix}"#),
            (#"\\\\\[[^\]]*\]"#, #"\\\\"#),
            (#"(?<!\\)\\ "#, "~"), (#"(?<!\\)\\$"#, ""),
        ]
        for (pattern, template) in swaps {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        if loose {
            s = s.replacingOccurrences(of: #"\\(begin|end)\{(aligned|cases|gather)\}"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(?<!\\)&"#, with: " ", options: .regularExpression)
        }
        // Several lines and no environment: stack them.
        if s.contains(#"\\"#), !s.contains(#"\begin"#) {
            s = s.contains("&") ? #"\begin{aligned}"# + s + #"\end{aligned}"# : #"\begin{gather}"# + s + #"\end{gather}"#
        }
        return s
    }
}
