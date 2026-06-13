//! Right-of-editor pane — rendered markdown preview.
//!
//! The rendered `Text` is cached on `App` keyed by (note, buffer revision,
//! width, theme), so markdown is re-parsed only when one of those changes —
//! not on every frame (cursor moves, graph ticks, idle redraws).

use std::collections::HashSet;

use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{App, Focus, PreviewCache};
use crate::markdown::parse::{extract_frontmatter_properties, strip_frontmatter};
use crate::markdown::render_to_text_with;
use crate::theme::Theme;

/// Hash the fold state so the preview cache re-renders when a callout is toggled
/// or the fold cursor moves.
fn fold_signature(collapsed: &HashSet<usize>, selected: Option<usize>) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut v: Vec<usize> = collapsed.iter().copied().collect();
    v.sort_unstable();
    let mut h = std::collections::hash_map::DefaultHasher::new();
    v.hash(&mut h);
    selected.hash(&mut h);
    h.finish()
}

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let focused = app.focus == Focus::Preview;
    let block = super::pane_block("Preview", focused, &app.theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let doc = match &app.doc {
        Some(d) => d,
        None => {
            let p = Paragraph::new("— nothing to preview —")
                .style(app.theme.s_subtle())
                .wrap(Wrap { trim: false });
            frame.render_widget(p, inner);
            return;
        }
    };

    let path = doc.path.clone();
    let rev = doc.buffer.revision;
    let width = inner.width;
    let theme_gen = app.theme_gen;
    // The fold cursor is only shown (highlighted) while the preview is focused.
    let selected = if focused {
        Some(app.preview_fold_sel)
    } else {
        None
    };
    let fold_sig = fold_signature(&app.preview_collapsed, selected);

    let mut cache = app.preview_cache.borrow_mut();
    let hit = cache
        .as_ref()
        .map(|c| {
            c.path == path
                && c.rev == rev
                && c.width == width
                && c.theme_gen == theme_gen
                && c.fold_sig == fold_sig
        })
        .unwrap_or(false);

    if !hit {
        let src = doc.buffer.to_string();
        let text = build_preview_text(
            &src,
            &app.theme,
            width as usize,
            &app.preview_collapsed,
            selected,
        );
        *cache = Some(PreviewCache {
            path: path.clone(),
            rev,
            width,
            theme_gen,
            fold_sig,
            text,
        });
    }

    let text = cache.as_ref().unwrap().text.clone();
    let p = Paragraph::new(text)
        .style(app.theme.s_normal())
        .wrap(Wrap { trim: false });
    frame.render_widget(p, inner);
}

/// Build the preview: a Notion-style page-properties block (from YAML
/// frontmatter) on top, then the markdown body with the raw frontmatter
/// stripped. Notes without frontmatter render exactly as before.
fn build_preview_text(
    src: &str,
    theme: &Theme,
    width: usize,
    collapsed: &HashSet<usize>,
    selected: Option<usize>,
) -> Text<'static> {
    // Show every frontmatter property except tags (those have their own pane).
    let props: Vec<(String, Vec<String>)> = extract_frontmatter_properties(src)
        .into_iter()
        .filter(|(k, _)| {
            let lk = k.to_ascii_lowercase();
            !matches!(lk.as_str(), "tags" | "tag" | "aliases" | "alias")
        })
        .collect();

    let mut lines: Vec<Line<'static>> = Vec::new();
    if !props.is_empty() {
        let key_w = props
            .iter()
            .map(|(k, _)| k.chars().count())
            .max()
            .unwrap_or(0)
            .clamp(1, 18);
        lines.push(Line::styled(
            "Properties",
            theme.s_accent().add_modifier(Modifier::BOLD),
        ));
        for (k, vals) in &props {
            let val = if vals.is_empty() {
                "—".to_string()
            } else {
                vals.join(", ")
            };
            lines.push(Line::from(vec![
                Span::styled(
                    format!("{k:<key_w$}  "),
                    theme.s_subtle().add_modifier(Modifier::BOLD),
                ),
                Span::styled(val, theme.s_normal()),
            ]));
        }
        lines.push(Line::styled(
            "─".repeat(width.clamp(1, 60)),
            theme.s_subtle(),
        ));
        lines.push(Line::raw(""));
    }

    let body = strip_frontmatter(src);
    let mut text = Text::from(lines);
    text.lines
        .extend(render_to_text_with(body, theme, width, collapsed, selected).lines);
    text
}
