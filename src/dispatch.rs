//! Keyboard dispatcher — routes key events to the focused pane.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::app::{self, App, ConfirmAction, Focus, PendingExternal, PromptAction, SidebarTab};
use crate::editor::Mode;
use crate::external;
use crate::theme::Theme;
use crate::ui::file_tree::selected_node;
use crate::ui::palette::{filtered as palette_filter, CommandId};
use crate::ui::switcher::filtered as switcher_filter;
use crate::vault;

pub fn on_key(app: &mut App, key: KeyEvent) {
    // Global shortcuts that work regardless of focus (except in text-entry overlays).
    if global_shortcut(app, key) {
        return;
    }

    match app.focus {
        Focus::Palette => palette_keys(app, key),
        Focus::Switcher => switcher_keys(app, key),
        Focus::Search => search_keys(app, key),
        Focus::Help => help_keys(app, key),
        Focus::Prompt => prompt_keys(app, key),
        Focus::Confirm => confirm_keys(app, key),
        Focus::CommandLine => cmdline_keys(app, key),
        Focus::FileTree => filetree_keys(app, key),
        Focus::Quicknote => quicknote_keys(app, key),
        Focus::Todo => todo_keys(app, key),
        Focus::Sidebar => sidebar_keys(app, key),
        Focus::Calendar => calendar_keys(app, key),
        Focus::Graph => graph_keys(app, key),
        Focus::Settings => help_keys(app, key),
        Focus::Editor | Focus::Preview => editor_keys(app, key),
    }
}

/// Handles globally-bound chords. Returns true if consumed.
fn global_shortcut(app: &mut App, key: KeyEvent) -> bool {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let shift = key.modifiers.contains(KeyModifiers::SHIFT);

    // ESC handled per-focus below — except we want it to close graph too.
    if let KeyCode::Esc = key.code {
        app.escape();
        return true;
    }

    // Vim ex command line — `:` opens it from any non-text-entry focus and
    // only when the editor is in NORMAL mode (so it doesn't steal `:` in
    // insert mode).
    if matches!(key.code, KeyCode::Char(':')) && !ctrl {
        let in_text_overlay = matches!(
            app.focus,
            Focus::Palette
                | Focus::Switcher
                | Focus::Search
                | Focus::Prompt
                | Focus::Confirm
                | Focus::CommandLine
                | Focus::Quicknote // quicknote is a live text field
        );
        let in_insert = matches!(app.focus, Focus::Editor | Focus::Preview)
            && app
                .doc
                .as_ref()
                .map(|d| d.mode == Mode::Insert)
                .unwrap_or(false);
        if !in_text_overlay && !in_insert {
            app.open_cmdline();
            return true;
        }
    }

    if !ctrl {
        return false;
    }

    // Don't let global ctrl- shortcuts steal from text-entry/modal overlays.
    let in_text_overlay = matches!(
        app.focus,
        Focus::Palette | Focus::Switcher | Focus::Search | Focus::Prompt | Focus::Confirm
    );

    match key.code {
        KeyCode::Char('q') => {
            app.should_quit = true;
            true
        }
        KeyCode::Char('p') if !in_text_overlay => {
            app.open_palette();
            true
        }
        KeyCode::Char('o') if !in_text_overlay => {
            app.open_switcher();
            true
        }
        KeyCode::Char('f') if shift && !in_text_overlay => {
            app.open_search();
            true
        }
        KeyCode::Char('n') if !in_text_overlay => {
            start_prompt(app, "New note title", PromptAction::NewNote, "");
            true
        }
        KeyCode::Char('s') if !in_text_overlay => {
            if let Err(e) = app.save_current() {
                app.set_status(format!("save failed: {e}"));
            }
            true
        }
        KeyCode::Char('e') if !in_text_overlay => {
            app.show_preview = !app.show_preview;
            true
        }
        KeyCode::Char('b') if !in_text_overlay => {
            app.show_left = !app.show_left;
            if !app.show_left && app.focus == Focus::FileTree {
                app.focus = Focus::Editor;
            }
            true
        }
        KeyCode::Char('r') if !in_text_overlay => {
            app.show_right = !app.show_right;
            if !app.show_right && (app.focus == Focus::Sidebar || app.focus == Focus::Calendar) {
                app.focus = Focus::Editor;
            }
            true
        }
        KeyCode::Char('g') if !in_text_overlay => {
            app.open_graph();
            true
        }
        KeyCode::Char('k') if !in_text_overlay => {
            app.open_calendar();
            true
        }
        KeyCode::Char('t') if !in_text_overlay => {
            app.show_right = true;
            app.sidebar_tab = SidebarTab::Tags;
            app.focus = Focus::Sidebar;
            true
        }
        KeyCode::Char('/') if !in_text_overlay => {
            app.open_help();
            true
        }
        KeyCode::Char('1') if !in_text_overlay => {
            if app.show_left {
                app.focus = Focus::FileTree;
            }
            true
        }
        KeyCode::Char('2') if !in_text_overlay => {
            app.focus = Focus::Editor;
            true
        }
        KeyCode::Char('3') if !in_text_overlay => {
            if app.show_preview {
                app.focus = Focus::Preview;
            }
            true
        }
        KeyCode::Char('4') if !in_text_overlay => {
            if app.show_right {
                app.focus = Focus::Sidebar;
            }
            true
        }
        _ => false,
    }
}

