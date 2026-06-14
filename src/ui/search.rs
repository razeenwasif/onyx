//! Full-vault content search overlay.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::App;
use crate::vault;

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let theme = &app.theme;
    let rect = super::centered_rect(86, 28, area);
    frame.render_widget(Clear, rect);
    let block = super::pane_block("Search vault", true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Length(1),
            Constraint::Min(0),
        ])
        .split(inner);

    let prompt = Paragraph::new(Line::from(vec![
        Span::styled("🔍 ", theme.s_accent().add_modifier(Modifier::BOLD)),
        Span::styled(app.search.query.clone(), theme.s_normal()),
        Span::styled("▏", theme.s_accent().add_modifier(Modifier::SLOW_BLINK)),
    ]))
    .style(theme.s_normal());
    frame.render_widget(prompt, split[0]);

    let summary = if app.search.query.trim().is_empty() {
        "operators: tag:foo · path:bar · line:N  · Tab results · Esc cancel".to_string()
    } else {
        format!(
            "{} matches  · tag:/path:/line: filters · Tab results · Enter open · Esc cancel",
            app.search.results.len()
        )
    };
    let summary_p = Paragraph::new(summary).style(theme.s_subtle());
    frame.render_widget(summary_p, split[1]);

    if app.search.selected >= app.search.results.len() {
        app.search.selected = app.search.results.len().saturating_sub(1);
    }
    // Highlight only the free-text part of the query, not the `tag:`/`path:` ops.
    let needle = crate::app::parse_search_query(&app.search.query).needle.to_lowercase();
    let items: Vec<ListItem> = app
        .search
        .results
        .iter()
        .map(|hit| {
            let rel = vault::note_relpath(&app.vault.root, &hit.path);
            let stem = vault::note_basename(&hit.path);
            let mut spans: Vec<Span<'static>> = Vec::new();
            spans.push(Span::styled(stem, theme.s_accent()));
            spans.push(Span::styled(format!("  {rel}:{}  ", hit.line + 1), theme.s_subtle()));
            for chunk in highlight(&hit.preview, &needle, theme) {
                spans.push(chunk);
            }
            ListItem::new(Line::from(spans))
        })
        .collect();
    let mut state = ListState::default();
    if !items.is_empty() {
        state.select(Some(app.search.selected));
    }
    let list = List::new(items)
        .highlight_style(theme.s_selection())
        .highlight_symbol(" ▸ ");
    frame.render_stateful_widget(list, split[2], &mut state);
}

fn highlight(text: &str, needle: &str, theme: &crate::theme::Theme) -> Vec<Span<'static>> {
    if needle.is_empty() {
        return vec![Span::styled(text.to_string(), theme.s_normal())];
    }
    let lower = text.to_lowercase();
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut start = 0;
    let mut i = 0;
    let bytes = lower.as_bytes();
    let nb = needle.as_bytes();
    while i + nb.len() <= bytes.len() {
        if bytes[i..i + nb.len()] == *nb {
            if start < i {
                spans.push(Span::styled(text[start..i].to_string(), theme.s_normal()));
            }
            spans.push(Span::styled(
                text[i..i + nb.len()].to_string(),
                theme.s_accent().add_modifier(Modifier::BOLD),
            ));
            i += nb.len();
            start = i;
        } else {
            i += 1;
        }
    }
    if start < text.len() {
        spans.push(Span::styled(text[start..].to_string(), theme.s_normal()));
    }
    spans
}
