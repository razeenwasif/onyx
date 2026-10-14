//! Renders the Scribe app icon.
//!
//! The mark is a single bold S in cream ink on a velvet-dark tile, with a drop
//! of terracotta ink where the nib lifted: one stroke, no paper, so it reads
//! at any size and sits beside Electron's icon in its app switcher. The
//! stroke is built by the app's ink engine (`scribe_core::geometry::outline`),
//! with pressure rising on downstrokes the way a real nib behaves, so the
//! icon is a picture of what Scribe actually draws.
//!
//! Usage: scribe-icon <out-dir>
//! Writes `AppIcon.iconset/` (every size macOS wants) and `AppIcon-preview.png`.
//! `build.sh` turns the iconset into `AppIcon.icns` with `iconutil`.

use std::f32::consts::PI;
use std::path::PathBuf;

use scribe_core::geometry::{outline, OutlineOptions};
use tiny_skia::{
    Color, FillRule, GradientStop, LinearGradient, Paint, Path, PathBuilder, Pixmap, Point, SpreadMode,
    Transform,
};

/// Design canvas, matching Apple's icon template.
const CANVAS: f32 = 1024.0;
/// The tile sits inside the canvas with room for its shadow.
const TILE: f32 = 824.0;
const TILE_ORIGIN: f32 = (CANVAS - TILE) / 2.0;

fn rgb(hex: u32) -> Color {
    Color::from_rgba8((hex >> 16) as u8, (hex >> 8) as u8, hex as u8, 255)
}

fn rgba(hex: u32, a: f32) -> Color {
    let mut c = rgb(hex);
    c.set_alpha(a);
    c
}

/// The macOS tile shape: a superellipse, which is what gives Apple's icons
/// their continuous corners rather than circular arcs.
fn squircle(x: f32, y: f32, size: f32) -> Path {
    let n = 5.0_f32;
    let r = size / 2.0;
    let (cx, cy) = (x + r, y + r);
    let mut pb = PathBuilder::new();
    let steps = 720;
    for i in 0..=steps {
        let t = i as f32 / steps as f32 * 2.0 * PI;
        let (c, s) = (t.cos(), t.sin());
        let px = cx + r * c.signum() * c.abs().powf(2.0 / n);
        let py = cy + r * s.signum() * s.abs().powf(2.0 / n);
        if i == 0 {
            pb.move_to(px, py);
        } else {
            pb.line_to(px, py);
        }
    }
    pb.close();
    pb.finish().unwrap()
}

fn polygon(points: &[f64]) -> Option<Path> {
    let mut pb = PathBuilder::new();
    let mut it = points.chunks_exact(2);
    let first = it.next()?;
    pb.move_to(first[0] as f32, first[1] as f32);
    for p in it {
        pb.line_to(p[0] as f32, p[1] as f32);
    }
    pb.close();
    pb.finish()
}

/// Catmull-Rom through the control points, sampled densely.
fn spline(ctrl: &[(f32, f32)], per_segment: usize) -> Vec<(f32, f32)> {
    let mut out = Vec::new();
    let n = ctrl.len();
    for i in 0..n - 1 {
        let p0 = ctrl[i.saturating_sub(1)];
        let p1 = ctrl[i];
        let p2 = ctrl[i + 1];
        let p3 = ctrl[(i + 2).min(n - 1)];
        for s in 0..per_segment {
            let t = s as f32 / per_segment as f32;
            let (t2, t3) = (t * t, t * t * t);
            let f = |a: f32, b: f32, c: f32, d: f32| {
                0.5 * (2.0 * b + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (-a + 3.0 * b - 3.0 * c + d) * t3)
            };
            out.push((f(p0.0, p1.0, p2.0, p3.0), f(p0.1, p1.1, p2.1, p3.1)));
        }
    }
    out.push(ctrl[n - 1]);
    out
}

