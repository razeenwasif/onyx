//! A small force-directed graph simulation, à la Obsidian's graph view.
//!
//! Nodes repel each other, edges act as springs, and a weak centering force
//! keeps the whole thing from drifting away. The centered note is pinned at the
//! origin. The simulation is never declared "settled" — a little jitter keeps it
//! gently alive, so it perpetually drifts like Obsidian's.

use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeKind {
    Link,
    Tag,
}

#[derive(Debug, Clone)]
pub struct SimNode {
    pub path: PathBuf,
    pub x: f32,
    pub y: f32,
    pub vx: f32,
    pub vy: f32,
    pub pinned: bool,
    /// Number of edges touching this node (drives dot size).
    pub degree: u32,
}

#[derive(Debug)]
pub struct GraphSim {
    pub nodes: Vec<SimNode>,
    pub edges: Vec<(usize, usize, EdgeKind)>,
    pub center: usize,
    /// The note the sim was built around (to detect when a rebuild is needed).
    pub built_for: Option<PathBuf>,
    pub global: bool,
    /// Frames simulated since build (lets the passive pane settle then freeze).
    pub steps: u32,
    rng: u64,
    /// Reused Barnes-Hut quadtree arena (avoids per-frame allocation).
    quad: Vec<Quad>,
}

// Tuned for a normalized space where nodes start ~10 units from the origin.
const REPULSION: f32 = 7.0;
const SPRING_K: f32 = 0.05;
const SPRING_REST: f32 = 5.0;
const CENTER_K: f32 = 0.012;
const DAMPING: f32 = 0.84;
const DT: f32 = 0.5;
const JITTER: f32 = 0.06;
const POS_CLAMP: f32 = 240.0;
const VEL_CLAMP: f32 = 24.0;

/// Below this node count, exact O(n²) repulsion is cheaper than building a tree.
const BH_THRESHOLD: usize = 96;
/// Barnes-Hut opening angle: smaller = more accurate, larger = faster.
const THETA: f32 = 0.85;
/// Stop subdividing quadtree cells smaller than this (handles coincident nodes).
const MIN_HALF: f32 = 0.5;
/// Softening term to avoid singularities at tiny distances.
const SOFTEN: f32 = 0.05;

/// A node in the Barnes-Hut quadtree (arena-indexed; `-1` = none).
#[derive(Clone, Copy, Debug)]
struct Quad {
    cx: f32,
    cy: f32,
    half: f32,
    sumx: f32,
    sumy: f32,
    count: u32,
    body: i32,
    children: [i32; 4],
}

impl Quad {
    fn new(cx: f32, cy: f32, half: f32) -> Self {
        Quad {
            cx,
            cy,
            half,
            sumx: 0.0,
            sumy: 0.0,
            count: 0,
            body: -1,
            children: [-1; 4],
        }
    }
}

#[inline]
fn quadrant(cx: f32, cy: f32, x: f32, y: f32) -> usize {
    // 0=NW 1=NE 2=SW 3=SE
    let east = (x >= cx) as usize;
    let south = (y >= cy) as usize;
    south * 2 + east
}

fn qt_child(arena: &mut Vec<Quad>, idx: usize, x: f32, y: f32) -> usize {
    let (cx, cy, half) = (arena[idx].cx, arena[idx].cy, arena[idx].half);
    let q = quadrant(cx, cy, x, y);
    if arena[idx].children[q] < 0 {
        let hh = half / 2.0;
        let ncx = if q & 1 == 1 { cx + hh } else { cx - hh };
        let ncy = if q & 2 == 2 { cy + hh } else { cy - hh };
        arena.push(Quad::new(ncx, ncy, hh));
        let ci = (arena.len() - 1) as i32;
        arena[idx].children[q] = ci;
    }
    arena[idx].children[q] as usize
}

