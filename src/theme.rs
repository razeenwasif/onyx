//! Themes — color palettes used across the UI.
//!
//! A few curated presets ship in the binary; users can override any field
//! through the `theme` table in `~/.config/onyx/config.toml`.

use ratatui::style::{Color, Modifier, Style};
use serde::{Deserialize, Serialize};

/// A full UI palette. Colors are parsed from `#rrggbb` or named ratatui colors.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Theme {
    pub name: String,

    // Surfaces
    pub bg: ColorSpec,
    pub bg_alt: ColorSpec,
    pub bg_sel: ColorSpec,
    pub fg: ColorSpec,
    pub fg_dim: ColorSpec,
    pub fg_subtle: ColorSpec,

    // Accents
    pub accent: ColorSpec,
    pub accent_alt: ColorSpec,
    pub link: ColorSpec,
    pub wikilink: ColorSpec,
    pub tag: ColorSpec,
    pub code: ColorSpec,
    pub heading: ColorSpec,
    pub heading_alt: ColorSpec,

    // Semantic
    pub success: ColorSpec,
    pub warning: ColorSpec,
    pub error: ColorSpec,
    pub info: ColorSpec,

    // Borders
    pub border: ColorSpec,
    pub border_focus: ColorSpec,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ColorSpec(pub String);

impl ColorSpec {
    #[allow(dead_code)]
    pub fn new<S: Into<String>>(s: S) -> Self {
        ColorSpec(s.into())
    }

    pub fn to_color(&self) -> Color {
        parse_color(&self.0).unwrap_or(Color::Reset)
    }
}

impl From<&str> for ColorSpec {
    fn from(s: &str) -> Self {
        ColorSpec(s.to_string())
    }
}

fn parse_color(s: &str) -> Option<Color> {
    let s = s.trim();
    if let Some(hex) = s.strip_prefix('#') {
        if hex.len() == 6 {
            let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
            let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
            let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
            return Some(Color::Rgb(r, g, b));
        }
    }
    match s.to_ascii_lowercase().as_str() {
        "black" => Some(Color::Black),
        "red" => Some(Color::Red),
        "green" => Some(Color::Green),
        "yellow" => Some(Color::Yellow),
        "blue" => Some(Color::Blue),
        "magenta" => Some(Color::Magenta),
        "cyan" => Some(Color::Cyan),
        "gray" | "grey" => Some(Color::Gray),
        "darkgray" | "darkgrey" => Some(Color::DarkGray),
        "white" => Some(Color::White),
        "reset" | "default" => Some(Color::Reset),
        _ => None,
    }
}

impl Theme {
    pub fn obsidian_dark() -> Self {
        Self {
            name: "Onyx Dark".into(),
            bg: "#1e1e24".into(),
            bg_alt: "#262631".into(),
            bg_sel: "#3a3a4d".into(),
            fg: "#dcd7ba".into(),
            fg_dim: "#9b97a8".into(),
            fg_subtle: "#6e6a7c".into(),
            accent: "#a78bfa".into(),
            accent_alt: "#f59e0b".into(),
            link: "#7aa2f7".into(),
            wikilink: "#a78bfa".into(),
            tag: "#34d399".into(),
            code: "#f7768e".into(),
            heading: "#e0c889".into(),
            heading_alt: "#bb9af7".into(),
            success: "#9ece6a".into(),
            warning: "#e0af68".into(),
            error: "#f7768e".into(),
            info: "#7dcfff".into(),
            border: "#3a3a4d".into(),
            border_focus: "#a78bfa".into(),
        }
    }

    pub fn obsidian_light() -> Self {
        Self {
            name: "Onyx Light".into(),
            bg: "#faf8f5".into(),
            bg_alt: "#eee9df".into(),
            bg_sel: "#d6cfc3".into(),
            fg: "#1c1c2a".into(),
            fg_dim: "#5a5870".into(),
            fg_subtle: "#84829a".into(),
            accent: "#6f42c1".into(),
            accent_alt: "#d97706".into(),
            link: "#1d4ed8".into(),
            wikilink: "#7c3aed".into(),
            tag: "#059669".into(),
            code: "#be185d".into(),
            heading: "#9a3412".into(),
            heading_alt: "#6d28d9".into(),
            success: "#15803d".into(),
            warning: "#a16207".into(),
            error: "#b91c1c".into(),
            info: "#0369a1".into(),
            border: "#cdc6b8".into(),
            border_focus: "#6f42c1".into(),
        }
    }

