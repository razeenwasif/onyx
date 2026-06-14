//! Local AI assistant (Ollama) chat overlay.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use ratatui::Frame;

use crate::app::{AiRole, App};
use crate::theme::Theme;

/// Wrap `s` to `width` columns (char-based), preserving existing newlines.
fn wrap(s: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    for raw in s.split('\n') {
        let mut line = String::new();
        let mut w = 0usize;
        for word in raw.split_inclusive(' ') {
            let ww = word.chars().count();
            if ww > width {
                if !line.is_empty() {
                    out.push(std::mem::take(&mut line));
                    w = 0;
                }
                for ch in word.chars() {
                    if w >= width {
                        out.push(std::mem::take(&mut line));
                        w = 0;
                    }
                    line.push(ch);
                    w += 1;
                }
            } else {
                if w + ww > width && !line.is_empty() {
                    out.push(std::mem::take(&mut line));
                    w = 0;
                }
                line.push_str(word);
                w += ww;
            }
        }
        out.push(line);
    }
    out
}

/// Build the full (owned) set of conversation lines for the given width.
fn conversation_lines(app: &App, width: usize, theme: &Theme) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();
    if app.ai.turns.is_empty() {
        lines.push(Line::styled(
            "Ask anything. The open note is sent as context.".to_string(),
            theme.s_subtle(),
        ));
        lines.push(Line::styled(
            "Try: \"summarize this\", \"suggest tags\", \"rewrite this clearer\".".to_string(),
            theme.s_subtle(),
        ));
        return lines;
    }
    for turn in &app.ai.turns {
        match turn.role {
            AiRole::User => {
                for (i, l) in wrap(&turn.content, width.saturating_sub(2)).into_iter().enumerate() {
                    let prefix = if i == 0 { "❯ " } else { "  " };
                    lines.push(Line::from(vec![
                        Span::styled(prefix, theme.s_accent().add_modifier(Modifier::BOLD)),
                        Span::styled(l, theme.s_normal().add_modifier(Modifier::BOLD)),
                    ]));
                }
            }
            AiRole::Assistant => {
                if !turn.thinking.trim().is_empty() {
                    for l in wrap(turn.thinking.trim(), width.saturating_sub(2)) {
                        lines.push(Line::styled(
                            format!("· {l}"),
                            theme.s_subtle().add_modifier(Modifier::ITALIC),
                        ));
                    }
                }
                for l in wrap(&turn.content, width) {
                    lines.push(Line::styled(l, theme.s_normal()));
                }
            }
        }
        lines.push(Line::raw("")); // gap between turns
    }
    lines
}

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let rect = super::centered_rect(100, 36, area);
    frame.render_widget(Clear, rect);

    let model = app.config.ai.model.clone();
    let streaming = app.ai_streaming();
    let inner_w = rect.width.saturating_sub(2) as usize; // borders
    let conv_h = rect.height.saturating_sub(4) as usize; // borders + input + sep

    // Build lines (owned) before any mutable borrow of app.
    let lines = {
        let theme = &app.theme;
        conversation_lines(app, inner_w.max(8), theme)
    };
    let total = lines.len();
    let max_scroll = total.saturating_sub(conv_h);
    app.ai.scroll = app.ai.scroll.min(max_scroll);
    let start = max_scroll - app.ai.scroll;
    let end = (start + conv_h).min(total);
    let visible: Vec<Line<'static>> = lines[start..end].to_vec();

    let theme = &app.theme;
    let spin = if app.rag.building {
        if app.rag.total > 0 {
            format!("  ⟳ indexing vault {}/{}…", app.rag.done, app.rag.total)
        } else {
            "  ⟳ indexing vault…".to_string()
        }
    } else if streaming {
        "  ⟳ generating…".to_string()
    } else {
        String::new()
    };
    let title = format!("AI · {model}{spin}");
    let block = super::pane_block(&title, true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(1), Constraint::Length(1)])
        .split(inner);

    frame.render_widget(Paragraph::new(visible).style(theme.s_normal()), rows[0]);

    // Separator-ish hint line.
    let hint = if app.ai.scroll > 0 {
        format!("↑{} more below — PgUp/PgDn scroll", app.ai.scroll)
    } else {
        "Enter send · Esc close · PgUp/PgDn scroll · :ai clear".to_string()
    };
    frame.render_widget(Paragraph::new(Line::styled(hint, theme.s_dim())), rows[1]);

    // Input line.
    let input = Line::from(vec![
        Span::styled("❯ ", theme.s_accent().add_modifier(Modifier::BOLD)),
        Span::styled(app.ai.input.clone(), theme.s_normal()),
        Span::styled(
            if streaming { "" } else { "▏" },
            theme.s_accent().add_modifier(Modifier::SLOW_BLINK),
        ),
    ]);
    frame.render_widget(Paragraph::new(input), rows[2]);
}
