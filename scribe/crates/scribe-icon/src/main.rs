//! Renders the Scribe app icon.
//!
//! The mark is a cursive S written in cream ink straight onto a dark, ruled
//! slate, with a terracotta margin rule and a drop of ink where the nib
//! lifted: the app's own dark page. The handwriting is built by the app's ink
//! engine (`scribe_core::geometry::outline`), with pressure rising on
//! downstrokes the way a real nib behaves, so the icon is a picture of what
//! Scribe actually draws.
//!
//! Usage: scribe-icon <out-dir>
//! Writes `AppIcon.iconset/` (every size macOS wants) and `AppIcon-preview.png`.
//! `build.sh` turns the iconset into `AppIcon.icns` with `iconutil`.

use std::f32::consts::PI;
use std::path::PathBuf;

use scribe_core::geometry::{outline, OutlineOptions};
use tiny_skia::{
    Color, FillRule, GradientStop, LinearGradient, Mask, Paint, Path, PathBuilder, Pixmap, Point,
    SpreadMode, Stroke, Transform,
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

/// The handwriting: a cursive capital S that finishes in an underline swash,
/// centred on the origin. Pressure follows direction, heavy on the way
/// down and light on the way up, as with a real nib.
fn handwriting(scale: f32, bold: bool) -> Vec<f64> {
    let ctrl = [
        (-205.0, 170.0),
        (-150.0, 100.0),
        (-40.0, -60.0),
        (70.0, -185.0),
        (125.0, -228.0),
        (120.0, -258.0),
        (60.0, -250.0),
        (-15.0, -205.0),
        (-45.0, -130.0),
        (-5.0, -55.0),
        (75.0, 15.0),
        (115.0, 100.0),
        (85.0, 185.0),
        (0.0, 228.0),
        (-95.0, 212.0),
        (-150.0, 160.0),
        (-120.0, 120.0),
        (-30.0, 135.0),
        (110.0, 150.0),
        (215.0, 120.0),
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
        let t = i as f32 / (n - 1) as f32;
        let ends = (PI * t).sin().powf(0.35);
        let p = (0.22 + 0.78 * down) * (0.55 + 0.45 * ends);
        let p = if bold { 0.45 + 0.55 * p } else { p };
        flat.extend_from_slice(&[(x * scale) as f64, (y * scale) as f64, p.clamp(0.02, 1.0) as f64]);
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
/// small icons drop the fine rules and get a heavier stroke so the mark
/// survives at 16 px instead of turning to mush.
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

    // Warm slate, the colour of the app's dark page.
    let mut paint = Paint { anti_alias: true, ..Paint::default() };
    paint.shader = LinearGradient::new(
        Point::from_xy(512.0, TILE_ORIGIN),
        Point::from_xy(512.0, TILE_ORIGIN + TILE),
        vec![GradientStop::new(0.0, rgb(0x34302C)), GradientStop::new(1.0, rgb(0x151413))],
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

    // ---- rules and the margin line, clipped to the tile
    let mut clip = Mask::new(size, size).unwrap();
    clip.fill_path(&tile, FillRule::Winding, true, base);

    if !small {
        let mut pb = PathBuilder::new();
        let mut y = 300.0;
        while y < TILE_ORIGIN + TILE {
            pb.move_to(TILE_ORIGIN, y);
            pb.line_to(TILE_ORIGIN + TILE, y);
            y += 72.0;
        }
        let mut line = Paint { anti_alias: true, ..Paint::default() };
        line.set_color(rgba(0x5A534C, 0.55));
        pix.stroke_path(&pb.finish().unwrap(), &line, &Stroke { width: 4.0, ..Stroke::default() }, base, Some(&clip));
    }

    if !tiny {
        let mut pb = PathBuilder::new();
        pb.move_to(300.0, TILE_ORIGIN);
        pb.line_to(300.0, TILE_ORIGIN + TILE);
        let mut margin = Paint { anti_alias: true, ..Paint::default() };
        margin.set_color(rgba(0xE08A66, if small { 0.9 } else { 0.7 }));
        let width = if small { 12.0 } else { 5.0 };
        pix.stroke_path(&pb.finish().unwrap(), &margin, &Stroke { width, ..Stroke::default() }, base, Some(&clip));
    }

    // ---- handwriting, through the real ink engine
    let ink_width = if tiny { 66.0 } else if small { 54.0 } else { 40.0 };
    let pts = handwriting(1.0, small);
    let poly = outline(&pts, OutlineOptions { width: ink_width, pressure_sensitive: true, fit: true, taper: true });
    let place = Transform::from_scale(1.12, 1.12).post_translate(520.0, 500.0).post_concat(base);
    if let Some(ink) = polygon(&poly) {
        let p = Paint {
            anti_alias: true,
            shader: LinearGradient::new(
                Point::from_xy(0.0, -260.0),
                Point::from_xy(0.0, 240.0),
                vec![GradientStop::new(0.0, rgb(0xFFF4E4)), GradientStop::new(1.0, rgb(0xE9D9C2))],
                SpreadMode::Pad,
                Transform::identity(),
            )
            .unwrap(),
            ..Paint::default()
        };
        pix.fill_path(&ink, &p, FillRule::Winding, place, None);
    }

    // A drop of terracotta ink where the nib lifted.
    if !tiny {
        let mut drop = Paint { anti_alias: true, ..Paint::default() };
        drop.set_color(rgb(0xE08A66));
        let r = if small { 24.0 } else { 15.0 };
        pix.fill_path(&PathBuilder::from_circle(770.0, 610.0, r).unwrap(), &drop, FillRule::Winding, base, None);
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
