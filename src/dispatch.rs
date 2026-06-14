//! Keyboard dispatcher — routes key events to the focused pane.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::app::{
    self, App, ConfirmAction, Focus, HomeAction, PendingExternal, PromptAction, SidebarTab,
};
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
        Focus::Home => home_keys(app, key),
        Focus::Quicknote => quicknote_keys(app, key),
        Focus::Todo => todo_keys(app, key),
        Focus::Sidebar => sidebar_keys(app, key),
        Focus::Calendar => calendar_keys(app, key),
        Focus::Graph => graph_keys(app, key),
        Focus::Database => database_keys(app, key),
        Focus::Tasks => tasks_keys(app, key),
        Focus::Properties => props_keys(app, key),
        Focus::GoogleTasks => gtasks_keys(app, key),
        Focus::Agenda => agenda_keys(app, key),
        Focus::Drive => drive_keys(app, key),
        Focus::Ai => ai_keys(app, key),
        Focus::Settings => help_keys(app, key),
        Focus::Editor => editor_keys(app, key),
        Focus::Preview => preview_keys(app, key),
    }
}

/// Handles globally-bound chords. Returns true if consumed.
fn global_shortcut(app: &mut App, key: KeyEvent) -> bool {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let shift = key.modifiers.contains(KeyModifiers::SHIFT);

    // ESC handled per-focus below — except we want it to close graph too.
    if let KeyCode::Esc = key.code {
        // First Esc dismisses an open insert-mode popup but keeps insert mode.
        if app.link_complete.is_some() {
            app.cancel_link_complete();
            return true;
        }
        if app.slash_complete.is_some() {
            app.cancel_slash_complete();
            return true;
        }
        if app.tag_complete.is_some() {
            app.cancel_tag_complete();
            return true;
        }
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
                | Focus::Ai // AI chat input is a live text field
        );
        let in_insert = matches!(app.focus, Focus::Editor | Focus::Preview)
            && app
                .doc
                .as_ref()
                .map(|d| d.mode == Mode::Insert)
                .unwrap_or(false);
        // While typing into the database filter or a property field, `:` is text.
        let db_filtering = app.database.as_ref().map(|d| d.filtering).unwrap_or(false);
        let prop_editing = app.focus == Focus::Properties && app.props_edit.editing.is_some();
        if !in_text_overlay && !in_insert && !db_filtering && !prop_editing {
            app.open_cmdline();
            return true;
        }
    }

    if !ctrl {
        return false;
    }

    // The database view is modal: swallow other ctrl shortcuts (except quit) so
    // focus can't drift out from under it. Esc and `:` are handled above; plain
    // keys fall through to the database key handler.
    if app.database.is_some() && key.code != KeyCode::Char('q') {
        return true;
    }

    // Don't let global ctrl- shortcuts steal from text-entry/modal overlays.
    let in_text_overlay = matches!(
        app.focus,
        Focus::Palette | Focus::Switcher | Focus::Search | Focus::Prompt | Focus::Confirm | Focus::Ai
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
        KeyCode::Char('a') if !in_text_overlay => {
            app.open_ai();
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
        KeyCode::Char('w') if !in_text_overlay => {
            app.close_current_tab(false);
            true
        }
        KeyCode::PageDown if !in_text_overlay => {
            app.cycle_tab(1);
            true
        }
        KeyCode::PageUp if !in_text_overlay => {
            app.cycle_tab(-1);
            true
        }
        KeyCode::Char('e') if !in_text_overlay => {
            app.show_preview = !app.show_preview;
            true
        }
        KeyCode::Char('b') if !in_text_overlay => {
            app.show_left = !app.show_left;
            if !app.show_left && app.focus == Focus::FileTree {
                app.focus = app.center_focus();
            }
            true
        }
        KeyCode::Char('r') if !in_text_overlay => {
            app.show_right = !app.show_right;
            if !app.show_right && (app.focus == Focus::Sidebar || app.focus == Focus::Calendar) {
                app.focus = app.center_focus();
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
        // Move the editor|preview divider (Ctrl-← shrinks the editor, Ctrl-→ grows it).
        KeyCode::Left if !in_text_overlay => {
            app.resize_editor_split(-5);
            true
        }
        KeyCode::Right if !in_text_overlay => {
            app.resize_editor_split(5);
            true
        }
        KeyCode::Char('1') if !in_text_overlay => {
            if app.show_left {
                app.focus = Focus::FileTree;
            }
            true
        }
        KeyCode::Char('2') if !in_text_overlay => {
            app.focus = app.center_focus();
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
// Home start page
// -----------------------------------------------------------------------------

fn home_keys(app: &mut App, key: KeyEvent) {
    let len = app.home_items().len();
    match key.code {
        KeyCode::Char('j') | KeyCode::Down if len > 0 => {
            app.home_selected = (app.home_selected + 1).min(len - 1);
        }
        KeyCode::Char('k') | KeyCode::Up => {
            app.home_selected = app.home_selected.saturating_sub(1);
        }
        KeyCode::Char('g') => app.home_selected = 0,
        KeyCode::Char('G') => app.home_selected = len.saturating_sub(1),
        KeyCode::Enter | KeyCode::Char('l') | KeyCode::Char(' ') => {
            activate_home_selection(app);
        }
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        _ => {}
    }
}

/// Run the action under the Home cursor. New note/folder open a prompt here
/// (dispatch owns the prompt helper); everything else delegates to the App.
fn activate_home_selection(app: &mut App) {
    let items = app.home_items();
    let Some(item) = items.get(app.home_selected) else {
        return;
    };
    match item.action.clone() {
        HomeAction::NewNote => {
            start_prompt(app, "New note (path)", PromptAction::NewNote, "");
        }
        HomeAction::NewFolder => {
            start_prompt(app, "New folder (path)", PromptAction::NewFolder, "");
        }
        other => app.activate_home(other),
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
        // Open the selected folder (or the selected note's folder) as a database.
        KeyCode::Char('t') => {
            if let Some(node) = selected_node(app) {
                let folder = if node.is_dir {
                    node.path
                } else {
                    node.path
                        .parent()
                        .map(|p| p.to_path_buf())
                        .unwrap_or_else(|| app.vault.root.clone())
                };
                app.open_database(folder);
            }
        }
        // Pin/unpin the selected note.
        KeyCode::Char('b') => {
            if let Some(node) = selected_node(app) {
                if !node.is_dir {
                    app.toggle_bookmark(node.path);
                }
            }
        }
        _ => {}
    }
}

fn visible_tree_len(app: &App) -> usize {
    app.visible_tree().len()
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

fn toggle_expand(app: &mut App, path: std::path::PathBuf) {
    if !app.expanded_dirs.remove(&path) {
        app.expanded_dirs.insert(path);
    }
    app.invalidate_tree_view();
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
        Mode::Visual => editor_visual(app, key),
    }
}

/// Line-wise Visual mode: motions extend the selection; `d`/`y` delete/yank it,
/// `r` AI-rewrites it, `v`/`Esc` leave.
fn editor_visual(app: &mut App, key: KeyEvent) {
    // App-level actions (need &mut App).
    match key.code {
        KeyCode::Char('d') | KeyCode::Char('x') => {
            app.visual_delete();
            return;
        }
        KeyCode::Char('y') => {
            app.visual_yank();
            return;
        }
        KeyCode::Char('r') => {
            app.rewrite_selection(String::new());
            return;
        }
        KeyCode::Char('v') | KeyCode::Char('V') => {
            app.exit_visual();
            return;
        }
        _ => {}
    }
    // Motions extend the selection (anchor stays put).
    let doc = app.doc.as_mut().unwrap();
    let pending = doc.pending_op.take();
    match key.code {
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
        _ => {}
    }
}

fn editor_insert(app: &mut App, key: KeyEvent) {
    // While the `[[wikilink]]` autocomplete popup is open, it captures the
    // navigation / accept / dismiss keys; everything else types through and then
    // refreshes the popup below.
    if app.link_complete.is_some() {
        match key.code {
            KeyCode::Up => {
                app.link_complete_move(false);
                return;
            }
            KeyCode::Down => {
                app.link_complete_move(true);
                return;
            }
            KeyCode::Tab | KeyCode::Enter => {
                // The popup only exists with matches, so this always inserts.
                app.accept_link_complete();
                return;
            }
            // Esc is handled in global_shortcut (it dismisses the popup there).
            _ => {}
        }
    }

    // The `/` slash-command popup captures the same navigation keys.
    if app.slash_complete.is_some() {
        match key.code {
            KeyCode::Up => {
                app.slash_complete_move(false);
                return;
            }
            KeyCode::Down => {
                app.slash_complete_move(true);
                return;
            }
            KeyCode::Tab | KeyCode::Enter => {
                app.accept_slash_complete();
                return;
            }
            _ => {}
        }
    }

    // The `#tag` popup captures the same navigation keys.
    if app.tag_complete.is_some() {
        match key.code {
            KeyCode::Up => {
                app.tag_complete_move(false);
                return;
            }
            KeyCode::Down => {
                app.tag_complete_move(true);
                return;
            }
            KeyCode::Tab | KeyCode::Enter => {
                app.accept_tag_complete();
                return;
            }
            _ => {}
        }
    }

    {
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

    // Update (or dismiss) the insert-mode popups from the new cursor context.
    app.refresh_link_complete();
    app.refresh_slash_complete();
    app.refresh_tag_complete();
}

fn editor_normal(app: &mut App, key: KeyEvent) {
    // Ctrl-Enter follows wikilink at cursor.
    if key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('m') | KeyCode::Enter) {
        follow_wikilink_at_cursor(app);
        return;
    }
    // `t` toggles a `- [ ]` checkbox on the current line (needs &mut App, so
    // handle it before borrowing the doc below).
    if key.code == KeyCode::Char('t') && key.modifiers.is_empty() {
        app.toggle_task_on_current_line();
        return;
    }
    // Paste the yank register (line-wise) — needs &mut App.
    if key.code == KeyCode::Char('p') && key.modifiers.is_empty() {
        app.paste_register(true);
        return;
    }
    if key.code == KeyCode::Char('P') && key.modifiers.is_empty() {
        app.paste_register(false);
        return;
    }
    // Enter (line-wise) Visual selection.
    if matches!(key.code, KeyCode::Char('v') | KeyCode::Char('V')) && key.modifiers.is_empty() {
        app.enter_visual();
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
// Inline property editor
// -----------------------------------------------------------------------------

fn props_keys(app: &mut App, key: KeyEvent) {
    // While editing a field, capture text input. (Esc cancels via global_shortcut.)
    if let Some(edit) = app.props_edit.editing.as_mut() {
        match key.code {
            KeyCode::Enter => app.props_commit_edit(),
            KeyCode::Backspace => {
                edit.buffer.pop();
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                edit.buffer.push(c);
            }
            _ => {}
        }
        return;
    }
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.props_move(1),
        KeyCode::Char('k') | KeyCode::Up => app.props_move(-1),
        KeyCode::Char('e') | KeyCode::Enter => app.props_begin_edit(),
        KeyCode::Char('a') => app.props_begin_add(),
        KeyCode::Char('d') => app.props_delete_selected(),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Google Tasks overlay
// -----------------------------------------------------------------------------

fn gtasks_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.gtasks_move(1),
        KeyCode::Char('k') | KeyCode::Up => app.gtasks_move(-1),
        KeyCode::Char('g') | KeyCode::Home => app.gtasks_move(i64::MIN / 2),
        KeyCode::Char('G') | KeyCode::End => app.gtasks_move(i64::MAX / 2),
        // Two-way: Space toggles complete, d deletes (both write to Google).
        KeyCode::Char(' ') => app.gtasks_toggle_selected(),
        KeyCode::Char('d') => app.gtasks_delete_selected(),
        // Enter pulls the task into the quicknote scratch.
        KeyCode::Enter | KeyCode::Char('p') => app.gtasks_pull_selected(),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Task rollup overlay
// -----------------------------------------------------------------------------

fn tasks_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.tasks_move(1),
        KeyCode::Char('k') | KeyCode::Up => app.tasks_move(-1),
        KeyCode::Char('g') | KeyCode::Home => app.tasks_move(i64::MIN / 2),
        KeyCode::Char('G') | KeyCode::End => app.tasks_move(i64::MAX / 2),
        KeyCode::Enter | KeyCode::Char('o') => app.tasks_open_selected(),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Preview (read-only) — navigate & toggle collapsible callouts
// -----------------------------------------------------------------------------

fn preview_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        KeyCode::Char('j') | KeyCode::Down => app.preview_fold_move(1),
        KeyCode::Char('k') | KeyCode::Up => app.preview_fold_move(-1),
        KeyCode::Char('g') => app.preview_fold_move(i64::MIN / 2),
        KeyCode::Char('G') => app.preview_fold_move(i64::MAX / 2),
        KeyCode::Char(' ') | KeyCode::Enter => app.preview_fold_toggle(),
        _ => {}
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
        SidebarTab::Pages => {
            let current = match app.doc.as_ref().and_then(|d| d.path.clone()) {
                Some(p) => p,
                None => return,
            };
            let entries =
                crate::page_nav::page_entries(&app.vault.tree, &app.vault.root, &current);
            if let Some(e) = entries.get(app.sidebar_selected) {
                let target = e.target.clone();
                let _ = app.open_note(target);
                app.sidebar_selected = 0;
            }
        }
        SidebarTab::Backlinks => {
            let path = match app.doc.as_ref().and_then(|d| d.path.clone()) {
                Some(p) => p,
                None => return,
            };
            // Rows are backlinks then unlinked mentions; open whichever is selected.
            let rows = app.backlink_rows(&path);
            if let Some((p, _unlinked)) = rows.get(app.sidebar_selected).cloned() {
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
            // Jump the editor cursor to the selected heading.
            app.jump_to_heading(app.sidebar_selected);
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
        // `v` opens the day's Google agenda; `g` re-syncs the month.
        KeyCode::Char('v') => {
            app.open_agenda();
            return;
        }
        KeyCode::Char('g') => {
            app.start_calendar_sync();
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
    // A month change auto-fetches its events (when opted in).
    app.maybe_autosync_calendar();
}

// -----------------------------------------------------------------------------
// Google Drive browser overlay
// -----------------------------------------------------------------------------

fn drive_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.drive_move(1),
        KeyCode::Char('k') | KeyCode::Up => app.drive_move(-1),
        KeyCode::Enter | KeyCode::Char('l') | KeyCode::Right => app.drive_enter(),
        KeyCode::Backspace | KeyCode::Char('h') | KeyCode::Char('-') | KeyCode::Left => app.drive_up(),
        KeyCode::Char('u') => app.upload_current_to_drive(),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Local AI assistant (Ollama) chat overlay — a live text field
// -----------------------------------------------------------------------------

fn ai_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Esc => app.close_ai(),
        KeyCode::Enter => app.ai_submit(),
        KeyCode::Backspace => app.ai_input_backspace(),
        KeyCode::PageUp => app.ai_scroll(5),   // toward older output
        KeyCode::PageDown => app.ai_scroll(-5),
        KeyCode::Char(c) => app.ai_input_char(c),
        _ => {}
    }
}

// -----------------------------------------------------------------------------
// Day-agenda overlay (Google Calendar)
// -----------------------------------------------------------------------------

fn agenda_keys(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.agenda_move(1),
        KeyCode::Char('k') | KeyCode::Up => app.agenda_move(-1),
        KeyCode::Char('a') => start_prompt(app, "New event (all-day, selected day)", PromptAction::AddEvent, ""),
        KeyCode::Char('d') | KeyCode::Delete => app.agenda_delete_selected(),
        _ => {}
    }
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
                match app.vault.rename_with_backlinks(&p, &target) {
                    Err(e) => app.set_status(format!("rename failed: {e}")),
                    Ok(updated) => {
                        if let Some(doc) = app.doc.as_mut() {
                            if doc.path.as_deref() == Some(p.as_path()) {
                                doc.path = Some(target.clone());
                            }
                        }
                        for tp in app.tab_paths.iter_mut() {
                            if *tp == p {
                                *tp = target.clone();
                            }
                        }
                        let note = vault::note_basename(&target);
                        app.set_status(match updated {
                            0 => format!("renamed to {note}"),
                            1 => format!("renamed to {note} · 1 note relinked"),
                            n => format!("renamed to {note} · {n} notes relinked"),
                        });
                    }
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
        PromptAction::AddEvent => {
            app.agenda_add_event(v);
            app.focus = Focus::Agenda;
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
        KeyCode::Char('j') | KeyCode::Down => app.help_scroll_by(1),
        KeyCode::Char('k') | KeyCode::Up => app.help_scroll_by(-1),
        KeyCode::Char('d') | KeyCode::PageDown => app.help_scroll_by(10),
        KeyCode::Char('u') | KeyCode::PageUp => app.help_scroll_by(-10),
        KeyCode::Char('g') | KeyCode::Home => app.help_scroll = 0,
        KeyCode::Char('G') | KeyCode::End => app.help_scroll_by(i64::MAX / 2),
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
        "w!" | "write!" => match app.force_save_current() {
            Ok(()) => {}
            Err(e) => app.set_status(format!("write failed: {e}")),
        },
        "wq" | "x" => match app.save_current() {
            Ok(()) => app.should_quit = true,
            Err(e) => app.set_status(format!("write failed: {e}")),
        },
        "wq!" | "x!" => match app.force_save_current() {
            Ok(()) => app.should_quit = true,
            Err(e) => app.set_status(format!("write failed: {e}")),
        },
        "e!" | "edit!" => {
            if args.is_empty() {
                app.reload_current();
            } else if let Some(p) = app.vault.resolve_link(args) {
                if let Err(e) = app.open_note(p) {
                    app.set_status(format!("open failed: {e}"));
                }
            } else {
                app.set_status(format!("E447: can't find note \"{args}\""));
            }
        }
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
        "notion" => {
            // `:notion import <unzipped-export-folder>` (path may contain spaces).
            match args.strip_prefix("import").map(str::trim) {
                Some(p) if !p.is_empty() => {
                    let path = expand_tilde(p);
                    app.import_notion(&path);
                }
                _ => app.set_status("usage: :notion import <unzipped-export-folder>"),
            }
        }
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
        "task" | "toggle" => app.toggle_task_on_current_line(),
        "tasks" => app.open_tasks(),
        "google" | "gauth" => match args {
            "" | "auth" => app.request_google_auth(),
            "tasks" => app.open_gtasks(),
            other => app.set_status(format!("usage: :google auth | :google tasks (got '{other}')")),
        },
        "gtasks" => match args.split_once(char::is_whitespace) {
            Some(("add", title)) => app.gtasks_add_task(title),
            _ if args == "auth" => app.request_google_auth(),
            _ if args == "add" => app.set_status("usage: :gtasks add <title>"),
            _ => app.open_gtasks(),
        },
        "props" | "properties" | "prop" => app.open_props_editor(),
        "bookmark" | "pin" => app.toggle_bookmark_current(),
        "tabnext" | "tabn" | "bnext" | "bn" => app.cycle_tab(1),
        "tabprev" | "tabprevious" | "tabp" | "bprev" | "bp" => app.cycle_tab(-1),
        "tabclose" | "tabc" | "bd" | "bdelete" => app.close_current_tab(false),
        "tabclose!" | "tabc!" | "bd!" | "bdelete!" => app.close_current_tab(true),
        "graph" => app.open_graph(),
        "up" | "parent" => {
            match app.doc.as_ref().and_then(|d| d.path.clone()) {
                Some(cur) => {
                    match crate::page_nav::parent_page(&app.vault.tree, &app.vault.root, &cur) {
                        Some(p) => {
                            if let Err(e) = app.open_note(p) {
                                app.set_status(format!("open failed: {e}"));
                            }
                        }
                        None => app.set_status("already at the top of this branch"),
                    }
                }
                None => app.set_status("no note open"),
            }
        }
        "database" | "db" | "table" => open_database_cmd(app, args, false),
        "board" | "kanban" => open_database_cmd(app, args, true),
        "calendar" | "cal" => {
            if args == "sync" {
                app.start_calendar_sync();
            } else {
                app.open_calendar();
            }
        }
        "agenda" => {
            app.open_calendar();
            app.open_agenda();
        }
        "drive" | "gdrive" => {
            if matches!(args.trim(), "upload" | "put") {
                app.upload_current_to_drive();
            } else {
                app.open_drive_browser();
            }
        }
        "ai" | "chat" => {
            let a = args.trim();
            if a == "models" {
                app.ai_list_models();
            } else if let Some(m) = a.strip_prefix("model") {
                app.ai_set_model(m.trim());
            } else if a == "clear" {
                app.ai_clear();
                app.open_ai();
            } else if a.is_empty() {
                app.open_ai();
            } else {
                app.ai_prompt(a.to_string());
            }
        }
        "summarize" | "summary" | "tldr" => app.summarize_current(),
        "ask" | "askvault" => {
            if args.trim().is_empty() {
                app.set_status("usage: :ask <question> — searches your whole vault");
            } else {
                app.ask_vault(args.to_string());
            }
        }
        // Visual selection if active, else paragraph (`:rewrite all` → whole note).
        "rewrite" | "rw" => app.rewrite_command(args),
        "todo" | "todos" => {
            if args == "sync" {
                app.start_gtasks_sync();
            } else {
                app.focus_todo();
            }
        }
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
        "vsplit" | "split" | "vs" => {
            if args.is_empty() {
                app.toggle_split();
            } else if let Some(p) = app.vault.resolve_link(args) {
                app.split_with(p);
            } else {
                app.set_status(format!("E447: can't find note \"{args}\""));
            }
        }
        "only" | "unsplit" => app.split_doc = None,
        "swap" => app.swap_split(),
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
                match app.vault.rename_with_backlinks(&p, &target) {
                    Err(e) => app.set_status(format!("rename failed: {e}")),
                    Ok(updated) => {
                        if let Some(doc) = app.doc.as_mut() {
                            doc.path = Some(target.clone());
                        }
                        for tp in app.tab_paths.iter_mut() {
                            if *tp == p {
                                *tp = target.clone();
                            }
                        }
                        let note = vault::note_basename(&target);
                        app.set_status(match updated {
                            0 => format!("renamed to {note}"),
                            n => format!("renamed to {note} · {n} relinked"),
                        });
                    }
                }
            }
        }
        other => {
            app.set_status(format!("E492: not an editor command: {other}"));
        }
    }
}

/// Open a folder as a database view. `args` is an optional vault-relative (or
/// absolute) folder; empty means "infer from context" (the open note's folder,
/// the file-tree selection, or the vault root). `board` opens in board mode.
fn open_database_cmd(app: &mut App, args: &str, board: bool) {
    let Some(folder) = resolve_db_folder(app, args) else {
        app.set_status(format!("E447: no such folder \"{args}\""));
        return;
    };
    app.open_database(folder);
    if board {
        if let Some(db) = app.database.as_mut() {
            if db.mode != crate::db_view::DbViewMode::Board {
                db.toggle_mode();
            }
        }
    }
}

/// Resolve the folder a database command should target.
fn resolve_db_folder(app: &App, args: &str) -> Option<std::path::PathBuf> {
    if !args.is_empty() {
        let direct = std::path::PathBuf::from(args);
        let p = if direct.is_absolute() {
            direct
        } else {
            app.vault.root.join(args)
        };
        return p.is_dir().then_some(p);
    }
    // Current note's folder, else the file-tree selection, else the vault root.
    if let Some(parent) = app.doc.as_ref().and_then(|d| d.path.clone()).and_then(|p| p.parent().map(|x| x.to_path_buf())) {
        return Some(parent);
    }
    if let Some(node) = selected_node(app) {
        return Some(if node.is_dir {
            node.path
        } else {
            node.path.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| app.vault.root.clone())
        });
    }
    Some(app.vault.root.clone())
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
    if let Some(val) = args
        .strip_prefix("editor-width=")
        .or_else(|| args.strip_prefix("editorwidth="))
        .map(str::trim)
    {
        match val.parse::<i16>() {
            Ok(pct) => {
                // Set absolutely by nudging from the current value.
                let cur = app.config.layout.editor_split_percent as i16;
                app.resize_editor_split(pct - cur);
            }
            Err(_) => app.set_status("usage: :set editor-width=<20-80>"),
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

/// Expand a leading `~` to the user's home directory.
fn expand_tilde(p: &str) -> std::path::PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    if p == "~" {
        if let Some(home) = dirs::home_dir() {
            return home;
        }
    }
    std::path::PathBuf::from(p)
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
// Database view (table / board over a folder)
// -----------------------------------------------------------------------------

fn database_keys(app: &mut App, key: KeyEvent) {
    // Opening a row needs `&mut app`, so handle it before borrowing the view.
    let filtering = app.database.as_ref().map(|d| d.filtering).unwrap_or(false);
    if !filtering && matches!(key.code, KeyCode::Enter | KeyCode::Char('o') | KeyCode::Char('l'))
    {
        let path = app.database.as_ref().and_then(|d| d.selected_path());
        if let Some(p) = path {
            app.database = None;
            if let Err(e) = app.open_note(p) {
                app.set_status(format!("open failed: {e}"));
            }
        }
        return;
    }

    // Moving a board card needs &mut App, so handle it before borrowing the view.
    if !filtering && matches!(key.code, KeyCode::Char('H') | KeyCode::Char('L')) {
        let dir = if key.code == KeyCode::Char('L') { 1 } else { -1 };
        app.board_move_card(dir);
        return;
    }

    let Some(db) = app.database.as_mut() else {
        return;
    };

    // Filter-edit mode captures text input live.
    if db.filtering {
        match key.code {
            KeyCode::Enter => db.filtering = false,
            KeyCode::Backspace => {
                db.filter.pop();
                db.clamp();
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                db.filter.push(c);
                db.clamp();
            }
            _ => {}
        }
        return;
    }

    match key.code {
        KeyCode::Char('j') | KeyCode::Down => db.move_sel(1),
        KeyCode::Char('k') | KeyCode::Up => db.move_sel(-1),
        KeyCode::Char('h') | KeyCode::Left => db.move_horiz(-1),
        KeyCode::Char('l') | KeyCode::Right => db.move_horiz(1),
        KeyCode::Char('g') | KeyCode::Home => db.goto_first(),
        KeyCode::Char('G') | KeyCode::End => db.goto_last(),
        KeyCode::Char('t') | KeyCode::Tab => db.toggle_mode(),
        KeyCode::Char('s') => db.cycle_sort(),
        KeyCode::Char('S') => {
            db.sort_desc = !db.sort_desc;
            db.clamp();
        }
        KeyCode::Char('[') => db.cycle_group(false),
        KeyCode::Char(']') => db.cycle_group(true),
        KeyCode::Char('/') => db.filtering = true,
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
        KeyCode::Char('j') | KeyCode::Down => app.todo_move(1),
        KeyCode::Char('k') | KeyCode::Up => app.todo_move(-1),
        KeyCode::Char(' ') | KeyCode::Enter => app.todo_toggle_selected(),
        KeyCode::Char('a') => start_prompt(app, "New todo", PromptAction::AddTodo, ""),
        KeyCode::Char('e') => {
            // Editing is local-only (Google task titles aren't edited here).
            if app.todo_selected_is_google() {
                app.set_status("editing Google tasks here isn't supported — use :gtasks");
            } else if let Some(crate::app::TodoSource::Local(i)) = app.todo_selected_source() {
                app.todos.selected = i;
                let cur = app.todos.selected_text().unwrap_or("").to_string();
                if !cur.is_empty() {
                    start_prompt(app, "Edit todo", PromptAction::EditTodo, &cur);
                }
            }
        }
        KeyCode::Char('d') | KeyCode::Delete => app.todo_delete_selected(),
        // Sync Google tasks into the pane (background).
        KeyCode::Char('s') => app.start_gtasks_sync(),
        KeyCode::Tab => app.toggle_pane_focus(true),
        KeyCode::BackTab => app.toggle_pane_focus(false),
        _ => {}
    }
}
