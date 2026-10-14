//! Turns a pen sample stream into a filled, variable-width outline.
//!
//! A stock stroke renderer stamps a fixed-size tip along the path, which is
//! why default ink looks like a marker rather than a pen. This builds a true
//! outline whose half-width tracks pressure, which gives handwriting its
//! thick-thin character on downstrokes.

/// Samples closer together than this are treated as duplicates.
const MIN_POINT_DISTANCE: f64 = 0.35;

/// Arc-length spacing of the resampled centreline.
const RESAMPLE_SPACING: f64 = 1.5;

/// Half-window of the pressure moving average.
const PRESSURE_SMOOTHING_RADIUS: usize = 3;

/// Pressure maps to width through a curve, not linearly. A light pass still
/// leaves a visible line and the exponent keeps the mid-range responsive.
const MIN_WIDTH_FACTOR: f64 = 0.30;
const PRESSURE_EXPONENT: f64 = 0.7;

/// Arc length over which stroke ends taper.
const TAPER_LENGTH: f64 = 3.5;

/// Longest chord used when flattening round caps and dots.
const ARC_CHORD: f64 = 1.25;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sample {
    pub x: f64,
    pub y: f64,
    pub p: f64,
}

#[derive(Clone, Copy, Debug)]
pub struct OutlineOptions {
    /// Nib width at full pressure.
    pub width: f64,
    pub pressure_sensitive: bool,
    /// Catmull-Rom resample the centreline (the jitter filter).
    pub fit: bool,
    /// False while ink is still wet: tapering every partial stroke would pinch
    /// the line at the end of each frame.
    pub taper: bool,
}

/// Reads a flat `x, y, pressure` array into samples, clamping pressure.
pub fn samples_from_flat(points: &[f64]) -> Vec<Sample> {
    points
        .chunks_exact(3)
        .map(|c| {
            let p = if c[2].is_nan() || c[2] < 0.0 { 0.5 } else { c[2].min(1.0) };
            Sample { x: c[0], y: c[1], p }
        })
        .collect()
}

/// Builds the stroke outline as a closed polygon, `[x0, y0, x1, y1, ...]`,
/// to be filled with the non-zero rule.
pub fn outline(points: &[f64], opts: OutlineOptions) -> Vec<f64> {
    let raw = samples_from_flat(points);
    let mut samples = dedupe(&raw);
    let base_half = (opts.width / 2.0).max(0.05);

    if samples.is_empty() {
        return Vec::new();
    }

    // A tap is a dot, and must still honour pressure.
    if samples.len() == 1 {
        let s = samples[0];
        let r = base_half * if opts.pressure_sensitive { width_factor(s.p) } else { 1.0 };
        return circle(s.x, s.y, r);
    }

    if opts.fit && samples.len() > 2 {
        samples = resample_catmull_rom(&samples, RESAMPLE_SPACING);
    }

    smooth_pressure(&mut samples);

    let mut half: Vec<f64> = samples
        .iter()
        .map(|s| base_half * if opts.pressure_sensitive { width_factor(s.p) } else { 1.0 })
        .collect();

    if opts.pressure_sensitive && opts.taper {
        apply_end_taper(&samples, &mut half);
    }

    build_outline(&samples, &half)
}

pub fn width_factor(pressure: f64) -> f64 {
    let p = pressure.clamp(0.0, 1.0);
    MIN_WIDTH_FACTOR + (1.0 - MIN_WIDTH_FACTOR) * p.powf(PRESSURE_EXPONENT)
}

fn dedupe(src: &[Sample]) -> Vec<Sample> {
    let mut out: Vec<Sample> = Vec::with_capacity(src.len());
    for s in src {
        // Digitisers repeat coordinates while the pen is held still; those
        // duplicates would create zero-length tangents further down.
        if let Some(prev) = out.last() {
            if (s.x - prev.x).abs() < MIN_POINT_DISTANCE && (s.y - prev.y).abs() < MIN_POINT_DISTANCE {
                continue;
            }
        }
        out.push(*s);
    }
    out
}

