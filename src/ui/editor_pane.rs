//! Center pane — the markdown editor.

use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use unicode_width::UnicodeWidthStr;

use crate::app::{App, Focus};
use crate::editor::Mode;

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::Editor;
    let title = match &app.doc {
        Some(d) => format!("{}  {}", d.title(), d.mode.label()),
        None => "Editor".into(),
    };
    let block = super::pane_block(&title, focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if app.doc.is_none() {
        draw_empty(frame, inner, app);
        return;
    }

    // Adjust scroll so cursor is in view.
    let height = inner.height as usize;
    {
        let doc = app.doc.as_mut().unwrap();
        let cursor_line = doc.buffer.cursor.line;
        if cursor_line < doc.scroll {
            doc.scroll = cursor_line;
        } else if cursor_line >= doc.scroll + height {
            doc.scroll = cursor_line + 1 - height;
        }
    }

    let theme = &app.theme;
    let doc = app.doc.as_ref().unwrap();
    let scroll = doc.scroll;
    let cursor = doc.buffer.cursor;
    let show_numbers = app.config.editor.line_numbers;
    let total = doc.buffer.line_count();
    let gutter_w = if show_numbers {
        ((total as f32).log10().floor() as usize + 2).max(3)
    } else {
        0
    };

    let mut lines: Vec<Line<'static>> = Vec::with_capacity(height);
    for row in 0..height {
        let lineno = scroll + row;
        if lineno >= total {
            lines.push(Line::raw(""));
            continue;
        }
        let raw = doc.buffer.line(lineno).to_string();
        let styled = render_line(&raw, theme);
        let mut spans: Vec<Span<'static>> = Vec::new();
        if show_numbers {
            let n = lineno + 1;
            let style = if n == cursor.line + 1 {
                theme.s_accent()
            } else {
                theme.s_subtle()
            };
            spans.push(Span::styled(format!("{:>width$} ", n, width = gutter_w - 1), style));
        }
        for s in styled {
            spans.push(s);
        }
        let mut line = Line::from(spans);

        // Cursor block — invert one cell when focused and we're on this line.
        if focused && doc.mode != Mode::Insert && lineno == cursor.line {
            apply_cursor_overlay(&mut line, cursor.col + gutter_w, theme);
        }
        lines.push(line);
    }

    let p = Paragraph::new(lines).style(theme.s_normal());
    frame.render_widget(p, inner);

    // Insert-mode caret is drawn by the terminal cursor for a real caret.
    if focused {
        if let Some(doc) = &app.doc {
            if doc.mode == Mode::Insert {
                let display_col = doc.buffer.display_col(cursor.line, cursor.col);
                let x = inner.x + gutter_w as u16 + display_col as u16;
                let y = inner.y + (cursor.line - doc.scroll) as u16;
                if x < inner.x + inner.width && y < inner.y + inner.height {
                    frame.set_cursor_position((x, y));
                }
            }
        }
    }
}

fn draw_empty(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let art = vec![
        Line::raw(""),
        Line::raw(""),
        Line::styled(
            "    ◆ Onyx",
            theme.s_accent().add_modifier(Modifier::BOLD),
        ),
        Line::styled("    a premium markdown vault", theme.s_subtle()),
        Line::raw(""),
        Line::styled("    Ctrl-O   Quick switcher", theme.s_dim()),
        Line::styled("    Ctrl-N   New note", theme.s_dim()),
        Line::styled("    Ctrl-P   Command palette", theme.s_dim()),
        Line::styled("    Ctrl-K   Calendar / daily notes", theme.s_dim()),
        Line::styled("    Ctrl-G   Graph view", theme.s_dim()),
        Line::styled("    Ctrl-/   Help", theme.s_dim()),
        Line::raw(""),
        Line::styled(
            format!("    vault: {}", app.vault.root.display()),
            theme.s_subtle(),
        ),
    ];
    let p = Paragraph::new(art).style(theme.s_normal());
    frame.render_widget(p, area);
}

/// Style a single editor line: headings, wikilinks, tags, code spans, bold/italic.
/// (We don't run the full markdown parser per-line — fast inline highlighting.)
fn render_line(line: &str, theme: &crate::theme::Theme) -> Vec<Span<'static>> {
    // Heading prefix.
    let trimmed = line.trim_start_matches(' ');
    let leading = line.len() - trimmed.len();
    let mut hashes = 0;
    for c in trimmed.chars() {
        if c == '#' {
            hashes += 1;
        } else {
            break;
        }
    }
    if hashes > 0 && hashes <= 6 && trimmed.chars().nth(hashes) == Some(' ') {
        let style = theme.s_heading(hashes as u8);
        return vec![Span::styled(line.to_string(), style)];
    }

    // List marker / quote / fence.
    if let Some(rest) = trimmed.strip_prefix("> ") {
        let mut spans: Vec<Span<'static>> = Vec::new();
        spans.push(Span::raw(" ".repeat(leading)));
        spans.push(Span::styled("▎ ".to_string(), theme.s_accent()));
        spans.extend(inline_spans(rest, theme));
        return spans;
    }
    if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
        return vec![Span::styled(line.to_string(), theme.s_subtle())];
    }
    if let Some(rest) = trimmed
        .strip_prefix("- [ ] ")
        .or_else(|| trimmed.strip_prefix("- [x] "))
    {
        let mut spans: Vec<Span<'static>> = Vec::new();
        spans.push(Span::raw(" ".repeat(leading)));
        let mark = &trimmed[..6];
        let mark_style = if mark.contains('x') {
            Style::default().fg(theme.success.to_color())
        } else {
            theme.s_accent()
        };
        spans.push(Span::styled(mark.to_string(), mark_style));
        spans.extend(inline_spans(rest, theme));
        return spans;
    }
    if trimmed.starts_with("- ") || trimmed.starts_with("* ") || trimmed.starts_with("+ ") {
        let mut spans: Vec<Span<'static>> = Vec::new();
        spans.push(Span::raw(" ".repeat(leading)));
        spans.push(Span::styled(trimmed[..2].to_string(), theme.s_accent()));
        spans.extend(inline_spans(&trimmed[2..], theme));
        return spans;
    }

    let mut spans: Vec<Span<'static>> = Vec::new();
    spans.push(Span::raw(" ".repeat(leading)));
    spans.extend(inline_spans(trimmed, theme));
    spans
}