// -----------------------------------------------------------------------------
// File tree
// -----------------------------------------------------------------------------

fn filetree_keys(app: &mut App, key: KeyEvent) {
    let len = visible_tree_len(app);
    match key.code {
        KeyCode::Char('j') | KeyCode::Down
            if len > 0 => {
                app.tree_selected = (app.tree_selected + 1).min(len - 1);
            }
        KeyCode::Char('k') | KeyCode::Up => {
            app.tree_selected = app.tree_selected.saturating_sub(1);
        }
        KeyCode::Char('g') => {
            app.tree_selected = 0;
        }
        KeyCode::Char('G') => {
            app.tree_selected = len.saturating_sub(1);
        }
        KeyCode::Enter => {
            if let Some(node) = selected_node(app) {
                if node.is_dir {
                    toggle_expand(app, node.path);
                } else {
                    let _ = app.open_note(node.path);
                }
            }
        }
        KeyCode::Char(' ') => {
            if let Some(node) = selected_node(app) {
                if node.is_dir {
                    toggle_expand(app, node.path);
                }
            }
        }
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        KeyCode::Char('n') => {
            // New note relative to the selected folder (or the selected note's
            // folder); typing more `/`-segments nests further.
            let prefix = selected_dir_prefix(app);
            start_prompt(app, "New note (path)", PromptAction::NewNote, &prefix);
        }
        KeyCode::Char('m') => {
            let prefix = selected_dir_prefix(app);
            start_prompt(app, "New folder (path)", PromptAction::NewFolder, &prefix);
        }
        KeyCode::Char('d') => {
            if let Some(node) = selected_node(app) {
                let what = if node.is_dir { "folder" } else { "note" };
                let extra = if node.is_dir {
                    " and everything in it"
                } else {
                    ""
                };
                app.start_confirm(
                    format!("Delete {what} '{}'{extra}?", node.name),
                    ConfirmAction::Delete(node.path),
                );
            }
        }
        KeyCode::Char('r') => {
            if let Some(node) = selected_node(app) {
                if !node.is_dir {
                    start_prompt(
                        app,
                        "Rename to",
                        PromptAction::Rename,
                        &vault::note_basename(&node.path),
                    );
                    // Rename the *selected* node, not whatever doc is open.
                    app.prompt.target = Some(node.path);
                }
            }
        }
        _ => {}
    }
}

fn visible_tree_len(app: &App) -> usize {
    let exp = TreeExp(&app.expanded_dirs);
    app.vault.tree.flatten(&exp).len()
}

/// Vault-relative folder of the current file-tree selection, as a `"Folder/"`
/// prefix for new-note/-folder prompts (empty string at the vault root).
fn selected_dir_prefix(app: &App) -> String {
    let Some(node) = selected_node(app) else {
        return String::new();
    };
    let dir = if node.is_dir {
        Some(node.path.clone())
    } else {
        node.path.parent().map(|p| p.to_path_buf())
    };
    if let Some(d) = dir {
        let rel = vault::note_relpath(&app.vault.root, &d);
        if !rel.is_empty() {
            return format!("{rel}/");
        }
    }
    String::new()
}

struct TreeExp<'a>(&'a std::collections::HashSet<std::path::PathBuf>);
impl<'a> crate::vault::tree::ExpansionSet for TreeExp<'a> {
    fn is_expanded(&self, path: &std::path::Path) -> bool {
        self.0.contains(path)
    }
}

fn toggle_expand(app: &mut App, path: std::path::PathBuf) {
    if !app.expanded_dirs.remove(&path) {
        app.expanded_dirs.insert(path);
    }
}

// -----------------------------------------------------------------------------
// Editor
// -----------------------------------------------------------------------------

fn editor_keys(app: &mut App, key: KeyEvent) {
    if app.doc.is_none() {
        // No document — only Tab navigates panes; everything else is no-op.
        match key.code {
            KeyCode::Tab => app.toggle_pane_focus(true),
            KeyCode::BackTab => app.toggle_pane_focus(false),
            _ => {}
        }
        return;
    }

    let mode = app.doc.as_ref().unwrap().mode;
    match mode {
        Mode::Insert => editor_insert(app, key),
        Mode::Normal | Mode::OpPending => editor_normal(app, key),
        Mode::Visual => editor_normal(app, key),
    }
}

