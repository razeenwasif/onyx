//! ASCII graph view of vault notes and their wikilinks.
//!
//! A real force-directed layout in a terminal is overkill — instead we use
//! a deterministic concentric-ring layout centered on the currently-open
//! note (or the most-linked note if none is open). Edges are drawn with
//! line-character approximations.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::App;
use crate::vault;

/// Subject → colour, from the vault's GRAPH_COLORS_SETUP scheme. Used for the
/// node dots and the legend.
const SUBJECTS: &[(&str, (u8, u8, u8))] = &[
    ("Physics", (0x2E, 0x86, 0xDE)),
    ("Math", (0x52, 0xC4, 0x1A)),
    ("ML", (0xFF, 0x95, 0x00)),
    ("Data Sci", (0x13, 0xC2, 0xC2)),
    ("SWE", (0x72, 0x2E, 0xD1)),
    ("Systems", (0x00, 0x3D, 0xA5)),
    ("Infra", (0xFF, 0x4D, 0x4F)),
    ("Interview", (0xFF, 0x85, 0xC0)),
    ("Lang", (0x5B, 0x21, 0xB6)),
    ("Projects", (0xFA, 0xAD, 0x14)),
    ("Resources", (0x20, 0xB2, 0xAA)),
];

pub fn draw(frame: &mut Frame, area: Rect, app: &App, focused: bool) {
    let theme = &app.theme;
    let block = super::pane_block("Graph", focused, theme);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Reserve one row for the header, plus a 2-row colour legend when the pane
    // is large enough (i.e. fullscreen).
    let legend_rows: i32 = if inner.height >= 20 && inner.width >= 60 { 2 } else { 0 };
    let width = inner.width as i32;
    let height = inner.height as i32 - 1 - legend_rows;
    if width < 16 || height < 6 {
        let p = Paragraph::new("Graph: pane too small.\nEnter = fullscreen.")
            .style(theme.s_subtle());
        frame.render_widget(p, inner);
        return;
    }

    // Pick the center node.
    let center_path: Option<PathBuf> = app
        .graph_focus
        .clone()
        .or_else(|| app.doc.as_ref().and_then(|d| d.path.clone()))
        .or_else(|| most_connected(app));

    let Some(center_path) = center_path else {
        let p = Paragraph::new("Graph: no notes yet.").style(theme.s_subtle());
        frame.render_widget(p, inner);
        return;
    };

    // BFS up to 2 hops from center. Edges are links (out + back) and, since many
    // vaults connect notes by tags rather than links, notes that share a tag.
    let mut layers: Vec<Vec<PathBuf>> = vec![vec![center_path.clone()]];
    let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    seen.insert(center_path.clone());
    // Fewer tag-neighbours on the inner ring keeps the hairball legible.
    let tag_cap = [10usize, 4];
    for hop in 0..2 {
        let mut next = Vec::new();
        for n in &layers[hop] {
            for neighbor in neighbors(app, n, tag_cap[hop]) {
                if seen.insert(neighbor.clone()) {
                    next.push(neighbor);
                }
            }
        }
        if next.is_empty() {
            break;
        }
        // Cap each ring for legibility.
        next.truncate(16);
        layers.push(next);
    }

    // Layout: layer 0 at center, layer 1 ring at r1, layer 2 ring at r2.
    let cx = width / 2;
    let cy = height / 2;
    let r1 = (height.min(width) / 4).max(3);
    let r2 = (height.min(width) / 2 - 2).max(r1 + 2);

    let mut positions: HashMap<PathBuf, (i32, i32)> = HashMap::new();
    positions.insert(center_path.clone(), (cx, cy));

    for (li, layer) in layers.iter().enumerate().skip(1) {
        let n = layer.len() as i32;
        let radius = if li == 1 { r1 } else { r2 };
        for (i, p) in layer.iter().enumerate() {
            let angle = (i as f32) * std::f32::consts::TAU / n.max(1) as f32;
            let x = cx + (angle.cos() * radius as f32 * 2.0) as i32; // x*2 to compensate cell aspect
            let y = cy + (angle.sin() * radius as f32) as i32;
            positions.insert(p.clone(), (x.clamp(1, width - 2), y.clamp(1, height - 1)));
        }
    }

    // Build a character grid + style overlay.
    let mut grid: Vec<Vec<char>> = vec![vec![' '; width as usize]; height as usize];
    let mut styles: Vec<Vec<Option<Style>>> = vec![vec![None; width as usize]; height as usize];

    // Draw edges between layer 0↔1 and 1↔2. Link edges use the subtle colour;
    // tag-only edges use a dim tag colour so the two are distinguishable.
    let tag_edge_style = Style::default().fg(theme.tag.to_color());
    for li in 0..layers.len().saturating_sub(1) {
        for a in &layers[li] {
            for b in &layers[li + 1] {
                let kind = edge_kind(app, a, b);
                let style = match kind {
                    EdgeKind::None => continue,
                    EdgeKind::Link => theme.s_subtle(),
                    EdgeKind::Tag => tag_edge_style,
                };
                if let (Some(&pa), Some(&pb)) = (positions.get(a), positions.get(b)) {
                    draw_line(&mut grid, &mut styles, pa, pb, style);
                }
            }
        }
    }

    // Draw nodes as colored dots (Obsidian-style — no labels). Each node's
    // colour comes from its subject (see `node_color`). The centered note is
    // drawn larger/brighter so it stands out.
    for (path, &(x, y)) in &positions {
        if y < 0 || y >= height || x < 0 || x >= width {
            continue;
        }
        let is_center = path == &center_path;
        let color = node_color(app, path);
        let (glyph, style) = if is_center {
            (
                '◉',
                Style::default()
                    .fg(color)
                    .add_modifier(Modifier::BOLD | Modifier::REVERSED),
            )
        } else {
            ('●', Style::default().fg(color).add_modifier(Modifier::BOLD))
        };
        grid[y as usize][x as usize] = glyph;
        styles[y as usize][x as usize] = Some(style);
    }

    // Render to lines.
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(height as usize);
    for y in 0..height as usize {
        let mut spans: Vec<Span<'static>> = Vec::new();
        let mut x = 0usize;
        while x < width as usize {
            let st = styles[y][x];
            let mut run = String::new();
            while x < width as usize && styles[y][x] == st {
                run.push(grid[y][x]);
                x += 1;
            }
            match st {
                Some(s) => spans.push(Span::styled(run, s)),
                None => spans.push(Span::styled(run, theme.s_normal())),
            }
        }
        lines.push(Line::from(spans));
    }

    // Header line with title (the centered note + a hint).
    let header = Line::from(vec![
        Span::styled("◉ ", Style::default().fg(node_color(app, &center_path))),
        Span::styled(
            vault::note_basename(&center_path),
            theme.s_accent().add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("   {} nodes   (Enter: fullscreen · o: open · Esc: back)", positions.len()),
            theme.s_subtle(),
        ),
    ]);

    let mut all = Vec::with_capacity(lines.len() + 1 + legend_rows as usize);
    all.push(header);
    all.extend(lines);
    if legend_rows > 0 {
        all.extend(legend_lines(theme));
    }
    let p = Paragraph::new(all).style(theme.s_normal());
    frame.render_widget(p, inner);
}