/// Catmull-Rom resampling to a fixed arc-length spacing. Raw pen data is
/// polygonal at speed; interpolating makes curves read as smooth without
/// cutting corners the way a moving average does.
fn resample_catmull_rom(src: &[Sample], spacing: f64) -> Vec<Sample> {
    let n = src.len();
    let mut out = Vec::with_capacity(n * 2);
    out.push(src[0]);

    for i in 0..n - 1 {
        let p0 = src[i.saturating_sub(1)];
        let p1 = src[i];
        let p2 = src[i + 1];
        let p3 = src[(i + 2).min(n - 1)];

        let seg = dist(p1, p2);
        // Long segments would otherwise explode the point count on a fast
        // flick across the page.
        let steps = ((seg / spacing).ceil() as usize).clamp(1, 64);

        for s in 1..=steps {
            let t = s as f64 / steps as f64;
            let (x, y) = catmull_rom(p0, p1, p2, p3, t);
            out.push(Sample { x, y, p: lerp(p1.p, p2.p, t) });
        }
    }
    out
}

fn catmull_rom(p0: Sample, p1: Sample, p2: Sample, p3: Sample, t: f64) -> (f64, f64) {
    let t2 = t * t;
    let t3 = t2 * t;
    let f = |a: f64, b: f64, c: f64, d: f64| {
        0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (-a + 3.0 * b - 3.0 * c + d) * t3)
    };
    (f(p0.x, p1.x, p2.x, p3.x), f(p0.y, p1.y, p2.y, p3.y))
}

/// Averages pressure over a small window. Raw pressure is noisy enough that
/// unsmoothed width visibly pulses along an otherwise even line.
fn smooth_pressure(samples: &mut [Sample]) {
    let n = samples.len();
    if n < 3 {
        return;
    }
    let original: Vec<f64> = samples.iter().map(|s| s.p).collect();
    for (i, s) in samples.iter_mut().enumerate() {
        let lo = i.saturating_sub(PRESSURE_SMOOTHING_RADIUS);
        let hi = (i + PRESSURE_SMOOTHING_RADIUS).min(n - 1);
        s.p = original[lo..=hi].iter().sum::<f64>() / (hi - lo + 1) as f64;
    }
}

/// Narrows the first and last few units of the stroke. Real nibs land and
/// lift progressively; without this, strokes start and stop with a blunt stub.
fn apply_end_taper(samples: &[Sample], half: &mut [f64]) {
    let n = samples.len();
    if n < 3 {
        return;
    }

    let total: f64 = samples.windows(2).map(|w| dist(w[0], w[1])).sum();

    // On a stroke shorter than two tapers, taper proportionally so dots and
    // tick marks do not vanish.
    let taper = TAPER_LENGTH.min(total / 2.0);
    if taper <= 0.01 {
        return;
    }

    // Never taper fully to zero: a hairline still needs to be visible.
    let ramp = |t: f64| 0.35 + 0.65 * t.clamp(0.0, 1.0).sqrt();

    let mut travelled = 0.0;
    for i in 1..n {
        travelled += dist(samples[i - 1], samples[i]);
        if travelled >= taper {
            break;
        }
        half[i] *= ramp(travelled / taper);
    }
    half[0] *= ramp(0.0);

    travelled = 0.0;
    for i in (0..n - 1).rev() {
        travelled += dist(samples[i + 1], samples[i]);
        if travelled >= taper {
            break;
        }
        half[i] *= ramp(travelled / taper);
    }
    half[n - 1] *= ramp(0.0);
}

