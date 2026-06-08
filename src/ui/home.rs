//! Home start page — the landing shown in the center pane when no note is open.
//! An interactive menu of quick actions plus the most recent notes; navigate
//! with j/k and press Enter to act. Built from `App::home_items` so the rendered
//! list and the dispatch handler can never drift.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::{App, Focus, HomeAction};

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let focused = app.focus == Focus::Home;
    let block = super::pane_block("Home", focused, theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let items = app.home_items();
    let sel = app.home_selected.min(items.len().saturating_sub(1));

    let mut lines: Vec<Line<'static>> = vec![
        Line::raw(""),
        Line::styled(
            "   ◆ Onyx",
            theme.s_accent().add_modifier(Modifier::BOLD),
        ),
        Line::styled("   a premium markdown vault", theme.s_subtle()),
        Line::raw(""),
    ];

    let mut recent_header = false;
    for (i, it) in items.iter().enumerate() {
        if matches!(it.action, HomeAction::OpenRecent(_)) && !recent_header {
            lines.push(Line::raw(""));
            lines.push(Line::styled("   Recent notes", theme.s_subtle()));
            recent_header = true;
        }
        let selected = i == sel;
        let marker = if selected { "▸" } else { " " };
        // Highlight the selected row only while Home actually has focus.
        let label_style = if selected && focused {
            theme.s_accent().add_modifier(Modifier::BOLD)
        } else if selected {
            theme.s_accent()
        } else {
            theme.s_normal()
        };
        let mut spans = vec![Span::styled(
            format!("  {marker} {}  {}", it.icon, it.label),
            label_style,
        )];
        if !it.hint.is_empty() {
            spans.push(Span::styled(format!("   {}", it.hint), theme.s_dim()));
        }
        lines.push(Line::from(spans));
    }

    lines.push(Line::raw(""));
    lines.push(Line::styled(
        "   j/k move · Enter open · Ctrl-/ help",
        theme.s_dim(),
    ));

    let p = Paragraph::new(lines).style(theme.s_normal());
    frame.render_widget(p, inner);
}
