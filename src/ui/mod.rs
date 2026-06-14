//! Top-level UI compositor.

pub mod agenda;
pub mod ai;
pub mod calendar;
pub mod cmdline;
pub mod confirm;
pub mod database;
pub mod drive;
pub mod editor_pane;
pub mod file_tree;
pub mod graph;
pub mod gtasks;
pub mod help;
pub mod home;
pub mod palette;
pub mod preview;
pub mod prompt;
pub mod props;
pub mod quicknote;
pub mod search;
pub mod sidebar;
pub mod splitview;
pub mod status;
pub mod switcher;
pub mod tabline;
pub mod tasks;
pub mod title_bar;
pub mod todo;

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::widgets::Clear;
use ratatui::Frame;

use crate::app::{App, Focus, FullPane};

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();

    // Top: title bar, Bottom: status bar.
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // title
            Constraint::Min(0),    // body
            Constraint::Length(1), // status
        ])
        .split(area);

    title_bar::draw(frame, outer[0], app);
    if app.focus == Focus::CommandLine {
        cmdline::draw(frame, outer[2], app);
    } else {
        status::draw(frame, outer[2], app);
    }

    if app.database.is_some() {
        // The database view is modal and fills the whole body for max width.
        database::draw_body(frame, outer[1], app);
    } else {
        match app.fullscreen {
            Some(FullPane::Graph) => graph::draw(frame, outer[1], app, true),
            Some(FullPane::Calendar) => draw_calendar_fullscreen(frame, outer[1], app),
            None => draw_body(frame, outer[1], app),
        }
    }

    // Overlays.
    match app.focus {
        Focus::Palette => palette::draw(frame, area, app),
        Focus::Switcher => switcher::draw(frame, area, app),
        Focus::Search => search::draw(frame, area, app),
        Focus::Help => help::draw(frame, area, app),
        Focus::Prompt => prompt::draw(frame, area, app),
        Focus::Confirm => confirm::draw(frame, area, app),
        Focus::Tasks => tasks::draw(frame, area, app),
        Focus::Properties => props::draw(frame, area, app),
        Focus::GoogleTasks => gtasks::draw(frame, area, app),
        Focus::Agenda => agenda::draw(frame, area, app),
        Focus::Drive => drive::draw(frame, area, app),
        Focus::Ai => ai::draw(frame, area, app),
        _ => {}
    }
    if app.help_open && app.focus != Focus::Help {
        help::draw(frame, area, app);
    }
}

fn draw_body(frame: &mut Frame, area: Rect, app: &mut App) {
    // Compose left | center | right with widths from config.
    let mut constraints: Vec<Constraint> = Vec::new();
    if app.show_left {
        constraints.push(Constraint::Length(app.config.layout.sidebar_left_width.max(16)));
    }
    constraints.push(Constraint::Min(40));
    if app.show_right {
        constraints.push(Constraint::Length(app.config.layout.sidebar_right_width.max(20)));
    }

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints(constraints)
        .split(area);

    let mut idx = 0;
    if app.show_left {
        draw_left_column(frame, cols[idx], app);
        idx += 1;
    }

    let center = cols[idx];
    idx += 1;

    if app.doc.is_none() {
        // No note open → the interactive start page fills the center (no preview).
        home::draw(frame, center, app);
    } else {
        // A one-row tab bar tops the center when >1 note is open.
        let body = if app.tab_paths.len() >= 2 {
            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Length(1), Constraint::Min(0)])
                .split(center);
            tabline::draw(frame, rows[0], app);
            rows[1]
        } else {
            center
        };
        if app.show_preview {
            // Editor|preview divider, adjustable with Ctrl-←/→ (persisted).
            let editor_pct = app.config.layout.editor_split_percent.clamp(20, 80);
            let center_split = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(editor_pct),
                    Constraint::Percentage(100 - editor_pct),
                ])
                .split(body);
            editor_pane::draw(frame, center_split[0], app);
            if app.split_doc.is_some() {
                splitview::draw(frame, center_split[1], app);
            } else {
                preview::draw(frame, center_split[1], app);
            }
        } else {
            editor_pane::draw(frame, body, app);
        }
    }

    if app.show_right {
        sidebar::draw(frame, cols[idx], app);
    }

    // Clear ensures background is painted under each pane (handled per-widget).
    let _ = Clear;
}

/// Left column: Files (top), Quicknote, Todo — each toggleable, files flexible.
fn draw_left_column(frame: &mut Frame, area: Rect, app: &mut App) {
    let mut constraints: Vec<Constraint> = vec![Constraint::Min(4)]; // files
    if app.show_quicknote {
        constraints.push(Constraint::Length(app.config.layout.quicknote_height.max(3)));
    }
    if app.show_todo {
        constraints.push(Constraint::Length(app.config.layout.todo_height.max(3)));
    }
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints(constraints)
        .split(area);

    let mut i = 0;
    file_tree::draw(frame, chunks[i], app);
    i += 1;
    if app.show_quicknote {
        quicknote::draw(frame, chunks[i], app);
        i += 1;
    }
    if app.show_todo {
        todo::draw(frame, chunks[i], app);
    }
}

/// Calendar expanded to fill the body.
fn draw_calendar_fullscreen(frame: &mut Frame, area: Rect, app: &App) {
    let block = pane_block("Calendar", true, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    calendar::draw(frame, inner, app);
}

/// Compute a centered rect of (width, height) inside `outer`.
pub fn centered_rect(width: u16, height: u16, outer: Rect) -> Rect {
    let w = width.min(outer.width.saturating_sub(4)).max(20);
    let h = height.min(outer.height.saturating_sub(2)).max(8);
    let x = outer.x + (outer.width.saturating_sub(w)) / 2;
    let y = outer.y + (outer.height.saturating_sub(h)) / 2;
    Rect {
        x,
        y,
        width: w,
        height: h,
    }
}

/// Build a `Block` with theme borders (focused vs unfocused).
pub fn pane_block(title: &str, focused: bool, theme: &crate::theme::Theme) -> ratatui::widgets::Block<'static> {
    use ratatui::style::Style;
    use ratatui::text::Span;
    use ratatui::widgets::{Block, BorderType, Borders};
    let style = if focused {
        theme.s_border_focus()
    } else {
        theme.s_border()
    };
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(style)
        .title(Span::styled(
            format!(" {title} "),
            if focused {
                theme.s_accent()
            } else {
                Style::default().fg(theme.fg_dim.to_color())
            },
        ))
        .style(Style::default().bg(theme.bg.to_color()))
}
