//! Bottom status bar — mode, cursor, transient messages, hints.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::{App, Focus};

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;

    let (mode_label, mode_style) = if let Some(doc) = &app.doc {
        let label = format!(" {} ", doc.mode.label());
        let style = match doc.mode {
            crate::editor::Mode::Insert => theme.s_accent().add_modifier(Modifier::REVERSED),
            crate::editor::Mode::Visual => {
                ratatui::style::Style::default()
                    .fg(theme.bg.to_color())
                    .bg(theme.warning.to_color())
                    .add_modifier(Modifier::BOLD)
            }
            crate::editor::Mode::Normal | crate::editor::Mode::OpPending => {
                ratatui::style::Style::default()
                    .fg(theme.bg.to_color())
                    .bg(theme.accent.to_color())
                    .add_modifier(Modifier::BOLD)
            }
        };
        (label, style)
    } else {
        (
            " READY ".to_string(),
            ratatui::style::Style::default()
                .fg(theme.bg.to_color())
                .bg(theme.fg_subtle.to_color()),
        )
    };

    let mut spans: Vec<Span<'static>> = Vec::new();
    spans.push(Span::styled(mode_label, mode_style));

    if let Some(doc) = &app.doc {
        let cur = doc.buffer.cursor;
        let words: usize = doc
            .buffer
            .lines
            .iter()
            .map(|l| l.split_whitespace().count())
            .sum();
        spans.push(Span::styled(
            format!(
                " {}:{}  {} lines · {} words ",
                cur.line + 1,
                cur.col + 1,
                doc.buffer.line_count(),
                words
            ),
            theme.s_subtle(),
        ));
        let stats = app.vault.index.stats();
        spans.push(Span::styled(
            format!("· {} unresolved ", stats.unresolved_links),
            if stats.unresolved_links > 0 {
                theme.s_dim()
            } else {
                theme.s_subtle()
            },
        ));
    }

    if let Some(msg) = app.current_status() {
        spans.push(Span::styled(
            format!("· {msg} "),
            ratatui::style::Style::default().fg(theme.info.to_color()),
        ));
    } else {
        spans.push(Span::styled(
            hint_for_focus(app.focus).to_string(),
            theme.s_subtle(),
        ));
    }

    let p = Paragraph::new(Line::from(spans)).style(
        ratatui::style::Style::default()
            .bg(theme.bg_alt.to_color())
            .fg(theme.fg.to_color()),
    );
    frame.render_widget(p, area);
}

fn hint_for_focus(focus: Focus) -> &'static str {
    match focus {
        Focus::FileTree => {
            "· j/k move · Enter open · Space expand · n new · m folder · t database · r rename · d delete"
        }
        Focus::Home => "· j/k move · Enter open/run · Ctrl-N new · Ctrl-O open · Ctrl-/ help",
        Focus::Quicknote => "· type to edit · autosaves · Tab/Esc leave",
        Focus::Todo => "· j/k move · Space toggle · a add · e edit · d delete",
        Focus::Editor => "· i insert · Ctrl-S save · Ctrl-Enter follow link · Ctrl-/ help",
        Focus::Preview => "· j/k fold cursor · Space toggle callout · Tab/Esc back to editor",
        Focus::Sidebar => "· n/p tab (Pages·Backlinks·Outline·Tags) · j/k move · Enter open",
        Focus::Calendar => "· h/j/k/l move · o open day · Enter fullscreen · t today",
        Focus::Palette => "· type to filter · Enter run · Esc cancel",
        Focus::Switcher => "· type to filter · Enter open · Esc cancel",
        Focus::Search => "· type to search · Enter focus results · Esc cancel",
        Focus::Graph => "· a scope · Enter fullscreen · o open node · Esc exit",
        Focus::Database => "· j/k rows · h/l cols · s sort · t board · / filter · Enter open · Esc close",
        Focus::Help => "· Esc close",
        Focus::Settings => "· Esc close",
        Focus::Prompt => "· Enter confirm · Esc cancel",
        Focus::Confirm => "· y confirm · n/Esc cancel",
        Focus::CommandLine => "· :q quit · :w save · :help",
    }
}