fn most_connected(app: &App) -> Option<PathBuf> {
    let mut best: Option<(usize, PathBuf)> = None;
    for (p, m) in &app.vault.index.notes {
        let deg = m.outgoing.len() + app.vault.index.backlinks_for(p).len();
        match &best {
            None => best = Some((deg, p.clone())),
            Some((d, _)) if deg > *d => best = Some((deg, p.clone())),
            _ => {}
        }
    }
    best.map(|(_, p)| p)
}

/// Colour a node by its subject, matching its tags + folder path against the
/// GRAPH_COLORS_SETUP scheme. First matching rule wins (most specific first).
fn node_color(app: &App, path: &Path) -> Color {
    // Haystack: relative path (folders) + the note's tags, all lowercased.
    let mut hay = vault::note_relpath(&app.vault.root, path).to_lowercase();
    if let Some(meta) = app.vault.index.notes.get(path) {
        for t in &meta.tags {
            hay.push(' ');
            hay.push_str(&t.to_lowercase());
        }
    }

    // (keywords, rgb). Cross-cutting thematic accents first, then subjects.
    type ColorRule = (&'static [&'static str], (u8, u8, u8));
    const RULES: &[ColorRule] = &[
        (&["gravitational"], (0x00, 0x3D, 0xA5)),
        (&["neural"], (0xFF, 0x95, 0x00)),
        (&["probabilistic"], (0x2E, 0x86, 0xDE)),
        (&["cryptograph", "crypto"], (0xFF, 0x4D, 0x4F)),
        (&["optimization", "optimisation"], (0xFA, 0xAD, 0x14)),
        (&["algorithm"], (0xFF, 0x85, 0xC0)),
        (&["machine learning", "ml/", "quantization"], (0xFF, 0x95, 0x00)),
        (&["data science", "data-science"], (0x13, 0xC2, 0xC2)),
        (&["physics"], (0x2E, 0x86, 0xDE)),
        (&["mathematic", "math"], (0x52, 0xC4, 0x1A)),
        (&["software engineering", "software-engineering"], (0x72, 0x2E, 0xD1)),
        (&["systems & architecture", "architecture", "systems"], (0x00, 0x3D, 0xA5)),
        (&["computer networks", "network", "infrastructure"], (0xFF, 0x4D, 0x4F)),
        (&["interview"], (0xFF, 0x85, 0xC0)),
        (&["markup", "programming language", "languages"], (0x5B, 0x21, 0xB6)),
        (&["project", "tinyml", "birdclef", "plantclef", "prism"], (0xFA, 0xAD, 0x14)),
        (&["resource"], (0x20, 0xB2, 0xAA)),
    ];
    for (keys, (r, g, b)) in RULES {
        if keys.iter().any(|k| hay.contains(k)) {
            return Color::Rgb(*r, *g, *b);
        }
    }
    app.theme.fg_subtle.to_color()
}