fn build_outline(samples: &[Sample], half: &[f64]) -> Vec<f64> {
    let n = samples.len();
    let mut normals = vec![(0.0, 1.0); n];
    let mut tangents = vec![(1.0, 0.0); n];

    for i in 0..n {
        let (a, b) = if i == 0 {
            (samples[0], samples[1])
        } else if i == n - 1 {
            (samples[n - 2], samples[n - 1])
        } else {
            (samples[i - 1], samples[i + 1])
        };

        let (dx, dy) = (b.x - a.x, b.y - a.y);
        let len = (dx * dx + dy * dy).sqrt();

        if len < 1e-9 {
            // Fall back to the previous direction rather than emitting NaN.
            if i > 0 {
                normals[i] = normals[i - 1];
                tangents[i] = tangents[i - 1];
            }
            continue;
        }

        let (tx, ty) = (dx / len, dy / len);
        tangents[i] = (tx, ty);
        normals[i] = (-ty, tx);
    }

    let mut out = Vec::with_capacity(n * 4 + 64);

    // Down one side...
    for i in 0..n {
        let s = samples[i];
        out.push(s.x + normals[i].0 * half[i]);
        out.push(s.y + normals[i].1 * half[i]);
    }

    // ...round the far cap, bulging past the tip...
    let e = samples[n - 1];
    push_cap(&mut out, e, normals[n - 1], tangents[n - 1], half[n - 1]);

    // ...back up the other side...
    for i in (0..n).rev() {
        let s = samples[i];
        out.push(s.x - normals[i].0 * half[i]);
        out.push(s.y - normals[i].1 * half[i]);
    }

    // ...and round the start cap, bulging back before the first sample.
    let s0 = samples[0];
    let (nx, ny) = normals[0];
    let (tx, ty) = tangents[0];
    push_cap(&mut out, s0, (-nx, -ny), (-tx, -ty), half[0]);

    out
}

/// A semicircle from `c + n*r` round through `c + t*r` to `c - n*r`,
/// excluding both ends (they are already in the outline).
fn push_cap(out: &mut Vec<f64>, c: Sample, n: (f64, f64), t: (f64, f64), r: f64) {
    let segments = ((std::f64::consts::PI * r / ARC_CHORD).ceil() as usize).clamp(4, 40);
    for k in 1..segments {
        let phi = std::f64::consts::PI * k as f64 / segments as f64;
        let (cs, sn) = (phi.cos(), phi.sin());
        out.push(c.x + r * (cs * n.0 + sn * t.0));
        out.push(c.y + r * (cs * n.1 + sn * t.1));
    }
}

fn circle(x: f64, y: f64, r: f64) -> Vec<f64> {
    let segments = ((2.0 * std::f64::consts::PI * r / ARC_CHORD).ceil() as usize).clamp(10, 64);
    let mut out = Vec::with_capacity(segments * 2);
    for k in 0..segments {
        let a = 2.0 * std::f64::consts::PI * k as f64 / segments as f64;
        out.push(x + r * a.cos());
        out.push(y + r * a.sin());
    }
    out
}

fn dist(a: Sample, b: Sample) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

// --------------------------------------------------------------- hit tests

/// Axis-aligned bounds of a stroke including its nib: `[x, y, w, h]`.
pub fn bounds(points: &[f64], width: f64) -> [f64; 4] {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for c in points.chunks_exact(3) {
        min_x = min_x.min(c[0]);
        min_y = min_y.min(c[1]);
        max_x = max_x.max(c[0]);
        max_y = max_y.max(c[1]);
    }
    if !min_x.is_finite() {
        return [0.0; 4];
    }
    // Catmull-Rom can overshoot the control polygon slightly on sharp turns.
    let pad = width / 2.0 + 2.0;
    [min_x - pad, min_y - pad, (max_x - min_x) + pad * 2.0, (max_y - min_y) + pad * 2.0]
}

fn seg_dist_sq(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    let t = if len2 < 1e-12 { 0.0 } else { (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0) };
    let (cx, cy) = (ax + t * dx, ay + t * dy);
    (px - cx).powi(2) + (py - cy).powi(2)
}

/// Whether a circle at (x, y) with `radius` touches the stroke's centreline,
/// widened by half the nib.
pub fn hit(points: &[f64], width: f64, x: f64, y: f64, radius: f64) -> bool {
    let reach = radius + width / 2.0;
    let reach2 = reach * reach;
    let n = points.len() / 3;
    if n == 0 {
        return false;
    }
    if n == 1 {
        return (points[0] - x).powi(2) + (points[1] - y).powi(2) <= reach2;
    }
    (0..n - 1).any(|i| {
        let (a, b) = (i * 3, (i + 1) * 3);
        seg_dist_sq(x, y, points[a], points[a + 1], points[b], points[b + 1]) <= reach2
    })
}

