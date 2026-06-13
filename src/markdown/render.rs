//! Render markdown source into a styled ratatui `Text` for preview.
//!
//! We walk pulldown-cmark events to build styled lines. Block-level handling is
//! intentionally simple — this is a TUI preview, not a typesetter.
//!
//! On top of CommonMark we render two Notion-style block extensions, detected by
//! a line-level pre-pass (`split_blocks`) so they're robust against cmark's
//! inline tokenization:
//! - **Callouts**: `> [!note] Title` / `[!warning]- …` — a styled blockquote
//!   variant with an icon + colored bar; a `-`/`+` marker makes it foldable, and
//!   a foldable callout whose document-order index is in `collapsed` renders as
//!   just its header.
//! - **Columns**: a `::: columns` … `+++` … `:::` block, laid out side-by-side.

use std::collections::HashSet;

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span, Text};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::markdown::parse::{extract_all_tags, extract_links, parse_callout_header, CalloutHeader};
use crate::theme::Theme;

/// Collapsed-default flags for each foldable callout in `source`, in the same
/// document order the renderer assigns fold indices. Length = number of foldable
/// callouts; `out[i] == true` means callout `i` starts collapsed (`-` marker).
/// Used to seed and clamp the preview's fold state.
pub fn foldable_callouts(source: &str) -> Vec<bool> {
    let mut out = Vec::new();
    for seg in split_blocks(source) {
        if let Seg::Callout(h, _) = seg {
            if h.foldable {
                out.push(h.collapsed_default);
            }
        }
    }
    out
}

/// Render with the preview's fold state: foldable callouts whose document-order
/// index is in `collapsed` render as just their header; `selected` highlights
/// one foldable callout's header (the preview's fold cursor).
pub fn render_to_text_with(
    source: &str,
    theme: &Theme,
    width: usize,
    collapsed: &HashSet<usize>,
    selected: Option<usize>,
) -> Text<'static> {
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut fold_idx = 0usize;

    for seg in split_blocks(source) {
        match seg {
            Seg::Normal(text) => render_block_into(&mut lines, &text, theme, width),
            Seg::Callout(h, body) => {
                fold_idx = render_callout(
                    &mut lines, &h, &body, theme, width, collapsed, selected, fold_idx,
                );
            }
            Seg::Cols(cols) => {
                let n = cols.len().max(1);
                let gutter = 3usize; // " │ "
                let col_w = (width.saturating_sub(gutter * n.saturating_sub(1)) / n).max(6);
                let mut rendered: Vec<Vec<Line<'static>>> = Vec::with_capacity(n);
                for c in &cols {
                    let mut cl = Vec::new();
                    render_block_into(&mut cl, c, theme, col_w);
                    while cl.last().map(line_is_blank).unwrap_or(false) {
                        cl.pop();
                    }
                    rendered.push(cl);
                }
                stitch_columns(&mut lines, &rendered, col_w, theme);
                lines.push(Line::raw(""));
            }
        }
    }

    // Tag-chip footer (computed once over the whole source).
    let tags = extract_all_tags(source);
    if !tags.is_empty() {
        lines.push(Line::raw(""));
        let mut spans = vec![Span::styled("tags  ", theme.s_subtle())];
        for (i, t) in tags.iter().enumerate() {
            if i > 0 {
                spans.push(Span::raw("  "));
            }
            spans.push(Span::styled(format!("#{t}"), theme.s_tag()));
        }
        lines.push(Line::from(spans));
    }

    Text::from(lines)
}

fn line_is_blank(l: &Line<'static>) -> bool {
    l.spans.iter().all(|s| s.content.trim().is_empty())
}

// -----------------------------------------------------------------------------
// Block splitting (callouts + columns)
// -----------------------------------------------------------------------------

enum Seg {
    Normal(String),
    Callout(CalloutHeader, String),
    Cols(Vec<String>),
}

