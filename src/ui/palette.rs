//! Command palette overlay.

use fuzzy_matcher::skim::SkimMatcherV2;
use fuzzy_matcher::FuzzyMatcher;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::app::App;

#[derive(Debug, Clone, Copy)]
pub struct Command {
    pub label: &'static str,
    pub hint: &'static str,
    pub id: CommandId,
}

#[derive(Debug, Clone, Copy)]
pub enum CommandId {
    NewNote,
    SaveNote,
    QuickSwitcher,
    Search,
    OpenToday,
    OpenCalendar,
    ToggleGraph,
    TogglePreview,
    ToggleLeft,
    ToggleRight,
    ThemeDark,
    ThemeLight,
    ThemeDracula,
    ThemeNord,
    Help,
    OpenVault,
    DeleteNote,
    RenameNote,
    Quit,
}

pub const COMMANDS: &[Command] = &[
    Command { label: "New note",                hint: "Ctrl-N",       id: CommandId::NewNote },
    Command { label: "Save note",               hint: "Ctrl-S",       id: CommandId::SaveNote },
    Command { label: "Quick switcher",          hint: "Ctrl-O",       id: CommandId::QuickSwitcher },
    Command { label: "Vault search",            hint: "Ctrl-Shift-F", id: CommandId::Search },
    Command { label: "Open today's daily note", hint: "",             id: CommandId::OpenToday },
    Command { label: "Open calendar",           hint: "Ctrl-K",       id: CommandId::OpenCalendar },
    Command { label: "Toggle graph view",       hint: "Ctrl-G",       id: CommandId::ToggleGraph },
    Command { label: "Toggle preview",          hint: "Ctrl-E",       id: CommandId::TogglePreview },
    Command { label: "Toggle left sidebar",     hint: "Ctrl-B",       id: CommandId::ToggleLeft },
    Command { label: "Toggle right sidebar",    hint: "Ctrl-R",       id: CommandId::ToggleRight },
    Command { label: "Theme: Onyx Dark",        hint: "",             id: CommandId::ThemeDark },
    Command { label: "Theme: Onyx Light",       hint: "",             id: CommandId::ThemeLight },
    Command { label: "Theme: Dracula",          hint: "",             id: CommandId::ThemeDracula },
    Command { label: "Theme: Nord",             hint: "",             id: CommandId::ThemeNord },
    Command { label: "Help",                    hint: "Ctrl-/",       id: CommandId::Help },
    Command { label: "Open vault…",             hint: "",             id: CommandId::OpenVault },
    Command { label: "Delete current note",     hint: "",             id: CommandId::DeleteNote },
    Command { label: "Rename current note",     hint: "",             id: CommandId::RenameNote },
    Command { label: "Quit Onyx",               hint: "Ctrl-Q",       id: CommandId::Quit },
];

pub fn filtered(query: &str) -> Vec<(usize, Command)> {
    if query.trim().is_empty() {
        return COMMANDS.iter().enumerate().map(|(i, c)| (i, *c)).collect();
    }
    let matcher = SkimMatcherV2::default();
    let mut scored: Vec<(i64, usize, Command)> = COMMANDS
        .iter()
        .enumerate()
        .filter_map(|(i, c)| matcher.fuzzy_match(c.label, query).map(|s| (s, i, *c)))
        .collect();
    scored.sort_by_key(|x| std::cmp::Reverse(x.0));
    scored.into_iter().map(|(_, i, c)| (i, c)).collect()
}

pub fn draw(frame: &mut Frame, area: Rect, app: &mut App) {
    let theme = &app.theme;
    let rect = super::centered_rect(72, 22, area);
    frame.render_widget(Clear, rect);
    let block = super::pane_block("Command palette", true, theme);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0)])
        .split(inner);

    let prompt = Paragraph::new(Line::from(vec![
        Span::styled("❯ ", theme.s_accent().add_modifier(Modifier::BOLD)),
        Span::styled(app.palette.query.clone(), theme.s_normal()),
        Span::styled("▏", theme.s_accent().add_modifier(Modifier::SLOW_BLINK)),
    ]))
    .style(theme.s_normal());
    frame.render_widget(prompt, split[0]);

    let filtered = filtered(&app.palette.query);
    if app.palette.selected >= filtered.len() {
        app.palette.selected = filtered.len().saturating_sub(1);
    }
    let items: Vec<ListItem> = filtered
        .iter()
        .map(|(_, cmd)| {
            ListItem::new(Line::from(vec![
                Span::styled(cmd.label.to_string(), theme.s_normal()),
                Span::raw("  "),
                Span::styled(cmd.hint.to_string(), theme.s_subtle()),
            ]))
        })
        .collect();
    let mut state = ListState::default();
    if !items.is_empty() {
        state.select(Some(app.palette.selected));
    }
    let list = List::new(items)
        .highlight_style(theme.s_selection())
        .highlight_symbol(" ▸ ");
    frame.render_stateful_widget(list, split[1], &mut state);
}
