//! Database view — renders a folder's notes as a table or a board (kanban),
//! keyed by their frontmatter properties. Pure read-only render off
//! `App::database` (state + logic live in `crate::db_view`).

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use unicode_segmentation::UnicodeSegmentation;

use crate::app::App;
use crate::db_view::{DatabaseView, DbViewMode};
use crate::theme::Theme;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let Some(db) = app.database.as_ref() else {
        return;
    };

    let mode = match db.mode {
        DbViewMode::Table => "table",
        DbViewMode::Board => "board",
    };
    let shown = db.visible_indices().len();
    let count = if db.filter.is_empty() {
        format!("{} rows", db.rows.len())
    } else {
        format!("{shown}/{} rows", db.rows.len())
    };
    let title = format!("Database · {} · {count} · {mode}", db.title);
    let block = super::pane_block(&title, true, theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height < 2 {
        return;
    }
    // Reserve the last row for the key/filter hint.
    let body = Rect {
        height: inner.height - 1,
        ..inner
    };
    let footer = Rect {
        y: inner.y + inner.height - 1,
        height: 1,
        ..inner
    };

    if db.rows.is_empty() {
        frame.render_widget(
            Paragraph::new("— this folder has no notes —").style(theme.s_subtle()),
            body,
        );
    } else {
        match db.mode {
            DbViewMode::Table => draw_table(frame, body, db, theme),
            DbViewMode::Board => draw_board(frame, body, db, theme),
        }
    }
    draw_footer(frame, footer, db, theme);
}

/// Truncate to `width` columns (grapheme-approximate) and right-pad to width.
fn pad_trunc(s: &str, width: usize) -> String {
    if width == 0 {
        return String::new();
    }
    let mut out = trunc(s, width);
    let used = out.graphemes(true).count();
    if used < width {
        out.push_str(&" ".repeat(width - used));
    }
    out
}

/// Truncate to at most `width` graphemes (no padding).
fn trunc(s: &str, width: usize) -> String {
    s.graphemes(true).take(width).collect()
}

fn draw_table(frame: &mut Frame, area: Rect, db: &DatabaseView, theme: &Theme) {
    let total_w = area.width as usize;
    let marker_w = 2usize;
    // Name column ~30% of width, clamped.
    let name_w = (total_w * 3 / 10).clamp(14, 32).min(total_w.saturating_sub(marker_w + 2));
    let mut remaining = total_w.saturating_sub(marker_w + name_w);

    // Choose property columns to show, starting at col_offset, that fit.
    let gap = 1usize;
    let mut shown: Vec<(&str, usize)> = Vec::new();
    for col in db.columns.iter().skip(db.col_offset) {
        if remaining < gap + 6 {
            break;
        }
        let avail = remaining - gap;
        let cw = avail.min(18);
        shown.push((col.as_str(), cw));
        remaining -= gap + cw;
    }

    let vis = db.visible_indices();
    let height = area.height.saturating_sub(1) as usize; // minus header row
    let sel = db.selected.min(vis.len().saturating_sub(1));
    let start = if height > 0 && sel >= height {
        sel + 1 - height
    } else {
        0
    };

    // Header.
    let mut header = vec![Span::raw(pad_trunc("", marker_w))];
    let name_label = match &db.sort_by {
        None => format!("Name {}", if db.sort_desc { "▾" } else { "▴" }),
        _ => "Name".to_string(),
    };
    header.push(Span::styled(pad_trunc(&name_label, name_w), theme.s_accent()));
    for (c, cw) in &shown {
        header.push(Span::raw(" "));
        let label = if db.sort_by.as_deref() == Some(c) {
            format!("{} {}", c, if db.sort_desc { "▾" } else { "▴" })
        } else {
            (*c).to_string()
        };
        header.push(Span::styled(
            pad_trunc(&label, *cw),
            theme.s_subtle().add_modifier(Modifier::BOLD),
        ));
    }
    let mut lines: Vec<Line> = vec![Line::from(header)];

    // Rows.
    for (vi, &ri) in vis.iter().enumerate().skip(start).take(height) {
        let r = &db.rows[ri];
        let selected = vi == sel;
        let row_style = if selected {
            theme.s_selection()
        } else {
            theme.s_normal()
        };
        let cell_style = if selected {
            theme.s_selection()
        } else {
            theme.s_subtle()
        };
        let marker = if selected { "▸ " } else { "  " };
        let mut spans = vec![
            Span::styled(marker.to_string(), row_style),
            Span::styled(pad_trunc(&r.name, name_w), row_style),
        ];
        for (c, cw) in &shown {
            spans.push(Span::styled(" ".to_string(), cell_style));
            spans.push(Span::styled(
                pad_trunc(r.cell(c).unwrap_or(""), *cw),
                cell_style,
            ));
        }
        lines.push(Line::from(spans));
    }

    frame.render_widget(Paragraph::new(lines).style(theme.s_normal()), area);
}

