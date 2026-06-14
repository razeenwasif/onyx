//! Google Tasks overlay — tasks pulled from the Google Tasks API.

use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let rect = super::centered_rect(area.width.saturating_sub(8).min(100), area.height.saturating_sub(4), area);
    frame.render_widget(Clear, rect);

    let open = app.gtasks.iter().filter(|t| !t.completed).count();
    let title = format!("Google Tasks · {open} open · {} total", app.gtasks.len());
    let block = super::pane_block(&title, true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let body = Rect { height: inner.height.saturating_sub(1), ..inner };
    let footer = Rect { y: inner.y + inner.height.saturating_sub(1), height: 1, ..inner };

    if app.gtasks.is_empty() {
        frame.render_widget(
            Paragraph::new("— no Google tasks — (:google auth first if you haven't) —")
                .style(theme.s_subtle()),
            body,
        );
    } else {
        let items: Vec<ListItem> = app
            .gtasks
            .iter()
            .map(|t| {
                let (box_str, text_style) = if t.completed {
                    ("[x] ", theme.s_subtle().add_modifier(Modifier::CROSSED_OUT))
                } else {
                    ("[ ] ", theme.s_normal())
                };
                let box_style = if t.completed {
                    Style::default().fg(theme.success.to_color())
                } else {
                    theme.s_accent()
                };
                let mut spans = vec![
                    Span::styled(box_str, box_style),
                    Span::styled(t.title.clone(), text_style),
                ];
                if let Some(due) = &t.due {
                    let day = due.split('T').next().unwrap_or(due);
                    spans.push(Span::styled(format!("  ⏲ {day}"), theme.s_subtle()));
                }
                spans.push(Span::styled(format!("   {}", t.list_title), theme.s_dim()));
                ListItem::new(Line::from(spans))
            })
            .collect();
        let mut state = ListState::default();
        state.select(Some(app.gtasks_selected.min(app.gtasks.len().saturating_sub(1))));
        let list = List::new(items).highlight_style(theme.s_selection()).highlight_symbol("▸ ");
        frame.render_stateful_widget(list, body, &mut state);
    }

    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            "j/k move · Space toggle ✓ · d delete · Enter→quicknote · Esc close",
            theme.s_dim(),
        ))),
        footer,
    );
}