/// Strip one level of blockquote marker (`>` + optional space) from a line,
/// preserving any further indentation of the content.
fn strip_one_bq(line: &str) -> &str {
    let s = line.trim_start();
    let s = s.strip_prefix('>').unwrap_or(s);
    s.strip_prefix(' ').unwrap_or(s)
}

fn is_bq_line(line: &str) -> bool {
    line.trim_start().starts_with('>')
}

/// Split source into normal chunks, callout blocks, and `::: columns` blocks.
fn split_blocks(source: &str) -> Vec<Seg> {
    let lines: Vec<&str> = source.lines().collect();
    let mut segs: Vec<Seg> = Vec::new();
    let mut normal = String::new();
    let mut i = 0;

    macro_rules! flush_normal {
        () => {
            if !normal.is_empty() {
                segs.push(Seg::Normal(std::mem::take(&mut normal)));
            }
        };
    }

    while i < lines.len() {
        let t = lines[i].trim();
        if t == "::: columns" || t == ":::columns" {
            flush_normal!();
            let mut cols: Vec<String> = vec![String::new()];
            i += 1;
            while i < lines.len() && lines[i].trim() != ":::" {
                if lines[i].trim() == "+++" {
                    cols.push(String::new());
                } else {
                    let cur = cols.last_mut().unwrap();
                    cur.push_str(lines[i]);
                    cur.push('\n');
                }
                i += 1;
            }
            if i < lines.len() {
                i += 1; // consume closing ":::"
            }
            segs.push(Seg::Cols(cols));
        } else if is_bq_line(lines[i]) {
            // Gather the whole consecutive blockquote run.
            let start = i;
            while i < lines.len() && is_bq_line(lines[i]) {
                i += 1;
            }
            let run = &lines[start..i];
            if let Some(h) = parse_callout_header(strip_one_bq(run[0])) {
                flush_normal!();
                let body = run[1..]
                    .iter()
                    .map(|l| strip_one_bq(l))
                    .collect::<Vec<_>>()
                    .join("\n");
                segs.push(Seg::Callout(h, body));
            } else {
                for l in run {
                    normal.push_str(l);
                    normal.push('\n');
                }
            }
        } else {
            normal.push_str(lines[i]);
            normal.push('\n');
            i += 1;
        }
    }
    flush_normal!();
    segs
}

// -----------------------------------------------------------------------------
// Callouts
// -----------------------------------------------------------------------------

/// Render a callout (header + optional body). Returns the next foldable-callout
/// index (incremented when this callout is foldable).
#[allow(clippy::too_many_arguments)]
fn render_callout(
    out: &mut Vec<Line<'static>>,
    h: &CalloutHeader,
    body: &str,
    theme: &Theme,
    width: usize,
    collapsed: &HashSet<usize>,
    selected: Option<usize>,
    fold_start: usize,
) -> usize {
    let (icon, color) = callout_visual(&h.kind, theme);
    let mut next = fold_start;
    let mut is_collapsed = false;
    let mut is_selected = false;
    let mut glyph = String::new();
    if h.foldable {
        let idx = next;
        next += 1;
        is_collapsed = collapsed.contains(&idx);
        is_selected = selected == Some(idx);
        glyph = if is_collapsed { "▸ ".into() } else { "▾ ".into() };
    }
    let label = if h.title.is_empty() {
        capitalize(&h.kind)
    } else {
        h.title.clone()
    };
    let icon_part = if icon.is_empty() {
        String::new()
    } else {
        format!("{icon} ")
    };
    let header_style = if is_selected {
        theme.s_selection()
    } else {
        color.add_modifier(Modifier::BOLD)
    };
    out.push(Line::from(vec![
        Span::styled("▎ ".to_string(), color),
        Span::styled(format!("{glyph}{icon_part}{label}"), header_style),
    ]));

    if !is_collapsed && !body.trim().is_empty() {
        let mut body_lines = Vec::new();
        render_block_into(&mut body_lines, body, theme, width.saturating_sub(2).max(4));
        while body_lines.last().map(line_is_blank).unwrap_or(false) {
            body_lines.pop();
        }
        for bl in body_lines {
            let mut spans = vec![Span::styled("▎ ".to_string(), color)];
            spans.extend(bl.spans);
            out.push(Line::from(spans));
        }
    }
    out.push(Line::raw(""));
    next
}

