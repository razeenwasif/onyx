import AppKit
import SwiftUI

extension NSAttributedString.Key {
    // Logical formatting, kept beside the AppKit attributes it produces. Font
    // traits cannot be read back reliably (a handwriting face may have no
    // bold), and the stored colour must survive dark-mode display changes.
    static let scribeFamily = NSAttributedString.Key("scribe.family")
    static let scribeSize = NSAttributedString.Key("scribe.size")
    static let scribeBold = NSAttributedString.Key("scribe.bold")
    static let scribeItalic = NSAttributedString.Key("scribe.italic")
    static let scribeColor = NSAttributedString.Key("scribe.color")
}

/// Font names written to the file are logical and shared with the Windows
/// app, so a page formatted on one platform reads sensibly on the other.
enum ScribeFonts {
    struct Choice: Identifiable, Hashable {
        let name: String
        let label: String
        var id: String { name }
    }

    static let choices: [Choice] = [
        Choice(name: "Segoe UI", label: "Rounded"),
        Choice(name: "Handwritten", label: "Handwritten"),
        Choice(name: "Georgia", label: "Georgia"),
        Choice(name: "Cascadia Code", label: "Monospace"),
        Choice(name: "Arial", label: "Arial"),
        Choice(name: "Times New Roman", label: "Times New Roman"),
        Choice(name: "Comic Sans MS", label: "Comic Sans"),
    ]

    static let sizes: [Double] = [11, 12, 13, 14, 15, 16, 18, 20, 24, 28, 32, 40]

    static func label(for family: String) -> String {
        choices.first { $0.name.caseInsensitiveCompare(canonical(family)) == .orderedSame }?.label ?? family
    }

    /// Folds Windows-specific names onto the logical ones.
    static func canonical(_ family: String) -> String {
        switch family.lowercased() {
        case "", "system", "segoe ui", "sf pro", ".appleSystemUIFont".lowercased(): "Segoe UI"
        case "handwritten", "segoe print", "ink free", "segoe script", "noteworthy", "cursive": "Handwritten"
        case "cascadia code", "cascadia mono", "consolas", "menlo", "sf mono", "monospace": "Cascadia Code"
        default: family
        }
    }

    static func font(family: String, size: Double, bold: Bool, italic: Bool) -> NSFont {
        let size = CGFloat(max(size, 4))
        var font: NSFont
        switch canonical(family) {
        case "Segoe UI":
            // The system face in its rounded cut, to match the velvet UI.
            let plain = NSFont.systemFont(ofSize: size)
            font = plain.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? plain
        case "Handwritten":
            font = NSFont(name: bold ? "Noteworthy-Bold" : "Noteworthy-Light", size: size)
                ?? NSFont(name: "Bradley Hand", size: size)
                ?? .systemFont(ofSize: size)
        case "Cascadia Code":
            font = .monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont(name: family, size: size)
                ?? .systemFont(ofSize: size)
        }
        let fm = NSFontManager.shared
        if bold, canonical(family) != "Handwritten" { font = fm.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
}

/// Formatting of a run of text, in the file's terms.
struct TextStyle: Equatable {
    var family: String
    var size: Double
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikethrough: Bool
    var color: String

    init(box d: TextBoxDTO) {
        family = d.fontFamily
        size = d.fontSize
        bold = d.bold
        italic = d.italic
        underline = d.underline
        strikethrough = d.strikethrough
        color = d.color
    }

    func applying(_ s: TextSpanDTO) -> TextStyle {
        var t = self
        if let v = s.fontFamily { t.family = v }
        if let v = s.fontSize { t.size = v }
        if let v = s.bold { t.bold = v }
        if let v = s.italic { t.italic = v }
        if let v = s.underline { t.underline = v }
        if let v = s.strikethrough { t.strikethrough = v }
        if let v = s.color { t.color = v }
        return t
    }

    init(attributes a: [NSAttributedString.Key: Any], fallback: TextStyle) {
        family = a[.scribeFamily] as? String ?? fallback.family
        size = a[.scribeSize] as? Double ?? fallback.size
        bold = a[.scribeBold] as? Bool ?? fallback.bold
        italic = a[.scribeItalic] as? Bool ?? fallback.italic
        underline = (a[.underlineStyle] as? Int ?? 0) != 0
        strikethrough = (a[.strikethroughStyle] as? Int ?? 0) != 0
        color = a[.scribeColor] as? String ?? fallback.color
    }

    func attributes(dark: Bool) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.12
        let font = ScribeFonts.font(family: family, size: size, bold: bold, italic: italic)
        // Some faces (SF Rounded among them) have no italic; slant instead.
        let slant = italic && !font.fontDescriptor.symbolicTraits.contains(.italic) ? 0.2 : 0
        return [
            .obliqueness: slant,
            .font: font,
            .foregroundColor: InkPaint.color(hex: color, highlighter: false, dark: dark),
            .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: strikethrough ? NSUnderlineStyle.single.rawValue : 0,
            .paragraphStyle: para,
            .scribeFamily: family,
            .scribeSize: size,
            .scribeBold: bold,
            .scribeItalic: italic,
            .scribeColor: color,
        ]
    }

    /// A span holding only the attributes that differ from `base`.
    func span(over base: TextStyle, range: NSRange) -> TextSpanDTO? {
        guard self != base else { return nil }
        return TextSpanDTO(
            start: range.location,
            length: range.length,
            bold: bold != base.bold ? bold : nil,
            italic: italic != base.italic ? italic : nil,
            underline: underline != base.underline ? underline : nil,
            strikethrough: strikethrough != base.strikethrough ? strikethrough : nil,
            fontSize: size != base.size ? size : nil,
            fontFamily: family != base.family ? family : nil,
            color: color != base.color ? color : nil
        )
    }
}

enum RichText {
    static func build(_ d: TextBoxDTO, dark: Bool) -> NSAttributedString {
        let base = TextStyle(box: d)
        let s = NSMutableAttributedString(string: d.text, attributes: base.attributes(dark: dark))
        let length = s.length
        for span in d.spans ?? [] {
            // Hand-edited or stale offsets are clipped rather than trusted.
            let start = min(max(span.start, 0), length)
            let len = min(max(span.length, 0), length - start)
            guard len > 0 else { continue }
            s.setAttributes(base.applying(span).attributes(dark: dark), range: NSRange(location: start, length: len))
        }
        return s
    }