fn editor_insert(app: &mut App, key: KeyEvent) {
    let doc = app.doc.as_mut().unwrap();
    match key.code {
        KeyCode::Esc => {
            doc.mode = Mode::Normal;
        }
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            doc.history.record(&doc.buffer);
            doc.buffer.insert_char(c);
            doc.dirty = true;
        }
        KeyCode::Enter => {
            doc.history.record(&doc.buffer);
            doc.buffer.insert_newline();
            doc.dirty = true;
        }
        KeyCode::Tab => {
            doc.history.record(&doc.buffer);
            let n = app.config.editor.tab_size;
            for _ in 0..n {
                doc.buffer.insert_char(' ');
            }
            doc.dirty = true;
        }
        KeyCode::Backspace => {
            doc.history.record(&doc.buffer);
            doc.buffer.backspace();
            doc.dirty = true;
        }
        KeyCode::Delete => {
            doc.history.record(&doc.buffer);
            doc.buffer.delete_forward();
            doc.dirty = true;
        }
        KeyCode::Left => doc.buffer.move_left(),
        KeyCode::Right => doc.buffer.move_right(),
        KeyCode::Up => doc.buffer.move_up(),
        KeyCode::Down => doc.buffer.move_down(),
        KeyCode::Home => doc.buffer.move_line_start(),
        KeyCode::End => doc.buffer.move_line_end(),
        KeyCode::PageUp => {
            for _ in 0..10 {
                doc.buffer.move_up();
            }
        }
        KeyCode::PageDown => {
            for _ in 0..10 {
                doc.buffer.move_down();
            }
        }
        _ => {}
    }
}

fn editor_normal(app: &mut App, key: KeyEvent) {
    // Ctrl-Enter follows wikilink at cursor.
    if key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('m') | KeyCode::Enter) {
        follow_wikilink_at_cursor(app);
        return;
    }

    let doc = app.doc.as_mut().unwrap();
    let pending = doc.pending_op.take();
    match key.code {
        KeyCode::Char('i') => doc.mode = Mode::Insert,
        KeyCode::Char('I') => {
            doc.buffer.move_line_start();
            doc.mode = Mode::Insert;
        }
        KeyCode::Char('a') => {
            doc.buffer.move_right();
            doc.mode = Mode::Insert;
        }
        KeyCode::Char('A') => {
            doc.buffer.move_line_end();
            doc.mode = Mode::Insert;
        }
        KeyCode::Char('o') => {
            doc.history.record(&doc.buffer);
            doc.buffer.move_line_end();
            doc.buffer.insert_newline();
            doc.mode = Mode::Insert;
            doc.dirty = true;
        }
        KeyCode::Char('O') => {
            doc.history.record(&doc.buffer);
            doc.buffer.move_line_start();
            doc.buffer.open_line_above();
            doc.mode = Mode::Insert;
            doc.dirty = true;
        }
        KeyCode::Char('h') | KeyCode::Left => doc.buffer.move_left(),
        KeyCode::Char('l') | KeyCode::Right => doc.buffer.move_right(),
        KeyCode::Char('j') | KeyCode::Down => doc.buffer.move_down(),
        KeyCode::Char('k') | KeyCode::Up => doc.buffer.move_up(),
        KeyCode::Char('w') => doc.buffer.move_word_forward(),
        KeyCode::Char('b') => doc.buffer.move_word_back(),
        KeyCode::Char('0') | KeyCode::Home => doc.buffer.move_line_start(),
        KeyCode::Char('$') | KeyCode::End => doc.buffer.move_line_end(),
        KeyCode::Char('G') => doc.buffer.move_doc_end(),
        KeyCode::Char('g') => {
            if pending == Some('g') {
                doc.buffer.move_doc_start();
            } else {
                doc.pending_op = Some('g');
            }
        }
        KeyCode::Char('x') => {
            doc.history.record(&doc.buffer);
            doc.buffer.delete_forward();
            doc.dirty = true;
        }
        KeyCode::Char('d') => {
            if pending == Some('d') {
                doc.history.record(&doc.buffer);
                doc.buffer.delete_line();
                doc.dirty = true;
            } else {
                doc.pending_op = Some('d');
            }
        }
        KeyCode::Char('D') => {
            doc.history.record(&doc.buffer);
            doc.buffer.delete_to_eol();
            doc.dirty = true;
        }
        KeyCode::Char('u')
            if doc.history.undo(&mut doc.buffer) => {
                doc.dirty = true;
            }
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        _ => {}
    }
}

fn follow_wikilink_at_cursor(app: &mut App) {
    let Some(doc) = app.doc.as_ref() else {
        return;
    };
    let line = doc.buffer.line(doc.buffer.cursor.line).to_string();
    let col = doc.buffer.cursor.col;
    let byte = doc.buffer.col_to_byte(doc.buffer.cursor.line, col);

    // Find the [[ ... ]] that surrounds `byte`.
    let mut left = None;
    let mut search = byte;
    while search > 1 {
        if &line[search - 2..search] == "[[" {
            left = Some(search);
            break;
        }
        search -= 1;
    }
    let Some(left) = left else {
        return;
    };
    let Some(rel) = line[left..].find("]]") else {
        return;
    };
    let inner = &line[left..left + rel];
    let target = inner.split_once('|').map(|x| x.0).unwrap_or(inner);
    let target = target.split_once('#').map(|x| x.0).unwrap_or(target).trim();
    if target.is_empty() {
        return;
    }
    match app.vault.resolve_link(target) {
        Some(p) => {
            let _ = app.open_note(p);
        }
        None => {
            // Create a new note with that title.
            let _ = app.create_note(target);
        }
    }
}

// -----------------------------------------------------------------------------
// Sidebar
// -----------------------------------------------------------------------------

