//! Split view — the right pane renders a *second* note read-only (rendered
//! markdown) alongside the editor, instead of the active note's preview.

use std::collections::HashSet;

use ratatui::layout::Rect;
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;

use crate::app::App;
use crate::markdown::parse::strip_frontmatter;
use crate::markdown::render_to_text_with;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let Some((name, content)) = app.split_content() else {
        return;
    };
    let block = super::pane_block(&format!("{name}  (split)"), false, theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let empty = HashSet::new();
    let body = strip_frontmatter(&content);
    let text = render_to_text_with(body, theme, inner.width as usize, &empty, None);
    frame.render_widget(
        Paragraph::new(text).style(theme.s_normal()).wrap(Wrap { trim: false }),
        inner,
    );
}
