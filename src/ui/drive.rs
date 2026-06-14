//! Google Drive file-browser overlay.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let Some(d) = app.drive.as_ref() else {
        return;
    };
    let rect = super::centered_rect(area.width.saturating_sub(8).min(96), area.height.saturating_sub(4), area);
    frame.render_widget(Clear, rect);

    let title = format!("Drive · {}", d.breadcrumb());
    let block = super::pane_block(&title, true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let body = Rect { height: inner.height.saturating_sub(1), ..inner };
    let footer = Rect { y: inner.y + inner.height.saturating_sub(1), height: 1, ..inner };

    if app.drive_loading() && d.files.is_empty() {
        frame.render_widget(Paragraph::new("loading…").style(theme.s_subtle()), body);
    } else if d.files.is_empty() {
        frame.render_widget(Paragraph::new("— empty folder —").style(theme.s_subtle()), body);
    } else {
        let items: Vec<ListItem> = d
            .files
            .iter()
            .map(|f| {
                let (glyph, style) = if f.is_folder() {
                    ("▸ ", theme.s_accent())
                } else if f.is_text() {
                    ("󰈙 ", theme.s_normal())
                } else if f.is_google_doc() {
                    ("◑ ", theme.s_subtle())
                } else {
                    ("· ", theme.s_subtle())
                };
                ListItem::new(Line::from(vec![
                    Span::styled(glyph.to_string(), theme.s_subtle()),
                    Span::styled(f.name.clone(), style),
                ]))
            })
            .collect();
        let mut state = ListState::default();
        state.select(Some(d.selected.min(d.files.len().saturating_sub(1))));
        let list = List::new(items)
            .highlight_style(theme.s_selection().add_modifier(Modifier::BOLD))
            .highlight_symbol("");
        frame.render_stateful_widget(list, body, &mut state);
    }

    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            "j/k move · Enter open/enter · Backspace up · u upload note · Esc close",
            theme.s_dim(),
        ))),
        footer,
    );
}