fn sidebar_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        KeyCode::Char('n') | KeyCode::Right => app.sidebar_tab = app.sidebar_tab.next(),
        KeyCode::Char('p') | KeyCode::Left => {
            app.sidebar_tab = app.sidebar_tab.prev();
        }
        KeyCode::Char('j') | KeyCode::Down => {
            app.sidebar_selected = app.sidebar_selected.saturating_add(1);
        }
        KeyCode::Char('k') | KeyCode::Up => {
            app.sidebar_selected = app.sidebar_selected.saturating_sub(1);
        }
        KeyCode::Enter => sidebar_open_selected(app),
        _ => {}
    }
}

fn sidebar_open_selected(app: &mut App) {
    match app.sidebar_tab {
        SidebarTab::Backlinks => {
            let path = match app.doc.as_ref().and_then(|d| d.path.clone()) {
                Some(p) => p,
                None => return,
            };
            let backs = app.vault.index.backlinks_for(&path);
            if let Some(p) = backs.get(app.sidebar_selected).cloned() {
                let _ = app.open_note(p);
            }
        }
        SidebarTab::Tags => {
            let tags = app.vault.index.all_tags();
            if let Some((t, _)) = tags.get(app.sidebar_selected).cloned() {
                app.set_status(format!("Filtering by #{t} — opening first match"));
                let notes = app.vault.index.notes_with_tag(&t);
                if let Some(p) = notes.first().cloned() {
                    let _ = app.open_note(p);
                }
            }
        }
        SidebarTab::Outline => {
            // No-op for now; opening headings would require navigation back into the editor.
        }
    }
}

// -----------------------------------------------------------------------------
// Calendar
// -----------------------------------------------------------------------------

fn calendar_keys(app: &mut App, key: KeyEvent) {
    use chrono::Datelike;
    let cur = app.calendar.cursor;
    let new = match key.code {
        KeyCode::Char('h') | KeyCode::Left => cur.pred_opt().unwrap_or(cur),
        KeyCode::Char('l') | KeyCode::Right => cur.succ_opt().unwrap_or(cur),
        KeyCode::Char('j') | KeyCode::Down => {
            cur.checked_add_signed(chrono::Duration::days(7)).unwrap_or(cur)
        }
        KeyCode::Char('k') | KeyCode::Up => {
            cur.checked_sub_signed(chrono::Duration::days(7)).unwrap_or(cur)
        }
        KeyCode::Char('H') => {
            // previous month
            let (y, m) = if cur.month() == 1 {
                (cur.year() - 1, 12)
            } else {
                (cur.year(), cur.month() - 1)
            };
            chrono::NaiveDate::from_ymd_opt(y, m, cur.day().min(28)).unwrap_or(cur)
        }
        KeyCode::Char('L') => {
            let (y, m) = if cur.month() == 12 {
                (cur.year() + 1, 1)
            } else {
                (cur.year(), cur.month() + 1)
            };
            chrono::NaiveDate::from_ymd_opt(y, m, cur.day().min(28)).unwrap_or(cur)
        }
        KeyCode::Char('t') => app::today(),
        KeyCode::Enter => {
            // Per design: Enter (un)fullscreens the calendar pane.
            app.toggle_fullscreen();
            return;
        }
        KeyCode::Char('o') | KeyCode::Char(' ') => {
            // Open the daily note for the selected date.
            let _ = app.open_daily_note(cur);
            app.focus = Focus::Editor;
            return;
        }
        KeyCode::Tab => {
            app.toggle_pane_focus(true);
            return;
        }
        KeyCode::BackTab => {
            app.toggle_pane_focus(false);
            return;
        }
        _ => cur,
    };
    app.calendar.cursor = new;
}

// -----------------------------------------------------------------------------
// Palette
// -----------------------------------------------------------------------------

fn palette_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Enter => {
            let filtered = palette_filter(&app.palette.query);
            if let Some((_, cmd)) = filtered.get(app.palette.selected).copied() {
                app.close_overlay();
                run_command(app, cmd.id);
            }
        }
        KeyCode::Up => {
            app.palette.selected = app.palette.selected.saturating_sub(1);
        }
        KeyCode::Down => {
            let len = palette_filter(&app.palette.query).len();
            if len > 0 {
                app.palette.selected = (app.palette.selected + 1).min(len - 1);
            }
        }
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.palette.query.push(c);
            app.palette.selected = 0;
        }
        KeyCode::Backspace => {
            app.palette.query.pop();
            app.palette.selected = 0;
        }
        _ => {}
    }
}