/// Rubs out the part of a stroke under a circular eraser.
///
/// Returns the surviving pieces as flat point arrays, or `None` when the
/// eraser does not touch the stroke at all (so callers can keep it as is).
///
/// A smoothed (`fit`) stroke is cut along its smoothed centreline, the line
/// the user actually sees; cutting the raw samples would leave pieces whose
/// curves had turned back into polygons. Long segments are subdivided too,
/// so erasing the middle of a straight line leaves two lines.
pub fn erase(points: &[f64], width: f64, fit: bool, x: f64, y: f64, radius: f64) -> Option<Vec<Vec<f64>>> {
    if !hit(points, width, x, y, radius) {
        return None;
    }

    let reach = radius + width / 2.0;
    let step = (radius / 2.0).max(0.75);

    let samples = dedupe(&samples_from_flat(points));
    let samples = if fit && samples.len() > 2 { resample_catmull_rom(&samples, RESAMPLE_SPACING) } else { samples };

    // Densify so the cut lands close to the eraser's edge.
    let mut dense: Vec<[f64; 3]> = Vec::with_capacity(samples.len() * 2);
    let src: Vec<[f64; 3]> = samples.iter().map(|s| [s.x, s.y, s.p]).collect();
    for i in 0..src.len() {
        if i > 0 {
            let (a, b) = (src[i - 1], src[i]);
            let len = ((b[0] - a[0]).powi(2) + (b[1] - a[1]).powi(2)).sqrt();
            let k = (len / step).floor() as usize;
            for j in 1..k.min(512) {
                let t = j as f64 / k as f64;
                dense.push([lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)]);
            }
        }
        dense.push(src[i]);
    }

    let mut pieces: Vec<Vec<f64>> = Vec::new();
    let mut current: Vec<f64> = Vec::new();
    for p in dense {
        let inside = (p[0] - x).powi(2) + (p[1] - y).powi(2) <= reach * reach;
        if inside {
            if current.len() >= 6 {
                pieces.push(std::mem::take(&mut current));
            } else {
                current.clear();
            }
        } else {
            current.extend_from_slice(&p);
        }
    }
    if current.len() >= 6 {
        pieces.push(current);
    }
    Some(pieces)
}