/// Icon + accent style for a callout type (Obsidian's vocabulary).
fn callout_visual(kind: &str, theme: &Theme) -> (&'static str, Style) {
    let (icon, color) = match kind {
        "note" | "info" | "abstract" | "summary" | "tldr" => ("ℹ", theme.info.to_color()),
        "tip" | "hint" | "important" => ("✦", theme.accent_alt.to_color()),
        "success" | "check" | "done" => ("✓", theme.success.to_color()),
        "question" | "help" | "faq" => ("", theme.warning.to_color()),
        "warning" | "caution" | "attention" => ("⚠", theme.warning.to_color()),
        "failure" | "fail" | "missing" => ("✗", theme.error.to_color()),
        "danger" | "error" | "bug" => ("⛔", theme.error.to_color()),
        "example" => ("❖", theme.accent.to_color()),
        "quote" | "cite" => ("❝", theme.fg_subtle.to_color()),
        "todo" => ("☐", theme.accent.to_color()),
        _ => ("◆", theme.accent.to_color()),
    };
    (icon, Style::default().fg(color))
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

// -----------------------------------------------------------------------------
// Columns
// -----------------------------------------------------------------------------

/// Lay rendered columns out side-by-side, padding/clipping each to `col_w`.
fn stitch_columns(out: &mut Vec<Line<'static>>, cols: &[Vec<Line<'static>>], col_w: usize, theme: &Theme) {
    let rows = cols.iter().map(|c| c.len()).max().unwrap_or(0);
    let blank = Line::raw("");
    for r in 0..rows {
        let mut spans: Vec<Span<'static>> = Vec::new();
        for (ci, col) in cols.iter().enumerate() {
            if ci > 0 {
                spans.push(Span::styled(" │ ", theme.s_subtle()));
            }
            spans.extend(fit_line(col.get(r).unwrap_or(&blank), col_w));
        }
        out.push(Line::from(spans));
    }
}

/// Clone a line's spans, clipped or space-padded to exactly `width` columns.
fn fit_line(line: &Line<'static>, width: usize) -> Vec<Span<'static>> {
    let mut out: Vec<Span<'static>> = Vec::new();
    let mut used = 0usize;
    for span in &line.spans {
        if used >= width {
            break;
        }
        let w = UnicodeWidthStr::width(span.content.as_ref());
        if used + w <= width {
            out.push(span.clone());
            used += w;
        } else {
            let remaining = width - used;
            let mut taken = String::new();
            let mut tw = 0usize;
            for ch in span.content.chars() {
                let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
                if tw + cw > remaining {
                    break;
                }
                taken.push(ch);
                tw += cw;
            }
            used += tw;
            out.push(Span::styled(taken, span.style));
            break;
        }
    }
    if used < width {
        out.push(Span::raw(" ".repeat(width - used)));
    }
    out
}

// -----------------------------------------------------------------------------
// CommonMark block renderer (no block extensions — those are pre-split out)
// -----------------------------------------------------------------------------

fn render_block_into(lines: &mut Vec<Line<'static>>, source: &str, theme: &Theme, width: usize) {
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    opts.insert(Options::ENABLE_TASKLISTS);
    opts.insert(Options::ENABLE_TABLES);
    opts.insert(Options::ENABLE_FOOTNOTES);

    let wikilinks = extract_links(source);
    let mut r = Renderer::new(theme, width);
    for event in Parser::new_ext(source, opts) {
        r.handle(event, source, &wikilinks);
    }
    r.flush_paragraph();
    lines.append(&mut r.lines);
}

#[allow(dead_code)]
struct Renderer<'t> {
    theme: &'t Theme,
    width: usize,
    lines: Vec<Line<'static>>,
    spans: Vec<Span<'static>>,
    style: Style,
    in_code_block: bool,
    code_lang: Option<String>,
    list_stack: Vec<ListCtx>,
    heading_level: Option<u8>,
    in_blockquote: u8,
    indent: usize,
}