fn run_command(app: &mut App, id: CommandId) {
    match id {
        CommandId::NewNote => start_prompt(app, "New note title", PromptAction::NewNote, ""),
        CommandId::SaveNote => {
            if let Err(e) = app.save_current() {
                app.set_status(format!("save failed: {e}"));
            }
        }
        CommandId::QuickSwitcher => app.open_switcher(),
        CommandId::Search => app.open_search(),
        CommandId::OpenToday => {
            let _ = app.open_daily_note(app::today());
        }
        CommandId::OpenCalendar => app.open_calendar(),
        CommandId::ToggleGraph => {
            app.show_graph_pane = !app.show_graph_pane;
            if app.show_graph_pane {
                app.open_graph();
            } else if app.focus == Focus::Graph {
                app.focus = Focus::Editor;
            }
        }
        CommandId::TogglePreview => app.show_preview = !app.show_preview,
        CommandId::ToggleLeft => app.show_left = !app.show_left,
        CommandId::ToggleRight => app.show_right = !app.show_right,
        CommandId::ThemeDark => set_theme(app, "dark"),
        CommandId::ThemeLight => set_theme(app, "light"),
        CommandId::ThemeDracula => set_theme(app, "dracula"),
        CommandId::ThemeNord => set_theme(app, "nord"),
        CommandId::Help => app.open_help(),
        CommandId::OpenVault => {
            let initial = app.vault.root.to_string_lossy().into_owned();
            start_prompt(
                app,
                "Open vault (path)",
                PromptAction::OpenVault,
                &initial,
            );
        }
        CommandId::DeleteNote => confirm_delete_current(app),
        CommandId::RenameNote => {
            if let Some(p) = app.doc.as_ref().and_then(|d| d.path.clone()) {
                start_prompt(
                    app,
                    "Rename to",
                    PromptAction::Rename,
                    &vault::note_basename(&p),
                );
            }
        }
        CommandId::Quit => app.should_quit = true,
    }
}

fn set_theme(app: &mut App, name: &str) {
    app.config.theme = name.to_string();
    app.theme = Theme::preset(name).unwrap_or_default();
    app.theme_gen += 1; // invalidate the preview render cache
    let _ = app.config.save();
    app.set_status(format!("theme: {}", app.theme.name));
}

// -----------------------------------------------------------------------------
// Switcher
// -----------------------------------------------------------------------------

fn switcher_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Enter => {
            let results = switcher_filter(app, &app.switcher.query);
            if let Some(p) = results.get(app.switcher.selected).cloned() {
                app.close_overlay();
                let _ = app.open_note(p);
            }
        }
        KeyCode::Up => {
            app.switcher.selected = app.switcher.selected.saturating_sub(1);
        }
        KeyCode::Down => {
            let len = switcher_filter(app, &app.switcher.query).len();
            if len > 0 {
                app.switcher.selected = (app.switcher.selected + 1).min(len - 1);
            }
        }
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.switcher.query.push(c);
            app.switcher.selected = 0;
        }
        KeyCode::Backspace => {
            app.switcher.query.pop();
            app.switcher.selected = 0;
        }
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Search
// -----------------------------------------------------------------------------

fn search_keys(app: &mut App, key: KeyEvent) {
    if app.search.editing_query {
        match key.code {
            KeyCode::Enter => {
                app.run_search();
                app.search.editing_query = false;
                app.search.selected = 0;
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.search.query.push(c);
            }
            KeyCode::Backspace => {
                app.search.query.pop();
            }
            KeyCode::Tab => {
                app.search.editing_query = false;
            }
            _ => {}
        }
    } else {
        match key.code {
            KeyCode::Tab => app.search.editing_query = true,
            KeyCode::Up => app.search.selected = app.search.selected.saturating_sub(1),
            KeyCode::Down
                if !app.search.results.is_empty() => {
                    app.search.selected =
                        (app.search.selected + 1).min(app.search.results.len() - 1);
                }
            KeyCode::Enter => {
                if let Some(hit) = app.search.results.get(app.search.selected).cloned() {
                    app.close_overlay();
                    let _ = app.open_note(hit.path.clone());
                    if let Some(doc) = app.doc.as_mut() {
                        doc.buffer.cursor.line = hit.line.min(doc.buffer.line_count() - 1);
                        doc.buffer.cursor.col = 0;
                    }
                }
            }
            _ => {}
        }
    }
}

// -----------------------------------------------------------------------------
// Prompt
// -----------------------------------------------------------------------------

fn start_prompt(app: &mut App, label: &str, action: PromptAction, initial: &str) {
    app.last_focus = app.focus;
    app.focus = Focus::Prompt;
    app.prompt.label = label.to_string();
    app.prompt.value = initial.to_string();
    app.prompt.action = action;
    app.prompt.target = None;
}

// -----------------------------------------------------------------------------
// Confirm dialog
// -----------------------------------------------------------------------------

fn confirm_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        // Only an explicit "y" confirms; anything else cancels (safe default).
        KeyCode::Char('y') | KeyCode::Char('Y') => app.execute_confirm(),
        _ => {
            app.confirm.action = ConfirmAction::None;
            app.focus = app.last_focus;
        }
    }
}

/// Ask to delete the currently-open note (used by `:delete` and the palette).
fn confirm_delete_current(app: &mut App) {
    if let Some(p) = app.doc.as_ref().and_then(|d| d.path.clone()) {
        let name = vault::note_basename(&p);
        app.start_confirm(format!("Delete note '{name}'?"), ConfirmAction::Delete(p));
    } else {
        app.set_status("no note to delete");
    }
}

fn prompt_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Enter => {
            let action = app.prompt.action;
            let value = std::mem::take(&mut app.prompt.value);
            app.close_overlay();
            apply_prompt(app, action, value);
        }
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.prompt.value.push(c);
        }
        KeyCode::Backspace => {
            app.prompt.value.pop();
        }
        _ => {}
    }
}