fn inline_spans(text: &str, theme: &crate::theme::Theme) -> Vec<Span<'static>> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let mut i = 0;
    let mut start = 0;
    let flush = |out: &mut Vec<Span<'static>>, s: &str| {
        if !s.is_empty() {
            out.push(Span::styled(s.to_string(), theme.s_normal()));
        }
    };
    while i < bytes.len() {
        // Wikilink
        if i + 1 < bytes.len() && bytes[i] == b'[' && bytes[i + 1] == b'[' {
            if let Some(rel) = text[i + 2..].find("]]") {
                flush(&mut out, &text[start..i]);
                out.push(Span::styled(
                    text[i..i + 2 + rel + 2].to_string(),
                    theme.s_wikilink(),
                ));
                i += 2 + rel + 2;
                start = i;
                continue;
            }
        }
        // Inline code
        if bytes[i] == b'`' {
            if let Some(rel) = text[i + 1..].find('`') {
                let end = i + 1 + rel + 1;
                flush(&mut out, &text[start..i]);
                out.push(Span::styled(text[i..end].to_string(), theme.s_code()));
                i = end;
                start = i;
                continue;
            }
        }
        // Tag
        if bytes[i] == b'#' {
            let prev_ok = i == 0 || {
                let p = bytes[i - 1];
                !p.is_ascii_alphanumeric() && p != b'_'
            };
            if prev_ok {
                let rest = &text[i + 1..];
                let first_ok = rest
                    .chars()
                    .next()
                    .map(|c| c.is_ascii_alphabetic())
                    .unwrap_or(false);
                if first_ok {
                    let rel = rest
                        .find(|c: char| {
                            !(c.is_ascii_alphanumeric() || c == '_' || c == '/' || c == '-')
                        })
                        .unwrap_or(rest.len());
                    let end = i + 1 + rel;
                    flush(&mut out, &text[start..i]);
                    out.push(Span::styled(text[i..end].to_string(), theme.s_tag()));
                    i = end;
                    start = i;
                    continue;
                }
            }
        }
        // Bold **
        if i + 1 < bytes.len() && bytes[i] == b'*' && bytes[i + 1] == b'*' {
            if let Some(rel) = text[i + 2..].find("**") {
                let end = i + 2 + rel + 2;
                flush(&mut out, &text[start..i]);
                out.push(Span::styled(
                    text[i..end].to_string(),
                    Style::default()
                        .fg(theme.fg.to_color())
                        .add_modifier(Modifier::BOLD),
                ));
                i = end;
                start = i;
                continue;
            }
        }
        // Italic _ or *
        if bytes[i] == b'_' || bytes[i] == b'*' {
            let ch = bytes[i];
            // Skip if double (handled above) or bold _
            let is_double = i + 1 < bytes.len() && bytes[i + 1] == ch;
            if !is_double {
                if let Some(rel) = text[i + 1..].find(ch as char) {
                    let end = i + 1 + rel + 1;
                    flush(&mut out, &text[start..i]);
                    out.push(Span::styled(
                        text[i..end].to_string(),
                        Style::default()
                            .fg(theme.fg.to_color())
                            .add_modifier(Modifier::ITALIC),
                    ));
                    i = end;
                    start = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    flush(&mut out, &text[start..]);
    out
}

/// Overlay a "cursor block" on `line` at the given display column.
fn apply_cursor_overlay(line: &mut Line<'static>, col: usize, theme: &crate::theme::Theme) {
    // Walk through spans, find the cell at `col`, swap its style with reversed bg.
    let cursor_style = Style::default()
        .bg(theme.accent.to_color())
        .fg(theme.bg.to_color())
        .add_modifier(Modifier::BOLD);

    let mut acc = 0;
    let mut new_spans: Vec<Span<'static>> = Vec::with_capacity(line.spans.len() + 2);
    let mut placed = false;
    for span in std::mem::take(&mut line.spans) {
        if placed {
            new_spans.push(span);
            continue;
        }
        let w = UnicodeWidthStr::width(span.content.as_ref());
        if acc + w <= col {
            acc += w;
            new_spans.push(span);
            continue;
        }
        // Split this span at byte offset corresponding to display col.
        let target_in_span = col - acc;
        let mut byte_at = 0;
        let mut width_at = 0;
        let mut found = false;
        for (i, ch) in span.content.char_indices() {
            if width_at == target_in_span {
                byte_at = i;
                found = true;
                break;
            }
            width_at += unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        }
        if !found {
            byte_at = span.content.len();
        }
        let s = span.content.into_owned();
        let (left, rest) = s.split_at(byte_at);
        if !left.is_empty() {
            new_spans.push(Span::styled(left.to_string(), span.style));
        }
        // Take the first char of `rest`.
        let mut chars = rest.chars();
        let first = chars.next().unwrap_or(' ');
        new_spans.push(Span::styled(first.to_string(), cursor_style));
        let remainder: String = chars.collect();
        if !remainder.is_empty() {
            new_spans.push(Span::styled(remainder, span.style));
        }
        placed = true;
    }
    if !placed {
        new_spans.push(Span::styled(" ".to_string(), cursor_style));
    }
    line.spans = new_spans;
}