    /// Spans describing where `s` differs from the box's own formatting.
    static func spans(of s: NSAttributedString, base: TextStyle) -> [TextSpanDTO] {
        var out: [TextSpanDTO] = []
        var current: (TextStyle, NSRange)?

        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            let style = TextStyle(attributes: attrs, fallback: base)
            if let (cs, cr) = current, cs == style, NSMaxRange(cr) == range.location {
                current = (cs, NSRange(location: cr.location, length: cr.length + range.length))
            } else {
                if let (cs, cr) = current, let span = cs.span(over: base, range: cr) { out.append(span) }
                current = (style, range)
            }
        }
        if let (cs, cr) = current, let span = cs.span(over: base, range: cr) { out.append(span) }
        return out
    }

    /// Re-paints colours for the theme without touching the stored ones.
    static func recolor(_ storage: NSTextStorage, dark: Bool) {
        storage.beginEditing()
        storage.enumerateAttribute(.scribeColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let hex = value as? String ?? "#1A1A1A"
            storage.addAttribute(.foregroundColor, value: InkPaint.color(hex: hex, highlighter: false, dark: dark), range: range)
        }
        storage.endEditing()
    }
}

/// What the formatting bar shows for the current selection.
struct TextFormatState: Equatable {
    var active = false
    /// The text box being edited.
    var itemID: String?
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var family = "Segoe UI"
    var size: Double = 15
    var heading = "body"
    var color = "#1A1A1A"
}

/// Heading presets apply to a whole text box.
enum HeadingPreset: String, CaseIterable, Identifiable {
    case body, title, h1, h2, h3, handwritten

    var id: String { rawValue }

    var label: String {
        switch self {
        case .body: "Body"
        case .title: "Title"
        case .h1: "Heading 1"
        case .h2: "Heading 2"
        case .h3: "Heading 3"
        case .handwritten: "Handwritten"
        }
    }

    /// (family, size, bold). Sizes match the Windows app.
    var style: (String, Double, Bool) {
        switch self {
        case .title: ("Georgia", 24, true)
        case .h1: ("Segoe UI", 20, true)
        case .h2: ("Segoe UI", 16, true)
        case .h3: ("Segoe UI", 14, true)
        case .body: ("Segoe UI", 14, false)
        case .handwritten: ("Handwritten", 16, false)
        }
    }
}

/// The text view inside a text box.
final class ScribeTextView: NSTextView {
    weak var item: TextBoxItem?
    weak var page: PageModel?
    weak var app: AppModel?
    var dark = true

    /// Pulls the view's text and formatting into the model.
    func flush() {
        guard let item, let storage = textStorage else { return }
        let text = storage.string
        let spans = RichText.spans(of: storage, base: TextStyle(box: item.dto))
        let newSpans = spans.isEmpty ? nil : spans
        guard text != item.dto.text || newSpans != item.dto.spans else { return }
        item.dto.text = text
        item.dto.spans = newSpans
        // Rich text from the Windows app describes the old text; keeping it
        // would make that app show stale content.
        item.dto.xaml = nil
    }

