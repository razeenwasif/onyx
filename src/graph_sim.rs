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
    rng: u64,
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

impl GraphSim {
    pub fn new(
        node_paths: Vec<PathBuf>,
        edges: Vec<(usize, usize, EdgeKind)>,
        center: usize,
        built_for: Option<PathBuf>,
        global: bool,
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
        // Seed positions on a circle so the first frame is already spread out.
        let nodes = node_paths
            .into_iter()
            .enumerate()
            .map(|(i, path)| {
                let pinned = i == center;
                let angle = (i as f32) * std::f32::consts::TAU / n as f32;
                let r = if pinned { 0.0 } else { 10.0 };
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
        Self {
            nodes,
            edges,
            center,
            built_for,
            global,
            rng: 0x9E3779B97F4A7C15,
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

    /// Advance the simulation by one frame.
    pub fn step(&mut self) {
        let n = self.nodes.len();
        if n == 0 {
            return;
        }
        let mut fx = vec![0f32; n];
        let mut fy = vec![0f32; n];

        // Pairwise repulsion (O(n²) — node sets are capped).
        for i in 0..n {
            for j in (i + 1)..n {
                let dx = self.nodes[i].x - self.nodes[j].x;
                let dy = self.nodes[i].y - self.nodes[j].y;
                let d2 = dx * dx + dy * dy + 0.05;
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

        // Spring attraction along edges.
        for &(a, b, _) in &self.edges {
            if a >= n || b >= n {
                continue;
            }
            let dx = self.nodes[b].x - self.nodes[a].x;
            let dy = self.nodes[b].y - self.nodes[a].y;
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
