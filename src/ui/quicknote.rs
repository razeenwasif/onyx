//! Quicknote scratch pane (left column). Always-editable when focused; the
//! buffer is persisted to `.onyx/quicknote.md`.

use ratatui::layout::Rect;
use ratatui::text::Line;
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::{App, Focus};

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::Quicknote;
    let dirty = if app.quicknote.dirty { " ●" } else { "" };
    let block = super::pane_block(&format!("Quicknote{dirty}"), focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let height = inner.height as usize;
    if height == 0 {
        return;
    }

    // Keep the cursor in view.
    let cursor = app.quicknote.buffer.cursor;
    if cursor.line < app.quicknote.scroll {
        app.quicknote.scroll = cursor.line;
    } else if cursor.line >= app.quicknote.scroll + height {
        app.quicknote.scroll = cursor.line + 1 - height;
    }
    let scroll = app.quicknote.scroll;

    let theme = &app.theme;
    let buf = &app.quicknote.buffer;
    let total = buf.line_count();
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(height);
    if total == 1 && buf.line(0).is_empty() && !focused {
        lines.push(Line::styled("scratch space…", theme.s_subtle()));
    } else {
        for row in 0..height {
            let n = scroll + row;
            if n >= total {
                break;
            }
            lines.push(Line::styled(buf.line(n).to_string(), theme.s_normal()));
        }
    }
    frame.render_widget(Paragraph::new(lines).style(theme.s_normal()), inner);

    if focused {
        let dc = buf.display_col(cursor.line, cursor.col);
        let x = inner.x + dc as u16;
        let y = inner.y + (cursor.line.saturating_sub(scroll)) as u16;
        if x < inner.x + inner.width && y < inner.y + inner.height {
            frame.set_cursor_position((x, y));
        }
    }
}
