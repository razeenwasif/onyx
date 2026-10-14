//! Colour parsing and theme adaptation.
//!
//! Adaptation is a rendering concern only: the colour written to disk never
//! changes. Black ink stays black in the file and *displays* as near-white on
//! a dark page, so a notebook written in dark mode still looks right in light
//! mode, and imported handwriting (almost always black) is legible.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    pub fn to_u32(self) -> u32 {
        (self.r as u32) << 24 | (self.g as u32) << 16 | (self.b as u32) << 8 | self.a as u32
    }

    pub fn from_u32(v: u32) -> Self {
        Self { r: (v >> 24) as u8, g: (v >> 16) as u8, b: (v >> 8) as u8, a: v as u8 }
    }
}

/// Parses `#RRGGBB` or `#AARRGGBB`.
pub fn parse_hex(hex: &str) -> Option<Rgba> {
    let s = hex.trim().trim_start_matches('#');
    let byte = |i: usize| u8::from_str_radix(s.get(i..i + 2)?, 16).ok();
    match s.len() {
        6 => Some(Rgba { r: byte(0)?, g: byte(2)?, b: byte(4)?, a: 255 }),
        8 => Some(Rgba { a: byte(0)?, r: byte(2)?, g: byte(4)?, b: byte(6)? }),
        _ => None,
    }
}

pub fn to_hex(c: Rgba) -> String {
    if c.a == 255 {
        format!("#{:02X}{:02X}{:02X}", c.r, c.g, c.b)
    } else {
        format!("#{:02X}{:02X}{:02X}{:02X}", c.a, c.r, c.g, c.b)
    }
}

/// Highlighters need more opacity on a dark page: a wash that reads as bright
/// over white barely registers over near-black.
pub fn highlighter_alpha(dark: bool) -> u8 {
    if dark { 150 } else { 110 }
}

/// The colour to paint ink with on the current theme.
pub fn adapt(c: Rgba, dark: bool) -> Rgba {
    if !dark {
        return c;
    }

    let luminance = (0.2126 * c.r as f64 + 0.7152 * c.g as f64 + 0.0722 * c.b as f64) / 255.0;

    // Already light enough to read on a dark page.
    if luminance >= 0.55 {
        return c;
    }

    let (h, s, l) = to_hsl(c);

    // Near-neutral dark ink is the common case: plain black handwriting. Send
    // it to a warm cream rather than pure white, which glares on the velvet
    // dark page.
    if s < 0.18 {
        return Rgba { r: 0xEF, g: 0xE6, b: 0xD8, a: c.a };
    }

    // Coloured ink keeps its hue so red stays red, lifted to a lightness that
    // carries on a dark background and desaturated a touch, because fully
    // saturated colour vibrates against dark.
    let (r, g, b) = from_hsl(h, s.min(0.72), l.max(0.68));
    Rgba { r, g, b, a: c.a }
}

fn to_hsl(c: Rgba) -> (f64, f64, f64) {
    let (r, g, b) = (c.r as f64 / 255.0, c.g as f64 / 255.0, c.b as f64 / 255.0);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;

    if (max - min).abs() < 1e-9 {
        return (0.0, 0.0, l);
    }

    let d = max - min;
    let s = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };
    let h = if max == r {
        ((g - b) / d + if g < b { 6.0 } else { 0.0 }) / 6.0
    } else if max == g {
        ((b - r) / d + 2.0) / 6.0
    } else {
        ((r - g) / d + 4.0) / 6.0
    };
    (h, s, l)
}

fn from_hsl(h: f64, s: f64, l: f64) -> (u8, u8, u8) {
    if s < 1e-9 {
        let v = (l * 255.0).round() as u8;
        return (v, v, v);
    }

    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;

    let channel = |mut t: f64| -> u8 {
        if t < 0.0 {
            t += 1.0;
        }
        if t > 1.0 {
            t -= 1.0;
        }
        let v = if t < 1.0 / 6.0 {
            p + (q - p) * 6.0 * t
        } else if t < 0.5 {
            q
        } else if t < 2.0 / 3.0 {
            p + (q - p) * (2.0 / 3.0 - t) * 6.0
        } else {
            p
        };
        (v.clamp(0.0, 1.0) * 255.0).round() as u8
    };

    (channel(h + 1.0 / 3.0), channel(h), channel(h - 1.0 / 3.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_hex_forms() {
        assert_eq!(parse_hex("#1A1A1A"), Some(Rgba::rgb(0x1A, 0x1A, 0x1A)));
        assert_eq!(parse_hex("80FF0000"), Some(Rgba { a: 0x80, r: 0xFF, g: 0, b: 0 }));
        assert_eq!(parse_hex("#12345"), None);
        assert_eq!(parse_hex("#GG0000"), None);
    }

    #[test]
    fn hex_round_trips() {
        for s in ["#1D4ED8", "#80FFE03D"] {
            assert_eq!(to_hex(parse_hex(s).unwrap()), s);
        }
    }

    #[test]
    fn light_theme_never_changes_ink() {
        let c = Rgba::rgb(0x1A, 0x1A, 0x1A);
        assert_eq!(adapt(c, false), c);
    }

    #[test]
    fn black_ink_becomes_warm_cream_on_dark() {
        assert_eq!(adapt(Rgba::rgb(0x1A, 0x1A, 0x1A), true), Rgba::rgb(0xEF, 0xE6, 0xD8));
    }

    #[test]
    fn coloured_ink_keeps_its_hue_but_lifts() {
        let red = adapt(Rgba::rgb(0xC0, 0x28, 0x28), true);
        assert!(red.r > red.g && red.r > red.b);
        let (_, _, l) = to_hsl(red);
        assert!(l >= 0.67);
    }

    #[test]
    fn pale_ink_passes_through() {
        let yellow = Rgba::rgb(0xFF, 0xE0, 0x3D);
        assert_eq!(adapt(yellow, true), yellow);
    }
}