/// Even-odd point in polygon test; `poly` is flat `[x0, y0, x1, y1, ...]`.
pub fn point_in_polygon(poly: &[f64], x: f64, y: f64) -> bool {
    let n = poly.len() / 2;
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        let (xi, yi) = (poly[i * 2], poly[i * 2 + 1]);
        let (xj, yj) = (poly[j * 2], poly[j * 2 + 1]);
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

/// Fraction of a stroke's points that fall inside a lasso polygon.
pub fn lasso_fraction(lasso: &[f64], points: &[f64]) -> f64 {
    let n = points.len() / 3;
    if n == 0 {
        return 0.0;
    }
    let inside = points.chunks_exact(3).filter(|c| point_in_polygon(lasso, c[0], c[1])).count();
    inside as f64 / n as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(n: usize, p: f64) -> Vec<f64> {
        (0..n).flat_map(|i| [i as f64 * 5.0, 10.0, p]).collect()
    }

    fn opts(width: f64) -> OutlineOptions {
        OutlineOptions { width, pressure_sensitive: true, fit: true, taper: true }
    }

    #[test]
    fn empty_input_gives_empty_outline() {
        assert!(outline(&[], opts(2.0)).is_empty());
    }

    #[test]
    fn single_sample_is_a_dot_scaled_by_pressure() {
        let heavy = outline(&[10.0, 10.0, 1.0], opts(4.0));
        let light = outline(&[10.0, 10.0, 0.0], opts(4.0));
        let radius = |o: &[f64]| ((o[0] - 10.0).powi(2) + (o[1] - 10.0).powi(2)).sqrt();
        assert!((radius(&heavy) - 2.0).abs() < 1e-9);
        assert!((radius(&light) - 2.0 * MIN_WIDTH_FACTOR).abs() < 1e-9);
    }

    #[test]
    fn duplicate_samples_collapse_to_a_dot() {
        let o = outline(&[5.0, 5.0, 0.5, 5.1, 5.1, 0.5, 5.0, 5.2, 0.5], opts(2.0));
        assert!(!o.is_empty());
        assert!(o.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn outline_is_finite_and_spans_the_stroke() {
        let o = outline(&line(20, 0.5), opts(3.0));
        assert!(o.len() > 40);
        assert!(o.iter().all(|v| v.is_finite()));
        let xs: Vec<f64> = o.chunks(2).map(|c| c[0]).collect();
        let min = xs.iter().cloned().fold(f64::INFINITY, f64::min);
        let max = xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        // Caps bulge past both ends.
        assert!(min < 0.0 && max > 95.0);
    }

    #[test]
    fn pressure_off_gives_even_width() {
        let pts: Vec<f64> = (0..20).flat_map(|i| [i as f64 * 5.0, 0.0, i as f64 / 20.0]).collect();
        let o = outline(&pts, OutlineOptions { width: 4.0, pressure_sensitive: false, fit: false, taper: true });
        // First half of the outline is the upper edge: all at y = +2.
        let n = 20;
        for c in o.chunks(2).take(n) {
            assert!((c[1].abs() - 2.0).abs() < 1e-9);
        }
    }

    #[test]
    fn taper_narrows_the_ends() {
        let pts = line(30, 1.0);
        let tapered = outline(&pts, opts(4.0));
        let blunt = outline(&pts, OutlineOptions { taper: false, ..opts(4.0) });
        assert!(tapered[1].abs() < blunt[1].abs());
    }

    #[test]
    fn width_factor_is_monotonic_and_floored() {
        assert!((width_factor(0.0) - MIN_WIDTH_FACTOR).abs() < 1e-12);
        assert!((width_factor(1.0) - 1.0).abs() < 1e-12);
        assert!(width_factor(0.3) < width_factor(0.6));
        assert_eq!(width_factor(-5.0), width_factor(0.0));
    }

    #[test]
    fn hit_test_respects_nib_and_radius() {
        let pts = line(10, 0.5);
        assert!(hit(&pts, 2.0, 20.0, 12.0, 1.5));
        assert!(!hit(&pts, 2.0, 20.0, 20.0, 1.5));
    }

    #[test]
    fn erasing_the_middle_splits_a_line_in_two() {
        let pts = vec![0.0, 0.0, 0.5, 100.0, 0.0, 0.5];
        let pieces = erase(&pts, 2.0, true, 50.0, 0.0, 5.0).unwrap();
        assert_eq!(pieces.len(), 2);
        assert!(pieces[0].chunks(3).all(|c| c[0] < 50.0));
        assert!(pieces[1].chunks(3).all(|c| c[0] > 50.0));
    }

    #[test]
    fn erasing_a_smooth_stroke_keeps_its_curve() {
        // A coarse arc: four raw samples that render as a smooth curve.
        let pts = vec![0.0, 0.0, 0.5, 30.0, 20.0, 0.5, 60.0, 20.0, 0.5, 90.0, 0.0, 0.5];
        let pieces = erase(&pts, 2.0, true, 0.0, 0.0, 3.0).unwrap();
        assert_eq!(pieces.len(), 1);
        // The survivor follows the spline, so it has many more samples than
        // the three raw points left after the cut.
        assert!(pieces[0].len() / 3 > 20);
    }

    #[test]
    fn erasing_elsewhere_leaves_the_stroke_alone() {
        let pts = vec![0.0, 0.0, 0.5, 100.0, 0.0, 0.5];
        assert!(erase(&pts, 2.0, true, 50.0, 50.0, 5.0).is_none());
    }

    #[test]
    fn lasso_counts_points_inside() {
        let square = [0.0, 0.0, 10.0, 0.0, 10.0, 10.0, 0.0, 10.0];
        let pts = [5.0, 5.0, 0.5, 20.0, 20.0, 0.5];
        assert!((lasso_fraction(&square, &pts) - 0.5).abs() < 1e-12);
    }
}
