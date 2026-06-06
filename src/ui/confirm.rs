//! A small centered yes/no confirmation dialog (e.g. before deleting).

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph, Wrap};
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let rect = super::centered_rect(60, 8, area);
    frame.render_widget(Clear, rect);
    let block = super::pane_block("Confirm", true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let p = Paragraph::new(vec![
        Line::raw(""),
        Line::from(Span::styled(
            format!("  {}", app.confirm.message),
            theme.s_normal(),
        )),
        Line::raw(""),
        Line::from(vec![
            Span::raw("  "),
            Span::styled("y", theme.s_error().add_modifier(Modifier::BOLD)),
            Span::styled("es    ", theme.s_subtle()),
            Span::styled("n", theme.s_accent().add_modifier(Modifier::BOLD)),
            Span::styled("o / Esc    (default: no)", theme.s_subtle()),
        ]),
    ])
    .wrap(Wrap { trim: false })
    .style(theme.s_normal());
    frame.render_widget(p, inner);
}