fn apply_prompt(app: &mut App, action: PromptAction, value: String) {
    let v = value.trim();
    if v.is_empty() {
        return;
    }
    match action {
        PromptAction::NewNote => {
            if let Err(e) = app.create_note(v) {
                app.set_status(format!("create failed: {e}"));
            }
        }
        PromptAction::NewFolder => {
            if let Err(e) = app.create_folder(v) {
                app.set_status(format!("mkdir failed: {e}"));
            }
            app.focus = Focus::FileTree;
        }
        PromptAction::Rename => {
            // Rename the prompt's subject (the selected file-tree node) if set,
            // otherwise fall back to the currently-open document.
            let from = app
                .prompt
                .target
                .take()
                .or_else(|| app.doc.as_ref().and_then(|d| d.path.clone()));
            if let Some(p) = from {
                let parent = p.parent().unwrap_or_else(|| std::path::Path::new("."));
                let target = parent.join(format!("{}.md", vault::sanitize_title(v)));
                if let Err(e) = app.vault.rename_note(&p, &target) {
                    app.set_status(format!("rename failed: {e}"));
                } else {
                    // Keep the open document's path in sync only if it's the one
                    // we renamed.
                    if let Some(doc) = app.doc.as_mut() {
                        if doc.path.as_deref() == Some(p.as_path()) {
                            doc.path = Some(target.clone());
                        }
                    }
                    app.set_status(format!("renamed to {}", target.display()));
                }
            }
        }
        PromptAction::Search => {
            app.search.query = v.to_string();
            app.open_search();
            app.run_search();
        }
        PromptAction::OpenVault => open_vault_path(app, v),
        PromptAction::AddTodo => {
            app.todos.add(v.to_string());
            app.save_todos();
            app.focus = Focus::Todo;
        }
        PromptAction::EditTodo => {
            app.todos.edit_selected(v.to_string());
            app.save_todos();
            app.focus = Focus::Todo;
        }
        PromptAction::None => {}
    }
}

// -----------------------------------------------------------------------------
// Help
// -----------------------------------------------------------------------------

fn help_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') | KeyCode::Enter => app.close_overlay(),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Command line — vim-style `:` ex commands
// -----------------------------------------------------------------------------

fn cmdline_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Enter => {
            let cmd = std::mem::take(&mut app.cmdline.value);
            app.cmdline.draft.clear();
            app.cmdline.history_idx = None;
            if !cmd.trim().is_empty() {
                // Push to history, dedup adjacent duplicates.
                if app.cmdline.history.last() != Some(&cmd) {
                    app.cmdline.history.push(cmd.clone());
                    if app.cmdline.history.len() > 100 {
                        app.cmdline.history.remove(0);
                    }
                }
            }
            app.focus = app.last_focus;
            if !cmd.trim().is_empty() {
                run_ex_command(app, &cmd);
            }
        }
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.cmdline.value.push(c);
            app.cmdline.history_idx = None;
        }
        KeyCode::Backspace => {
            app.cmdline.value.pop();
            app.cmdline.history_idx = None;
        }
        KeyCode::Up => cmdline_history_step(app, true),
        KeyCode::Down => cmdline_history_step(app, false),
        _ => {}
    }
}

fn cmdline_history_step(app: &mut App, older: bool) {
    if app.cmdline.history.is_empty() {
        return;
    }
    let len = app.cmdline.history.len();
    let idx = match app.cmdline.history_idx {
        None => {
            // Save the in-progress draft so we can restore it on the way back.
            app.cmdline.draft = app.cmdline.value.clone();
            if older {
                Some(len - 1)
            } else {
                None
            }
        }
        Some(i) => {
            if older {
                if i == 0 {
                    Some(0)
                } else {
                    Some(i - 1)
                }
            } else if i + 1 >= len {
                None
            } else {
                Some(i + 1)
            }
        }
    };
    app.cmdline.history_idx = idx;
    app.cmdline.value = match idx {
        Some(i) => app.cmdline.history[i].clone(),
        None => std::mem::take(&mut app.cmdline.draft),
    };
}

