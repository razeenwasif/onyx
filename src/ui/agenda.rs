//! Day-agenda overlay — Google Calendar events on the calendar's selected day.

use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let day = app.calendar.cursor;
    let rect = super::centered_rect(area.width.saturating_sub(8).min(80), area.height.saturating_sub(6).min(20), area);
    frame.render_widget(Clear, rect);

    let title = format!("Agenda · {}", day.format("%a %-d %b %Y"));
    let block = super::pane_block(&title, true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let body = Rect { height: inner.height.saturating_sub(1), ..inner };
    let footer = Rect { y: inner.y + inner.height.saturating_sub(1), height: 1, ..inner };

    let events = app.events_on(day);
    if events.is_empty() {
        let msg = if app.calendar_syncing() {
            "syncing…"
        } else {
            "— no events — 'a' to add an all-day event —"
        };
        frame.render_widget(Paragraph::new(msg).style(theme.s_subtle()), body);
    } else {
        let time_w = events.iter().map(|e| e.time_label.len()).max().unwrap_or(7);
        let items: Vec<ListItem> = events
            .iter()
            .map(|e| {
                ListItem::new(Line::from(vec![
                    Span::styled(format!("{:<time_w$}  ", e.time_label), theme.s_accent()),
                    Span::styled(e.summary.clone(), theme.s_normal()),
                ]))
            })
            .collect();
        let mut state = ListState::default();
        state.select(Some(app.agenda_selected.min(events.len().saturating_sub(1))));
        let list = List::new(items).highlight_style(theme.s_selection()).highlight_symbol("▸ ");
        frame.render_stateful_widget(list, body, &mut state);
    }

    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            "j/k move · a add event · d delete · Esc close",
            theme.s_dim(),
        ))),
        footer,
    );
}
