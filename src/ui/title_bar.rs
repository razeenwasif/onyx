//! Top title bar — shows the app name, vault, and the currently-open note.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let mut spans: Vec<Span<'static>> = Vec::new();
    spans.push(Span::styled(
        "  ◆ Onyx ",
        theme.s_accent().add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled(
        format!("· {}  ", app.vault.root.display()),
        theme.s_subtle(),
    ));
    if let Some(doc) = &app.doc {
        let title = doc.title();
        let dirty = if doc.dirty { " ●" } else { "" };
        spans.push(Span::styled(
            format!("· {title}{dirty}"),
            theme.s_normal().add_modifier(Modifier::BOLD),
        ));
    } else {
        spans.push(Span::styled("· no note open", theme.s_subtle()));
    }
    // Right side: index stats.
    let stats = app.vault.index.stats();
    let right = format!(
        "{} notes  {} links  {} tags  ",
        stats.notes, stats.links, stats.tags
    );
    let mut line = Line::from(spans);
    // Pad to push right text to the edge.
    let used: usize = line
        .spans
        .iter()
        .map(|s| unicode_width::UnicodeWidthStr::width(s.content.as_ref()))
        .sum();
    let total = area.width as usize;
    let right_w = unicode_width::UnicodeWidthStr::width(right.as_str());
    if used + right_w + 1 < total {
        let pad = total - used - right_w;
        line.spans.push(Span::raw(" ".repeat(pad)));
        line.spans.push(Span::styled(right, theme.s_subtle()));
    }
    let p = Paragraph::new(line).style(
        ratatui::style::Style::default()
            .bg(theme.bg_alt.to_color())
            .fg(theme.fg.to_color()),
    );
    frame.render_widget(p, area);
}
