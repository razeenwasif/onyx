//! Quick switcher — fuzzy-find notes by name.

use fuzzy_matcher::skim::SkimMatcherV2;
use fuzzy_matcher::FuzzyMatcher;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState, Paragraph};
use ratatui::Frame;
use std::path::PathBuf;

use crate::app::App;
use crate::vault;

pub fn filtered(app: &App, query: &str) -> Vec<PathBuf> {
    let matcher = SkimMatcherV2::default();
    if query.trim().is_empty() {
        // Sort by recency.
        return app
            .vault
            .index
            .recent_notes()
            .into_iter()
            .map(|(p, _)| p)
            .take(200)
            .collect();
    }
    let mut scored: Vec<(i64, PathBuf)> = Vec::new();
    for (path, _meta) in app.vault.index.all_notes() {
        let stem = vault::note_basename(&path);
        let rel = vault::note_relpath(&app.vault.root, &path);
        let s1 = matcher.fuzzy_match(&stem, query).unwrap_or(i64::MIN);
        let s2 = matcher.fuzzy_match(&rel, query).unwrap_or(i64::MIN);
        let best = s1.max(s2);
        if best > i64::MIN {
            scored.push((best, path));
        }
    }
    scored.sort_by(|a, b| b.0.cmp(&a.0));
    scored.into_iter().map(|(_, p)| p).take(200).collect()
}

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let theme = &app.theme;
    let rect = super::centered_rect(72, 24, area);
    frame.render_widget(Clear, rect);
    let block = super::pane_block("Quick switcher", true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0)])
        .split(inner);

    let prompt = Paragraph::new(Line::from(vec![
        Span::styled("❯ ", theme.s_accent().add_modifier(Modifier::BOLD)),
        Span::styled(app.switcher.query.clone(), theme.s_normal()),
        Span::styled("▏", theme.s_accent().add_modifier(Modifier::SLOW_BLINK)),
    ]))
    .style(theme.s_normal());
    frame.render_widget(prompt, split[0]);

    let results = filtered(app, &app.switcher.query);
    if app.switcher.selected >= results.len() {
        app.switcher.selected = results.len().saturating_sub(1);
    }
    let root = app.vault.root.clone();
    let items: Vec<ListItem> = results
        .iter()
        .map(|p| {
            let stem = vault::note_basename(p);
            let rel = vault::note_relpath(&root, p);
            let parent = rel
                .rsplit_once('/')
                .map(|(a, _)| a.to_string())
                .unwrap_or_default();
            ListItem::new(Line::from(vec![
                Span::styled("󰈙 ", theme.s_subtle()),
                Span::styled(stem, theme.s_normal()),
                Span::styled(
                    if parent.is_empty() {
                        String::new()
                    } else {
                        format!("  {}", parent)
                    },
                    theme.s_subtle(),
                ),
            ]))
        })
        .collect();

    let mut state = ListState::default();
    if !items.is_empty() {
        state.select(Some(app.switcher.selected));
    }
    let list = List::new(items)
        .highlight_style(theme.s_selection())
        .highlight_symbol(" ▸ ");
    frame.render_stateful_widget(list, split[1], &mut state);
}
