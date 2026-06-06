//! Vim-style ex command line — a single-row prompt rendered along the bottom
//! of the screen when `Focus::CommandLine` is active. Replaces the status bar
//! for that frame.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let line = Line::from(vec![
        Span::styled(" :", theme.s_accent().add_modifier(Modifier::BOLD)),
        Span::styled(app.cmdline.value.clone(), theme.s_normal()),
        Span::styled("▏", theme.s_accent().add_modifier(Modifier::SLOW_BLINK)),
    ]);
    let p = Paragraph::new(line).style(
        ratatui::style::Style::default()
            .bg(theme.bg_alt.to_color())
            .fg(theme.fg.to_color()),
    );
    frame.render_widget(p, area);
}
