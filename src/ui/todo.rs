//! Todo / reminder checklist pane (left column). Backed by `.onyx/todos.md`.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::{App, Focus};

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::Todo;
    let title = format!("Todo · {} left", app.todos.remaining());
    let block = super::pane_block(&title, focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let theme = &app.theme;
    if app.todos.items.is_empty() {
        let hint = if focused {
            "no todos — press 'a' to add"
        } else {
            "no todos yet"
        };
        frame.render_widget(Paragraph::new(hint).style(theme.s_subtle()), inner);
        return;
    }

    app.todos.clamp();
    let items: Vec<ListItem> = app
        .todos
        .items
        .iter()
        .map(|it| {
            let (box_, box_style) = if it.done {
                ("✔ ", theme.s_tag())
            } else {
                ("□ ", theme.s_accent())
            };
            let text_style = if it.done {
                theme.s_subtle().add_modifier(Modifier::CROSSED_OUT)
            } else {
                theme.s_normal()
            };
            ListItem::new(Line::from(vec![
                Span::styled(box_.to_string(), box_style),
                Span::styled(it.text.clone(), text_style),
            ]))
        })
        .collect();

    let mut state = ListState::default();
    if focused {
        state.select(Some(app.todos.selected));
    }
    let list = List::new(items)
        .highlight_style(theme.s_selection())
        .highlight_symbol("▸");
    frame.render_stateful_widget(list, inner, &mut state);
}
