//! Right sidebar — a tabbed pane (Backlinks · Outline · Tags) with the
//! calendar optionally docked in the lower half.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::{App, Focus, SidebarTab};
use crate::vault;

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    // Right column: tabbed pane (top), then optional Graph pane, then the
    // Calendar hugging a fixed height at the bottom.
    let cal_h = app.config.layout.calendar_height.max(8);
    let mut constraints: Vec<Constraint> = vec![Constraint::Min(4)]; // tabbed
    if app.show_graph_pane {
        constraints.push(Constraint::Min(6)); // graph shares remaining space
    }
    if app.show_calendar {
        constraints.push(Constraint::Length(cal_h));
    }
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints(constraints)
        .split(area);

    let mut i = 0;
    draw_tabbed(frame, chunks[i], app);
    i += 1;
    if app.show_graph_pane {
        super::graph::draw(frame, chunks[i], app, app.focus == Focus::Graph);
        i += 1;
    }
    if app.show_calendar {
        draw_calendar_pane(frame, chunks[i], app);
    }
}

fn draw_tabbed(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::Sidebar;
    let block = super::pane_block(app.sidebar_tab.label(), focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0)])
        .split(inner);

    draw_tabs(frame, split[0], app);
    match app.sidebar_tab {
        SidebarTab::Backlinks => draw_backlinks(frame, split[1], app),
        SidebarTab::Outline => draw_outline(frame, split[1], app),
        SidebarTab::Tags => draw_tags(frame, split[1], app),
    }
}

fn draw_calendar_pane(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::Calendar;
    let block = super::pane_block("Calendar", focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    super::calendar::draw(frame, inner, app);
}

fn draw_tabs(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let mut spans: Vec<Span<'static>> = Vec::new();
    for (i, tab) in [
        SidebarTab::Backlinks,
        SidebarTab::Outline,
        SidebarTab::Tags,
    ]
    .iter()
    .enumerate()
    {
        if i > 0 {
            spans.push(Span::styled(" · ", theme.s_subtle()));
        }
        let style = if *tab == app.sidebar_tab {
            theme.s_accent().add_modifier(Modifier::BOLD)
        } else {
            theme.s_dim()
        };
        spans.push(Span::styled(tab.label().to_string(), style));
    }
    let p = Paragraph::new(Line::from(spans));
    frame.render_widget(p, area);
}

fn draw_backlinks(frame: &mut Frame, area: Rect, app: &mut App) {
    let theme = &app.theme;
    let path = match app.doc.as_ref().and_then(|d| d.path.clone()) {
        Some(p) => p,
        None => {
            let p = Paragraph::new("Open a note to see its backlinks.").style(theme.s_subtle());
            frame.render_widget(p, area);
            return;
        }
    };
    let backs = app.vault.index.backlinks_for(&path);
    if backs.is_empty() {
        let p = Paragraph::new("— no backlinks yet —").style(theme.s_subtle());
        frame.render_widget(p, area);
        return;
    }
    let items: Vec<ListItem> = backs
        .iter()
        .map(|p| {
            let rel = vault::note_relpath(&app.vault.root, p);
            let stem = vault::note_basename(p);
            ListItem::new(Line::from(vec![
                Span::styled("← ", theme.s_accent()),
                Span::styled(stem, theme.s_normal()),
                Span::styled(format!("  {rel}"), theme.s_subtle()),
            ]))
        })
        .collect();
    let mut state = ListState::default();
    if app.sidebar_selected < items.len() {
        state.select(Some(app.sidebar_selected));
    }
    let list = List::new(items).highlight_style(theme.s_selection());
    frame.render_stateful_widget(list, area, &mut state);
}

fn draw_outline(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let src = match &app.doc {
        Some(d) => d.buffer.to_string(),
        None => {
            let p = Paragraph::new("Open a note to see its outline.").style(theme.s_subtle());
            frame.render_widget(p, area);
            return;
        }
    };
    let mut items: Vec<ListItem> = Vec::new();
    let mut in_code = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_code = !in_code;
            continue;
        }
        if in_code {
            continue;
        }
        let hashes = trimmed.chars().take_while(|c| *c == '#').count();
        if (1..=6).contains(&hashes) && trimmed.chars().nth(hashes) == Some(' ') {
            let title = trimmed[hashes + 1..].trim();
            let indent = "  ".repeat(hashes.saturating_sub(1));
            items.push(ListItem::new(Line::from(vec![
                Span::raw(indent),
                Span::styled(format!("§ {}", title), theme.s_heading(hashes as u8)),
            ])));
        }
    }
    if items.is_empty() {
        let p = Paragraph::new("— no headings —").style(theme.s_subtle());
        frame.render_widget(p, area);
        return;
    }
    let list = List::new(items).highlight_style(theme.s_selection());
    let mut state = ListState::default();
    frame.render_stateful_widget(list, area, &mut state);
}

fn draw_tags(frame: &mut Frame, area: Rect, app: &mut App) {
    let theme = &app.theme;
    let tags = app.vault.index.all_tags();
    if tags.is_empty() {
        let p = Paragraph::new("— no tags yet — add #tag to a note —").style(theme.s_subtle());
        frame.render_widget(p, area);
        return;
    }
    let items: Vec<ListItem> = tags
        .iter()
        .map(|(t, n)| {
            ListItem::new(Line::from(vec![
                Span::styled(format!("#{}", t), theme.s_tag()),
                Span::styled(format!("  {}", n), theme.s_subtle()),
            ]))
        })
        .collect();
    let mut state = ListState::default();
    if app.sidebar_selected < items.len() {
        state.select(Some(app.sidebar_selected));
    }
    let list = List::new(items).highlight_style(theme.s_selection());
    frame.render_stateful_widget(list, area, &mut state);
}
