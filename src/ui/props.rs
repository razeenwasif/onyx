//! Inline frontmatter-property editor — a modal over the open note that lists
//! its properties and edits them on the buffer (joins undo + save).

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let rect = super::centered_rect(area.width.saturating_sub(10).min(80), 18.min(area.height.saturating_sub(4)), area);
    frame.render_widget(Clear, rect);
    let block = super::pane_block("Properties", true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let body = Rect { height: inner.height.saturating_sub(1), ..inner };
    let footer = Rect { y: inner.y + inner.height.saturating_sub(1), height: 1, ..inner };

    let st = &app.props_edit;
    let key_w = st.items.iter().map(|(k, _)| k.chars().count()).max().unwrap_or(4).clamp(4, 22);

    let mut items: Vec<ListItem> = st
        .items
        .iter()
        .enumerate()
        .map(|(i, (k, v))| {
            // If this row is being edited, show the live buffer.
            let value = match &st.editing {
                Some(e) if !e.is_add && e.key == *k && i == st.selected => format!("{}▌", e.buffer),
                _ => v.clone(),
            };
            ListItem::new(Line::from(vec![
                Span::styled(format!("{k:<key_w$}  "), theme.s_subtle().add_modifier(Modifier::BOLD)),
                Span::styled(value, theme.s_normal()),
            ]))
        })
        .collect();

    // The "add" row, when adding.
    if let Some(e) = &st.editing {
        if e.is_add {
            items.push(ListItem::new(Line::from(Span::styled(
                format!("+ {}▌", e.buffer),
                theme.s_accent(),
            ))));
        }
    }
    if items.is_empty() {
        frame.render_widget(
            Paragraph::new("— no properties — press 'a' to add one —").style(theme.s_subtle()),
            body,
        );
    } else {
        let mut state = ListState::default();
        let sel = if st.editing.as_ref().map(|e| e.is_add).unwrap_or(false) {
            items.len() - 1
        } else {
            st.selected.min(items.len().saturating_sub(1))
        };
        state.select(Some(sel));
        let list = List::new(items).highlight_style(theme.s_selection());
        frame.render_stateful_widget(list, body, &mut state);
    }

    let hint = if st.editing.is_some() {
        "type · Enter commit · Esc cancel"
    } else {
        "j/k move · e edit · a add · d delete · Esc close"
    };
    frame.render_widget(Paragraph::new(Line::from(Span::styled(hint, theme.s_dim()))), footer);
}