/// Parse and execute an ex command (the text after `:`).
/// Errors are reported via `app.set_status` — never panics.
fn run_ex_command(app: &mut App, raw: &str) {
    let raw = raw.trim();
    if raw.is_empty() {
        return;
    }
    // `:42` jumps to line 42 in the current document.
    if raw.chars().all(|c| c.is_ascii_digit()) {
        if let (Some(doc), Ok(n)) = (app.doc.as_mut(), raw.parse::<usize>()) {
            let target = n.saturating_sub(1).min(doc.buffer.line_count().saturating_sub(1));
            doc.buffer.cursor.line = target;
            doc.buffer.cursor.col = 0;
            doc.buffer.goal_col = 0;
        }
        return;
    }

    let (cmd, args) = raw
        .split_once(|c: char| c.is_whitespace())
        .map(|(c, a)| (c, a.trim()))
        .unwrap_or((raw, ""));

    match cmd {
        "q" | "quit" => {
            let dirty = app.doc.as_ref().map(|d| d.dirty).unwrap_or(false);
            if dirty {
                app.set_status("E37: unsaved changes — use :q! to override or :wq to save");
            } else {
                app.should_quit = true;
            }
        }
        "q!" | "quit!" => {
            app.should_quit = true;
        }
        "w" | "write" => match app.save_current() {
            Ok(()) => {}
            Err(e) => app.set_status(format!("write failed: {e}")),
        },
        "wq" | "x" | "wq!" => match app.save_current() {
            Ok(()) => app.should_quit = true,
            Err(e) => app.set_status(format!("write failed: {e}")),
        },
        "e" | "edit" => {
            if args.is_empty() {
                app.set_status("usage: :e <name-or-path>");
                return;
            }
            // Try wikilink resolution first (Obsidian-like), then absolute path,
            // then relative-to-vault-root path.
            if let Some(p) = app.vault.resolve_link(args) {
                if let Err(e) = app.open_note(p) {
                    app.set_status(format!("open failed: {e}"));
                }
                return;
            }
            let direct = std::path::PathBuf::from(args);
            let resolved = if direct.is_absolute() {
                direct
            } else {
                app.vault.root.join(args)
            };
            if resolved.exists() {
                if let Err(e) = app.open_note(resolved) {
                    app.set_status(format!("open failed: {e}"));
                }
            } else {
                app.set_status(format!("E447: can't find note \"{args}\""));
            }
        }
        "new" => {
            if args.is_empty() {
                app.set_status("usage: :new <title>");
                return;
            }
            if let Err(e) = app.create_note(args) {
                app.set_status(format!("create failed: {e}"));
            }
        }
        "help" | "h" => app.open_help(),
        "set" => apply_set(app, args),
        "vault" => {
            if args.is_empty() {
                app.set_status(format!("vault: {}", app.vault.root.display()));
                return;
            }
            open_vault_path(app, args);
        }
        "today" => {
            if let Err(e) = app.open_daily_note(app::today()) {
                app.set_status(format!("daily note failed: {e}"));
            }
        }
        "graph" => app.open_graph(),
        "calendar" | "cal" => app.open_calendar(),
        "todo" | "todos" => app.focus_todo(),
        "quicknote" | "scratch" | "qn" => app.focus_quicknote(),
        "mkdir" | "newfolder" => {
            if args.is_empty() {
                app.set_status("usage: :mkdir <folder/path>");
            } else if let Err(e) = app.create_folder(args) {
                app.set_status(format!("mkdir failed: {e}"));
            }
        }
        "preview" => {
            app.show_preview = !app.show_preview;
        }
        "fzf" | "files" => request_external(app, PendingExternal::Fzf, "fzf"),
        "rg" | "livegrep" | "grep" => request_external(app, PendingExternal::FzfGrep, "fzf"),
        "yazi" | "files!" | "browse" => request_external(app, PendingExternal::Yazi, "yazi"),
        "Telescope" | "telescope" => run_telescope(app, args),
        "search" => {
            app.search.query = args.to_string();
            app.open_search();
            if !args.is_empty() {
                app.run_search();
            }
        }
        "delete" | "rm" => confirm_delete_current(app),
        "rename" => {
            if args.is_empty() {
                app.set_status("usage: :rename <new-name>");
                return;
            }
            if let Some(p) = app.doc.as_ref().and_then(|d| d.path.clone()) {
                let parent = p.parent().unwrap_or_else(|| std::path::Path::new("."));
                let target = parent.join(format!("{}.md", vault::sanitize_title(args)));
                if let Err(e) = app.vault.rename_note(&p, &target) {
                    app.set_status(format!("rename failed: {e}"));
                } else if let Some(doc) = app.doc.as_mut() {
                    doc.path = Some(target);
                }
            }
        }
        other => {
            app.set_status(format!("E492: not an editor command: {other}"));
        }
    }
}

/// Queue an external tool for the event loop, but only if it's installed.
fn request_external(app: &mut App, ext: PendingExternal, tool: &str) {
    if external::exists(tool) {
        app.pending_external = Some(ext);
    } else {
        app.set_status(format!("{tool} not found on PATH"));
    }
}

/// Neovim Telescope-style verbs, e.g. `:Telescope find_files`,
/// `:Telescope live_grep query`. Maps each picker to its Onyx equivalent.
fn run_telescope(app: &mut App, args: &str) {
    let (picker, query) = args
        .split_once(|c: char| c.is_whitespace())
        .map(|(p, q)| (p, q.trim()))
        .unwrap_or((args.trim(), ""));

    match picker {
        "" | "builtin" => {
            app.set_status("Telescope: find_files · live_grep · grep_string · buffers · oldfiles · help_tags · file_browser");
        }
        "find_files" | "git_files" | "fd" | "files" => {
            // Native fuzzy switcher; fall through to fzf if the user prefers it.
            app.open_switcher();
            if !query.is_empty() {
                app.switcher.query = query.to_string();
                app.switcher.selected = 0;
            }
        }
        "fzf" => request_external(app, PendingExternal::Fzf, "fzf"),
        // live_grep uses the external fzf+ripgrep picker so it gets a bat
        // preview pane (Telescope-style). For the in-process search overlay
        // instead, use `:search` or `:Telescope native_grep`.
        "live_grep" | "grep_string" | "grep" | "rg" => {
            request_external(app, PendingExternal::FzfGrep, "fzf")
        }
        "native_grep" => {
            app.search.query = query.to_string();
            app.open_search();
            if !query.is_empty() {
                app.run_search();
                app.search.editing_query = false;
            }
        }
        "buffers" | "oldfiles" | "recent" => {
            // Switcher defaults to recency order when the query is empty.
            app.open_switcher();
        }
        "help_tags" | "help" | "keymaps" => app.open_help(),
        "file_browser" | "browse" => request_external(app, PendingExternal::Yazi, "yazi"),
        "colorscheme" | "themes" => {
            app.set_status("use :set theme=<dark|light|dracula|nord>");
        }
        other => app.set_status(format!("Telescope: unknown picker '{other}'")),
    }
}