struct ListCtx {
    ordered: Option<u64>,
}

impl<'t> Renderer<'t> {
    fn new(theme: &'t Theme, width: usize) -> Self {
        Self {
            theme,
            width,
            lines: Vec::new(),
            spans: Vec::new(),
            style: Style::default(),
            in_code_block: false,
            code_lang: None,
            list_stack: Vec::new(),
            heading_level: None,
            in_blockquote: 0,
            indent: 0,
        }
    }

    fn push_span<S: Into<String>>(&mut self, s: S, style: Style) {
        self.spans.push(Span::styled(s.into(), style));
    }

    fn flush_paragraph(&mut self) {
        if self.spans.is_empty() {
            return;
        }
        let mut line_spans = Vec::new();
        if self.in_blockquote > 0 {
            let bar = "▎ ".repeat(self.in_blockquote as usize);
            line_spans.push(Span::styled(bar, self.theme.s_accent()));
        }
        if self.indent > 0 {
            line_spans.push(Span::raw(" ".repeat(self.indent)));
        }
        line_spans.extend(std::mem::take(&mut self.spans));
        self.lines.push(Line::from(line_spans));
    }

    fn handle(&mut self, event: Event<'_>, source: &str, wikilinks: &[super::WikiLink]) {
        match event {
            Event::Start(tag) => self.start_tag(tag),
            Event::End(tag) => self.end_tag(tag),
            Event::Text(t) => self.handle_text(t.as_ref(), source, wikilinks),
            Event::Code(c) => {
                let style = self.theme.s_code();
                self.push_span(format!("`{}`", c.as_ref()), style);
            }
            Event::Html(h) | Event::InlineHtml(h) => {
                let style = self.theme.s_subtle();
                self.push_span(h.to_string(), style);
            }
            Event::SoftBreak => self.spans.push(Span::raw(" ")),
            Event::HardBreak => self.flush_paragraph(),
            Event::Rule => {
                self.flush_paragraph();
                let rule = "─".repeat(self.width.saturating_sub(2).max(8));
                self.lines.push(Line::styled(rule, self.theme.s_subtle()));
                self.lines.push(Line::raw(""));
            }
            Event::FootnoteReference(name) => {
                let style = self.theme.s_link();
                self.push_span(format!("[^{}]", name.as_ref()), style);
            }
            Event::TaskListMarker(done) => {
                let mark = if done { "[x] " } else { "[ ] " };
                self.push_span(mark, self.theme.s_accent());
            }
            _ => {}
        }
    }

