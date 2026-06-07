//! Left sidebar — the vault file tree.

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState};
use ratatui::Frame;

use crate::app::{App, Focus, TreeRow};

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::FileTree;
    let block = super::pane_block(
        &format!("Files · {}", app.vault.tree.notes.len()),
        focused,
        &app.theme,
    );
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let rows = app.visible_tree(); // cached flattened view
    let theme = &app.theme;
    let items: Vec<ListItem> = rows.iter().map(|row| render_row(row, app, theme)).collect();
    let len = items.len();
    drop(rows);

    if app.tree_selected >= len {
        app.tree_selected = len.saturating_sub(1);
    }
    let mut state = ListState::default();
    if len > 0 {
        state.select(Some(app.tree_selected));
    }

    let list = List::new(items)
        .highlight_style(app.theme.s_selection())
        .highlight_symbol(" ▸ ");
    frame.render_stateful_widget(list, inner, &mut state);
}

fn render_row<'a>(row: &TreeRow, app: &App, theme: &crate::theme::Theme) -> ListItem<'a> {
    let indent = "  ".repeat(row.depth.saturating_sub(1));
    // Folders show an expand/collapse chevron; notes show a doc glyph.
    let icon = if row.is_dir {
        if app.expanded_dirs.contains(&row.path) {
            "▾"
        } else {
            "▸"
        }
    } else {
        "󰈙"
    };
    let name = if !row.is_dir {
        row.name
            .trim_end_matches(".md")
            .trim_end_matches(".markdown")
            .trim_end_matches(".mdx")
            .to_string()
    } else {
        row.name.clone()
    };
    let is_current = !row.is_dir
        && app
            .doc
            .as_ref()
            .and_then(|d| d.path.as_ref())
            .map(|p| p == &row.path)
            .unwrap_or(false);
    let style = if row.is_dir {
        theme.s_accent()
    } else if is_current {
        // The open note is highlighted bold to set it apart from folders.
        theme.s_accent().add_modifier(Modifier::BOLD)
    } else {
        theme.s_normal()
    };
    ListItem::new(Line::from(vec![
        Span::raw(indent),
        Span::styled(format!("{} ", icon), theme.s_subtle()),
        Span::styled(name, style),
    ]))
}

/// Currently-selected file-tree row, given flattened ordering.
pub fn selected_node(app: &App) -> Option<TreeRow> {
    app.visible_tree().get(app.tree_selected).cloned()
}