/// The handwriting: one S, entering with a hook at the top right and
/// finishing low on the left, in canvas coordinates. Pressure follows
/// direction, heavy on the way down and light on the way up, as with a real
/// nib.
fn handwriting(bold: bool) -> Vec<f64> {
    let ctrl = [
        (646.0, 337.0),
        (564.0, 296.0),
        (475.0, 296.0),
        (407.0, 334.0),
        (388.0, 409.0),
        (437.0, 472.0),
        (524.0, 511.0),
        (604.0, 555.0),
        (636.0, 636.0),
        (598.0, 709.0),
        (520.0, 742.0),
        (430.0, 736.0),
        (358.0, 687.0),
    ];
    let pts = spline(&ctrl, 24);

    let mut flat = Vec::with_capacity(pts.len() * 3);
    let n = pts.len();
    for i in 0..n {
        let (x, y) = pts[i];
        let (a, b) = (pts[i.saturating_sub(1)], pts[(i + 1).min(n - 1)]);
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        let len = (dx * dx + dy * dy).sqrt().max(1e-3);
        // Downstrokes (dy > 0) bear down; upstrokes lift.
        let down = (dy / len).max(0.0);
        // The nib lands and lifts over the first and last stretch of the
        // stroke. The engine's own taper is sized for strokes on a page, a
        // few units long, so at icon scale the ease has to come from here.
        let t = i as f32 / (n - 1) as f32;
        let edge = (t.min(1.0 - t) / 0.15).min(1.0);
        let ends = edge * edge * (3.0 - 2.0 * edge);
        let p = (0.18 + 0.82 * down) * ends;
        let p = if bold { 0.35 + 0.65 * p } else { p };
        flat.extend_from_slice(&[x as f64, y as f64, p.clamp(0.02, 1.0) as f64]);
    }
    flat
}

/// Separable box blur of the alpha channel, three passes (≈ Gaussian), for
/// soft shadows. tiny-skia has no blur of its own.
fn blur(pix: &mut Pixmap, radius: usize) {
    if radius == 0 {
        return;
    }
    let (w, h) = (pix.width() as usize, pix.height() as usize);
    let mut a: Vec<f32> = pix.pixels().iter().map(|p| p.alpha() as f32).collect();
    let mut tmp = vec![0f32; a.len()];
    let pass = |src: &Vec<f32>, dst: &mut Vec<f32>, horizontal: bool| {
        let (outer, inner) = if horizontal { (h, w) } else { (w, h) };
        let idx = |o: usize, i: usize| if horizontal { o * w + i } else { i * w + o };
        let win = (radius * 2 + 1) as f32;
        for o in 0..outer {
            let mut acc = 0f32;
            for k in 0..=radius.min(inner - 1) {
                acc += src[idx(o, k)];
            }
            for i in 0..inner {
                dst[idx(o, i)] = acc / win;
                let add = i + radius + 1;
                if add < inner {
                    acc += src[idx(o, add)];
                }
                if i >= radius {
                    acc -= src[idx(o, i - radius)];
                }
            }
        }
    };
    for _ in 0..3 {
        pass(&a, &mut tmp, true);
        pass(&tmp, &mut a, false);
    }
    let data = pix.data_mut();
    for (i, v) in a.iter().enumerate() {
        let al = v.round().clamp(0.0, 255.0) as u8;
        // Shadow colour is black: premultiplied RGB stays zero.
        data[i * 4] = 0;
        data[i * 4 + 1] = 0;
        data[i * 4 + 2] = 0;
        data[i * 4 + 3] = al;
    }
}

fn shadow_layer(size: u32, path: &Path, transform: Transform, alpha: f32, blur_px: usize, dy: f32) -> Pixmap {
    let mut layer = Pixmap::new(size, size).unwrap();
    let mut paint = Paint::default();
    paint.set_color(Color::from_rgba(0.0, 0.0, 0.0, alpha).unwrap());
    paint.anti_alias = true;
    layer.fill_path(path, &paint, FillRule::Winding, transform.post_translate(0.0, dy), None);
    blur(&mut layer, blur_px);
    layer
}