/// Two compact legend rows mapping dot colours to subjects.
fn legend_lines(theme: &crate::theme::Theme) -> Vec<Line<'static>> {
    let mut rows: Vec<Line<'static>> = Vec::new();
    for chunk in SUBJECTS.chunks(6) {
        let mut spans: Vec<Span<'static>> = Vec::new();
        for (name, (r, g, b)) in chunk {
            spans.push(Span::styled("● ", Style::default().fg(Color::Rgb(*r, *g, *b))));
            spans.push(Span::styled(format!("{name}   "), theme.s_subtle()));
        }
        rows.push(Line::from(spans));
    }
    rows
}

#[derive(Clone, Copy, PartialEq)]
enum EdgeKind {
    None,
    Link,
    Tag,
}

/// Classify the edge between two notes: a real link beats a shared-tag edge.
fn edge_kind(app: &App, a: &PathBuf, b: &PathBuf) -> EdgeKind {
    let idx = &app.vault.index;
    let linked = idx.notes.get(a).map(|m| m.outgoing.contains(b)).unwrap_or(false)
        || idx.notes.get(b).map(|m| m.outgoing.contains(a)).unwrap_or(false);
    if linked {
        EdgeKind::Link
    } else if idx.shares_tag(a, b) {
        EdgeKind::Tag
    } else {
        EdgeKind::None
    }
}

/// Neighbours of a note for graph expansion: linked notes (out + back) first,
/// then up to `tag_cap` notes that share a tag. De-duplicated, link-priority.
fn neighbors(app: &App, path: &PathBuf, tag_cap: usize) -> Vec<PathBuf> {
    let idx = &app.vault.index;
    let mut out: Vec<PathBuf> = Vec::new();
    let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    seen.insert(path.clone());

    if let Some(meta) = idx.notes.get(path) {
        for p in &meta.outgoing {
            if seen.insert(p.clone()) {
                out.push(p.clone());
            }
        }
    }
    for p in idx.backlinks_for(path) {
        if seen.insert(p.clone()) {
            out.push(p);
        }
    }
    for p in idx.shared_tag_notes(path, tag_cap) {
        if seen.insert(p.clone()) {
            out.push(p);
        }
    }
    out
}

fn draw_line(
    grid: &mut [Vec<char>],
    styles: &mut [Vec<Option<Style>>],
    (x0, y0): (i32, i32),
    (x1, y1): (i32, i32),
    style: Style,
) {
    // Bresenham.
    let mut x = x0;
    let mut y = y0;
    let dx = (x1 - x0).abs();
    let sx = if x0 < x1 { 1 } else { -1 };
    let dy = -(y1 - y0).abs();
    let sy = if y0 < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    loop {
        if y >= 0 && (y as usize) < grid.len() && x >= 0 && (x as usize) < grid[0].len() {
            let cur = grid[y as usize][x as usize];
            if cur == ' ' {
                grid[y as usize][x as usize] = '·';
                styles[y as usize][x as usize] = Some(style);
            }
        }
        if x == x1 && y == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            x += sx;
        }
        if e2 <= dx {
            err += dx;
            y += sy;
        }
    }
}