fn qt_insert(arena: &mut Vec<Quad>, idx: usize, b: usize, px: &[f32], py: &[f32]) {
    arena[idx].sumx += px[b];
    arena[idx].sumy += py[b];
    arena[idx].count += 1;
    if arena[idx].count == 1 {
        arena[idx].body = b as i32;
        return;
    }
    if arena[idx].half < MIN_HALF {
        // Coincident/degenerate cell: keep as a cluster, don't subdivide.
        arena[idx].body = -1;
        return;
    }
    if arena[idx].body >= 0 {
        let old = arena[idx].body as usize;
        arena[idx].body = -1;
        let c = qt_child(arena, idx, px[old], py[old]);
        qt_insert(arena, c, old, px, py);
    }
    let c = qt_child(arena, idx, px[b], py[b]);
    qt_insert(arena, c, b, px, py);
}

/// Net repulsion on body `b` from the quadtree (Barnes-Hut approximation).
fn qt_force(arena: &[Quad], idx: usize, b: usize, px: &[f32], py: &[f32]) -> (f32, f32) {
    let q = arena[idx];
    if q.count == 0 {
        return (0.0, 0.0);
    }
    if q.body >= 0 {
        let j = q.body as usize;
        if j == b {
            return (0.0, 0.0);
        }
        let dx = px[b] - px[j];
        let dy = py[b] - py[j];
        let d2 = dx * dx + dy * dy + SOFTEN;
        let dist = d2.sqrt();
        let f = REPULSION / d2;
        return (dx / dist * f, dy / dist * f);
    }
    // Internal / clustered cell.
    let inv = 1.0 / q.count as f32;
    let comx = q.sumx * inv;
    let comy = q.sumy * inv;
    let dx = px[b] - comx;
    let dy = py[b] - comy;
    let d2 = dx * dx + dy * dy + SOFTEN;
    let dist = d2.sqrt();
    let has_children = q.children.iter().any(|&c| c >= 0);
    if !has_children || (q.half * 2.0) / dist < THETA {
        let f = REPULSION * q.count as f32 / d2;
        return (dx / dist * f, dy / dist * f);
    }
    let mut fx = 0.0;
    let mut fy = 0.0;
    for &c in &q.children {
        if c >= 0 {
            let (a, b2) = qt_force(arena, c as usize, b, px, py);
            fx += a;
            fy += b2;
        }
    }
    (fx, fy)
}

impl GraphSim {
    pub fn new(
        node_paths: Vec<PathBuf>,
        edges: Vec<(usize, usize, EdgeKind)>,
        center: usize,
        built_for: Option<PathBuf>,
        global: bool,
        pin_center: bool,
    ) -> Self {
        let n = node_paths.len().max(1);
        let mut degree = vec![0u32; node_paths.len()];
        for &(a, b, _) in &edges {
            if a < degree.len() {
                degree[a] += 1;
            }
            if b < degree.len() {
                degree[b] += 1;
            }
        }
        // Seed positions on a spiral so the first frame is already spread out
        // (a plain circle makes large vaults start as a thin ring).
        let nodes = node_paths
            .into_iter()
            .enumerate()
            .map(|(i, path)| {
                let pinned = pin_center && i == center;
                let t = i as f32;
                let angle = t * 2.399_963; // golden angle → even spiral
                let r = if pinned { 0.0 } else { 1.5 * (t + 1.0).sqrt() };
                SimNode {
                    x: angle.cos() * r,
                    y: angle.sin() * r,
                    vx: 0.0,
                    vy: 0.0,
                    pinned,
                    degree: *degree.get(i).unwrap_or(&0),
                    path,
                }
            })
            .collect();
        let _ = n;
        Self {
            nodes,
            edges,
            center,
            built_for,
            global,
            steps: 0,
            rng: 0x9E3779B97F4A7C15,
            quad: Vec::new(),
        }
    }

    fn rand_unit(&mut self) -> f32 {
        // xorshift64* → [-1, 1)
        let mut x = self.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rng = x;
        let v = (x.wrapping_mul(0x2545F4914F6CDD1D) >> 33) as f32 / (1u64 << 31) as f32;
        v - 1.0
    }

