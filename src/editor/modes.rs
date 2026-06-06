//! Editor modes (modal editing — Insert / Normal / Visual).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum Mode {
    Normal,
    Insert,
    Visual,
    /// Single-char operator-pending (e.g., after `d`, awaiting motion).
    OpPending,
}

impl Mode {
    pub fn label(&self) -> &'static str {
        match self {
            Mode::Normal => "NORMAL",
            Mode::Insert => "INSERT",
            Mode::Visual => "VISUAL",
            Mode::OpPending => "OP",
        }
    }
}
