//! Inline text-prompt overlay (used for "new note title", "rename to", etc).

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let rect = super::centered_rect(60, 7, area);
    frame.render_widget(Clear, rect);
    let block = super::pane_block(&app.prompt.label, true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let p = Paragraph::new(vec![
        Line::raw(""),
        Line::from(vec![
            Span::styled(" ❯ ", theme.s_accent().add_modifier(Modifier::BOLD)),
            Span::styled(app.prompt.value.clone(), theme.s_normal()),
            Span::styled("▏", theme.s_accent().add_modifier(Modifier::SLOW_BLINK)),
        ]),
        Line::raw(""),
        Line::styled("  Enter confirm · Esc cancel", theme.s_subtle()),
    ])
    .style(theme.s_normal());
    frame.render_widget(p, inner);
}
