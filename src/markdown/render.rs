//! Render markdown source into a styled ratatui `Text` for preview.
//!
//! We post-process source with our wikilink/tag parsers and then walk
//! pulldown-cmark events, building styled lines. Block-level handling is
//! intentionally simple — this is a TUI preview, not a typesetter.

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span, Text};

use crate::markdown::parse::{extract_all_tags, extract_links};
use crate::theme::Theme;

/// Render `source` markdown to a styled `Text`.
pub fn render_to_text(source: &str, theme: &Theme, width: usize) -> Text<'static> {
    let mut r = Renderer::new(theme, width);
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    opts.insert(Options::ENABLE_TASKLISTS);
    opts.insert(Options::ENABLE_TABLES);
    opts.insert(Options::ENABLE_FOOTNOTES);

    // We feed our source through cmark, but wikilinks and tags aren't in the spec.
    // Strategy: build a Vec<Token> of pre-parsed wikilink/tag spans, then weave
    // them into the regular flow by splitting Text events.
    let wikilinks = extract_links(source);
    let tags_in_source = extract_all_tags(source);

    let parser = Parser::new_ext(source, opts);
    for event in parser {
        r.handle(event, source, &wikilinks);
    }
    r.flush_paragraph();

    // Append a tag chip footer if any tags exist.
    if !tags_in_source.is_empty() {
        r.lines.push(Line::raw(""));
        let mut spans = Vec::new();
        spans.push(Span::styled("tags  ", theme.s_subtle()));
        for (i, t) in tags_in_source.iter().enumerate() {
            if i > 0 {
                spans.push(Span::raw("  "));
            }
            spans.push(Span::styled(format!("#{t}"), theme.s_tag()));
        }
        r.lines.push(Line::from(spans));
    }

    Text::from(r.lines)
}

#[allow(dead_code)]
struct Renderer<'t> {
    theme: &'t Theme,
    width: usize,
    lines: Vec<Line<'static>>,
    // Currently-accumulating inline spans for a paragraph / heading / list item.
    spans: Vec<Span<'static>>,
    /// Stack of currently-active inline styles (bold, italic, code, link).
    style: Style,
    in_code_block: bool,
    code_lang: Option<String>,
    list_stack: Vec<ListCtx>,
    heading_level: Option<u8>,
    in_blockquote: u8,
    indent: usize,
}

struct ListCtx {
    /// `Some(n)` for ordered lists with next item number; `None` for bulleted.
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
        if !self.spans.is_empty() {
            let mut line_spans = Vec::new();
            // Apply blockquote prefix once.
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
    }

    #[allow(dead_code)]
    fn break_line(&mut self) {
        self.flush_paragraph();
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
                if let Some(lang) = &self.code_lang {
                    if !lang.is_empty() {
                        self.lines.push(Line::styled(
                            format!("┌─ {} ", lang),
                            self.theme.s_subtle(),
                        ));
                    } else {
                        self.lines
                            .push(Line::styled("┌─", self.theme.s_subtle()));
                    }
                } else {
                    self.lines
                        .push(Line::styled("┌─", self.theme.s_subtle()));
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
            Tag::Strikethrough => {
                self.style = self.style.add_modifier(Modifier::CROSSED_OUT)
            }
            Tag::Link { dest_url, .. } => {
                self.style = self.theme.s_link();
                // Show URL in muted form after the link is closed.
                let _ = dest_url; // captured by closing tag via context — keep simple
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
                // Add an accent underline-ish for h1/h2.
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
            TagEnd::Strikethrough => {
                self.style = self.style.remove_modifier(Modifier::CROSSED_OUT)
            }
            TagEnd::Link => self.style = Style::default(),
            TagEnd::Table => self.lines.push(Line::raw("")),
            TagEnd::TableHead | TagEnd::TableRow => self.flush_paragraph(),
            _ => {}
        }
    }

    fn handle_text(&mut self, text: &str, _source: &str, wikilinks: &[super::WikiLink]) {
        if self.in_code_block {
            // Codeblocks come as one big text — split on newlines.
            for line in text.split('\n') {
                if line.is_empty() {
                    self.lines
                        .push(Line::styled("│ ".to_string(), self.theme.s_subtle()));
                } else {
                    let mut spans = vec![Span::styled("│ ", self.theme.s_subtle())];
                    spans.push(Span::styled(line.to_string(), self.theme.s_code()));
                    self.lines.push(Line::from(spans));
                }
            }
            return;
        }

        let effective_style = if self.heading_level.is_some() {
            self.style
        } else {
            self.style
        };

        // Highlight wikilinks and tags inside text by simple substring scan
        // on the raw text fragment. (cmark emits link targets as plain text
        // for `[[...]]` since it isn't a cmark construct.)
        let segments = split_into_segments(text, self.theme, wikilinks);
        for (s, st) in segments {
            // Merge inline style with segment style.
            let merged = match st {
                Some(seg_style) => seg_style,
                None => effective_style,
            };
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
        // Wikilink?
        if i + 1 < bytes.len() && bytes[i] == b'[' && bytes[i + 1] == b'[' {
            if let Some(end_rel) = text[i + 2..].find("]]") {
                let inner = &text[i + 2..i + 2 + end_rel];
                if !inner.is_empty() && !inner.contains('\n') {
                    if plain_start < i {
                        out.push((text[plain_start..i].to_string(), None));
                    }
                    let display = inner.split_once('|').map(|x| x.1).unwrap_or(inner);
                    let display = display
                        .split_once('#')
                        .map(|x| x.0)
                        .unwrap_or(display);
                    out.push((format!("[[{display}]]"), Some(theme.s_wikilink())));
                    i += 2 + end_rel + 2;
                    plain_start = i;
                    continue;
                }
            }
        }
        // Tag?
        if bytes[i] == b'#' {
            let prev_ok = i == 0 || {
                let prev = bytes[i - 1];
                !prev.is_ascii_alphanumeric() && prev != b'_' && prev != b'&'
            };
            if prev_ok {
                // Scan a tag name.
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
