//! Right-of-editor pane — rendered markdown preview.
//!
//! The rendered `Text` is cached on `App` keyed by (note, buffer revision,
//! width, theme), so markdown is re-parsed only when one of those changes —
//! not on every frame (cursor moves, graph ticks, idle redraws).

use ratatui::layout::Rect;
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{App, Focus, PreviewCache};
use crate::markdown::render_to_text;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let focused = app.focus == Focus::Preview;
    let block = super::pane_block("Preview", focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let doc = match &app.doc {
        Some(d) => d,
        None => {
            let p = Paragraph::new("— nothing to preview —")
                .style(app.theme.s_subtle())
                .wrap(Wrap { trim: false });
            frame.render_widget(p, inner);
            return;
        }
    };

    let path = doc.path.clone();
    let rev = doc.buffer.revision;
    let width = inner.width;
    let theme_gen = app.theme_gen;

    let mut cache = app.preview_cache.borrow_mut();
    let hit = cache
        .as_ref()
        .map(|c| c.path == path && c.rev == rev && c.width == width && c.theme_gen == theme_gen)
        .unwrap_or(false);

    if !hit {
        let src = doc.buffer.to_string();
        let text = render_to_text(&src, &app.theme, width as usize);
        *cache = Some(PreviewCache {
            path: path.clone(),
            rev,
            width,
            theme_gen,
            text,
        });
    }

    let text = cache.as_ref().unwrap().text.clone();
    let p = Paragraph::new(text)
        .style(app.theme.s_normal())
        .wrap(Wrap { trim: false });
    frame.render_widget(p, inner);
}
