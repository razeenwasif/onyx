//! Small per-machine preferences, kept out of the notebook folder so syncing
//! notebooks between machines does not drag one machine's state along.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::workspace::{read_json, write_json};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Settings {
    #[serde(default, rename = "workspaceRoot", skip_serializing_if = "Option::is_none")]
    pub workspace_root: Option<String>,
    #[serde(default, rename = "lastPageFile", skip_serializing_if = "Option::is_none")]
    pub last_page_file: Option<String>,
    /// Dark is the default; writing at night is the common case.
    #[serde(default = "default_true", rename = "darkMode")]
    pub dark_mode: bool,
    /// Widths the user has dialled in for each pen in the tray, by pen name.
    #[serde(default, rename = "penWidths")]
    pub pen_widths: std::collections::BTreeMap<String, f64>,
    /// The notebooks sidebar is folded down to its icon rail.
    #[serde(default, rename = "sidebarCollapsed")]
    pub sidebar_collapsed: bool,
    /// The page list is hidden.
    #[serde(default, rename = "pageListCollapsed")]
    pub page_list_collapsed: bool,
}

fn default_true() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            workspace_root: None,
            last_page_file: None,
            dark_mode: true,
            pen_widths: Default::default(),
            sidebar_collapsed: false,
            page_list_collapsed: false,
        }
    }
}

impl Settings {
    pub fn path() -> PathBuf {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| ".".into());
        home.join("Library").join("Application Support").join("Scribe").join("settings.json")
    }

    /// Corrupt settings should never stop the app from opening.
    pub fn load() -> Self {
        read_json(&Self::path()).unwrap_or_default()
    }

    pub fn save(&self) -> Result<(), String> {
        write_json(&Self::path(), self)
    }
}
