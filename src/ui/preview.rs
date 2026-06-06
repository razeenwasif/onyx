//! Right-of-editor pane — rendered markdown preview.

use ratatui::layout::Rect;
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{App, Focus};
use crate::markdown::render_to_text;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let focused = app.focus == Focus::Preview;
    let block = super::pane_block("Preview", focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let src = match &app.doc {
        Some(doc) => doc.buffer.to_string(),
        None => String::new(),
    };
    if src.trim().is_empty() {
        let p = Paragraph::new("— nothing to preview —")
            .style(app.theme.s_subtle())
            .wrap(Wrap { trim: false });
        frame.render_widget(p, inner);
        return;
    }
    let text = render_to_text(&src, &app.theme, inner.width as usize);
    let p = Paragraph::new(text)
        .style(app.theme.s_normal())
        .wrap(Wrap { trim: false });
    frame.render_widget(p, inner);
}