    /// Rebuild the Barnes-Hut quadtree over the current positions (arena reused).
    fn build_quadtree(&mut self, px: &[f32], py: &[f32]) {
        self.quad.clear();
        let n = px.len();
        if n == 0 {
            return;
        }
        let (mut minx, mut maxx, mut miny, mut maxy) = (px[0], px[0], py[0], py[0]);
        for k in 1..n {
            minx = minx.min(px[k]);
            maxx = maxx.max(px[k]);
            miny = miny.min(py[k]);
            maxy = maxy.max(py[k]);
        }
        let cx = (minx + maxx) * 0.5;
        let cy = (miny + maxy) * 0.5;
        let half = ((maxx - minx).max(maxy - miny) * 0.5 + 1.0).max(1.0);
        self.quad.push(Quad::new(cx, cy, half));
        for b in 0..n {
            qt_insert(&mut self.quad, 0, b, px, py);
        }
    }

    /// Advance the simulation by one frame.
    pub fn step(&mut self) {
        let n = self.nodes.len();
        if n == 0 {
            return;
        }
        self.steps = self.steps.saturating_add(1);
        let mut fx = vec![0f32; n];
        let mut fy = vec![0f32; n];

        // Snapshot positions so force calc doesn't fight the borrow checker
        // with the (mutably-borrowed) quadtree arena.
        let px: Vec<f32> = self.nodes.iter().map(|nd| nd.x).collect();
        let py: Vec<f32> = self.nodes.iter().map(|nd| nd.y).collect();

        // Repulsion: exact O(n²) for small graphs, Barnes-Hut O(n log n) above
        // a threshold (the global "earth" can hold many hundreds of nodes).
        if n <= BH_THRESHOLD {
            for i in 0..n {
                for j in (i + 1)..n {
                    let dx = px[i] - px[j];
                    let dy = py[i] - py[j];
                    let d2 = dx * dx + dy * dy + SOFTEN;
                    let dist = d2.sqrt();
                    let f = REPULSION / d2;
                    let ux = dx / dist;
                    let uy = dy / dist;
                    fx[i] += ux * f;
                    fy[i] += uy * f;
                    fx[j] -= ux * f;
                    fy[j] -= uy * f;
                }
            }
        } else {
            self.build_quadtree(&px, &py);
            for i in 0..n {
                let (rx, ry) = qt_force(&self.quad, 0, i, &px, &py);
                fx[i] += rx;
                fy[i] += ry;
            }
        }

        // Spring attraction along edges.
        for &(a, b, _) in &self.edges {
            if a >= n || b >= n {
                continue;
            }
            let dx = px[b] - px[a];
            let dy = py[b] - py[a];
            let dist = (dx * dx + dy * dy).sqrt().max(0.01);
            let f = SPRING_K * (dist - SPRING_REST);
            let ux = dx / dist;
            let uy = dy / dist;
            fx[a] += ux * f;
            fy[a] += uy * f;
            fx[b] -= ux * f;
            fy[b] -= uy * f;
        }

        // Centering + jitter, then integrate.
        for i in 0..n {
            if self.nodes[i].pinned {
                self.nodes[i].x = 0.0;
                self.nodes[i].y = 0.0;
                self.nodes[i].vx = 0.0;
                self.nodes[i].vy = 0.0;
                continue;
            }
            fx[i] += -CENTER_K * self.nodes[i].x + self.rand_unit() * JITTER;
            fy[i] += -CENTER_K * self.nodes[i].y + self.rand_unit() * JITTER;

            let mut vx = (self.nodes[i].vx + fx[i] * DT) * DAMPING;
            let mut vy = (self.nodes[i].vy + fy[i] * DT) * DAMPING;
            vx = vx.clamp(-VEL_CLAMP, VEL_CLAMP);
            vy = vy.clamp(-VEL_CLAMP, VEL_CLAMP);
            self.nodes[i].vx = vx;
            self.nodes[i].vy = vy;
            self.nodes[i].x = (self.nodes[i].x + vx * DT).clamp(-POS_CLAMP, POS_CLAMP);
            self.nodes[i].y = (self.nodes[i].y + vy * DT).clamp(-POS_CLAMP, POS_CLAMP);
        }
    }

    /// Max distance of any node from the origin (for scaling to the viewport).
    pub fn max_radius(&self) -> f32 {
        self.nodes
            .iter()
            .map(|nd| (nd.x * nd.x + nd.y * nd.y).sqrt())
            .fold(1.0, f32::max)
    }
}