fn draw_board(frame: &mut Frame, area: Rect, db: &DatabaseView, theme: &Theme) {
    let groups = db.groups();
    if groups.is_empty() {
        return;
    }
    // Each board column is ~24 wide; show as many as fit, windowed around the
    // selected group.
    let col_w = 24u16;
    let per = (area.width / col_w).max(1) as usize;
    let start = if db.board_group >= per {
        db.board_group + 1 - per
    } else {
        0
    };
    let visible: Vec<usize> = (start..groups.len()).take(per).collect();
    if visible.is_empty() {
        return;
    }
    let constraints: Vec<Constraint> = visible
        .iter()
        .map(|_| Constraint::Ratio(1, visible.len() as u32))
        .collect();
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints(constraints)
        .split(area);

    for (slot, &gi) in visible.iter().enumerate() {
        let (label, idxs) = &groups[gi];
        let focused = gi == db.board_group;
        let block = super::pane_block(&format!("{label} ({})", idxs.len()), focused, theme);
        let cinner = block.inner(cols[slot]);
        frame.render_widget(block, cols[slot]);
        if cinner.width == 0 || cinner.height == 0 {
            continue;
        }

        let height = cinner.height as usize;
        let sel_card = if focused {
            db.board_card.min(idxs.len().saturating_sub(1))
        } else {
            usize::MAX
        };
        let cstart = if focused && db.board_card >= height {
            db.board_card + 1 - height
        } else {
            0
        };
        let card_w = cinner.width as usize;
        let mut lines: Vec<Line> = Vec::new();
        for (ci, &ri) in idxs.iter().enumerate().skip(cstart).take(height) {
            let r = &db.rows[ri];
            let selected = ci == sel_card;
            let (style, marker) = if selected {
                (theme.s_selection(), "▸ ")
            } else {
                (theme.s_normal(), "  ")
            };
            let text = format!("{marker}{}", trunc(&r.name, card_w.saturating_sub(2)));
            lines.push(Line::from(Span::styled(pad_trunc(&text, card_w), style)));
        }
        frame.render_widget(Paragraph::new(lines).style(theme.s_normal()), cinner);
    }
}

fn draw_footer(frame: &mut Frame, area: Rect, db: &DatabaseView, theme: &Theme) {
    if db.filtering {
        let line = Line::from(vec![
            Span::styled("filter: ", theme.s_accent()),
            Span::styled(db.filter.clone(), theme.s_normal()),
            Span::styled("▌", theme.s_accent()),
        ]);
        frame.render_widget(Paragraph::new(line), area);
        return;
    }
    let hint = match db.mode {
        DbViewMode::Table => "j/k row · h/l cols · s sort · S dir · t board · / filter · ↵ open · Esc close",
        DbViewMode::Board => "j/k card · h/l group · [ ] group-by · t table · / filter · ↵ open · Esc close",
    };
    let mut spans = vec![Span::styled(hint, theme.s_dim())];
    if !db.filter.is_empty() {
        spans.push(Span::styled(
            format!("   filter: {}", db.filter),
            theme.s_subtle(),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// Bridge so `ui::mod` can call with `&mut App` like the other body panes.
pub fn draw_body(frame: &mut Frame, area: Rect, app: &mut App) {
    draw(frame, area, app);
}
