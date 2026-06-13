//! A one-row tab bar above the editor, shown when more than one note is open.

use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::App;
use crate::vault;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let mut spans: Vec<Span<'static>> = Vec::new();
    for (i, (path, active, dirty)) in app.tab_infos().iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw(" "));
        }
        let name = vault::note_basename(path);
        let mark = if *dirty { " •" } else { "" };
        let label = format!(" {name}{mark} ");
        let style = if *active {
            theme.s_selection()
        } else {
            theme.s_subtle()
        };
        spans.push(Span::styled(label, style));
    }
    let bar = Paragraph::new(Line::from(spans))
        .style(Style::default().bg(theme.bg_alt.to_color()).fg(theme.fg.to_color()));
    frame.render_widget(bar, area);
}
