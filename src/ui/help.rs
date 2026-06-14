//! Help overlay — keybinding glossary (scrollable).

use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem};
use ratatui::Frame;

use crate::app::App;
use crate::keymap::GLOSSARY;

/// Total rows the glossary renders to: 2 (blank + header) per new group, plus
/// one per entry. Must mirror the line-building loop below.
fn glossary_line_count() -> usize {
    let mut n = 0;
    let mut last = "";
    for e in GLOSSARY {
        if e.group != last {
            n += 2;
            last = e.group;
        }
        n += 1;
    }
    n
}

pub fn draw(frame: &mut Frame, area: ratatui::layout::Rect, app: &mut App) {
    let rect = super::centered_rect(86, 32, area);
    frame.render_widget(Clear, rect);

    // Clamp scroll first (mutable) so we don't hold a &theme borrow across it.
    let viewport = rect.height.saturating_sub(2) as usize;
    let total = glossary_line_count();
    let max_scroll = total.saturating_sub(viewport);
    if app.help_scroll > max_scroll {
        app.help_scroll = max_scroll;
    }
    let start = app.help_scroll;
    let end = (start + viewport).min(total);
    let pos = if max_scroll == 0 {
        "all".to_string()
    } else {
        format!("{}–{}/{}", start + 1, end, total)
    };

    let theme = &app.theme;
    let mut lines: Vec<Line> = Vec::with_capacity(total);
    let mut last_group = "";
    for entry in GLOSSARY {
        if entry.group != last_group {
            lines.push(Line::raw(""));
            lines.push(Line::styled(
                format!(" ── {} ──", entry.group),
                theme.s_accent(),
            ));
            last_group = entry.group;
        }
        lines.push(Line::from(vec![
            Span::styled(format!(" {:<16}", entry.keys), theme.s_subtle()),
            Span::styled(entry.action.to_string(), theme.s_normal()),
        ]));
    }

    let title = format!("Help — keybindings  ({pos})  ·  j/k scroll · Esc close");
    let block = super::pane_block(&title, true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let visible: Vec<ListItem> = lines[start..end]
        .iter()
        .cloned()
        .map(ListItem::new)
        .collect();
    let list = List::new(visible).style(theme.s_normal());
    frame.render_widget(list, inner);
}