    /// Pasting into a text box takes the text and leaves foreign formatting.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// Escape ends editing and hands the keyboard back to the page, so the
    /// tool keys work again.
    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(app?.canvas?.inkView)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            app?.activeTextView = self
            publishFormat()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            flush()
            if app?.activeTextView === self {
                app?.activeTextView = nil
                app?.textFormat.active = false
            }
            if let item, let page {
                DispatchQueue.main.async { page.discardIfEmpty(item) }
            }
        }
        return ok
    }

    func publishFormat() {
        guard let app, let item else { return }
        let base = TextStyle(box: item.dto)
        let loc = min(selectedRange().location, max((textStorage?.length ?? 0) - 1, 0))
        let attrs: [NSAttributedString.Key: Any] = (textStorage?.length ?? 0) > 0 && selectedRange().length > 0
            ? textStorage!.attributes(at: loc, effectiveRange: nil)
            : typingAttributes
        let st = TextStyle(attributes: attrs, fallback: base)
        app.textFormat = TextFormatState(
            active: true, itemID: item.dto.id, bold: st.bold, italic: st.italic, underline: st.underline, strikethrough: st.strikethrough,
            family: st.family, size: st.size, heading: item.dto.heading ?? "body", color: st.color
        )
    }

    // ------------------------------------------------------------ formatting

    /// Applies a change to the selection, or to the whole box when nothing is
    /// selected, as one undoable text edit.
    func format(_ change: (inout TextStyle) -> Void) {
        guard let item, let storage = textStorage else { return }
        let base = TextStyle(box: item.dto)
        var range = selectedRange()
        let whole = range.length == 0
        if whole { range = NSRange(location: 0, length: storage.length) }

        if whole {
            // The box's own style changes, so later typing and spans agree.
            var b = base
            change(&b)
            item.dto.fontFamily = b.family
            item.dto.fontSize = b.size
            item.dto.bold = b.bold
            item.dto.italic = b.italic
            item.dto.underline = b.underline
            item.dto.strikethrough = b.strikethrough
            item.dto.color = b.color
        }

        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attrs, r, _ in
                var st = TextStyle(attributes: attrs, fallback: base)
                change(&st)
                storage.setAttributes(st.attributes(dark: dark), range: r)
            }
            storage.endEditing()
            didChangeText()
        }

        var typing = TextStyle(attributes: typingAttributes, fallback: base)
        change(&typing)
        typingAttributes = typing.attributes(dark: dark)
        flush()
        publishFormat()
        page?.contentChanged()
    }

    func applyHeading(_ preset: HeadingPreset) {
        guard let item, let storage = textStorage else { return }
        let (family, size, bold) = preset.style
        item.dto.heading = preset.rawValue
        item.dto.fontFamily = family
        item.dto.fontSize = size
        item.dto.bold = bold
        item.dto.italic = false

        let all = NSRange(location: 0, length: storage.length)
        let base = TextStyle(box: item.dto)
        if all.length > 0, shouldChangeText(in: all, replacementString: nil) {
            storage.setAttributes(base.attributes(dark: dark), range: all)
            didChangeText()
        }
        typingAttributes = base.attributes(dark: dark)
        flush()
        publishFormat()
        page?.contentChanged()
    }
}

/// SwiftUI wrapper for a text box's editor.
struct RichTextEditor: NSViewRepresentable {
    let app: AppModel
    let page: PageModel
    let item: TextBoxItem
    let dark: Bool
    let width: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScribeTextView {
        let tv = ScribeTextView(usingTextLayoutManager: false)
        tv.item = item
        tv.page = page
        tv.app = app
        tv.dark = dark
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 2, height: 3)
        tv.textContainer?.lineFragmentPadding = 2
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.insertionPointColor = Palette.of(dark: dark).accent
        tv.textStorage?.setAttributedString(RichText.build(item.dto, dark: dark))
        tv.typingAttributes = TextStyle(box: item.dto).attributes(dark: dark)
        context.coordinator.measure(tv)
        return tv
    }

    func updateNSView(_ tv: ScribeTextView, context: Context) {
        tv.item = item
        if tv.dark != dark {
            tv.dark = dark
            tv.insertionPointColor = Palette.of(dark: dark).accent
            if let storage = tv.textStorage { RichText.recolor(storage, dark: dark) }
            tv.typingAttributes = TextStyle(attributes: tv.typingAttributes, fallback: TextStyle(box: item.dto)).attributes(dark: dark)
        }

        // The model changed underneath the view (undo of a paste, a reload).
        if !tv.hasMarkedText(), tv.window?.firstResponder !== tv, tv.string != item.dto.text {
            tv.textStorage?.setAttributedString(RichText.build(item.dto, dark: dark))
        }

        context.coordinator.measure(tv)

        if page.focusRequest == item.dto.id {
            DispatchQueue.main.async {
                guard page.focusRequest == item.dto.id else { return }
                page.focusRequest = nil
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }

    static func dismantleNSView(_ tv: ScribeTextView, coordinator: Coordinator) {
        // Typing undo steps target this view; once it is gone they must not
        // be replayed.
        tv.undoManager?.removeAllActions(withTarget: tv)
        if let storage = tv.textStorage { tv.undoManager?.removeAllActions(withTarget: storage) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? ScribeTextView else { return }
            tv.flush()
            measure(tv)
            tv.page?.contentChanged()
        }

        func textViewDidChangeSelection(_ note: Notification) {
            (note.object as? ScribeTextView)?.publishFormat()
        }

        func measure(_ tv: ScribeTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer, let item = tv.item else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let lineFallback = TextStyle(box: item.dto).size * 1.5
            let h = ceil(max(used, lineFallback) + tv.textContainerInset.height * 2)
            if abs(item.measuredHeight - h) > 0.5 {
                DispatchQueue.main.async { item.measuredHeight = h }
            }
        }
    }
}
