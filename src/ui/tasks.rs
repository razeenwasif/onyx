//! Vault-wide task rollup overlay — every `- [ ]` checkbox across the vault,
//! open ones first, with jump-to-note on Enter.

use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState};
use ratatui::Frame;

use crate::app::App;
use crate::vault;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let rect = super::centered_rect(area.width.saturating_sub(8).min(110), area.height.saturating_sub(4), area);
    frame.render_widget(Clear, rect);

    let open = app.tasks.items.iter().filter(|t| !t.done).count();
    let title = format!("Tasks · {} open · {} total", open, app.tasks.items.len());
    let block = super::pane_block(&title, true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    if app.tasks.items.is_empty() {
        frame.render_widget(
            ratatui::widgets::Paragraph::new("— no tasks in the vault — add a \"- [ ] …\" line —")
                .style(theme.s_subtle()),
            inner,
        );
        return;
    }

    let items: Vec<ListItem> = app
        .tasks
        .items
        .iter()
        .map(|t| {
            let rel = vault::note_relpath(&app.vault.root, &t.path);
            let (box_str, text_style) = if t.done {
                ("[x] ", theme.s_subtle().add_modifier(Modifier::CROSSED_OUT))
            } else {
                ("[ ] ", theme.s_normal())
            };
            let box_style = if t.done {
                Style::default().fg(theme.success.to_color())
            } else {
                theme.s_accent()
            };
            ListItem::new(Line::from(vec![
                Span::styled(box_str, box_style),
                Span::styled(t.text.clone(), text_style),
                Span::styled(format!("   {rel}:{}", t.line + 1), theme.s_subtle()),
            ]))
        })
        .collect();

    let mut state = ListState::default();
    state.select(Some(app.tasks.selected.min(app.tasks.items.len().saturating_sub(1))));
    let list = List::new(items)
        .highlight_style(theme.s_selection())
        .highlight_symbol("▸ ");
    frame.render_stateful_widget(list, inner, &mut state);
}
