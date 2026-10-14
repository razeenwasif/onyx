//! Scribe's core: the file format, the folder workspace, the ink geometry
//! engine, theme-aware colour, and table clipboard formats.
//!
//! Everything platform-specific (windows, pen input, drawing) lives in the
//! macOS app; it reaches this crate through the C ABI in [`ffi`].

pub mod color;
pub mod ffi;
pub mod geometry;
pub mod model;
pub mod settings;
pub mod table;
pub mod workspace;