fn apply_set(app: &mut App, args: &str) {
    // Forms supported: `set theme=<name>`, `set preview`, `set nopreview`,
    // `set numbers`, `set nonumbers`, `set wrap`, `set nowrap`.
    if args.is_empty() {
        app.set_status("usage: :set theme=<dark|light|dracula|nord>");
        return;
    }
    if let Some(name) = args.strip_prefix("theme=").map(str::trim) {
        match Theme::preset(name) {
            Some(t) => {
                app.theme = t;
                app.config.theme = name.to_string();
                let _ = app.config.save();
                app.set_status(format!("theme: {}", app.theme.name));
            }
            None => app.set_status(format!("unknown theme: {name}")),
        }
        return;
    }
    match args {
        "preview" => app.show_preview = true,
        "nopreview" => app.show_preview = false,
        "numbers" | "number" => app.config.editor.line_numbers = true,
        "nonumbers" | "nonumber" => app.config.editor.line_numbers = false,
        "wrap" => app.config.editor.wrap = true,
        "nowrap" => app.config.editor.wrap = false,
        "left" => app.show_left = true,
        "noleft" => app.show_left = false,
        "right" => app.show_right = true,
        "noright" => app.show_right = false,
        other => app.set_status(format!("unknown :set option: {other}")),
    }
    let _ = app.config.save();
}

fn open_vault_path(app: &mut App, path: &str) {
    let pb = std::path::PathBuf::from(path);
    // Try to open an existing vault; otherwise create one. Either way
    // `switch_vault` resets all vault-derived state (doc, tree, side panes).
    match crate::vault::Vault::open(&pb).or_else(|_| crate::vault::Vault::create(&pb)) {
        Ok(v) => app.switch_vault(v, pb),
        Err(e) => app.set_status(format!("vault failed: {e}")),
    }
}

// -----------------------------------------------------------------------------
// Graph
// -----------------------------------------------------------------------------

fn graph_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        // Enter (un)fullscreens the graph pane.
        KeyCode::Enter => app.toggle_fullscreen(),
        // `a` toggles local ↔ whole-vault scope.
        KeyCode::Char('a') => app.toggle_graph_scope(),
        // `o` opens the centered note.
        KeyCode::Char('o') => {
            if let Some(p) = app.graph_focus.clone() {
                let _ = app.open_note(p);
            }
        }
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Quicknote — always-editable scratch buffer
// -----------------------------------------------------------------------------

fn quicknote_keys(app: &mut App, key: KeyEvent) {
    // Tab leaves the pane (saving first).
    match key.code {
        KeyCode::Tab => {
            app.save_quicknote();
            app.toggle_pane_focus(true);
            return;
        }
        KeyCode::BackTab => {
            app.save_quicknote();
            app.toggle_pane_focus(false);
            return;
        }
        _ => {}
    }
    let qn = &mut app.quicknote;
    match key.code {
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            qn.buffer.insert_char(c);
            qn.dirty = true;
        }
        KeyCode::Enter => {
            qn.buffer.insert_newline();
            qn.dirty = true;
        }
        KeyCode::Backspace => {
            qn.buffer.backspace();
            qn.dirty = true;
        }
        KeyCode::Left => qn.buffer.move_left(),
        KeyCode::Right => qn.buffer.move_right(),
        KeyCode::Up => qn.buffer.move_up(),
        KeyCode::Down => qn.buffer.move_down(),
        KeyCode::Home => qn.buffer.move_line_start(),
        KeyCode::End => qn.buffer.move_line_end(),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Todo checklist
// -----------------------------------------------------------------------------

fn todo_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.todos.down(),
        KeyCode::Char('k') | KeyCode::Up => app.todos.up(),
        KeyCode::Char(' ') | KeyCode::Enter => {
            app.todos.toggle();
            app.save_todos();
        }
        KeyCode::Char('a') => start_prompt(app, "New todo", PromptAction::AddTodo, ""),
        KeyCode::Char('e') => {
            let cur = app.todos.selected_text().unwrap_or("").to_string();
            if !cur.is_empty() {
                start_prompt(app, "Edit todo", PromptAction::EditTodo, &cur);
            }
        }
        KeyCode::Char('d') | KeyCode::Delete => {
            app.todos.delete_selected();
            app.save_todos();
        }
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        _ => {}
    }
}
