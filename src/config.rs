//! Persistent configuration for Onyx.
//!
//! Loaded from `~/.config/onyx/config.toml` (or `$XDG_CONFIG_HOME/onyx`).
//! Missing fields fall back to compile-time defaults so the file can be empty
//! or hand-crafted partial.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::theme::Theme;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Last-opened vault path, used when launching with no arguments.
    pub last_vault: Option<PathBuf>,

    /// Name of the active theme (one of the presets or "custom").
    pub theme: String,

    /// User-overridden theme. If present and `theme = "custom"`, this is used.
    pub custom_theme: Option<Theme>,

    /// Daily-notes settings.
    pub daily_notes: DailyNotesConfig,

    /// Editor preferences.
    pub editor: EditorConfig,

    /// UI sizing hints (saved between sessions).
    pub layout: LayoutConfig,

    /// Google integration (Calendar/Tasks/Drive). Off until you fill in OAuth
    /// credentials from a Google Cloud "Desktop app" client.
    pub google: GoogleConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct GoogleConfig {
    /// OAuth client id from your Google Cloud project (Desktop app type).
    pub client_id: String,
    /// OAuth client secret (not truly secret for installed apps).
    pub client_secret: String,
}

impl GoogleConfig {
    pub fn is_configured(&self) -> bool {
        !self.client_id.trim().is_empty() && !self.client_secret.trim().is_empty()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DailyNotesConfig {
    pub folder: String,
    pub format: String, // chrono format string
    pub template: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct EditorConfig {
    pub tab_size: usize,
    pub use_spaces: bool,
    pub line_numbers: bool,
    pub wrap: bool,
    pub autosave: bool,
    pub autosave_idle_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct LayoutConfig {
    pub sidebar_left_width: u16,
    pub sidebar_right_width: u16,
    /// The editor pane's share of the center area, in percent (the preview takes
    /// the rest). Clamped to a sane range at render time. Adjust with Ctrl-←/→.
    pub editor_split_percent: u16,
    pub show_preview: bool,
    pub show_left_sidebar: bool,
    pub show_right_sidebar: bool,
    // Stacked panes (default on).
    pub show_graph_pane: bool,
    pub show_calendar: bool,
    pub show_quicknote: bool,
    pub show_todo: bool,
    // Fixed heights for stacked side panes.
    pub quicknote_height: u16,
    pub todo_height: u16,
    pub calendar_height: u16,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            last_vault: None,
            theme: "dark".into(),
            custom_theme: None,
            daily_notes: DailyNotesConfig::default(),
            editor: EditorConfig::default(),
            layout: LayoutConfig::default(),
            google: GoogleConfig::default(),
        }
    }
}

impl Default for DailyNotesConfig {
    fn default() -> Self {
        Self {
            folder: "Daily".into(),
            format: "%Y-%m-%d".into(),
            template: None,
        }
    }
}

impl Default for EditorConfig {
    fn default() -> Self {
        Self {
            tab_size: 4,
            use_spaces: true,
            line_numbers: true,
            wrap: true,
            autosave: false,
            autosave_idle_ms: 2500,
        }
    }
}

impl Default for LayoutConfig {
    fn default() -> Self {
        Self {
            sidebar_left_width: 26,
            sidebar_right_width: 30,
            editor_split_percent: 55,
            show_preview: true,
            show_left_sidebar: true,
            show_right_sidebar: true,
            show_graph_pane: true,
            show_calendar: true,
            show_quicknote: true,
            show_todo: true,
            quicknote_height: 7,
            todo_height: 9,
            calendar_height: 13,
        }
    }
}

impl Config {
    /// Directory holding `config.toml`.
    ///
    /// Overridable for tests / throwaway sessions:
    /// - `ONYX_CONFIG`     — full path to a config file; its parent is the dir.
    /// - `ONYX_CONFIG_DIR` — a directory to hold `config.toml`.
    ///
    /// Otherwise `$XDG_CONFIG_HOME/onyx` (or the platform equivalent).
    pub fn config_dir() -> PathBuf {
        if let Some(path) = std::env::var_os("ONYX_CONFIG") {
            let p = PathBuf::from(path);
            return p.parent().map(|d| d.to_path_buf()).unwrap_or(p);
        }
        if let Some(dir) = std::env::var_os("ONYX_CONFIG_DIR") {
            return PathBuf::from(dir);
        }
        if let Some(dir) = dirs::config_dir() {
            dir.join("onyx")
        } else {
            PathBuf::from(".onyx")
        }
    }

    pub fn config_path() -> PathBuf {
        if let Some(path) = std::env::var_os("ONYX_CONFIG") {
            return PathBuf::from(path);
        }
        Self::config_dir().join("config.toml")
    }

    /// Where the Google OAuth token is cached (mode 600), separate from
    /// `config.toml` so secrets never land in the human-edited file.
    pub fn google_token_path() -> PathBuf {
        Self::config_dir().join("google.json")
    }

    pub fn load() -> Self {
        Self::load_from(&Self::config_path()).unwrap_or_default()
    }

    pub fn load_from(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = fs::read_to_string(path)?;
        let cfg: Config = toml::from_str(&raw)
            .map_err(|e| crate::error::OnyxError::Config(e.to_string()))?;
        Ok(cfg)
    }

    pub fn save(&self) -> Result<()> {
        let dir = Self::config_dir();
        fs::create_dir_all(&dir)?;
        let raw = toml::to_string_pretty(self)
            .map_err(|e| crate::error::OnyxError::Config(e.to_string()))?;
        fs::write(Self::config_path(), raw)?;
        Ok(())
    }

    pub fn resolve_theme(&self) -> Theme {
        if self.theme.eq_ignore_ascii_case("custom") {
            if let Some(t) = self.custom_theme.clone() {
                return t;
            }
        }
        Theme::preset(&self.theme).unwrap_or_default()
    }
}
