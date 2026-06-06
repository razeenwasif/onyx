//! Onyx error types.

use std::path::PathBuf;
use thiserror::Error;

#[derive(Debug, Error)]
#[allow(dead_code)]
pub enum OnyxError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("vault not found at {0}")]
    VaultNotFound(PathBuf),

    #[error("note not found: {0}")]
    NoteNotFound(String),

    #[error("config parse error: {0}")]
    Config(String),

    #[error("terminal error: {0}")]
    Terminal(String),

    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, OnyxError>;
