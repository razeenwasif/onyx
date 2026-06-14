//! Todo / reminder checklist pane (left column). Shows the local checklist
//! (`.onyx/todos.md`) merged with open Google tasks (marked `☁`), one cursor.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::{App, Focus, TodoSource};

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::Todo;
    let rows = app.todo_rows();
    let left = rows.iter().filter(|r| !r.done).count();
    let mut title = format!("Todo · {left} left");
    if app.gtasks_syncing() {
        title.push_str(" · ⟳");
    }
    let block = super::pane_block(&title, focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let theme = &app.theme;
    if rows.is_empty() {
        let hint = if focused {
            "no todos — 'a' add · 's' sync Google"
        } else {
            "no todos yet"
        };
        frame.render_widget(Paragraph::new(hint).style(theme.s_subtle()), inner);
        return;
    }

    let items: Vec<ListItem> = rows
        .iter()
        .map(|r| {
            let (box_, box_style) = if r.done {
                ("✔ ", theme.s_tag())
            } else {
                ("□ ", theme.s_accent())
            };
            let text_style = if r.done {
                theme.s_subtle().add_modifier(Modifier::CROSSED_OUT)
            } else {
                theme.s_normal()
            };
            let label = match r.source {
                TodoSource::Google(_) => format!("☁ {}", r.text),
                TodoSource::Local(_) => r.text.clone(),
            };
            ListItem::new(Line::from(vec![
                Span::styled(box_.to_string(), box_style),
                Span::styled(label, text_style),
            ]))
        })
        .collect();

    let mut state = ListState::default();
    if focused {
        state.select(Some(app.todo_cursor.min(rows.len().saturating_sub(1))));
    }
    let list = List::new(items)
        .highlight_style(theme.s_selection())
        .highlight_symbol("▸");
    frame.render_stateful_widget(list, inner, &mut state);
}