/// Draws the icon at `size` pixels. `target` is the size it is destined for:
/// small icons get a heavier stroke (and the tiniest lose the ink drop) so the
/// mark survives at 16 px instead of turning to mush.
fn render(size: u32, target: u32) -> Pixmap {
    let small = target <= 32;
    let tiny = target <= 16;
    let s = size as f32 / CANVAS;
    let base = Transform::from_scale(s, s);
    let mut pix = Pixmap::new(size, size).unwrap();

    // ---- tile, with Apple's drop shadow
    let tile = squircle(TILE_ORIGIN, TILE_ORIGIN, TILE);
    let sh = shadow_layer(size, &tile, base, 0.32, (10.0 * s).round() as usize, 12.0 * s);
    pix.draw_pixmap(0, 0, sh.as_ref(), &Default::default(), Transform::identity(), None);

    // Velvet dark, the app's own ground.
    let mut paint = Paint { anti_alias: true, ..Paint::default() };
    paint.shader = LinearGradient::new(
        Point::from_xy(512.0, TILE_ORIGIN),
        Point::from_xy(512.0, TILE_ORIGIN + TILE),
        vec![GradientStop::new(0.0, rgb(0x2A2530)), GradientStop::new(1.0, rgb(0x141117))],
        SpreadMode::Pad,
        Transform::identity(),
    )
    .unwrap();
    pix.fill_path(&tile, &paint, FillRule::Winding, base, None);

    // A faint top sheen gives the tile some depth.
    paint.shader = LinearGradient::new(
        Point::from_xy(512.0, TILE_ORIGIN),
        Point::from_xy(512.0, TILE_ORIGIN + TILE * 0.5),
        vec![GradientStop::new(0.0, rgba(0xFFFFFF, 0.16)), GradientStop::new(1.0, rgba(0xFFFFFF, 0.0))],
        SpreadMode::Pad,
        Transform::identity(),
    )
    .unwrap();
    pix.fill_path(&tile, &paint, FillRule::Winding, base, None);

    // ---- the S, through the real ink engine
    let ink_width = if tiny { 96.0 } else if small { 82.0 } else { 66.0 };
    let pts = handwriting(small);
    // The engine's end taper is sized for page strokes; at this scale it
    // leaves a nub on a blunt end. Round caps on the eased ends read cleaner.
    let poly = outline(&pts, OutlineOptions { width: ink_width, pressure_sensitive: true, fit: true, taper: false });
    if let Some(ink) = polygon(&poly) {
        let p = Paint {
            anti_alias: true,
            shader: LinearGradient::new(
                Point::from_xy(0.0, 290.0),
                Point::from_xy(0.0, 750.0),
                vec![GradientStop::new(0.0, rgb(0xFFF4E4)), GradientStop::new(1.0, rgb(0xE9D9C2))],
                SpreadMode::Pad,
                Transform::identity(),
            )
            .unwrap(),
            ..Paint::default()
        };
        pix.fill_path(&ink, &p, FillRule::Winding, base, None);
    }

    // A drop of terracotta ink where the nib lifted.
    if !tiny {
        let mut drop = Paint { anti_alias: true, ..Paint::default() };
        drop.set_color(rgb(0xE39072));
        let r = if small { 40.0 } else { 33.0 };
        pix.fill_path(&PathBuilder::from_circle(306.0, 739.0, r).unwrap(), &drop, FillRule::Winding, base, None);
    }

    pix
}

fn main() {
    let out = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| "macos/Resources".into()));
    let iconset = out.join("AppIcon.iconset");
    std::fs::create_dir_all(&iconset).expect("create iconset dir");

    // Draw large and downsample for clean edges; small sizes get their own
    // simplified artwork rather than a shrunk copy of the big one.
    let sizes: [(u32, &str); 10] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ];

    for (px, name) in sizes {
        // The design size a 2x file stands in for decides the simplification.
        let design = if name.contains("@2x") { px / 2 } else { px };
        let big = render(1024, design);
        let img = if px == 1024 { big } else { downsample(&big, px) };
        img.save_png(iconset.join(name)).expect("write png");
        println!("  {name} ({px}px)");
    }

    render(1024, 1024).save_png(out.join("AppIcon-preview.png")).expect("write preview");
    println!("wrote {}", iconset.display());
}

/// Area-averaging downsample in premultiplied space.
fn downsample(src: &Pixmap, size: u32) -> Pixmap {
    let mut dst = Pixmap::new(size, size).unwrap();
    let ratio = src.width() as f32 / size as f32;
    let sw = src.width() as usize;
    let sdata = src.data();
    let ddata = dst.data_mut();
    for y in 0..size as usize {
        for x in 0..size as usize {
            let (x0, y0) = ((x as f32 * ratio) as usize, (y as f32 * ratio) as usize);
            let (x1, y1) = (((x + 1) as f32 * ratio) as usize, ((y + 1) as f32 * ratio) as usize);
            let mut acc = [0u32; 4];
            let mut n = 0u32;
            for sy in y0..y1.max(y0 + 1) {
                for sx in x0..x1.max(x0 + 1) {
                    let i = (sy * sw + sx) * 4;
                    for c in 0..4 {
                        acc[c] += sdata[i + c] as u32;
                    }
                    n += 1;
                }
            }
            let o = (y * size as usize + x) * 4;
            for c in 0..4 {
                ddata[o + c] = (acc[c] / n) as u8;
            }
        }
    }
    dst
}