    fn start_tag(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => {}
            Tag::Heading { level, .. } => {
                self.flush_paragraph();
                let n = heading_to_u8(level);
                self.heading_level = Some(n);
                let hashes = format!("{} ", "#".repeat(n as usize));
                self.push_span(hashes, self.theme.s_subtle());
                self.style = self.theme.s_heading(n);
            }
            Tag::BlockQuote(_) => {
                self.flush_paragraph();
                self.in_blockquote += 1;
            }
            Tag::CodeBlock(kind) => {
                self.flush_paragraph();
                self.in_code_block = true;
                self.code_lang = match kind {
                    CodeBlockKind::Fenced(s) => Some(s.into_string()),
                    CodeBlockKind::Indented => None,
                };
                match &self.code_lang {
                    Some(lang) if !lang.is_empty() => self
                        .lines
                        .push(Line::styled(format!("┌─ {} ", lang), self.theme.s_subtle())),
                    _ => self.lines.push(Line::styled("┌─", self.theme.s_subtle())),
                }
            }
            Tag::List(start) => {
                self.flush_paragraph();
                self.list_stack.push(ListCtx { ordered: start });
                self.indent += 2;
            }
            Tag::Item => {
                self.flush_paragraph();
                let marker = match self.list_stack.last_mut() {
                    Some(ctx) => match ctx.ordered.as_mut() {
                        Some(n) => {
                            let s = format!("{}. ", n);
                            *n += 1;
                            s
                        }
                        None => "• ".to_string(),
                    },
                    None => "• ".to_string(),
                };
                self.push_span(marker, self.theme.s_accent());
            }
            Tag::Emphasis => self.style = self.style.add_modifier(Modifier::ITALIC),
            Tag::Strong => self.style = self.style.add_modifier(Modifier::BOLD),
            Tag::Strikethrough => self.style = self.style.add_modifier(Modifier::CROSSED_OUT),
            Tag::Link { dest_url, .. } => {
                self.style = self.theme.s_link();
                let _ = dest_url;
            }
            Tag::Image { dest_url, .. } => {
                let s = format!("[image: {}]", dest_url);
                self.push_span(s, self.theme.s_subtle());
            }
            Tag::Table(_) => self.flush_paragraph(),
            Tag::TableHead | Tag::TableRow => {}
            Tag::TableCell => self.push_span(" | ", self.theme.s_subtle()),
            Tag::FootnoteDefinition(name) => {
                self.flush_paragraph();
                self.push_span(format!("[^{name}]: "), self.theme.s_subtle());
            }
            _ => {}
        }
    }

    fn end_tag(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => {
                self.flush_paragraph();
                self.lines.push(Line::raw(""));
            }
            TagEnd::Heading(_) => {
                self.flush_paragraph();
                self.heading_level = None;
                self.style = Style::default();
                self.lines.push(Line::raw(""));
            }
            TagEnd::BlockQuote(_) => {
                self.flush_paragraph();
                self.in_blockquote = self.in_blockquote.saturating_sub(1);
                self.lines.push(Line::raw(""));
            }
            TagEnd::CodeBlock => {
                self.flush_paragraph();
                self.lines.push(Line::styled("└─", self.theme.s_subtle()));
                self.lines.push(Line::raw(""));
                self.in_code_block = false;
                self.code_lang = None;
            }
            TagEnd::List(_) => {
                self.flush_paragraph();
                self.list_stack.pop();
                self.indent = self.indent.saturating_sub(2);
            }
            TagEnd::Item => self.flush_paragraph(),
            TagEnd::Emphasis => self.style = self.style.remove_modifier(Modifier::ITALIC),
            TagEnd::Strong => self.style = self.style.remove_modifier(Modifier::BOLD),
            TagEnd::Strikethrough => self.style = self.style.remove_modifier(Modifier::CROSSED_OUT),
            TagEnd::Link => self.style = Style::default(),
            TagEnd::Table => self.lines.push(Line::raw("")),
            TagEnd::TableHead | TagEnd::TableRow => self.flush_paragraph(),
            _ => {}
        }
    }

    fn handle_text(&mut self, text: &str, _source: &str, wikilinks: &[super::WikiLink]) {
        if self.in_code_block {
            for line in text.split('\n') {
                if line.is_empty() {
                    self.lines
                        .push(Line::styled("│ ".to_string(), self.theme.s_subtle()));
                } else {
                    let spans = vec![
                        Span::styled("│ ", self.theme.s_subtle()),
                        Span::styled(line.to_string(), self.theme.s_code()),
                    ];
                    self.lines.push(Line::from(spans));
                }
            }
            return;
        }
        let effective_style = self.style;
        for (s, st) in split_into_segments(text, self.theme, wikilinks) {
            let merged = st.unwrap_or(effective_style);
            self.push_span(s, merged);
        }
    }
}