    pub fn dracula() -> Self {
        Self {
            name: "Dracula".into(),
            bg: "#282a36".into(),
            bg_alt: "#21222c".into(),
            bg_sel: "#44475a".into(),
            fg: "#f8f8f2".into(),
            fg_dim: "#bdbdbd".into(),
            fg_subtle: "#6272a4".into(),
            accent: "#bd93f9".into(),
            accent_alt: "#ffb86c".into(),
            link: "#8be9fd".into(),
            wikilink: "#bd93f9".into(),
            tag: "#50fa7b".into(),
            code: "#ff79c6".into(),
            heading: "#ffb86c".into(),
            heading_alt: "#ff79c6".into(),
            success: "#50fa7b".into(),
            warning: "#f1fa8c".into(),
            error: "#ff5555".into(),
            info: "#8be9fd".into(),
            border: "#44475a".into(),
            border_focus: "#bd93f9".into(),
        }
    }

    pub fn nord() -> Self {
        Self {
            name: "Nord".into(),
            bg: "#2e3440".into(),
            bg_alt: "#3b4252".into(),
            bg_sel: "#434c5e".into(),
            fg: "#eceff4".into(),
            fg_dim: "#d8dee9".into(),
            fg_subtle: "#7e8a9e".into(),
            accent: "#88c0d0".into(),
            accent_alt: "#d08770".into(),
            link: "#81a1c1".into(),
            wikilink: "#b48ead".into(),
            tag: "#a3be8c".into(),
            code: "#bf616a".into(),
            heading: "#ebcb8b".into(),
            heading_alt: "#b48ead".into(),
            success: "#a3be8c".into(),
            warning: "#ebcb8b".into(),
            error: "#bf616a".into(),
            info: "#88c0d0".into(),
            border: "#434c5e".into(),
            border_focus: "#88c0d0".into(),
        }
    }

    pub fn preset(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "dark" | "obsidian" | "onyx-dark" => Some(Self::obsidian_dark()),
            "light" | "onyx-light" => Some(Self::obsidian_light()),
            "dracula" => Some(Self::dracula()),
            "nord" => Some(Self::nord()),
            _ => None,
        }
    }

    // Convenience style helpers used across the UI.
    pub fn s_normal(&self) -> Style {
        Style::default().fg(self.fg.to_color()).bg(self.bg.to_color())
    }

    pub fn s_dim(&self) -> Style {
        Style::default().fg(self.fg_dim.to_color())
    }

    pub fn s_subtle(&self) -> Style {
        Style::default().fg(self.fg_subtle.to_color())
    }

    pub fn s_accent(&self) -> Style {
        Style::default()
            .fg(self.accent.to_color())
            .add_modifier(Modifier::BOLD)
    }

    pub fn s_border(&self) -> Style {
        Style::default().fg(self.border.to_color())
    }

    pub fn s_border_focus(&self) -> Style {
        Style::default()
            .fg(self.border_focus.to_color())
            .add_modifier(Modifier::BOLD)
    }

    pub fn s_selection(&self) -> Style {
        Style::default()
            .fg(self.fg.to_color())
            .bg(self.bg_sel.to_color())
            .add_modifier(Modifier::BOLD)
    }

    pub fn s_link(&self) -> Style {
        Style::default()
            .fg(self.link.to_color())
            .add_modifier(Modifier::UNDERLINED)
    }

    pub fn s_wikilink(&self) -> Style {
        Style::default()
            .fg(self.wikilink.to_color())
            .add_modifier(Modifier::UNDERLINED)
    }

    pub fn s_tag(&self) -> Style {
        Style::default().fg(self.tag.to_color())
    }

    pub fn s_code(&self) -> Style {
        Style::default()
            .fg(self.code.to_color())
            .bg(self.bg_alt.to_color())
    }

    pub fn s_heading(&self, level: u8) -> Style {
        let color = if level <= 1 {
            self.heading.to_color()
        } else if level == 2 {
            self.heading_alt.to_color()
        } else {
            self.accent.to_color()
        };
        Style::default().fg(color).add_modifier(Modifier::BOLD)
    }

    #[allow(dead_code)]
    pub fn s_error(&self) -> Style {
        Style::default()
            .fg(self.error.to_color())
            .add_modifier(Modifier::BOLD)
    }
}

impl Default for Theme {
    fn default() -> Self {
        Theme::obsidian_dark()
    }
}
