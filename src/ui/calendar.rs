//! Monthly calendar — used as the bottom of the right sidebar and for
//! navigating daily notes.

use chrono::{Datelike, NaiveDate};
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::App;

pub fn draw(frame: &mut Frame, area: Rect, app: &App) {
    let theme = &app.theme;
    let cursor = app.calendar.cursor;
    let year = cursor.year();
    let month = cursor.month();
    let today = chrono::Local::now().date_naive();

    let first_of_month = NaiveDate::from_ymd_opt(year, month, 1).unwrap();
    let next_month_first = if month == 12 {
        NaiveDate::from_ymd_opt(year + 1, 1, 1).unwrap()
    } else {
        NaiveDate::from_ymd_opt(year, month + 1, 1).unwrap()
    };
    let days_in_month = next_month_first
        .signed_duration_since(first_of_month)
        .num_days() as u32;
    // Monday-first weekday index of the 1st.
    let lead = first_of_month.weekday().num_days_from_monday() as usize;

    let mut lines: Vec<Line<'static>> = Vec::new();
    lines.push(Line::from(vec![
        Span::styled(
            format!("◂ {} {} ▸", month_name(month), year),
            theme.s_accent().add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::raw(""));
    lines.push(Line::styled(
        "Mo Tu We Th Fr Sa Su".to_string(),
        theme.s_subtle(),
    ));

    let mut row: Vec<Span<'static>> = Vec::new();
    for _ in 0..lead {
        row.push(Span::raw("   "));
    }
    for d in 1..=days_in_month {
        let date = NaiveDate::from_ymd_opt(year, month, d).unwrap();
        let has_note = daily_note_exists(app, date);
        let is_today = date == today;
        let is_cursor = date == cursor;

        let style = if is_cursor && is_today {
            Style::default()
                .fg(theme.bg.to_color())
                .bg(theme.accent.to_color())
                .add_modifier(Modifier::BOLD)
        } else if is_cursor {
            theme.s_selection()
        } else if is_today {
            theme.s_accent().add_modifier(Modifier::BOLD)
        } else if has_note {
            Style::default().fg(theme.info.to_color())
        } else {
            theme.s_dim()
        };
        let label = format!("{:>2}", d);
        row.push(Span::styled(label, style));
        // A `·` after the number marks a day with Google Calendar events.
        if app.has_calendar_event(date) {
            row.push(Span::styled("·", theme.s_accent().add_modifier(Modifier::BOLD)));
        } else {
            row.push(Span::raw(" "));
        }
        if (lead + d as usize).is_multiple_of(7) {
            lines.push(Line::from(std::mem::take(&mut row)));
        }
    }
    if !row.is_empty() {
        lines.push(Line::from(row));
    }
    lines.push(Line::raw(""));
    lines.push(Line::styled(
        "h/l day · j/k week · v agenda · g sync · t today",
        theme.s_subtle(),
    ));

    let p = Paragraph::new(lines).style(theme.s_normal());
    frame.render_widget(p, area);
}

fn daily_note_exists(app: &App, date: NaiveDate) -> bool {
    let folder = &app.config.daily_notes.folder;
    let filename = date.format(&app.config.daily_notes.format).to_string();
    let path = app
        .vault
        .root
        .join(folder)
        .join(format!("{filename}.md"));
    path.exists()
}

fn month_name(m: u32) -> &'static str {
    match m {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        _ => "—",
    }
}
