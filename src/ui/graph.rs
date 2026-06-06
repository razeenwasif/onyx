//! ASCII graph view of vault notes and their wikilinks.
//!
//! A real force-directed layout in a terminal is overkill — instead we use
//! a deterministic concentric-ring layout centered on the currently-open
//! note (or the most-linked note if none is open). Edges are drawn with
//! line-character approximations.

use std::path::Path;

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

    // The force-directed simulation (built/stepped by App::tick_graph).
    let Some(sim) = app.graph_sim.as_ref() else {
        let p = Paragraph::new("Graph: building…").style(theme.s_subtle());
        frame.render_widget(p, inner);
        return;
    };
    if sim.nodes.is_empty() {
        let p = Paragraph::new("Graph: no notes yet.").style(theme.s_subtle());
        frame.render_widget(p, inner);
        return;
    }

    // Map simulation coordinates → cell grid. The centered node sits at the
    // origin and is placed at the grid center; everything scales to fit, with a
    // 2× horizontal factor so dots look round in the ~2:1 terminal cell aspect.
    let cx = width / 2;
    let cy = height / 2;
    let aspect = 2.0f32;
    let maxr = sim.max_radius();
    let scale_x = (width as f32 / 2.0 - 1.0) / (maxr * aspect).max(1.0);
    let scale_y = (height as f32 / 2.0 - 1.0) / maxr.max(1.0);
    let scale = scale_x.min(scale_y).max(0.01);
    let to_cell = |x: f32, y: f32| -> (i32, i32) {
        let col = cx + (x * aspect * scale).round() as i32;
        let row = cy + (y * scale).round() as i32;
        (col.clamp(0, width - 1), row.clamp(0, height - 1))
    };

    let mut grid: Vec<Vec<char>> = vec![vec![' '; width as usize]; height as usize];
    let mut styles: Vec<Vec<Option<Style>>> = vec![vec![None; width as usize]; height as usize];

    // Edges first (so dots paint over them). Link edges subtle, tag edges tinted.
    let tag_edge_style = Style::default().fg(theme.tag.to_color());
    for &(a, b, kind) in &sim.edges {
        let (Some(na), Some(nb)) = (sim.nodes.get(a), sim.nodes.get(b)) else {
            continue;
        };
        let style = match kind {
            crate::graph_sim::EdgeKind::Link => theme.s_subtle(),
            crate::graph_sim::EdgeKind::Tag => tag_edge_style,
        };
        draw_line(
            &mut grid,
            &mut styles,
            to_cell(na.x, na.y),
            to_cell(nb.x, nb.y),
            style,
        );
    }

    // Nodes as colored dots — no labels (Obsidian-style). Higher-degree nodes
    // use a bolder glyph; the centered note is reversed so it pops.
    for (i, nd) in sim.nodes.iter().enumerate() {
        let (x, y) = to_cell(nd.x, nd.y);
        let color = node_color(app, &nd.path);
        let (glyph, style) = if i == sim.center {
            (
                '◉',
                Style::default()
                    .fg(color)
                    .add_modifier(Modifier::BOLD | Modifier::REVERSED),
            )
        } else {
            let glyph = if nd.degree >= 5 { '⬤' } else { '●' };
            (glyph, Style::default().fg(color).add_modifier(Modifier::BOLD))
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

    // Header line: scope + centered note + count + hints.
    let center_node = &sim.nodes[sim.center];
    let scope = if sim.global { "all notes" } else { "local" };
    let header = Line::from(vec![
        Span::styled("◉ ", Style::default().fg(node_color(app, &center_node.path))),
        Span::styled(
            vault::note_basename(&center_node.path),
            theme.s_accent().add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(
                "   {} nodes · {scope}   (a: scope · Enter: fullscreen · o: open · Esc: back)",
                sim.nodes.len()
            ),
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
