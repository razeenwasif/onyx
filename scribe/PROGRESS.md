# Scribe Development Progress

## macOS rewrite (Rust + SwiftUI)

The Windows/WPF app (C#) has been replaced by a macOS app: a Rust core
(`crates/scribe-core`) and a SwiftUI front end (`macos/`). The on-disk format is
unchanged, so notebooks move between the two. The WPF sources remain in git
history (commit `49a6b5f`).

### Carried over
- [x] Folder workspace: notebooks, sections, pages, manifests, atomic writes
- [x] Pressure-varying ink with Catmull-Rom smoothing, pressure smoothing, end tapers
- [x] Pen tray, highlighter, whole-stroke and partial eraser, tablet eraser end
- [x] Lasso selection: move, resize, delete, copy/cut/paste
- [x] Text boxes with headings, fonts, sizes, bold/italic/underline/strikethrough
- [x] LaTeX equations with live preview (SwiftMath)
- [x] Tables: header row, column widths, row/column editing, copy as table or Markdown
- [x] Images: paste, insert, drag and drop, resize
- [x] Paste tables from HTML, Markdown, TSV and CSV
- [x] Ruled / grid / dots / blank paper
- [x] Dark and light themes with display-only ink adaptation
- [x] Search across every notebook
- [x] Undo/redo, autosave, title-follows-file renaming
- [x] Ink render self-test (`--render-selftest`)

### New on macOS
- [x] Per-run text formatting stored as portable `spans` (see docs/FORMAT.md)
- [x] Unknown JSON fields preserved through every save
- [x] Page reordering by drag, moving pages between sections
- [x] Deletes go to the Trash
- [x] Search also covers table cells
- [x] Redesigned app icon (cursive S on a dark ruled slate), drawn by the Rust ink engine (`crates/scribe-icon`)

### Velvet dark interface
- [x] Three rounded panels on a dark ground; no hard edges or sharp corners
- [x] Collapsible notebooks sidebar (icon rail) and page list, remembered between launches
- [x] Page centred in its pane, zoomed to fit beside open panels
- [x] Focus mode; automatic rail in narrow windows
- [x] Floating dock with pen tray (live preview stroke) and Insert menu
- [x] Format pill above the text being edited; action pill above a lasso selection
- [x] Fraunces (soft) page titles, SF Pro Rounded interface
- [x] Black ink painted warm cream; dark theme only
- [x] Clicks on on-page controls land correctly at any zoom

### Not carried over
- [ ] OneNote import (needs OneNote's Windows COM API; use the Windows build, then open the folder here)
- [ ] Touch-specific palm rejection (no touchscreens on the Mac)

## Tests
- `cargo test -p scribe-core`: format round trips, legacy files, unknown-field
  preservation, manifests, renames, moves, search, geometry, erase, tables, FFI
- `swift test`: core bridge, rich-text spans, page model undo and growth
