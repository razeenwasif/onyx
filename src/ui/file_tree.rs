//! Left sidebar — the vault file tree.

use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState};
use ratatui::Frame;

use crate::app::{App, Focus};
use crate::vault::tree::{ExpansionSet, TreeNode};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

struct Expansion<'a>(&'a HashSet<PathBuf>);
impl<'a> ExpansionSet for Expansion<'a> {
    fn is_expanded(&self, path: &Path) -> bool {
        self.0.contains(path)
    }
}

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let focused = app.focus == Focus::FileTree;
    let block = super::pane_block(
        &format!("Files · {}", app.vault.tree.notes.len()),
        focused,
        &app.theme,
    );
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let theme = &app.theme;
    let exp = Expansion(&app.expanded_dirs);
    let nodes = app.vault.tree.flatten(&exp);
    let items: Vec<ListItem> = nodes
        .iter()
        .enumerate()
        .map(|(i, node)| render_node(i, node, app, theme))
        .collect();

    if app.tree_selected >= items.len() {
        app.tree_selected = items.len().saturating_sub(1);
    }
    let mut state = ListState::default();
    if !items.is_empty() {
        state.select(Some(app.tree_selected));
    }

    let list = List::new(items)
        .highlight_style(theme.s_selection())
        .highlight_symbol(" ▸ ");
    frame.render_stateful_widget(list, inner, &mut state);
}

fn render_node<'a>(
    _i: usize,
    node: &TreeNode,
    app: &App,
    theme: &crate::theme::Theme,
) -> ListItem<'a> {
    let indent = "  ".repeat(node.depth.saturating_sub(1));
    let icon = if node.is_dir {
        if app.expanded_dirs.contains(&node.path) {
            ""
        } else {
            ""
        }
    } else {
        "󰈙"
    };
    let name = node.name.clone();
    let name = if !node.is_dir {
        name.trim_end_matches(".md")
            .trim_end_matches(".markdown")
            .trim_end_matches(".mdx")
            .to_string()
    } else {
        name
    };
    let style = if node.is_dir {
        theme.s_accent()
    } else if app
        .doc
        .as_ref()
        .and_then(|d| d.path.as_ref())
        .map(|p| p == &node.path)
        .unwrap_or(false)
    {
        theme.s_accent()
    } else {
        theme.s_normal()
    };
    ListItem::new(Line::from(vec![
        Span::raw(indent),
        Span::styled(format!("{} ", icon), theme.s_subtle()),
        Span::styled(name, style),
    ]))
}

/// Currently-selected tree node, given flattened ordering.
pub fn selected_node(app: &App) -> Option<TreeNode> {
    let exp = Expansion(&app.expanded_dirs);
    let nodes = app.vault.tree.flatten(&exp);
    nodes.get(app.tree_selected).map(|n| (*n).clone())
}