fn heading_to_u8(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

/// Slice a text fragment into styled segments, recognizing `[[wikilinks]]`
/// and `#tag` substrings.
fn split_into_segments(
    text: &str,
    theme: &Theme,
    _all_links: &[super::WikiLink],
) -> Vec<(String, Option<Style>)> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let mut i = 0;
    let mut plain_start = 0;

    while i < bytes.len() {
        if i + 1 < bytes.len() && bytes[i] == b'[' && bytes[i + 1] == b'[' {
            if let Some(end_rel) = text[i + 2..].find("]]") {
                let inner = &text[i + 2..i + 2 + end_rel];
                if !inner.is_empty() && !inner.contains('\n') {
                    if plain_start < i {
                        out.push((text[plain_start..i].to_string(), None));
                    }
                    let display = inner.split_once('|').map(|x| x.1).unwrap_or(inner);
                    let display = display.split_once('#').map(|x| x.0).unwrap_or(display);
                    out.push((format!("[[{display}]]"), Some(theme.s_wikilink())));
                    i += 2 + end_rel + 2;
                    plain_start = i;
                    continue;
                }
            }
        }
        if bytes[i] == b'#' {
            let prev_ok = i == 0 || {
                let prev = bytes[i - 1];
                !prev.is_ascii_alphanumeric() && prev != b'_' && prev != b'&'
            };
            if prev_ok {
                let rest = &text[i + 1..];
                let first_ok = rest
                    .chars()
                    .next()
                    .map(|c| c.is_ascii_alphabetic())
                    .unwrap_or(false);
                if first_ok {
                    let end_rel = rest
                        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '/' || c == '-'))
                        .unwrap_or(rest.len());
                    let tag = &rest[..end_rel];
                    if !tag.is_empty() {
                        if plain_start < i {
                            out.push((text[plain_start..i].to_string(), None));
                        }
                        out.push((format!("#{tag}"), Some(theme.s_tag())));
                        i += 1 + end_rel;
                        plain_start = i;
                        continue;
                    }
                }
            }
        }
        i += 1;
    }
    if plain_start < bytes.len() {
        out.push((text[plain_start..].to_string(), None));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(text: &Text<'static>) -> String {
        text.lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Render with no fold state (the common no-collapse case).
    fn render(source: &str, theme: &Theme, width: usize) -> Text<'static> {
        render_to_text_with(source, theme, width, &HashSet::new(), None)
    }

    #[test]
    fn callout_renders_header_and_body() {
        let theme = Theme::default();
        let out = render("> [!warning] Be careful\n> mind the gap\n", &theme, 80);
        let s = plain(&out);
        assert!(s.contains("Be careful"), "header title shown: {s:?}");
        assert!(s.contains("mind the gap"), "body shown: {s:?}");
        assert!(s.contains('⚠'), "warning icon shown: {s:?}");
        // The `[!warning]` marker must not leak into the rendered text.
        assert!(!s.contains("[!warning]"), "marker stripped: {s:?}");
    }

    #[test]
    fn collapsed_callout_hides_body() {
        let theme = Theme::default();
        let src = "> [!note]- Secret\n> hidden body text\n";
        assert_eq!(foldable_callouts(src), vec![true]);

        let mut collapsed = HashSet::new();
        collapsed.insert(0);
        let s = plain(&render_to_text_with(src, &theme, 80, &collapsed, None));
        assert!(s.contains("Secret"), "header shown: {s:?}");
        assert!(!s.contains("hidden body text"), "body hidden: {s:?}");
        assert!(s.contains('▸'), "collapsed glyph: {s:?}");

        let s = plain(&render_to_text_with(src, &theme, 80, &HashSet::new(), None));
        assert!(s.contains("hidden body text"));
        assert!(s.contains('▾'));
    }

    #[test]
    fn columns_render_side_by_side() {
        let theme = Theme::default();
        let src = "::: columns\nLEFTWORD\n+++\nRIGHTWORD\n:::\n";
        let s = plain(&render(src, &theme, 60));
        let row = s.lines().find(|l| l.contains("LEFTWORD")).unwrap();
        assert!(row.contains("RIGHTWORD"), "columns on one row: {row:?}");
        assert!(row.contains('│'), "column separator: {row:?}");
    }

    #[test]
    fn normal_blockquote_still_renders() {
        let theme = Theme::default();
        let s = plain(&render("> just a quote\n", &theme, 80));
        assert!(s.contains("just a quote"));
        assert!(s.contains('▎'));
    }
}
