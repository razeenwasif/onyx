//! Help overlay — keybinding glossary.

use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem};
use ratatui::Frame;

use crate::app::App;
use crate::keymap::GLOSSARY;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let rect = super::centered_rect(86, 32, area);
    frame.render_widget(Clear, rect);
    let block = super::pane_block("Help — keybindings", true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let mut items: Vec<ListItem> = Vec::new();
    let mut last_group = "";
    for entry in GLOSSARY {
        if entry.group != last_group {
            items.push(ListItem::new(Line::raw("")));
            items.push(ListItem::new(Line::styled(
                format!(" ── {} ──", entry.group),
                theme.s_accent(),
            )));
            last_group = entry.group;
        }
        items.push(ListItem::new(Line::from(vec![
            Span::styled(format!(" {:<16}", entry.keys), theme.s_subtle()),
            Span::styled(entry.action.to_string(), theme.s_normal()),
        ])));
    }
    let list = List::new(items).style(theme.s_normal());
    frame.render_widget(list, inner);
}
